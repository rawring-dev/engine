//! Recursive-descent and Pratt parser for `../../grammar.ebnf`.
//!
//! Layout is driven by the lexer's virtual `newline` / `indent` / `dedent`
//! tokens.  Brace blocks are explicit and ignore formatting indentation;
//! colon blocks consume the indentation tokens directly.  The parser is
//! intentionally permissive about blank lines and semicolons while still
//! requiring the grammar's structural tokens.

const std = @import("std");
const ast = @import("ast.zig");
const syntax = @import("syntax.zig");
const lexer = @import("lexer.zig");

pub const Diagnostic = syntax.Diagnostic;

pub const Ast = struct {
    arena: std.heap.ArenaAllocator,
    module: *ast.Module,
    tokens: []syntax.Token,
    source: []const u8,

    pub fn deinit(self: *Ast) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ParseResult = union(enum) {
    ast: Ast,
    diagnostic: Diagnostic,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_allocator = arena.allocator();

    const lexed = lexer.lex(arena_allocator, source) catch |err| {
        arena.deinit();
        return err;
    };
    if (lexed.diagnostic) |diagnostic| {
        arena.deinit();
        return .{ .diagnostic = .{
            .offset = diagnostic.offset,
            .line = diagnostic.line,
            .column = diagnostic.column,
            .message = diagnostic.message,
        } };
    }

    var parser = Parser{
        .allocator = arena_allocator,
        .tokens = lexed.tokens,
    };
    const module = parser.parseModule() catch |err| switch (err) {
        error.OutOfMemory => {
            arena.deinit();
            return error.OutOfMemory;
        },
        error.ParseFailed => {
            const diagnostic = parser.diagnostic orelse Diagnostic{
                .message = "parse failed",
            };
            arena.deinit();
            return .{ .diagnostic = diagnostic };
        },
    };

    return .{ .ast = .{
        .arena = arena,
        .module = module,
        .tokens = lexed.tokens,
        .source = source,
    } };
}

const ParserError = error{ OutOfMemory, ParseFailed };

const ExprOptions = struct {
    allow_struct_literal: bool = true,
};

const TableFields = struct {
    fields: []ast.Field,
    has_ellipsis: bool,
};

const Infix = struct {
    op: ast.BinaryOp,
    bp: u8,
    right_assoc: bool = false,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []syntax.Token,
    index: usize = 0,
    diagnostic: ?Diagnostic = null,
    spans: ast.SpanMap = .empty,

    // ------------------------------------------------------------------
    // Token helpers
    // ------------------------------------------------------------------

    fn peek(self: *const Parser) *const syntax.Token {
        return &self.tokens[@min(self.index, self.tokens.len - 1)];
    }

    fn peekAt(self: *const Parser, n: usize) *const syntax.Token {
        return &self.tokens[@min(self.index + n, self.tokens.len - 1)];
    }

    fn at(self: *const Parser, kind: syntax.TokenKind) bool {
        return self.peek().kind == kind;
    }

    fn advance(self: *Parser) *const syntax.Token {
        const token = self.peek();
        if (self.index + 1 < self.tokens.len) self.index += 1;
        return token;
    }

    fn match(self: *Parser, kind: syntax.TokenKind) ?*const syntax.Token {
        if (!self.at(kind)) return null;
        return self.advance();
    }

    fn expect(self: *Parser, kind: syntax.TokenKind, message: []const u8) ParserError!*const syntax.Token {
        if (!self.at(kind)) return self.fail(message);
        return self.advance();
    }

    fn fail(self: *Parser, message: []const u8) ParserError {
        if (self.diagnostic == null) {
            const token = self.peek();
            self.diagnostic = .{
                .offset = token.offset,
                .line = token.line,
                .column = token.column,
                .message = message,
            };
        }
        return error.ParseFailed;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.at(.newline)) _ = self.advance();
    }

    fn skipSeparators(self: *Parser) void {
        while (self.at(.newline) or self.at(.semicolon)) _ = self.advance();
    }

    fn skipBraceNoise(self: *Parser) void {
        while (self.at(.newline) or self.at(.semicolon) or self.at(.indent) or self.at(.dedent)) {
            _ = self.advance();
        }
    }

    // ------------------------------------------------------------------
    // Allocation helpers
    // ------------------------------------------------------------------

    fn createExpr(self: *Parser, value: ast.Expr) ParserError!*ast.Expr {
        const node = try self.allocator.create(ast.Expr);
        node.* = value;
        return node;
    }

    fn createType(self: *Parser, value: ast.Type) ParserError!*ast.Type {
        const node = try self.allocator.create(ast.Type);
        node.* = value;
        return node;
    }

    fn createPattern(self: *Parser, value: ast.Pattern) ParserError!*ast.Pattern {
        const node = try self.allocator.create(ast.Pattern);
        node.* = value;
        return node;
    }

    fn createStmt(self: *Parser, value: ast.Stmt, start: usize) ParserError!*ast.Stmt {
        const node = try self.allocator.create(ast.Stmt);
        node.* = value;
        try self.recordSpan(node, start);
        return node;
    }

    fn createBlock(self: *Parser, entries: []ast.Entry) ParserError!*ast.Block {
        const node = try self.allocator.create(ast.Block);
        node.* = .{ .entries = entries };
        return node;
    }

    fn createItem(self: *Parser, attrs: []ast.Attribute, visibility: ?ast.Visibility, kind: ast.ItemKind, start: usize) ParserError!*ast.Item {
        const node = try self.allocator.create(ast.Item);
        node.* = .{
            .attributes = attrs,
            .visibility = visibility,
            .kind = kind,
        };
        try self.recordSpan(node, start);
        return node;
    }

    fn recordSpan(self: *Parser, pointer: anytype, start: usize) ParserError!void {
        const token = if (start < self.tokens.len) self.tokens[start] else self.peek().*;
        try self.spans.put(self.allocator, @intFromPtr(pointer), .{
            .offset = token.offset,
            .line = token.line,
            .column = token.column,
        });
    }

    fn pathOf(self: *Parser, segments: []ast.PathSegment) ast.Path {
        _ = self;
        return .{ .segments = segments };
    }

    // ------------------------------------------------------------------
    // Module and items
    // ------------------------------------------------------------------

    fn parseModule(self: *Parser) ParserError!*ast.Module {
        var items = std.ArrayList(*ast.Item).empty;
        self.skipSeparators();
        while (!self.at(.eof)) {
            if (self.at(.indent) or self.at(.dedent)) {
                return self.fail("unexpected layout token at module scope");
            }
            try items.append(self.allocator, try self.parseItem());
            self.skipSeparators();
        }
        const node = try self.allocator.create(ast.Module);
        node.* = .{
            .items = try items.toOwnedSlice(self.allocator),
            .spans = self.spans,
        };
        return node;
    }

    fn parseItem(self: *Parser) ParserError!*ast.Item {
        const start = self.index;
        const attrs = try self.parseAttributes();
        const visibility = try self.parseVisibility();
        const kind = try self.parseItemKind();
        return self.createItem(attrs, visibility, kind, start);
    }

    fn parseItemKind(self: *Parser) ParserError!ast.ItemKind {
        return switch (self.peek().kind) {
            .kw_use => .{ .use = try self.parseUseDecl() },
            .kw_mod => .{ .mod = try self.parseModDecl() },
            .kw_impl => .{ .impl = try self.parseImplDecl() },
            .kw_trait => .{ .trait_decl = try self.parseTraitDecl() },
            .identifier => try self.parseNamedItem(),
            else => self.fail("expected an item"),
        };
    }

    fn parseNamedItem(self: *Parser) ParserError!ast.ItemKind {
        const name_token = try self.expect(.identifier, "expected item name");
        const name = name_token.lexeme;
        const generics = try self.parseOptionalGenericParams();

        if (self.match(.bind_mutable) != null) {
            return .{ .binding = try self.parseBindingValue(name, null, true) };
        }

        if (self.match(.bind_immutable) != null) {
            switch (self.peek().kind) {
                .kw_struct => return .{ .struct_decl = try self.parseStructAfterName(name, generics) },
                .kw_enum => return .{ .enum_decl = try self.parseEnumAfterName(name, generics) },
                .kw_table => return .{ .table_decl = try self.parseTableAfterName(name, generics) },
                .kw_trigger => return .{ .trigger_decl = try self.parseTriggerAfterName(name, generics) },
                .kw_sys => return .{ .sys = try self.parseSysAfterName(name, generics) },
                .kw_plugin => return .{ .plugin_decl = try self.parsePluginAfterName(name, generics) },
                .kw_trait => return .{ .trait_decl = try self.parseTraitAfterName(name, generics) },
                else => {},
            }
            if (self.looksLikeFunctionSignatureAt(self.index)) {
                return .{ .function = try self.parseFunctionAfterSignature(name, generics) };
            }
            return .{ .binding = try self.parseBindingValue(name, null, false) };
        }

        if (self.match(.colon) != null) {
            const ty = try self.parseType();
            const op = self.peek().kind;
            if (op != .bind_immutable and op != .bind_mutable) {
                switch (op) {
                    .newline, .semicolon, .eof => {
                        return .{ .uninitialized = .{ .name = name, .ty = ty, .mutable = true } };
                    },
                    else => return self.fail("expected `<-` or `:=` after binding type"),
                }
            }
            _ = self.advance();
            return .{ .binding = try self.parseBindingValue(name, ty, op == .bind_mutable) };
        }

        return self.fail("expected `<-` or `:` after item name");
    }

    fn parseBindingValue(
        self: *Parser,
        name: []const u8,
        ty: ?*ast.Type,
        mutable: bool,
    ) ParserError!ast.Binding {
        return .{
            .name = name,
            .ty = ty,
            .mutable = mutable,
            .value = try self.parseAssignmentValue(),
        };
    }

    /// Parses the value of a binding or assignment.
    ///
    /// Besides the usual same-line expression, e7 accepts the value as an
    /// indented continuation block:
    ///
    ///     colour <-
    ///         if focused: white
    ///         else: grey
    ///
    /// The indentation is a layout container for exactly one expression; it
    /// ends at the matching `dedent`.  This keeps long right-hand sides
    /// readable without inventing a wrapping token, and the formatter uses it
    /// when a binding/assignment does not fit on one line.
    fn parseAssignmentValue(self: *Parser) ParserError!*ast.Expr {
        if (self.at(.newline) and self.peekAt(1).kind == .indent) {
            _ = self.advance();
            _ = try self.expect(.indent, "expected an indented value after assignment");
            const value = try self.parseExpression();
            self.skipSeparators();
            _ = try self.expect(.dedent, "expected dedent after the indented value");
            return value;
        }
        return self.parseExpression();
    }

    // ------------------------------------------------------------------
    // Attributes and visibility
    // ------------------------------------------------------------------

    fn parseAttributes(self: *Parser) ParserError![]ast.Attribute {
        var attrs = std.ArrayList(ast.Attribute).empty;
        while (self.at(.at)) {
            _ = self.advance();
            const path = try self.parseAttributePath();
            var args = std.ArrayList(*ast.Expr).empty;
            if (self.match(.lparen) != null) {
                if (!self.at(.rparen)) {
                    while (true) {
                        try args.append(self.allocator, try self.parseExpression());
                        if (self.match(.comma) == null) break;
                        if (self.at(.rparen)) break;
                    }
                }
                _ = try self.expect(.rparen, "expected `)` after attribute arguments");
            }
            try attrs.append(self.allocator, .{
                .path = path,
                .args = try args.toOwnedSlice(self.allocator),
            });
            // Attributes may be written on lines preceding their item.
            self.skipNewlines();
        }
        return attrs.toOwnedSlice(self.allocator);
    }

    fn parseAttributePath(self: *Parser) ParserError!ast.Path {
        var segments = std.ArrayList(ast.PathSegment).empty;
        var root = try self.parseAttributeSegment();
        while (true) {
            try segments.append(self.allocator, .{ .name = root.lexeme, .args = &.{} });
            if (self.match(.colon_colon) == null) break;
            root = try self.parseAttributeSegment();
        }
        return self.pathOf(try segments.toOwnedSlice(self.allocator));
    }

    fn parseAttributeSegment(self: *Parser) ParserError!*const syntax.Token {
        const token = self.peek();
        if (token.kind == .identifier or syntax.isKeywordKind(token.kind)) {
            return self.advance();
        }
        return self.fail("expected attribute path");
    }

    fn parseVisibility(self: *Parser) ParserError!?ast.Visibility {
        if (self.match(.kw_pub) == null) return null;
        var scope: ?ast.VisibilityScope = null;
        if (self.match(.lparen) != null) {
            scope = switch (self.peek().kind) {
                .kw_crate => blk: {
                    _ = self.advance();
                    break :blk .crate;
                },
                .kw_self => blk: {
                    _ = self.advance();
                    break :blk .self;
                },
                .kw_super => blk: {
                    _ = self.advance();
                    break :blk .super;
                },
                .kw_in => blk: {
                    _ = self.advance();
                    break :blk .{ .in_path = try self.parsePath(false) };
                },
                else => return self.fail("expected visibility scope"),
            };
            _ = try self.expect(.rparen, "expected `)` after visibility scope");
        }
        return .{ .scope = scope };
    }

    // ------------------------------------------------------------------
    // use / mod
    // ------------------------------------------------------------------

    fn parseUseDecl(self: *Parser) ParserError!ast.UseDecl {
        _ = try self.expect(.kw_use, "expected `use`");
        const tree = try self.parseUseTree();
        _ = try self.expect(.semicolon, "expected `;` after use declaration");
        return .{ .tree = tree };
    }

    fn parseUseTree(self: *Parser) ParserError!ast.UseTree {
        var segments = std.ArrayList(ast.PathSegment).empty;
        try segments.append(self.allocator, .{
            .name = (try self.parsePathRoot()).lexeme,
            .args = &.{},
        });

        while (self.match(.colon_colon) != null) {
            if (self.match(.star) != null) {
                return .{ .glob = self.pathOf(try segments.toOwnedSlice(self.allocator)) };
            }
            if (self.match(.lbrace) != null) {
                var trees = std.ArrayList(ast.UseTree).empty;
                if (!self.at(.rbrace)) {
                    while (true) {
                        try trees.append(self.allocator, try self.parseUseTree());
                        if (self.match(.comma) == null) break;
                        if (self.at(.rbrace)) break;
                    }
                }
                _ = try self.expect(.rbrace, "expected `}` in use group");
                return .{ .group = .{
                    .prefix = self.pathOf(try segments.toOwnedSlice(self.allocator)),
                    .trees = try trees.toOwnedSlice(self.allocator),
                } };
            }
            try segments.append(self.allocator, .{
                .name = (try self.expect(.identifier, "expected path segment")).lexeme,
                .args = &.{},
            });
        }

        var alias: ?[]const u8 = null;
        if (self.match(.kw_as) != null) {
            alias = (try self.expect(.identifier, "expected alias name")).lexeme;
        }
        return .{ .path = .{
            .path = self.pathOf(try segments.toOwnedSlice(self.allocator)),
            .alias = alias,
        } };
    }

    fn parseModDecl(self: *Parser) ParserError!ast.ModDecl {
        _ = try self.expect(.kw_mod, "expected `mod`");
        const name = (try self.expect(.identifier, "expected module name")).lexeme;
        if (self.match(.semicolon) != null) {
            return .{ .name = name, .items = null };
        }
        // `mod ui` followed by a newline or EOF is an external module
        // reference (the DX spelling in engine/main.e7).  A `{` introduces an
        // inline body instead.
        switch (self.peek().kind) {
            .newline, .dedent, .eof => return .{ .name = name, .items = null },
            else => {},
        }
        _ = try self.expect(.lbrace, "expected `;`, a newline, or `{` after module name");
        var items = std.ArrayList(*ast.Item).empty;
        self.skipBraceNoise();
        while (!self.at(.rbrace) and !self.at(.eof)) {
            try items.append(self.allocator, try self.parseItem());
            self.skipBraceNoise();
        }
        _ = try self.expect(.rbrace, "expected `}` after module body");
        return .{ .name = name, .items = try items.toOwnedSlice(self.allocator) };
    }

    // ------------------------------------------------------------------
    // Type declarations
    // ------------------------------------------------------------------

    fn parseStructAfterName(self: *Parser, name: []const u8, generics: []ast.GenericParam) ParserError!ast.StructDecl {
        _ = try self.expect(.kw_struct, "expected `struct`");
        const where_clause = try self.parseOptionalWhereClause();
        const fields = try self.parseRecordBody();
        return .{ .name = name, .generics = generics, .where_clause = where_clause, .fields = fields };
    }

    fn parseEnumAfterName(self: *Parser, name: []const u8, generics: []ast.GenericParam) ParserError!ast.EnumDecl {
        _ = try self.expect(.kw_enum, "expected `enum`");
        const where_clause = try self.parseOptionalWhereClause();
        const variants = try self.parseEnumBody();
        return .{ .name = name, .generics = generics, .where_clause = where_clause, .variants = variants };
    }

    fn parseTableAfterName(self: *Parser, name: []const u8, generics: []ast.GenericParam) ParserError!ast.TableDecl {
        _ = try self.expect(.kw_table, "expected `table`");
        const where_clause = try self.parseOptionalWhereClause();
        const result = try self.parseTableBody();
        return .{
            .name = name,
            .generics = generics,
            .where_clause = where_clause,
            .fields = result.fields,
            .has_ellipsis = result.has_ellipsis,
        };
    }

    fn parseTriggerAfterName(self: *Parser, name: []const u8, generics: []ast.GenericParam) ParserError!ast.TriggerDecl {
        _ = try self.expect(.kw_trigger, "expected `trigger`");
        const where_clause = try self.parseOptionalWhereClause();
        const fields = try self.parseRecordBody();
        return .{ .name = name, .generics = generics, .where_clause = where_clause, .fields = fields };
    }

    /// `Name <- plugin` with an optional body of member items.  Members are
    /// ordinary declarations; the engine sample only uses `init <- sys (...)`.
    fn parsePluginAfterName(
        self: *Parser,
        name: []const u8,
        generics: []ast.GenericParam,
    ) ParserError!ast.PluginDecl {
        _ = try self.expect(.kw_plugin, "expected `plugin`");
        const where_clause = try self.parseOptionalWhereClause();
        const items = try self.parsePluginBody();
        return .{
            .name = name,
            .generics = generics,
            .where_clause = where_clause,
            .items = items,
        };
    }

    fn parsePluginBody(self: *Parser) ParserError![]*ast.Item {
        _ = self.match(.colon);
        if (self.match(.lbrace) != null) {
            var items = std.ArrayList(*ast.Item).empty;
            self.skipBraceNoise();
            while (!self.at(.rbrace) and !self.at(.eof)) {
                try items.append(self.allocator, try self.parseItem());
                self.skipBraceNoise();
            }
            _ = try self.expect(.rbrace, "expected `}` after plugin body");
            return items.toOwnedSlice(self.allocator);
        }
        // A bare `Name <- plugin` is valid: a plugin with no members.
        if (self.match(.newline) == null) return &.{};
        if (!self.at(.indent)) return &.{};
        _ = self.advance();
        var items = std.ArrayList(*ast.Item).empty;
        while (true) {
            self.skipSeparators();
            if (self.at(.dedent) or self.at(.eof)) break;
            if (self.at(.indent)) return self.fail("unexpected indentation in plugin body");
            try items.append(self.allocator, try self.parseItem());
        }
        _ = try self.expect(.dedent, "expected dedent after plugin body");
        return items.toOwnedSlice(self.allocator);
    }

    fn parseRecordBody(self: *Parser) ParserError![]ast.Field {
        _ = self.match(.colon);
        if (self.match(.lbrace) != null) {
            const fields = try self.parseFields(.rbrace, true);
            _ = try self.expect(.rbrace, "expected `}` after fields");
            return fields;
        }
        _ = try self.expect(.newline, "expected newline or `{` after aggregate declaration");
        // `Trigger <- trigger` with no indented fields is a valid empty body;
        // the next declaration follows at the enclosing indentation.
        if (!self.at(.indent)) return &.{};
        _ = self.advance();
        const fields = try self.parseFields(.dedent, false);
        _ = try self.expect(.dedent, "expected dedent after fields");
        return fields;
    }

    fn parseTableBody(self: *Parser) ParserError!TableFields {
        _ = self.match(.colon);
        if (self.match(.lbrace) != null) {
            const result = try self.parseTableFields(.rbrace, true);
            _ = try self.expect(.rbrace, "expected `}` after table fields");
            return result;
        }
        _ = try self.expect(.newline, "expected newline or `{` after table declaration");
        _ = try self.expect(.indent, "expected indented table fields");
        const result = try self.parseTableFields(.dedent, false);
        _ = try self.expect(.dedent, "expected dedent after table fields");
        return result;
    }

    fn parseEnumBody(self: *Parser) ParserError![]ast.Variant {
        _ = self.match(.colon);
        if (self.match(.lbrace) != null) {
            const variants = try self.parseVariants(.rbrace, true);
            _ = try self.expect(.rbrace, "expected `}` after variants");
            return variants;
        }
        _ = try self.expect(.newline, "expected newline or `{` after enum declaration");
        _ = try self.expect(.indent, "expected indented variant list");
        const variants = try self.parseVariants(.dedent, false);
        _ = try self.expect(.dedent, "expected dedent after variants");
        return variants;
    }

    fn parseFields(self: *Parser, stop: syntax.TokenKind, brace: bool) ParserError![]ast.Field {
        var fields = std.ArrayList(ast.Field).empty;
        while (true) {
            try self.skipFieldSeparators(brace);
            if (self.at(stop) or self.at(.eof)) break;
            try fields.append(self.allocator, try self.parseField());
        }
        return fields.toOwnedSlice(self.allocator);
    }

    fn parseTableFields(self: *Parser, stop: syntax.TokenKind, brace: bool) ParserError!TableFields {
        var fields = std.ArrayList(ast.Field).empty;
        var has_ellipsis = false;
        while (true) {
            try self.skipFieldSeparators(brace);
            if (self.at(stop) or self.at(.eof)) break;
            if (self.at(.ellipsis)) {
                _ = self.advance();
                has_ellipsis = true;
                try self.skipFieldSeparators(brace);
                if (!self.at(stop) and !self.at(.eof)) {
                    return self.fail("`...` must be the final table entry");
                }
                break;
            }
            try fields.append(self.allocator, try self.parseField());
        }
        return .{ .fields = try fields.toOwnedSlice(self.allocator), .has_ellipsis = has_ellipsis };
    }

    fn skipFieldSeparators(self: *Parser, brace: bool) ParserError!void {
        while (true) {
            switch (self.peek().kind) {
                .comma, .newline, .semicolon => _ = self.advance(),
                .indent, .dedent => {
                    if (!brace) break;
                    _ = self.advance();
                },
                else => break,
            }
        }
    }

    fn parseField(self: *Parser) ParserError!ast.Field {
        const attrs = try self.parseAttributes();
        const visibility = try self.parseVisibility();
        const name = (try self.expect(.identifier, "expected field name")).lexeme;
        _ = try self.expect(.colon, "expected `:` after field name");
        return .{
            .attributes = attrs,
            .visibility = visibility,
            .name = name,
            .ty = try self.parseType(),
        };
    }

    fn parseVariants(self: *Parser, stop: syntax.TokenKind, brace: bool) ParserError![]ast.Variant {
        var variants = std.ArrayList(ast.Variant).empty;
        while (true) {
            try self.skipFieldSeparators(brace);
            if (self.at(stop) or self.at(.eof)) break;
            try variants.append(self.allocator, try self.parseVariant());
        }
        return variants.toOwnedSlice(self.allocator);
    }

    fn parseVariant(self: *Parser) ParserError!ast.Variant {
        const name = (try self.expect(.identifier, "expected variant name")).lexeme;
        var payload: ast.VariantPayload = .unit;
        if (self.match(.lparen) != null) {
            var items = std.ArrayList(ast.Payload).empty;
            if (!self.at(.rparen)) {
                while (true) {
                    try items.append(self.allocator, try self.parsePayload());
                    if (self.match(.comma) == null) break;
                    if (self.at(.rparen)) break;
                }
            }
            _ = try self.expect(.rparen, "expected `)` after variant payload");
            payload = .{ .tuple = try items.toOwnedSlice(self.allocator) };
        } else if (self.match(.lbrace) != null) {
            const fields = try self.parseFields(.rbrace, true);
            _ = try self.expect(.rbrace, "expected `}` after variant fields");
            payload = .{ .struct_fields = fields };
        }
        return .{ .name = name, .payload = payload };
    }

    fn parsePayload(self: *Parser) ParserError!ast.Payload {
        var name: ?[]const u8 = null;
        if (self.at(.identifier) and self.peekAt(1).kind == .colon) {
            name = self.advance().lexeme;
            _ = self.advance();
        }
        return .{ .name = name, .ty = try self.parseType() };
    }

    // ------------------------------------------------------------------
    // Traits
    // ------------------------------------------------------------------

    /// Keyword-first form: `trait Name : Parent`.
    fn parseTraitDecl(self: *Parser) ParserError!ast.TraitDecl {
        _ = try self.expect(.kw_trait, "expected `trait`");
        const name = (try self.expect(.identifier, "expected trait name")).lexeme;
        const generics = try self.parseOptionalGenericParams();
        return self.parseTraitAfterHeader(name, generics);
    }

    /// Name-first form used by the engine samples: `Name <- trait : Parent`.
    fn parseTraitAfterName(
        self: *Parser,
        name: []const u8,
        generics: []ast.GenericParam,
    ) ParserError!ast.TraitDecl {
        _ = try self.expect(.kw_trait, "expected `trait`");
        return self.parseTraitAfterHeader(name, generics);
    }

    fn parseTraitAfterHeader(
        self: *Parser,
        name: []const u8,
        generics: []ast.GenericParam,
    ) ParserError!ast.TraitDecl {
        var bounds: []*ast.Type = &.{};
        if (self.match(.colon) != null) bounds = try self.parseBounds();
        const methods = try self.parseTraitBody();
        return .{
            .name = name,
            .generics = generics,
            .bounds = bounds,
            .methods = methods,
        };
    }

    /// Trait bodies are optional and hold signature-only method requirements.
    /// They accept the same two body forms as other declarations: a braced
    /// body or a newline followed by an indented body.
    fn parseTraitBody(self: *Parser) ParserError![]ast.TraitMethod {
        if (self.match(.lbrace) != null) {
            var methods = std.ArrayList(ast.TraitMethod).empty;
            while (true) {
                self.skipBraceNoise();
                if (self.at(.rbrace) or self.at(.eof)) break;
                try methods.append(self.allocator, try self.parseTraitMethod());
            }
            _ = try self.expect(.rbrace, "expected `}` after trait body");
            return methods.toOwnedSlice(self.allocator);
        }
        if (self.match(.newline) != null) {
            if (!self.at(.indent)) return &.{};
            _ = self.advance();
            var methods = std.ArrayList(ast.TraitMethod).empty;
            while (true) {
                self.skipSeparators();
                if (self.at(.dedent) or self.at(.eof)) break;
                if (self.at(.indent)) return self.fail("unexpected indentation in trait body");
                try methods.append(self.allocator, try self.parseTraitMethod());
            }
            _ = try self.expect(.dedent, "expected dedent after trait body");
            return methods.toOwnedSlice(self.allocator);
        }
        _ = self.match(.semicolon);
        return &.{};
    }

    /// `render <- async (&self, &mut Gpu) -> !nil` — a requirement without a
    /// body.  Terminated by a separator, `}`, or the enclosing dedent.
    fn parseTraitMethod(self: *Parser) ParserError!ast.TraitMethod {
        const attrs = try self.parseAttributes();
        const visibility = try self.parseVisibility();
        const name = (try self.expect(.identifier, "expected trait method name")).lexeme;
        const generics = try self.parseOptionalGenericParams();
        _ = try self.expect(.bind_immutable, "expected `<-` in trait method signature");
        const is_async = self.match(.kw_async) != null;

        var receiver: ?ast.Receiver = null;
        var params = std.ArrayList(ast.TraitParam).empty;
        _ = try self.expect(.lparen, "expected `(` in trait method signature");
        if (!self.at(.rparen)) {
            receiver = try self.tryParseReceiver();
            if (receiver != null) _ = self.match(.comma);
            if (!self.at(.rparen)) {
                while (true) {
                    try params.append(self.allocator, try self.parseTraitParam());
                    if (self.match(.comma) == null) break;
                    if (self.at(.rparen)) break;
                }
            }
        }
        _ = try self.expect(.rparen, "expected `)` after trait method parameters");

        _ = try self.expect(.arrow, "expected `->` after trait method parameters");
        const result = try self.parseType();
        const where_clause = try self.parseOptionalWhereClause();
        _ = self.match(.semicolon);
        return .{
            .attributes = attrs,
            .visibility = visibility,
            .name = name,
            .is_async = is_async,
            .generics = generics,
            .receiver = receiver,
            .params = try params.toOwnedSlice(self.allocator),
            .result = result,
            .where_clause = where_clause,
        };
    }

    /// Trait parameters are either `name: Type` or a bare type (`&mut Gpu`).
    fn parseTraitParam(self: *Parser) ParserError!ast.TraitParam {
        var name: ?[]const u8 = null;
        if (self.at(.identifier) and self.peekAt(1).kind == .colon) {
            name = self.advance().lexeme;
            _ = self.advance();
        }
        return .{ .name = name, .ty = try self.parseType() };
    }

    /// Recognize `self`, `&self`, and `&mut self` as a receiver when it is a
    /// complete parameter.  Returns null for ordinary reference parameters.
    fn tryParseReceiver(self: *Parser) ParserError!?ast.Receiver {
        if (self.at(.kw_self)) {
            const next = self.peekAt(1).kind;
            if (next == .comma or next == .rparen) {
                _ = self.advance();
                return .{ .by_ref = false, .mutable = false };
            }
            return null;
        }
        if (!self.at(.amp)) return null;
        var offset: usize = 1;
        const mutable = self.peekAt(offset).kind == .kw_mut;
        if (mutable) offset += 1;
        if (self.peekAt(offset).kind != .kw_self) return null;
        const after = self.peekAt(offset + 1).kind;
        if (after != .comma and after != .rparen) return null;
        self.index += offset + 1;
        return .{ .by_ref = true, .mutable = mutable };
    }

    fn parseImplDecl(self: *Parser) ParserError!ast.ImplDecl {
        _ = try self.expect(.kw_impl, "expected `impl`");
        const generics = try self.parseOptionalGenericParams();
        const first = try self.parseType();
        var trait_ty: ?*ast.Type = null;
        var target = first;
        if (self.match(.kw_for) != null) {
            trait_ty = first;
            target = try self.parseType();
        }
        const where_clause = try self.parseOptionalWhereClause();
        const methods = try self.parseImplBody();
        return .{
            .generics = generics,
            .trait_ty = trait_ty,
            .target = target,
            .where_clause = where_clause,
            .methods = methods,
        };
    }

    fn parseImplBody(self: *Parser) ParserError![]ast.Method {
        if (self.match(.lbrace) != null) {
            const methods = try self.parseMethods(.rbrace, true);
            _ = try self.expect(.rbrace, "expected `}` after impl body");
            return methods;
        }
        _ = try self.expect(.colon, "expected `:` or `{` after impl target");
        if (self.match(.newline) != null) {
            _ = try self.expect(.indent, "expected indented impl body");
            const methods = try self.parseMethods(.dedent, false);
            _ = try self.expect(.dedent, "expected dedent after impl body");
            return methods;
        }
        var methods = std.ArrayList(ast.Method).empty;
        try methods.append(self.allocator, try self.parseMethod());
        return methods.toOwnedSlice(self.allocator);
    }

    fn parseMethods(self: *Parser, stop: syntax.TokenKind, brace: bool) ParserError![]ast.Method {
        var methods = std.ArrayList(ast.Method).empty;
        while (true) {
            if (brace) {
                self.skipBraceNoise();
            } else {
                self.skipSeparators();
                if (self.at(.indent)) return self.fail("unexpected indentation in impl body");
            }
            if (self.at(stop) or self.at(.eof)) break;
            try methods.append(self.allocator, try self.parseMethod());
        }
        return methods.toOwnedSlice(self.allocator);
    }

    fn parseMethod(self: *Parser) ParserError!ast.Method {
        const attrs = try self.parseAttributes();
        const visibility = try self.parseVisibility();
        const function = try self.parseFunction();
        return .{ .attributes = attrs, .visibility = visibility, .function = function };
    }

    // ------------------------------------------------------------------
    // Functions
    // ------------------------------------------------------------------

    fn parseFunction(self: *Parser) ParserError!ast.FunctionDecl {
        const name = (try self.expect(.identifier, "expected function name")).lexeme;
        const generics = try self.parseOptionalGenericParams();
        _ = try self.expect(.bind_immutable, "expected `<-` in function declaration");
        return self.parseFunctionAfterSignature(name, generics);
    }

    fn parseFunctionAfterSignature(
        self: *Parser,
        name: []const u8,
        generics: []ast.GenericParam,
    ) ParserError!ast.FunctionDecl {
        const async_token = self.match(.kw_async) != null;
        const params = try self.parseParamList();
        _ = try self.expect(.arrow, "expected `->` after function parameters");
        const result = try self.parseType();
        const where_clause = try self.parseOptionalWhereClause();
        const body = try self.parseFunctionBody();
        return .{
            .name = name,
            .is_async = async_token,
            .generics = generics,
            .params = params,
            .result = result,
            .where_clause = where_clause,
            .body = body,
        };
    }

    fn parseParamList(self: *Parser) ParserError![]ast.Param {
        _ = try self.expect(.lparen, "expected `(`");
        var params = std.ArrayList(ast.Param).empty;
        if (!self.at(.rparen)) {
            while (true) {
                const name = (try self.expect(.identifier, "expected parameter name")).lexeme;
                _ = try self.expect(.colon, "expected `:` after parameter name");
                try params.append(self.allocator, .{ .name = name, .ty = try self.parseType() });
                if (self.match(.comma) == null) break;
                if (self.at(.rparen)) break;
            }
        }
        _ = try self.expect(.rparen, "expected `)` after parameters");
        return params.toOwnedSlice(self.allocator);
    }

    fn parseFunctionBody(self: *Parser) ParserError!ast.FunctionBody {
        if (self.match(.assign) != null) {
            return .{ .expr = try self.parseExpression() };
        }
        if (self.at(.lbrace) or self.at(.colon)) {
            return .{ .block = try self.parseBlock() };
        }
        return self.fail("expected `=`, `{`, or `:` for function body");
    }

    fn looksLikeFunctionSignatureAt(self: *const Parser, start: usize) bool {
        var start_index = start;
        if (start_index < self.tokens.len and self.tokens[start_index].kind == .kw_async) {
            start_index += 1;
        }
        if (start_index >= self.tokens.len or self.tokens[start_index].kind != .lparen) return false;
        const lparen_start = start_index;
        var depth: usize = 0;
        var i = lparen_start;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].kind) {
                .lparen => depth += 1,
                .rparen => {
                    if (depth == 0) return false;
                    depth -= 1;
                    if (depth == 0) {
                        const next = i + 1;
                        return next < self.tokens.len and self.tokens[next].kind == .arrow;
                    }
                },
                .eof => return false,
                else => {},
            }
        }
        return false;
    }

    // ------------------------------------------------------------------
    // sys
    // ------------------------------------------------------------------

    fn parseSysAfterName(self: *Parser, name: []const u8, generics: []ast.GenericParam) ParserError!ast.SysDecl {
        _ = try self.expect(.kw_sys, "expected `sys`");
        _ = try self.expect(.lparen, "expected `(` after `sys`");
        var params = std.ArrayList(ast.SysParam).empty;
        if (!self.at(.rparen)) {
            while (true) {
                try params.append(self.allocator, try self.parseSysParam());
                if (self.match(.comma) != null) {
                    if (self.at(.rparen)) break;
                    continue;
                }
                if (self.at(.rparen)) break;
                // The engine samples write one parameter per line without
                // trailing commas.  Newlines inside `(` are suppressed by the
                // lexer, so a parameter start is simply the next identifier.
                if (self.at(.identifier)) continue;
                return self.fail("expected `,` or `)` after sys parameter");
            }
        }
        _ = try self.expect(.rparen, "expected `)` after sys parameters");
        const where_clause = try self.parseOptionalWhereClause();
        const body = try self.parseBlock();
        return .{
            .name = name,
            .generics = generics,
            .params = try params.toOwnedSlice(self.allocator),
            .where_clause = where_clause,
            .body = body,
        };
    }

    fn parseSysParam(self: *Parser) ParserError!ast.SysParam {
        const name = (try self.expect(.identifier, "expected sys parameter name")).lexeme;
        _ = try self.expect(.colon, "expected `:` after sys parameter name");
        if (self.match(.kw_select) != null) {
            return .{ .query = try self.parseQueryParam(name) };
        }
        if (self.match(.kw_res) != null) {
            return .{ .resource = .{ .name = name, .ty = try self.parseType() } };
        }
        return .{ .normal = .{ .name = name, .ty = try self.parseType() } };
    }

    fn parseQueryParam(self: *Parser, name: []const u8) ParserError!ast.QueryParam {
        var projections = std.ArrayList(ast.QueryProjection).empty;
        try projections.append(self.allocator, try self.parseQueryProjection());
        while (self.at(.comma) and self.peekAt(1).kind == .amp) {
            _ = self.advance();
            try projections.append(self.allocator, try self.parseQueryProjection());
        }
        _ = try self.expect(.kw_from, "expected `from` in query");
        const from = try self.parseType();
        var filter: ?*ast.Expr = null;
        var has: ?*ast.Type = null;
        if (self.match(.kw_where) != null) {
            // `where has Type` is a presence filter, not a boolean expression.
            if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "has")) {
                _ = self.advance();
                has = try self.parseType();
            } else {
                filter = try self.parseExpression();
            }
        }
        return .{
            .name = name,
            .projections = try projections.toOwnedSlice(self.allocator),
            .from = from,
            .filter = filter,
            .has = has,
        };
    }

    fn parseQueryProjection(self: *Parser) ParserError!ast.QueryProjection {
        _ = try self.expect(.amp, "expected `&` in query projection");
        const mutable = self.match(.kw_mut) != null;
        return .{ .mutable = mutable, .path = try self.parsePath(false) };
    }

    // ------------------------------------------------------------------
    // Generics and where clauses
    // ------------------------------------------------------------------

    fn parseOptionalGenericParams(self: *Parser) ParserError![]ast.GenericParam {
        if (!self.at(.lt)) return &.{};
        return self.parseGenericParams();
    }

    fn parseGenericParams(self: *Parser) ParserError![]ast.GenericParam {
        _ = try self.expect(.lt, "expected `<`");
        var params = std.ArrayList(ast.GenericParam).empty;
        if (!self.at(.gt)) {
            while (true) {
                const name = (try self.expect(.identifier, "expected generic parameter name")).lexeme;
                var bounds: []*ast.Type = &.{};
                if (self.match(.colon) != null) bounds = try self.parseBounds();
                try params.append(self.allocator, .{ .name = name, .bounds = bounds });
                if (self.match(.comma) == null) break;
                if (self.at(.gt)) break;
            }
        }
        _ = try self.expect(.gt, "expected `>` after generic parameters");
        return params.toOwnedSlice(self.allocator);
    }

    fn parseBounds(self: *Parser) ParserError![]*ast.Type {
        var bounds = std.ArrayList(*ast.Type).empty;
        try bounds.append(self.allocator, try self.parseType());
        while (self.match(.plus) != null) {
            try bounds.append(self.allocator, try self.parseType());
        }
        return bounds.toOwnedSlice(self.allocator);
    }

    fn parseOptionalWhereClause(self: *Parser) ParserError!?ast.WhereClause {
        if (self.match(.kw_where) == null) return null;
        var predicates = std.ArrayList(ast.WherePredicate).empty;
        while (true) {
            const ty = try self.parseType();
            _ = try self.expect(.colon, "expected `:` in where predicate");
            const bounds = try self.parseBounds();
            try predicates.append(self.allocator, .{ .ty = ty, .bounds = bounds });
            if (self.match(.comma) == null) break;
            if (self.at(.lbrace) or self.at(.colon) or self.at(.newline) or
                self.at(.assign) or self.at(.dedent) or self.at(.eof)) break;
        }
        return .{ .predicates = try predicates.toOwnedSlice(self.allocator) };
    }

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    fn parseType(self: *Parser) ParserError!*ast.Type {
        var ty = try self.parseTypePrefix();
        if (self.match(.bang) != null) {
            const rhs = try self.parseType();
            ty = try self.createType(.{ .error_union = .{
                .error_type = ty,
                .value_type = rhs,
            } });
        }
        return ty;
    }

    fn parseTypePrefix(self: *Parser) ParserError!*ast.Type {
        return switch (self.peek().kind) {
            .bang => blk: {
                _ = self.advance();
                break :blk self.createType(.{ .inferred_error = try self.parseType() });
            },
            .question => blk: {
                _ = self.advance();
                break :blk self.createType(.{ .optional = try self.parseType() });
            },
            .amp => blk: {
                _ = self.advance();
                const mutable = self.match(.kw_mut) != null;
                break :blk self.createType(.{ .reference = .{
                    .mutable = mutable,
                    .child = try self.parseType(),
                } });
            },
            .star => blk: {
                _ = self.advance();
                const raw = self.match(.kw_raw) != null;
                const child = try self.parseType();
                break :blk if (raw)
                    self.createType(.{ .raw_pointer = child })
                else
                    self.createType(.{ .box = child });
            },
            .lparen => self.parseParenType(),
            .lbracket => self.parseArrayType(),
            .identifier => blk: {
                if (std.mem.eql(u8, self.peek().lexeme, "map") and self.peekAt(1).kind == .lbracket) {
                    break :blk self.parseMapType();
                }
                break :blk self.createType(.{ .path = try self.parsePath(true) });
            },
            .kw_crate, .kw_self, .kw_super => self.createType(.{
                .path = try self.parsePath(true),
            }),
            // `nil` is the unit/empty result type; `!nil` is the common
            // "errors or nothing" result shape.
            .kw_nil => blk: {
                _ = self.advance();
                break :blk self.createType(.nil_type);
            },
            else => self.fail("expected a type"),
        };
    }

    fn parseParenType(self: *Parser) ParserError!*ast.Type {
        _ = try self.expect(.lparen, "expected `(`");
        var items = std.ArrayList(*ast.Type).empty;
        if (!self.at(.rparen)) {
            while (true) {
                try items.append(self.allocator, try self.parseType());
                if (self.match(.comma) == null) break;
                if (self.at(.rparen)) break;
            }
        }
        _ = try self.expect(.rparen, "expected `)` after type");
        if (self.match(.arrow) != null) {
            return self.createType(.{ .function = .{
                .params = try items.toOwnedSlice(self.allocator),
                .result = try self.parseType(),
            } });
        }
        return self.createType(.{ .tuple = try items.toOwnedSlice(self.allocator) });
    }

    fn parseArrayType(self: *Parser) ParserError!*ast.Type {
        _ = try self.expect(.lbracket, "expected `[`");
        const element = try self.parseType();
        var length: ?*ast.Expr = null;
        var columns: ?*ast.Expr = null;
        if (self.match(.semicolon) != null) {
            length = try self.parseExpression();
            if (self.match(.comma) != null) columns = try self.parseExpression();
        }
        _ = try self.expect(.rbracket, "expected `]` after array type");
        return self.createType(.{ .array = .{
            .element = element,
            .length = length,
            .columns = columns,
        } });
    }

    fn parseMapType(self: *Parser) ParserError!*ast.Type {
        _ = try self.expect(.identifier, "expected `map`");
        _ = try self.expect(.lbracket, "expected `[` after `map`");
        const key = try self.parseType();
        _ = try self.expect(.comma, "expected `,` between map key and value types");
        const value = try self.parseType();
        _ = try self.expect(.rbracket, "expected `]` after map type");
        return self.createType(.{ .map = .{ .key = key, .value = value } });
    }

    fn parseTypeArgs(self: *Parser) ParserError![]*ast.Type {
        _ = try self.expect(.lt, "expected `<`");
        var args = std.ArrayList(*ast.Type).empty;
        if (!self.at(.gt)) {
            while (true) {
                try args.append(self.allocator, try self.parseType());
                if (self.match(.comma) == null) break;
                if (self.at(.gt)) break;
            }
        }
        _ = try self.expect(.gt, "expected `>` after type arguments");
        return args.toOwnedSlice(self.allocator);
    }

    fn parsePath(self: *Parser, allow_generics: bool) ParserError!ast.Path {
        var segments = std.ArrayList(ast.PathSegment).empty;
        var root = try self.parsePathRoot();
        while (true) {
            var args: []*ast.Type = &.{};
            if (allow_generics and self.at(.lt)) args = try self.parseTypeArgs();
            try segments.append(self.allocator, .{ .name = root.lexeme, .args = args });
            if (self.match(.colon_colon) == null) break;
            root = try self.expect(.identifier, "expected path segment after `::`");
        }
        return self.pathOf(try segments.toOwnedSlice(self.allocator));
    }

    fn parsePathRoot(self: *Parser) ParserError!*const syntax.Token {
        return switch (self.peek().kind) {
            .identifier, .kw_crate, .kw_self, .kw_super => self.advance(),
            else => self.fail("expected path"),
        };
    }

    /// Parse a path in expression/pattern position.  Generic arguments are
    /// accepted only when they are lexically attached to the previous segment
    /// and followed by a token that continues a path expression.  This keeps
    /// `a < b` and `a < b > c` as comparisons while allowing `Foo<T> { ... }`
    /// and `foo<T>(...)`.
    fn parseExpressionPath(self: *Parser) ParserError!ast.Path {
        var segments = std.ArrayList(ast.PathSegment).empty;
        var root = try self.parsePathRoot();
        while (true) {
            var args: []*ast.Type = &.{};
            if (self.at(.lt) and self.looksLikeExpressionTypeArgs(self.index)) {
                args = try self.parseTypeArgs();
            }
            try segments.append(self.allocator, .{ .name = root.lexeme, .args = args });
            if (self.match(.colon_colon) == null) break;
            // Turbofish: `json_decode::<Point>(text)` attaches type arguments to
            // the preceding segment instead of naming another path segment.
            if (self.at(.lt)) {
                const turbofish = try self.parseTypeArgs();
                const last = &segments.items[segments.items.len - 1];
                if (last.args.len == 0) last.args = turbofish;
                break;
            }
            root = try self.expect(.identifier, "expected path segment after `::`");
        }
        return self.pathOf(try segments.toOwnedSlice(self.allocator));
    }

    fn looksLikeExpressionTypeArgs(self: *const Parser, start: usize) bool {
        if (start == 0 or self.tokens[start].kind != .lt) return false;
        const previous = self.tokens[start - 1];
        if (self.tokens[start].offset != previous.offset + previous.lexeme.len) return false;

        var depth: usize = 0;
        var i = start;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].kind) {
                .lt => depth += 1,
                .gt => {
                    if (depth == 0) return false;
                    depth -= 1;
                    if (depth == 0) {
                        const next = i + 1;
                        if (next >= self.tokens.len) return false;
                        return switch (self.tokens[next].kind) {
                            .lbrace, .lparen, .dot, .colon_colon, .question, .lbracket, .newline, .semicolon, .comma, .rparen, .rbracket, .rbrace, .eof => true,
                            else => false,
                        };
                    }
                },
                .eof => return false,
                else => {},
            }
        }
        return false;
    }

    // ------------------------------------------------------------------
    // Blocks and statements
    // ------------------------------------------------------------------

    fn parseBlock(self: *Parser) ParserError!*ast.Block {
        if (self.at(.lbrace)) return self.parseBraceBlock();
        if (self.match(.colon) != null) return self.parseBodyAfterColon();
        return self.fail("expected `{` or `:` for block");
    }

    fn parseBraceBlock(self: *Parser) ParserError!*ast.Block {
        _ = try self.expect(.lbrace, "expected `{`");
        const entries = try self.parseEntries(.rbrace, true);
        _ = try self.expect(.rbrace, "expected `}` after block");
        return self.createBlock(entries);
    }

    fn parseBodyAfterColon(self: *Parser) ParserError!*ast.Block {
        if (self.match(.newline) != null) {
            _ = try self.expect(.indent, "expected indented block");
            const entries = try self.parseEntries(.dedent, false);
            _ = try self.expect(.dedent, "expected dedent after block");
            return self.createBlock(entries);
        }
        var entries = std.ArrayList(ast.Entry).empty;
        try entries.append(self.allocator, .{ .stmt = try self.parseStatement() });
        return self.createBlock(try entries.toOwnedSlice(self.allocator));
    }

    fn parseEntries(self: *Parser, stop: syntax.TokenKind, brace: bool) ParserError![]ast.Entry {
        var entries = std.ArrayList(ast.Entry).empty;
        while (true) {
            if (brace) {
                self.skipBraceNoise();
            } else {
                self.skipSeparators();
                if (self.at(.indent)) return self.fail("unexpected indentation in block");
            }
            if (self.at(stop) or self.at(.eof)) break;
            try entries.append(self.allocator, try self.parseEntry());
        }
        return entries.toOwnedSlice(self.allocator);
    }

    fn parseEntry(self: *Parser) ParserError!ast.Entry {
        const is_item = switch (self.peek().kind) {
            .at, .kw_pub, .kw_use, .kw_mod, .kw_impl => true,
            .identifier => self.looksLikeItemDecl(),
            else => false,
        };
        if (is_item) return .{ .item = try self.parseItem() };
        return .{ .stmt = try self.parseStatement() };
    }

    fn looksLikeItemDecl(self: *const Parser) bool {
        var i = self.index;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].kind) {
                .newline, .semicolon, .eof => return false,
                .bind_immutable => {
                    const next = i + 1;
                    if (next >= self.tokens.len) return false;
                    return switch (self.tokens[next].kind) {
                        .kw_struct, .kw_enum, .kw_table, .kw_trigger, .kw_sys, .kw_trait => true,
                        .lparen => self.looksLikeFunctionSignatureAt(next),
                        else => false,
                    };
                },
                .bind_mutable => return false,
                else => {},
            }
        }
        return false;
    }

    fn parseStatement(self: *Parser) ParserError!*ast.Stmt {
        const start = self.index;
        return switch (self.peek().kind) {
            .kw_ret => self.parseRet(),
            .kw_break => blk: {
                _ = self.advance();
                break :blk self.createStmt(.break_stmt, start);
            },
            .kw_cont => blk: {
                _ = self.advance();
                break :blk self.createStmt(.cont, start);
            },
            .kw_while => self.parseWhile(),
            .kw_for => self.parseFor(),
            .kw_loop => self.parseLoop(),
            .kw_unsafe => blk: {
                _ = self.advance();
                break :blk self.createStmt(.{ .unsafe_block = try self.parseBlock() }, start);
            },
            .kw_disown => self.parseDisown(),
            .identifier => if (self.looksLikeBinding())
                self.parseBindingStmt()
            else if (self.looksLikeUninitializedDecl())
                self.parseUninitializedDecl()
            else
                self.parseExprOrAssign(),
            else => self.parseExprOrAssign(),
        };
    }

    fn looksLikeUninitializedDecl(self: *const Parser) bool {
        if (self.peek().kind != .identifier or self.peekAt(1).kind != .colon) return false;
        var i = self.index + 2;
        var saw_type = false;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].kind) {
                .newline, .semicolon, .eof, .dedent, .rbrace => return saw_type,
                .bind_immutable, .bind_mutable => return false,
                else => saw_type = true,
            }
        }
        return saw_type;
    }

    fn parseUninitializedDecl(self: *Parser) ParserError!*ast.Stmt {
        const start = self.index;
        const name = (try self.expect(.identifier, "expected binding name")).lexeme;
        _ = try self.expect(.colon, "expected `:`");
        const ty = try self.parseType();
        return self.createStmt(.{ .uninitialized = .{
            .name = name,
            .ty = ty,
            .mutable = true,
        } }, start);
    }

    fn looksLikeBinding(self: *const Parser) bool {
        var i = self.index;
        // Semicolons can occur inside a binding's type (`[f32; 3]`) or
        // initializer, so only separators at bracket depth zero terminate the
        // lookahead.
        var depth: usize = 0;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].kind) {
                .lparen, .lbracket, .lbrace => depth += 1,
                .rparen, .rbracket, .rbrace => {
                    if (depth > 0) depth -= 1;
                },
                .newline, .semicolon, .eof => if (depth == 0) return false,
                .bind_immutable, .bind_mutable => if (depth == 0) return true,
                else => {},
            }
        }
        return false;
    }

    fn parseBindingStmt(self: *Parser) ParserError!*ast.Stmt {
        const start = self.index;
        const name = (try self.expect(.identifier, "expected binding name")).lexeme;
        var ty: ?*ast.Type = null;
        if (self.match(.colon) != null) ty = try self.parseType();
        const op = self.peek().kind;
        if (op != .bind_immutable and op != .bind_mutable) {
            return self.fail("expected `<-` or `:=`");
        }
        _ = self.advance();
        return self.createStmt(.{ .binding = try self.parseBindingValue(name, ty, op == .bind_mutable) }, start);
    }

    fn parseRet(self: *Parser) ParserError!*ast.Stmt {
        const start = self.index;
        _ = try self.expect(.kw_ret, "expected `ret`");
        if (self.atExprEnd()) return self.createStmt(.{ .ret = null }, start);
        return self.createStmt(.{ .ret = try self.parseExpression() }, start);
    }

    fn parseDisown(self: *Parser) ParserError!*ast.Stmt {
        const start = self.index;
        _ = try self.expect(.kw_disown, "expected `disown`");
        if (self.atExprEnd()) return self.fail("expected a lease expression after `disown`");
        return self.createStmt(.{ .disown = try self.parseExpression() }, start);
    }

    fn parseWhile(self: *Parser) ParserError!*ast.Stmt {
        const start = self.index;
        _ = try self.expect(.kw_while, "expected `while`");
        const condition = try self.parseExprBP(0, .{ .allow_struct_literal = false });
        const body = try self.parseBlock();
        return self.createStmt(.{ .while_stmt = .{ .condition = condition, .body = body } }, start);
    }

    fn parseFor(self: *Parser) ParserError!*ast.Stmt {
        const start = self.index;
        _ = try self.expect(.kw_for, "expected `for`");
        const pattern = try self.parsePattern();
        _ = try self.expect(.kw_in, "expected `in` in for loop");
        const iterable = try self.parseExprBP(0, .{ .allow_struct_literal = false });
        const body = try self.parseBlock();
        return self.createStmt(.{ .for_stmt = .{
            .pattern = pattern,
            .iterable = iterable,
            .body = body,
        } }, start);
    }

    fn parseLoop(self: *Parser) ParserError!*ast.Stmt {
        const start = self.index;
        _ = try self.expect(.kw_loop, "expected `loop`");
        return self.createStmt(.{ .loop_stmt = .{ .body = try self.parseBlock() } }, start);
    }

    fn parseExprOrAssign(self: *Parser) ParserError!*ast.Stmt {
        const start = self.index;
        const expr = try self.parseExpression();
        const op: ast.AssignOp = switch (self.peek().kind) {
            .assign => .assign,
            .plus_assign => .add,
            .minus_assign => .sub,
            .star_assign => .mul,
            .slash_assign => .div,
            .percent_assign => .mod,
            else => return self.createStmt(.{ .expr = expr }, start),
        };
        _ = self.advance();
        return self.createStmt(.{ .assign = .{
            .target = expr,
            .op = op,
            .value = try self.parseAssignmentValue(),
        } }, start);
    }

    fn atExprEnd(self: *const Parser) bool {
        return switch (self.peek().kind) {
            .newline, .semicolon, .dedent, .rbrace, .eof => true,
            else => false,
        };
    }

    // ------------------------------------------------------------------
    // Patterns
    // ------------------------------------------------------------------

    fn parsePattern(self: *Parser) ParserError!*ast.Pattern {
        var items = std.ArrayList(*ast.Pattern).empty;
        try items.append(self.allocator, try self.parsePrimaryPattern());
        while (self.match(.pipe) != null) {
            try items.append(self.allocator, try self.parsePrimaryPattern());
        }
        if (items.items.len == 1) return items.items[0];
        return self.createPattern(.{ .or_pattern = try items.toOwnedSlice(self.allocator) });
    }

    fn parsePrimaryPattern(self: *Parser) ParserError!*ast.Pattern {
        switch (self.peek().kind) {
            .identifier => {
                if (std.mem.eql(u8, self.peek().lexeme, "_")) {
                    _ = self.advance();
                    return self.createPattern(.wildcard);
                }
                if (self.peekAt(1).kind == .colon_colon or
                    self.peekAt(1).kind == .lparen or
                    self.peekAt(1).kind == .lbrace)
                {
                    return self.parsePathPattern();
                }
                const name = self.advance().lexeme;
                return self.createPattern(.{ .binding = name });
            },
            .kw_crate, .kw_self, .kw_super => return self.parsePathPattern(),
            .int_lit => {
                const token = self.advance();
                return self.createPattern(.{ .literal = .{ .int = self.parseInteger(token.lexeme) catch return self.fail("invalid integer literal") } });
            },
            .float_lit => {
                const token = self.advance();
                return self.createPattern(.{ .literal = .{ .float = self.parseFloat(token.lexeme) catch return self.fail("invalid float literal") } });
            },
            .string_lit => {
                const token = self.advance();
                return self.createPattern(.{ .literal = .{ .string = try self.decodeString(token.lexeme) } });
            },
            .kw_true, .kw_false => {
                const value = self.peek().kind == .kw_true;
                _ = self.advance();
                return self.createPattern(.{ .literal = .{ .boolean = value } });
            },
            .kw_nil => {
                _ = self.advance();
                return self.createPattern(.{ .literal = .nil });
            },
            .minus => {
                _ = self.advance();
                if (self.at(.int_lit)) {
                    const token = self.advance();
                    const value = self.parseInteger(token.lexeme) catch
                        return self.fail("invalid integer literal");
                    return self.createPattern(.{ .literal = .{ .int = -value } });
                }
                if (self.at(.float_lit)) {
                    const token = self.advance();
                    const value = self.parseFloat(token.lexeme) catch
                        return self.fail("invalid float literal");
                    return self.createPattern(.{ .literal = .{ .float = -value } });
                }
                return self.fail("expected numeric literal after `-`");
            },
            .lparen => return self.parseTuplePattern(),
            else => return self.fail("expected pattern"),
        }
    }

    fn parsePathPattern(self: *Parser) ParserError!*ast.Pattern {
        const path = try self.parseExpressionPath();
        if (self.match(.lparen) != null) {
            var items = std.ArrayList(*ast.Pattern).empty;
            if (!self.at(.rparen)) {
                while (true) {
                    try items.append(self.allocator, try self.parsePattern());
                    if (self.match(.comma) == null) break;
                    if (self.at(.rparen)) break;
                }
            }
            _ = try self.expect(.rparen, "expected `)` after tuple pattern");
            return self.createPattern(.{ .tuple_struct = .{
                .path = path,
                .items = try items.toOwnedSlice(self.allocator),
            } });
        }
        if (self.match(.lbrace) != null) {
            var fields = std.ArrayList(ast.FieldPattern).empty;
            while (!self.at(.rbrace) and !self.at(.eof)) {
                if (self.match(.comma) != null) continue;
                if (self.at(.newline) or self.at(.indent) or self.at(.dedent) or self.at(.semicolon)) {
                    _ = self.advance();
                    continue;
                }
                const name = (try self.expect(.identifier, "expected field pattern name")).lexeme;
                const sub = if (self.match(.colon) != null) try self.parsePattern() else null;
                try fields.append(self.allocator, .{ .name = name, .pattern = sub });
                _ = self.match(.comma);
            }
            _ = try self.expect(.rbrace, "expected `}` after struct pattern");
            return self.createPattern(.{ .struct_pattern = .{
                .path = path,
                .fields = try fields.toOwnedSlice(self.allocator),
            } });
        }
        return self.createPattern(.{ .path = path });
    }

    fn parseTuplePattern(self: *Parser) ParserError!*ast.Pattern {
        _ = try self.expect(.lparen, "expected `(`");
        var items = std.ArrayList(*ast.Pattern).empty;
        if (!self.at(.rparen)) {
            while (true) {
                try items.append(self.allocator, try self.parsePattern());
                if (self.match(.comma) == null) break;
                if (self.at(.rparen)) break;
            }
        }
        _ = try self.expect(.rparen, "expected `)` after tuple pattern");
        return self.createPattern(.{ .tuple = try items.toOwnedSlice(self.allocator) });
    }

    // ------------------------------------------------------------------
    // Expressions
    // ------------------------------------------------------------------

    fn parseExpression(self: *Parser) ParserError!*ast.Expr {
        return self.parseExprBP(0, .{});
    }

    fn parseExprBP(self: *Parser, min_bp: u8, options: ExprOptions) ParserError!*ast.Expr {
        var lhs = try self.parseUnary(options);
        while (true) {
            if (self.at(.dotdot) or self.at(.dotdot_eq)) {
                if (min_bp > 5) break;
                const inclusive = self.peek().kind == .dotdot_eq;
                _ = self.advance();
                var end: ?*ast.Expr = null;
                if (!self.atExprEnd() and !self.at(.comma) and !self.at(.rparen) and !self.at(.rbracket) and !self.at(.colon)) {
                    end = try self.parseExprBP(6, options);
                } else if (inclusive) {
                    return self.fail("expected end of inclusive range");
                }
                lhs = try self.createExpr(.{ .range = .{
                    .start = lhs,
                    .end = end,
                    .inclusive = inclusive,
                } });
                continue;
            }

            const info = infixInfo(self.peek().kind) orelse break;
            if (info.bp < min_bp) break;
            _ = self.advance();
            const rhs = try self.parseExprBP(
                if (info.right_assoc) info.bp else info.bp + 1,
                options,
            );
            lhs = try self.createExpr(.{ .binary = .{
                .op = info.op,
                .lhs = lhs,
                .rhs = rhs,
            } });
        }
        return lhs;
    }

    fn infixInfo(kind: syntax.TokenKind) ?Infix {
        return switch (kind) {
            .kw_or => .{ .op = .or_, .bp = 1 },
            .kw_xor => .{ .op = .xor_, .bp = 2 },
            .kw_and => .{ .op = .and_, .bp = 3 },
            .eq_eq => .{ .op = .eq, .bp = 4 },
            .bang_eq => .{ .op = .ne, .bp = 4 },
            .lt => .{ .op = .lt, .bp = 4 },
            .le => .{ .op = .le, .bp = 4 },
            .gt => .{ .op = .gt, .bp = 4 },
            .ge => .{ .op = .ge, .bp = 4 },
            .plus => .{ .op = .add, .bp = 6 },
            .minus => .{ .op = .sub, .bp = 6 },
            .star => .{ .op = .mul, .bp = 7 },
            .slash => .{ .op = .div, .bp = 7 },
            .percent => .{ .op = .mod, .bp = 7 },
            else => null,
        };
    }

    fn parseMapLiteral(self: *Parser) ParserError!*ast.Expr {
        _ = try self.expect(.identifier, "expected `map`");
        _ = try self.expect(.lbracket, "expected `[` after `map`");
        const key_ty = try self.parseType();
        _ = try self.expect(.comma, "expected `,` between map key and value types");
        const value_ty = try self.parseType();
        _ = try self.expect(.rbracket, "expected `]` after map type");
        _ = try self.expect(.lbrace, "expected `{` after map type");
        var entries = std.ArrayList(ast.MapEntry).empty;
        if (!self.at(.rbrace)) {
            while (true) {
                const key = try self.parseExpression();
                _ = try self.expect(.colon, "expected `:` between map key and value");
                const value = try self.parseExpression();
                try entries.append(self.allocator, .{ .key = key, .value = value });
                if (self.match(.comma) == null) break;
                if (self.at(.rbrace)) break;
            }
        }
        _ = try self.expect(.rbrace, "expected `}` after map literal");
        return self.createExpr(.{ .map_literal = .{
            .key_ty = key_ty,
            .value_ty = value_ty,
            .entries = try entries.toOwnedSlice(self.allocator),
        } });
    }

    fn parseFunctionExpr(self: *Parser, is_async: bool) ParserError!*ast.Expr {
        const params = try self.parseParamList();
        _ = try self.expect(.arrow, "expected `->` in function expression");
        const result = try self.parseType();
        const body = try self.parseFunctionBody();
        return self.createExpr(.{ .function = .{
            .is_async = is_async,
            .params = params,
            .result = result,
            .body = body,
        } });
    }

    fn parseUnary(self: *Parser, options: ExprOptions) ParserError!*ast.Expr {
        if (self.match(.kw_await) != null) {
            return self.createExpr(.{ .prefix = .{
                .op = .await_,
                .operand = try self.parseUnary(options),
            } });
        }
        if (self.match(.kw_spawn) != null) {
            return self.createExpr(.{ .prefix = .{
                .op = .spawn,
                .operand = try self.parseUnary(options),
            } });
        }
        if (self.match(.kw_detach) != null) {
            return self.createExpr(.{ .prefix = .{
                .op = .detach,
                .operand = try self.parseUnary(options),
            } });
        }
        if (self.match(.kw_cancel) != null) {
            return self.createExpr(.{ .prefix = .{
                .op = .cancel,
                .operand = try self.parseUnary(options),
            } });
        }
        if (self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "query") and
            self.peekAt(1).kind == .amp)
        {
            // `await query &mut Commands` — `query` is contextual so the word
            // remains usable as an ordinary binding/field name.
            _ = self.advance();
            return self.createExpr(.{ .query = .{
                .ty = try self.parseType(),
            } });
        }
        if (self.match(.kw_not) != null) {
            return self.createExpr(.{ .unary = .{
                .op = .not,
                .operand = try self.parseUnary(options),
            } });
        }
        if (self.match(.minus) != null) {
            return self.createExpr(.{ .unary = .{
                .op = .negative,
                .operand = try self.parseUnary(options),
            } });
        }
        if (self.match(.amp) != null) {
            const mutable = self.match(.kw_mut) != null;
            return self.createExpr(.{ .unary = .{
                .op = if (mutable) .borrow_mut else .borrow_shared,
                .operand = try self.parseUnary(options),
            } });
        }
        if (self.match(.star) != null) {
            return self.createExpr(.{ .unary = .{
                .op = .deref,
                .operand = try self.parseUnary(options),
            } });
        }
        return self.parseCast(options);
    }

    fn parseCast(self: *Parser, options: ExprOptions) ParserError!*ast.Expr {
        var expr = try self.parsePostfix(options);
        while (self.match(.kw_as) != null) {
            expr = try self.createExpr(.{ .cast = .{
                .expr = expr,
                .ty = try self.parseType(),
            } });
        }
        return expr;
    }

    fn parsePostfix(self: *Parser, options: ExprOptions) ParserError!*ast.Expr {
        var expr = try self.parsePrimary(options);
        while (true) {
            switch (self.peek().kind) {
                .lparen => {
                    _ = self.advance();
                    // `commands.add_row(Table, { component })`: the row argument
                    // is always a brace row literal, including the single-item
                    // case that would otherwise parse as a block expression.
                    const row_argument = expr.* == .field and
                        std.mem.eql(u8, expr.field.name, "add_row");
                    var args = std.ArrayList(*ast.Expr).empty;
                    if (!self.at(.rparen)) {
                        while (true) {
                            const argument = if (row_argument and args.items.len == 1 and self.at(.lbrace))
                                try self.parseRowLiteral()
                            else
                                try self.parseExpression();
                            try args.append(self.allocator, argument);
                            if (self.match(.comma) == null) break;
                            if (self.at(.rparen)) break;
                        }
                    }
                    _ = try self.expect(.rparen, "expected `)` after call arguments");
                    expr = try self.createExpr(.{ .call = .{
                        .callee = expr,
                        .args = try args.toOwnedSlice(self.allocator),
                    } });
                },
                .dot => {
                    _ = self.advance();
                    const name = (try self.expect(.identifier, "expected field name")).lexeme;
                    expr = try self.createExpr(.{ .field = .{ .target = expr, .name = name } });
                },
                .colon_colon => {
                    // Method turbofish: `commands.remove_component::<Held>(e)`.
                    if (self.peekAt(1).kind != .lt) break;
                    _ = self.advance();
                    const type_args = try self.parseTypeArgs();
                    if (!self.at(.lparen)) {
                        return self.fail("expected `(` after method type arguments");
                    }
                    _ = self.advance();
                    var args = std.ArrayList(*ast.Expr).empty;
                    if (!self.at(.rparen)) {
                        while (true) {
                            try args.append(self.allocator, try self.parseExpression());
                            if (self.match(.comma) == null) break;
                            if (self.at(.rparen)) break;
                        }
                    }
                    _ = try self.expect(.rparen, "expected `)` after call arguments");
                    expr = try self.createExpr(.{ .call = .{
                        .callee = expr,
                        .args = try args.toOwnedSlice(self.allocator),
                        .type_args = type_args,
                    } });
                },
                .lbracket => {
                    _ = self.advance();
                    var indices = std.ArrayList(*ast.Expr).empty;
                    if (self.at(.rbracket)) {
                        return self.fail("expected index expression inside `[`");
                    }
                    while (true) {
                        try indices.append(self.allocator, try self.parseExpression());
                        if (self.match(.comma) == null) break;
                        if (self.at(.rbracket)) break;
                    }
                    _ = try self.expect(.rbracket, "expected `]` after index");
                    expr = try self.createExpr(.{ .index = .{
                        .target = expr,
                        .indices = try indices.toOwnedSlice(self.allocator),
                    } });
                },
                .question => {
                    _ = self.advance();
                    expr = try self.createExpr(.{ .try_expr = expr });
                },
                else => break,
            }
        }
        return expr;
    }

    fn parsePrimary(self: *Parser, options: ExprOptions) ParserError!*ast.Expr {
        switch (self.peek().kind) {
            .int_lit => {
                const token = self.advance();
                return self.createExpr(.{ .int = self.parseInteger(token.lexeme) catch return self.fail("invalid integer literal") });
            },
            .float_lit => {
                const token = self.advance();
                return self.createExpr(.{ .float = self.parseFloat(token.lexeme) catch return self.fail("invalid float literal") });
            },
            .string_lit => {
                const token = self.advance();
                return self.createExpr(.{ .string = try self.decodeString(token.lexeme) });
            },
            .kw_true, .kw_false => {
                const value = self.peek().kind == .kw_true;
                _ = self.advance();
                return self.createExpr(.{ .boolean = value });
            },
            .kw_nil => {
                _ = self.advance();
                return self.createExpr(.nil);
            },
            .bang => {
                _ = self.advance();
                return self.createExpr(.{ .error_literal = try self.parsePath(false) });
            },
            .dotdot, .dotdot_eq => {
                const inclusive = self.peek().kind == .dotdot_eq;
                _ = self.advance();
                var end: ?*ast.Expr = null;
                if (!self.atExprEnd() and !self.at(.comma) and !self.at(.rparen) and !self.at(.rbracket)) {
                    end = try self.parseExprBP(6, options);
                } else if (inclusive) {
                    return self.fail("expected end of inclusive range");
                }
                return self.createExpr(.{ .range = .{ .start = null, .end = end, .inclusive = inclusive } });
            },
            .lparen => {
                if (self.looksLikeFunctionSignatureAt(self.index)) {
                    return self.parseFunctionExpr(false);
                }
                _ = self.advance();
                const expr = try self.parseExpression();
                _ = try self.expect(.rparen, "expected `)` after expression");
                return expr;
            },
            .lbracket => return self.parseListExpr(),
            .lbrace => {
                if (self.looksLikeRowLiteral()) return self.parseRowLiteral();
                return self.createExpr(.{ .block = try self.parseBraceBlock() });
            },
            .kw_async => {
                _ = self.advance();
                if (!self.looksLikeFunctionSignatureAt(self.index)) return self.fail("expected async function parameters");
                return self.parseFunctionExpr(true);
            },
            .kw_if => return self.parseIfExpr(),
            .kw_match => return self.parseMatchExpr(),
            .identifier, .kw_crate, .kw_self, .kw_super => {
                if (self.peek().kind == .identifier and std.mem.eql(u8, self.peek().lexeme, "map") and self.peekAt(1).kind == .lbracket) {
                    return self.parseMapLiteral();
                }
                const path = try self.parseExpressionPath();
                if (options.allow_struct_literal and self.at(.lbrace)) {
                    return self.parseStructLiteral(path);
                }
                return self.createExpr(.{ .path = path });
            },
            else => return self.fail("expected expression"),
        }
    }

    fn parseListExpr(self: *Parser) ParserError!*ast.Expr {
        _ = try self.expect(.lbracket, "expected `[`");
        var items = std.ArrayList(*ast.Expr).empty;
        if (!self.at(.rbracket)) {
            while (true) {
                try items.append(self.allocator, try self.parseExpression());
                if (self.match(.comma) == null) break;
                if (self.at(.rbracket)) break;
            }
        }
        _ = try self.expect(.rbracket, "expected `]` after list");
        return self.createExpr(.{ .list = try items.toOwnedSlice(self.allocator) });
    }

    /// Distinguish `{ a, b, c }` (anonymous row value) from a block expression.
    /// A row literal has at least one comma directly inside the braces, outside
    /// any nested `()`/`[]`/`{}`.  `{ expr }`, `{ stmt; stmt }`, and `{}` stay
    /// blocks, so existing block expressions are unchanged.
    fn looksLikeRowLiteral(self: *const Parser) bool {
        if (self.peek().kind != .lbrace) return false;
        var brace_depth: usize = 0;
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var i = self.index;
        while (i < self.tokens.len) : (i += 1) {
            switch (self.tokens[i].kind) {
                .lbrace => brace_depth += 1,
                .rbrace => {
                    if (brace_depth == 0) return false;
                    brace_depth -= 1;
                    if (brace_depth == 0) return false;
                },
                .lparen => paren_depth += 1,
                .rparen => {
                    if (paren_depth > 0) paren_depth -= 1;
                },
                .lbracket => bracket_depth += 1,
                .rbracket => {
                    if (bracket_depth > 0) bracket_depth -= 1;
                },
                .comma => {
                    if (brace_depth == 1 and paren_depth == 0 and bracket_depth == 0) return true;
                },
                .eof => return false,
                else => {},
            }
        }
        return false;
    }

    fn parseRowLiteral(self: *Parser) ParserError!*ast.Expr {
        _ = try self.expect(.lbrace, "expected `{`");
        var items = std.ArrayList(*ast.Expr).empty;
        while (true) {
            self.skipBraceNoise();
            if (self.at(.rbrace) or self.at(.eof)) break;
            try items.append(self.allocator, try self.parseExpression());
            if (self.match(.comma) != null) continue;
            self.skipBraceNoise();
            if (self.at(.rbrace)) break;
            return self.fail("expected `,` or `}` in row literal");
        }
        _ = try self.expect(.rbrace, "expected `}` after row literal");
        return self.createExpr(.{ .row_literal = try items.toOwnedSlice(self.allocator) });
    }

    fn parseStructLiteral(self: *Parser, path: ast.Path) ParserError!*ast.Expr {
        _ = try self.expect(.lbrace, "expected `{`");
        var fields = std.ArrayList(ast.FieldInit).empty;
        while (!self.at(.rbrace) and !self.at(.eof)) {
            if (self.match(.comma) != null) continue;
            if (self.at(.newline) or self.at(.semicolon) or self.at(.indent) or self.at(.dedent)) {
                _ = self.advance();
                continue;
            }
            const name = (try self.expect(.identifier, "expected field name")).lexeme;
            const value = if (self.match(.colon) != null)
                try self.parseExpression()
            else
                try self.createExpr(.{ .path = .{ .segments = try self.singlePathSegment(name) } });
            try fields.append(self.allocator, .{ .name = name, .value = value });
            _ = self.match(.comma);
        }
        _ = try self.expect(.rbrace, "expected `}` after struct literal");
        return self.createExpr(.{ .struct_literal = .{
            .path = path,
            .fields = try fields.toOwnedSlice(self.allocator),
        } });
    }

    fn singlePathSegment(self: *Parser, name: []const u8) ParserError![]ast.PathSegment {
        const segments = try self.allocator.alloc(ast.PathSegment, 1);
        segments[0] = .{ .name = name, .args = &.{} };
        return segments;
    }

    fn parseIfExpr(self: *Parser) ParserError!*ast.Expr {
        _ = try self.expect(.kw_if, "expected `if`");
        var branches = std.ArrayList(ast.IfBranch).empty;
        const condition = try self.parseExprBP(0, .{ .allow_struct_literal = false });
        try branches.append(self.allocator, .{
            .condition = condition,
            .body = try self.parseBlock(),
        });
        self.skipNewlines();
        while (self.match(.kw_elif) != null) {
            const elif_condition = try self.parseExprBP(0, .{ .allow_struct_literal = false });
            try branches.append(self.allocator, .{
                .condition = elif_condition,
                .body = try self.parseBlock(),
            });
            self.skipNewlines();
        }
        self.skipNewlines();
        const else_body = if (self.match(.kw_else) != null) try self.parseBlock() else null;
        return self.createExpr(.{ .if_expr = .{
            .branches = try branches.toOwnedSlice(self.allocator),
            .else_body = else_body,
        } });
    }

    fn parseMatchExpr(self: *Parser) ParserError!*ast.Expr {
        _ = try self.expect(.kw_match, "expected `match`");
        const scrutinee = try self.parseExprBP(0, .{ .allow_struct_literal = false });
        const arms = try self.parseMatchBody();
        return self.createExpr(.{ .match_expr = .{
            .scrutinee = scrutinee,
            .arms = arms,
        } });
    }

    fn parseMatchBody(self: *Parser) ParserError![]ast.MatchArm {
        if (self.match(.lbrace) != null) {
            const arms = try self.parseMatchArms(.rbrace, true);
            _ = try self.expect(.rbrace, "expected `}` after match arms");
            return arms;
        }
        _ = try self.expect(.colon, "expected `:` or `{` after match subject");
        if (self.match(.newline) != null) {
            _ = try self.expect(.indent, "expected indented match arms");
            const arms = try self.parseMatchArms(.dedent, false);
            _ = try self.expect(.dedent, "expected dedent after match arms");
            return arms;
        }
        var arms = std.ArrayList(ast.MatchArm).empty;
        try arms.append(self.allocator, try self.parseMatchArm());
        return arms.toOwnedSlice(self.allocator);
    }

    fn parseMatchArms(self: *Parser, stop: syntax.TokenKind, brace: bool) ParserError![]ast.MatchArm {
        var arms = std.ArrayList(ast.MatchArm).empty;
        while (true) {
            if (brace) {
                self.skipBraceNoise();
            } else {
                self.skipSeparators();
            }
            if (self.at(stop) or self.at(.eof)) break;
            try arms.append(self.allocator, try self.parseMatchArm());
        }
        return arms.toOwnedSlice(self.allocator);
    }

    fn parseMatchArm(self: *Parser) ParserError!ast.MatchArm {
        const pattern = try self.parsePattern();
        const guard = if (self.match(.kw_if) != null) try self.parseExpression() else null;

        var body: *ast.Block = undefined;
        if (self.at(.lbrace)) {
            body = try self.parseBraceBlock();
        } else {
            _ = try self.expect(.colon, "expected `:` or `{` after match pattern");
            body = try self.parseBodyAfterColon();
        }
        return .{ .pattern = pattern, .guard = guard, .body = body };
    }

    // ------------------------------------------------------------------
    // Literals
    // ------------------------------------------------------------------

    fn cleanNumericLiteral(self: *Parser, raw: []const u8) ParserError![]const u8 {
        var out = std.ArrayList(u8).empty;
        for (raw) |ch| {
            if (ch != '_') try out.append(self.allocator, ch);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn parseInteger(self: *Parser, raw: []const u8) !i64 {
        const cleaned = try self.cleanNumericLiteral(raw);
        return std.fmt.parseInt(i64, cleaned, 10);
    }

    fn parseFloat(self: *Parser, raw: []const u8) !f64 {
        const cleaned = try self.cleanNumericLiteral(raw);
        return std.fmt.parseFloat(f64, cleaned);
    }

    fn decodeString(self: *Parser, raw: []const u8) ParserError![]const u8 {
        if (raw.len < 2) return self.fail("invalid string literal");
        var out = std.ArrayList(u8).empty;
        var i: usize = 1;
        while (i + 1 < raw.len) : (i += 1) {
            const ch = raw[i];
            if (ch != '\\') {
                try out.append(self.allocator, ch);
                continue;
            }
            i += 1;
            if (i + 1 >= raw.len) return self.fail("unterminated string escape");
            const escaped: u8 = switch (raw[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '0' => 0,
                '\\' => '\\',
                '"' => '"',
                '\'' => '\'',
                else => return self.fail("unsupported string escape"),
            };
            try out.append(self.allocator, escaped);
        }
        return out.toOwnedSlice(self.allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectAst(source: []const u8) !Ast {
    const result = try parse(std.testing.allocator, source);
    return switch (result) {
        .ast => |tree| tree,
        .diagnostic => |diagnostic| {
            std.debug.print("parse failed at {d}:{d}: {s}\n", .{
                diagnostic.line,
                diagnostic.column,
                diagnostic.message,
            });
            return error.TestUnexpectedResult;
        },
    };
}

fn expectParseDiagnostic(source: []const u8) !Diagnostic {
    const result = try parse(std.testing.allocator, source);
    return switch (result) {
        .ast => |tree| blk: {
            var owned = tree;
            owned.deinit();
            break :blk error.TestUnexpectedResult;
        },
        .diagnostic => |diagnostic| diagnostic,
    };
}

test "parses declarations and assignments in a function body" {
    const source =
        \\f <- () -> i32:
        \\    a <- 10
        \\    b := 10
        \\    b += 1
        \\    b = 15
        \\    b
    ;
    var tree = try expectAst(source);
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 1), tree.module.items.len);
    const fn_decl = tree.module.items[0].kind.function;
    try std.testing.expectEqualStrings("f", fn_decl.name);
    try std.testing.expectEqual(@as(usize, 0), fn_decl.params.len);
    const block = fn_decl.body.block;
    try std.testing.expectEqual(@as(usize, 5), block.entries.len);
    try std.testing.expect(block.entries[0].stmt.* == .binding);
    try std.testing.expect(block.entries[1].stmt.* == .binding);
    try std.testing.expect(block.entries[2].stmt.* == .assign);
    try std.testing.expect(block.entries[3].stmt.* == .assign);
    try std.testing.expect(block.entries[4].stmt.* == .expr);
}

test "parses indented assignment values" {
    const source =
        \\colour <-
        \\    if field.focused: [1.0, 1.0, 1.0, 1.0]
        \\    else: [0.82, 0.86, 0.92, 1.0]
        \\run <- () -> i32:
        \\    x :=
        \\        compute(1, 2)
        \\    x =
        \\        3
        \\    x
    ;
    var tree = try expectAst(source);
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 2), tree.module.items.len);
    const colour = tree.module.items[0].kind.binding;
    try std.testing.expectEqualStrings("colour", colour.name);
    try std.testing.expect(colour.value.* == .if_expr);

    const fn_decl = tree.module.items[1].kind.function;
    const block = fn_decl.body.block;
    try std.testing.expectEqual(@as(usize, 3), block.entries.len);
    const binding = block.entries[0].stmt.*.binding;
    try std.testing.expectEqualStrings("x", binding.name);
    try std.testing.expect(binding.value.* == .call);
    const assign = block.entries[1].stmt.*.assign;
    try std.testing.expectEqualStrings("x", assign.target.path.segments[0].name);
    try std.testing.expect(assign.value.* == .int);
}

test "parses function expression bodies" {
    const source =
        \\add <- (a: i32, b: i32) -> i32 = a + b
        \\make <- () -> i32 = 2
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 2), tree.module.items.len);
    try std.testing.expect(tree.module.items[0].kind == .function);
    try std.testing.expect(tree.module.items[1].kind == .function);
}

test "parses if, match, loops, break, and continue" {
    const source =
        \\run <- () -> i32:
        \\    if a:
        \\        print("a")
        \\    elif b:
        \\        print("b")
        \\    else:
        \\        print("c")
        \\    match foo:
        \\        Bar(f): print("bar: " + f as str)
        \\        Baz(f): print("baz: " + f as str)
        \\        _: ret !MyError::NotBazOrBar
        \\    loop:
        \\        if a: cont
        \\        break
        \\    for i in 0..5:
        \\        print(i)
        \\    while a:
        \\        a = false
        \\    0
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const block = tree.module.items[0].kind.function.body.block;
    try std.testing.expect(block.entries.len >= 6);
    try std.testing.expect(block.entries[0].stmt.*.expr.* == .if_expr);
    try std.testing.expect(block.entries[1].stmt.*.expr.* == .match_expr);
    try std.testing.expect(block.entries[2].stmt.* == .loop_stmt);
    try std.testing.expect(block.entries[3].stmt.* == .for_stmt);
    try std.testing.expect(block.entries[4].stmt.* == .while_stmt);
}

test "parses aggregates, impl, use, and mod" {
    const source =
        \\use std::collections::{List, Map as M};
        \\mod inner {
        \\    pub const_value <- 1
        \\}
        \\@resource
        \\Foo<T> <- struct where T: Bound
        \\    a: i32,
        \\    pub b: u32,
        \\    c: T,
        \\Bar <- enum
        \\    Unit,
        \\    Pair(i32, u32),
        \\    Named { x: i32, y: u32 },
        \\Rows <- table
        \\    a: i32,
        \\    b: u32,
        \\    ...
        \\Update <- trigger
        \\    a: i32
        \\impl<T> Foo<T> where T: Bound:
        \\    new <- () -> Foo<T> = Foo { a: 0, b: 0, c: 0 }
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 7), tree.module.items.len);
    try std.testing.expect(tree.module.items[0].kind == .use);
    try std.testing.expect(tree.module.items[1].kind == .mod);
    try std.testing.expect(tree.module.items[2].kind == .struct_decl);
    try std.testing.expect(tree.module.items[3].kind == .enum_decl);
    try std.testing.expect(tree.module.items[4].kind == .table_decl);
    try std.testing.expect(tree.module.items[5].kind == .trigger_decl);
    try std.testing.expect(tree.module.items[2].kind.struct_decl.fields.len == 3);
    try std.testing.expect(tree.module.items[2].kind.struct_decl.where_clause != null);
}

test "parses sys queries and resources" {
    const source =
        \\Update <- trigger
        \\    a: i32
        \\@trigger(Update)
        \\foo <- sys (
        \\    update: &Update,
        \\    queries: select &a, &b from Foo where a < 5,
        \\    foo: res &mut foo
        \\):
        \\    foo.a += update.a
        \\    for query in queries:
        \\        foo.a += query.a - query.b as i32
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const sys = tree.module.items[1].kind.sys;
    try std.testing.expectEqual(@as(usize, 3), sys.params.len);
    try std.testing.expect(sys.params[1] == .query);
    try std.testing.expect(sys.params[2] == .resource);
}

test "parses all type constructors" {
    const source =
        \\Thing <- struct
        \\    a: !i32,
        \\    b: MyError!i32,
        \\    c: ?str,
        \\    d: &Foo,
        \\    e: &mut Foo,
        \\    f: *Foo,
        \\    g: *raw Foo,
        \\    h: (i32, u32) -> bool,
        \\    i: (A) -> B,
        \\    j: () -> B,
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const fields = tree.module.items[0].kind.struct_decl.fields;
    try std.testing.expectEqual(@as(usize, 10), fields.len);
    try std.testing.expect(fields[0].ty.* == .inferred_error);
    try std.testing.expect(fields[1].ty.* == .error_union);
    try std.testing.expect(fields[2].ty.* == .optional);
    try std.testing.expect(fields[3].ty.* == .reference);
    try std.testing.expect(fields[4].ty.*.reference.mutable);
    try std.testing.expect(fields[5].ty.* == .box);
    try std.testing.expect(fields[6].ty.* == .raw_pointer);
    try std.testing.expect(fields[7].ty.* == .function);
    try std.testing.expect(fields[8].ty.* == .function);
    try std.testing.expect(fields[9].ty.* == .function);
}

test "parses expression precedence and ranges" {
    const source =
        \\f <- () -> i32 = 1 + 2 * 3 ..= 5 and not false
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const body = tree.module.items[0].kind.function.body.expr;
    try std.testing.expect(body.* == .binary);
    try std.testing.expectEqual(ast.BinaryOp.and_, body.binary.op);
}

test "reports a useful diagnostic for malformed input" {
    const diagnostic = try expectParseDiagnostic("f <- () -> i32:\n    if\n");
    try std.testing.expect(diagnostic.line >= 2);
    try std.testing.expect(diagnostic.message.len > 0);
}

test "parses brace blocks, struct literals, and brace conditionals" {
    const source =
        \\f <- () -> i32:
        \\    a := Foo {
        \\        x: 1,
        \\        y: 2,
        \\    }
        \\    if true {
        \\        a.x
        \\    } else {
        \\        0
        \\    }
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const block = tree.module.items[0].kind.function.body.block;
    try std.testing.expectEqual(@as(usize, 2), block.entries.len);
    try std.testing.expect(block.entries[0].stmt.* == .binding);
    try std.testing.expect(block.entries[1].stmt.*.expr.* == .if_expr);
}

test "parses anonymous function expressions" {
    const source =
        \\apply <- (f: (i32) -> i32) -> i32 = f(1)
        \\g <- () -> (i32) -> i32 = (x: i32) -> i32 = x + 1
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const apply = tree.module.items[0].kind.function;
    try std.testing.expect(apply.params[0].ty.* == .function);
    const g = tree.module.items[1].kind.function;
    try std.testing.expect(g.body.expr.* == .function);
}

test "parses match guards and struct patterns" {
    const source =
        \\m <- (x: Foo) -> i32:
        \\    match x:
        \\        Bar(f) if f > 0: f
        \\        Baz { a, b }: a + b
        \\        _: 0
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const match = tree.module.items[0].kind.function.body.block.entries[0].stmt.*.expr.match_expr;
    try std.testing.expectEqual(@as(usize, 3), match.arms.len);
    try std.testing.expect(match.arms[0].guard != null);
    try std.testing.expect(match.arms[1].pattern.* == .struct_pattern);
}

test "parses nested type constructors" {
    const source =
        \\nested <- struct
        \\    a: !Foo
        \\    b: Foo!Bar
        \\    c: ?&mut *raw Foo
        \\    d: *?&Foo
        \\    e: (A, B) -> ?C
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const fields = tree.module.items[0].kind.struct_decl.fields;
    try std.testing.expect(fields[0].ty.* == .inferred_error);
    try std.testing.expect(fields[1].ty.* == .error_union);
    try std.testing.expect(fields[2].ty.* == .optional);
    try std.testing.expect(fields[2].ty.*.optional.* == .reference);
    try std.testing.expect(fields[2].ty.*.optional.*.reference.child.* == .raw_pointer);
    try std.testing.expect(fields[3].ty.* == .box);
    try std.testing.expect(fields[3].ty.*.box.* == .optional);
    try std.testing.expect(fields[4].ty.* == .function);
    try std.testing.expect(fields[4].ty.*.function.result.* == .optional);
}

test "parses nested use groups" {
    const source =
        \\use a::{b, c::{d, e as f}};
        \\use a::*;
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 2), tree.module.items.len);
    try std.testing.expect(tree.module.items[0].kind == .use);
    try std.testing.expect(tree.module.items[1].kind == .use);
}

test "reports unexpected layout and missing blocks" {
    try std.testing.expect((try expectParseDiagnostic("  f <- 1\n")).line == 1);
    try std.testing.expect((try expectParseDiagnostic("f <- () -> i32:")).message.len > 0);
}

test "parses top-level mutable and typed bindings" {
    const source =
        \\a <- 10
        \\b := 10
        \\c: Foo := Foo { a: 0 }
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 3), tree.module.items.len);
    try std.testing.expect(tree.module.items[0].kind.binding.mutable == false);
    try std.testing.expect(tree.module.items[1].kind.binding.mutable == true);
    try std.testing.expect(tree.module.items[2].kind.binding.ty != null);
}

test "parses generic function where clauses and method attributes" {
    const source =
        \\map<T> <- (x: T) -> T where T: Bound = x
        \\impl Foo:
        \\    @inline
        \\    pub get <- () -> i32 = 1
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const function = tree.module.items[0].kind.function;
    try std.testing.expectEqual(@as(usize, 1), function.generics.len);
    try std.testing.expect(function.where_clause != null);
    const impl = tree.module.items[1].kind.impl;
    try std.testing.expectEqual(@as(usize, 1), impl.methods.len);
    try std.testing.expect(impl.methods[0].attributes.len == 1);
    try std.testing.expect(impl.methods[0].visibility != null);
}

test "parses brace match bodies and guarded arms" {
    const source =
        \\m <- (x: Foo) -> i32:
        \\    match x {
        \\        Bar(f) if f > 0: f
        \\        Baz { a, b } { a + b }
        \\        _: 0
        \\    }
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const match = tree.module.items[0].kind.function.body.block.entries[0].stmt.*.expr.match_expr;
    try std.testing.expectEqual(@as(usize, 3), match.arms.len);
    try std.testing.expect(match.arms[0].guard != null);
    try std.testing.expect(match.arms[1].body.entries.len == 1);
}

test "parses function expressions with colon bodies and try" {
    const source =
        \\make <- () -> (i32) -> i32 = (x: i32) -> i32: x?
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const outer = tree.module.items[0].kind.function;
    const inner = outer.body.expr.function;
    try std.testing.expect(inner.body.block.entries.len == 1);
    const expr = inner.body.block.entries[0].stmt.*.expr;
    try std.testing.expect(expr.* == .try_expr);
}

test "parses open ranges, bare ret, and word boolean operators" {
    const source =
        \\f <- () -> i32:
        \\    ret
        \\    for i in ..5:
        \\        cont
        \\    for i in 0..:
        \\        break
        \\    1 xor 2 and not false or true
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const block = tree.module.items[0].kind.function.body.block;
    try std.testing.expect(block.entries[0].stmt.*.ret == null);
    try std.testing.expect(block.entries[1].stmt.*.for_stmt.iterable.* == .range);
    try std.testing.expect(block.entries[2].stmt.*.for_stmt.iterable.*.range.start != null);
    try std.testing.expect(block.entries[2].stmt.*.for_stmt.iterable.*.range.end == null);
}

test "rejects table ellipsis before another field" {
    const diagnostic = try expectParseDiagnostic(
        \\T <- table
        \\    ...
        \\    a: i32
    );
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "...") != null);
}

test "parses attributes on struct fields" {
    const source =
        \\S <- struct
        \\    @json
        \\    a: i32,
        \\    pub b: u32,
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const fields = tree.module.items[0].kind.struct_decl.fields;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expect(fields[0].attributes.len == 1);
    try std.testing.expect(fields[1].visibility != null);
}

test "attaches elif and else after brace blocks" {
    const source =
        \\f <- () -> i32:
        \\    if a {
        \\        1
        \\    }
        \\    elif b {
        \\        2
        \\    }
        \\    else {
        \\        3
        \\    }
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const block = tree.module.items[0].kind.function.body.block;
    const if_expr = block.entries[0].stmt.*.expr.if_expr;
    try std.testing.expectEqual(@as(usize, 2), if_expr.branches.len);
    try std.testing.expect(if_expr.else_body != null);
}

test "does not steal an outer else for a nested if" {
    const source =
        \\f <- () -> i32:
        \\    if a:
        \\        if b:
        \\            1
        \\    else:
        \\        2
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const outer = tree.module.items[0].kind.function.body.block.entries[0].stmt.*.expr.if_expr;
    try std.testing.expect(outer.else_body != null);
    try std.testing.expect(outer.branches[0].body.entries[0].stmt.*.expr.if_expr.else_body == null);
}

test "parses the function declaration forms from the language sample" {
    const source =
        \\foo <- (a: i32) -> i32:
        \\    ret a + 5
        \\bar <- (a: i32) -> i32 = a + 5
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const foo = tree.module.items[0].kind.function;
    try std.testing.expectEqual(@as(usize, 1), foo.params.len);
    try std.testing.expect(foo.body == .block);
    const bar = tree.module.items[1].kind.function;
    try std.testing.expect(bar.body == .expr);
}

test "parses generic struct literals and calls without breaking comparisons" {
    const source =
        \\f <- () -> i32:
        \\    x := Foo<T> { a: 0 }
        \\    foo<T>(1)
        \\    a < b
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const block = tree.module.items[0].kind.function.body.block;
    try std.testing.expect(block.entries[0].stmt.*.binding.value.* == .struct_literal);
    try std.testing.expect(block.entries[1].stmt.*.expr.* == .call);
    try std.testing.expect(block.entries[2].stmt.*.expr.* == .binary);
}

test "parses literals, tuple, path, struct, and or-patterns" {
    const source =
        \\f <- (x: Foo) -> i32:
        \\    match x:
        \\        1 | 2: 1
        \\        (a, b): a
        \\        Foo::Bar(f): f
        \\        Baz { a, b: c }: a + c
        \\        true: 1
        \\        nil: 0
        \\        _: 0
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const arms = tree.module.items[0].kind.function.body.block.entries[0].stmt.*.expr.match_expr.arms;
    try std.testing.expectEqual(@as(usize, 7), arms.len);
    try std.testing.expect(arms[0].pattern.* == .or_pattern);
    try std.testing.expect(arms[1].pattern.* == .tuple);
    try std.testing.expect(arms[2].pattern.* == .tuple_struct);
    try std.testing.expect(arms[3].pattern.* == .struct_pattern);
    try std.testing.expect(arms[6].pattern.* == .wildcard);
}

test "parses subscript, list, block expressions, and numeric separators" {
    const source =
        \\f <- () -> i32:
        \\    a := [1_000, 2]
        \\    b := { 1 }
        \\    a[0]
        \\    a[1, 0]
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const block = tree.module.items[0].kind.function.body.block;
    try std.testing.expect(block.entries[0].stmt.*.binding.value.* == .list);
    try std.testing.expect(block.entries[1].stmt.*.binding.value.* == .block);
    try std.testing.expect(block.entries[2].stmt.*.expr.* == .index);
    const one = block.entries[2].stmt.*.expr.index;
    try std.testing.expectEqual(@as(usize, 1), one.indices.len);
    const two = block.entries[3].stmt.*.expr.index;
    try std.testing.expectEqual(@as(usize, 2), two.indices.len);
    try std.testing.expect(two.indices[0].* == .int and two.indices[1].* == .int);
}

test "parses visibility scopes, external modules, and aliased imports" {
    const source =
        \\pub(crate) mod inner;
        \\pub use crate::foo::{Bar as Baz, self};
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 2), tree.module.items.len);
    try std.testing.expect(tree.module.items[0].visibility != null);
    try std.testing.expect(tree.module.items[0].kind.mod.items == null);
    try std.testing.expect(tree.module.items[1].visibility != null);
}

test "parses multiple impl methods with layout and expression bodies" {
    const source =
        \\impl Foo:
        \\    a <- () -> i32:
        \\        1
        \\    b <- () -> i32 = 2
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const impl = tree.module.items[0].kind.impl;
    try std.testing.expectEqual(@as(usize, 2), impl.methods.len);
    try std.testing.expect(impl.methods[0].function.body == .block);
    try std.testing.expect(impl.methods[1].function.body == .expr);
}

test "if and match can be binding expressions" {
    const source =
        \\x <- if a:
        \\    1
        \\else:
        \\    2
        \\y <- match z:
        \\    Some(v): v
        \\    _: 0
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 2), tree.module.items.len);
    try std.testing.expect(tree.module.items[0].kind.binding.value.* == .if_expr);
    try std.testing.expect(tree.module.items[1].kind.binding.value.* == .match_expr);
}

test "parses borrow, mutable borrow, and deref expressions" {
    const source =
        \\f <- (p: &mut i32, q: &i32) -> i32:
        \\    a := &q
        \\    b := &mut p
        \\    *p
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const block = tree.module.items[0].kind.function.body.block;
    try std.testing.expect(block.entries[0].stmt.*.binding.value.*.unary.op == .borrow_shared);
    try std.testing.expect(block.entries[1].stmt.*.binding.value.*.unary.op == .borrow_mut);
    try std.testing.expect(block.entries[2].stmt.*.expr.*.unary.op == .deref);
}

test "parses native method namespaces and typed raw pointer access" {
    const source =
        \\f <- (p: *raw u32, x: f32) -> u32:
        \\    q := p as *raw u8
        \\    v := p[0]
        \\    *p = 1
        \\    f32::sin(x)
    ;
    var tree = try expectAst(source);
    defer tree.deinit();
    const block = tree.module.items[0].kind.function.body.block;
    try std.testing.expect(block.entries[0].stmt.*.binding.value.* == .cast);
    try std.testing.expect(block.entries[0].stmt.*.binding.value.*.cast.ty.* == .raw_pointer);
    try std.testing.expect(block.entries[1].stmt.*.binding.value.* == .index);
    try std.testing.expect(block.entries[2].stmt.* == .assign);
    try std.testing.expect(block.entries[2].stmt.*.assign.target.*.unary.op == .deref);
    try std.testing.expect(block.entries[3].stmt.*.expr.* == .call);
    const callee = block.entries[3].stmt.*.expr.*.call.callee;
    try std.testing.expectEqual(@as(usize, 2), callee.path.segments.len);
    try std.testing.expectEqualStrings("f32", callee.path.segments[0].name);
    try std.testing.expectEqualStrings("sin", callee.path.segments[1].name);
}

test "parses async functions, prefix await/spawn, and trigger calls" {
    var tree = try expectAst(
        \\load <- async (path: i32) -> i32 = path + 1
        \\inline := async (x: i32) -> i32 = x
        \\Update <- trigger
        \\    amount: i32
        \\run <- async () -> ():
        \\    task := spawn load(1)
        \\    value := await task
        \\    await Update(10)
    );
    defer tree.deinit();

    try std.testing.expect(tree.module.items[0].kind.function.is_async);
    try std.testing.expect(tree.module.items[1].kind.binding.value.* == .function);
    try std.testing.expect(tree.module.items[1].kind.binding.value.function.is_async);
    try std.testing.expect(tree.module.items[2].kind == .trigger_decl);
    try std.testing.expect(tree.module.items[3].kind.function.is_async);
}

test "parses vector, matrix, map, and str types" {
    var tree = try expectAst(
        \\v: [i32] := [1, 2, 3]
        \\w: [i32; 3] := [1, 2, 3]
        \\m: [f64; 2, 3] := [[1.0]]
        \\tbl: map[str, i32] := nil
        \\name: str := "engine7"
    );
    defer tree.deinit();
    try std.testing.expect(tree.module.items[0].kind.binding.ty.?.array.length == null);
    try std.testing.expectEqual(@as(i64, 3), tree.module.items[1].kind.binding.ty.?.array.length.?.int);
    try std.testing.expect(tree.module.items[2].kind.binding.ty.?.array.columns != null);
    try std.testing.expect(tree.module.items[3].kind.binding.ty.?.* == .map);
    try std.testing.expect(tree.module.items[4].kind.binding.ty.?.* == .path);
}

test "parses statement bindings with semicolons inside their type" {
    var tree = try expectAst(
        \\f <- () -> i32:
        \\    fixed: [f32; 3] <- [1.0, 2.0, 3.0]
        \\    matrix: [f32; 2, 2] := [[1.0, 0.0], [0.0, 1.0]]
        \\    ret 0
    );
    defer tree.deinit();

    const block = tree.module.items[0].kind.function.body.block;
    try std.testing.expectEqual(@as(usize, 3), block.entries.len);

    const fixed = block.entries[0].stmt.*.binding;
    try std.testing.expectEqualStrings("fixed", fixed.name);
    try std.testing.expect(!fixed.mutable);
    try std.testing.expect(fixed.ty.?.array.columns == null);
    try std.testing.expectEqual(@as(i64, 3), fixed.ty.?.array.length.?.int);

    const matrix = block.entries[1].stmt.*.binding;
    try std.testing.expectEqualStrings("matrix", matrix.name);
    try std.testing.expect(matrix.mutable);
    try std.testing.expect(matrix.ty.?.array.columns != null);
}

test "parses unsafe blocks and uninitialized declarations" {
    var tree = try expectAst(
        \\f <- (p: *raw i32) -> i32:
        \\    unsafe:
        \\        out: i32
        \\        q := p + 1
        \\        out = *q
        \\        ret out
    );
    defer tree.deinit();
    const body = tree.module.items[0].kind.function.body.block;
    try std.testing.expect(body.entries[0].stmt.* == .unsafe_block);
    const inner = body.entries[0].stmt.unsafe_block.entries;
    try std.testing.expect(inner[0].stmt.* == .uninitialized);
}

test "parses map literals" {
    var tree = try expectAst(
        \\m := map[str, i32] { "a": 1, "b": 2 }
    );
    defer tree.deinit();
    try std.testing.expect(tree.module.items[0].kind.binding.value.* == .map_literal);
    try std.testing.expectEqual(@as(usize, 2), tree.module.items[0].kind.binding.value.map_literal.entries.len);
}

test "parses name-first traits with supertraits and required methods" {
    var tree = try expectAst(
        \\UIElement <- trait
        \\UIRenderable <- trait : UIElement
        \\    render <- async (&self, &mut Gpu) -> !nil
        \\UIInteractable <- trait : UIElement
        \\    interact <- (&mut self, &Input) -> !nil
    );
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 3), tree.module.items.len);
    const base = tree.module.items[0].kind.trait_decl;
    try std.testing.expectEqualStrings("UIElement", base.name);
    try std.testing.expectEqual(@as(usize, 0), base.bounds.len);
    try std.testing.expectEqual(@as(usize, 0), base.methods.len);

    const renderable = tree.module.items[1].kind.trait_decl;
    try std.testing.expectEqualStrings("UIRenderable", renderable.name);
    try std.testing.expectEqual(@as(usize, 1), renderable.bounds.len);
    try std.testing.expectEqualStrings("UIElement", renderable.bounds[0].path.segments[0].name);
    try std.testing.expectEqual(@as(usize, 1), renderable.methods.len);

    const render = renderable.methods[0];
    try std.testing.expectEqualStrings("render", render.name);
    try std.testing.expect(render.is_async);
    try std.testing.expect(render.receiver != null);
    try std.testing.expect(render.receiver.?.by_ref);
    try std.testing.expect(!render.receiver.?.mutable);
    try std.testing.expectEqual(@as(usize, 1), render.params.len);
    try std.testing.expect(render.params[0].name == null);
    try std.testing.expect(render.params[0].ty.* == .reference);
    try std.testing.expect(render.params[0].ty.reference.mutable);
    try std.testing.expectEqualStrings("Gpu", render.params[0].ty.reference.child.path.segments[0].name);
    try std.testing.expect(render.result.* == .inferred_error);
    try std.testing.expect(render.result.inferred_error.* == .nil_type);

    const interact = tree.module.items[2].kind.trait_decl.methods[0];
    try std.testing.expectEqualStrings("interact", interact.name);
    try std.testing.expect(!interact.is_async);
    try std.testing.expect(interact.receiver.?.mutable);
    try std.testing.expectEqual(@as(usize, 1), interact.params.len);
    try std.testing.expect(interact.params[0].ty.reference.mutable == false);
    try std.testing.expect(interact.result.inferred_error.* == .nil_type);
}

test "parses keyword-first traits with braced and named method requirements" {
    var tree = try expectAst(
        \\trait Foo: Bar {
        \\    poke <- (&self, x: i32) -> !nil;
        \\    reset <- (&mut self) -> nil
        \\}
        \\trait Empty
    );
    defer tree.deinit();

    const foo = tree.module.items[0].kind.trait_decl;
    try std.testing.expectEqual(@as(usize, 1), foo.bounds.len);
    try std.testing.expectEqualStrings("Bar", foo.bounds[0].path.segments[0].name);
    try std.testing.expectEqual(@as(usize, 2), foo.methods.len);

    const poke = foo.methods[0];
    try std.testing.expectEqualStrings("poke", poke.name);
    try std.testing.expect(poke.receiver.?.by_ref);
    try std.testing.expectEqual(@as(usize, 1), poke.params.len);
    try std.testing.expectEqualStrings("x", poke.params[0].name.?);
    try std.testing.expect(poke.params[0].ty.* == .path);
    try std.testing.expect(poke.result.* == .inferred_error);

    const reset = foo.methods[1];
    try std.testing.expect(reset.receiver.?.mutable);
    try std.testing.expectEqual(@as(usize, 0), reset.params.len);
    try std.testing.expect(reset.result.* == .nil_type);

    const empty = tree.module.items[1].kind.trait_decl;
    try std.testing.expectEqual(@as(usize, 0), empty.methods.len);
}

test "parses nil result types without changing error unions" {
    var tree = try expectAst(
        \\f <- () -> !nil:
        \\    ret
        \\g <- () -> nil:
        \\    ret
        \\h <- () -> !i32 = 1
    );
    defer tree.deinit();

    try std.testing.expect(tree.module.items[0].kind.function.result.* == .inferred_error);
    try std.testing.expect(tree.module.items[0].kind.function.result.inferred_error.* == .nil_type);
    try std.testing.expect(tree.module.items[1].kind.function.result.* == .nil_type);
    try std.testing.expect(tree.module.items[2].kind.function.result.* == .inferred_error);
    try std.testing.expect(tree.module.items[2].kind.function.result.inferred_error.* == .path);
}

test "parses sys reference parameter modifiers" {
    var tree = try expectAst(
        \\Comp <- struct
        \\    a: i32
        \\T <- trait
        \\N <- struct
        \\    a: i32
        \\s <- sys (
        \\    n_mut: res &mut N,
        \\    n_shared: res &N,
        \\    t_mut: select &mut T from Comp,
        \\    t_shared: select &T from Comp,
        \\    n_plain: res N,
        \\    q_plain: select &a from Comp,
        \\):
        \\    ret
    );
    defer tree.deinit();

    const sys = tree.module.items[3].kind.sys;
    try std.testing.expectEqual(@as(usize, 6), sys.params.len);

    const n_mut = sys.params[0].resource.ty;
    try std.testing.expect(n_mut.* == .reference and n_mut.reference.mutable);
    try std.testing.expectEqualStrings("N", n_mut.reference.child.path.segments[0].name);

    const n_shared = sys.params[1].resource.ty;
    try std.testing.expect(n_shared.* == .reference and !n_shared.reference.mutable);

    const t_mut = sys.params[2].query;
    try std.testing.expect(t_mut.projections[0].mutable);
    try std.testing.expectEqualStrings("T", t_mut.projections[0].path.segments[0].name);
    try std.testing.expectEqualStrings("Comp", t_mut.from.path.segments[0].name);

    const t_shared = sys.params[3].query;
    try std.testing.expect(!t_shared.projections[0].mutable);
    try std.testing.expectEqualStrings("T", t_shared.projections[0].path.segments[0].name);

    const n_plain = sys.params[4].resource.ty;
    try std.testing.expect(n_plain.* == .path);
    try std.testing.expectEqualStrings("N", n_plain.path.segments[0].name);

    const q_plain = sys.params[5].query;
    try std.testing.expect(!q_plain.projections[0].mutable);
    try std.testing.expectEqualStrings("a", q_plain.projections[0].path.segments[0].name);
}

test "parses external modules without semicolons and plugin declarations" {
    var tree = try expectAst(
        \\mod ui
        \\Ui <- plugin
        \\    init <- sys (
        \\        commands: &mut Commands
        \\    ):
        \\        ret
        \\@plugin(Ui)
        \\@resource
        \\UINode <- struct
        \\    pos: [f32; 2]
    );
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 3), tree.module.items.len);
    const module = tree.module.items[0].kind.mod;
    try std.testing.expectEqualStrings("ui", module.name);
    try std.testing.expect(module.items == null);

    const plugin = tree.module.items[1].kind.plugin_decl;
    try std.testing.expectEqualStrings("Ui", plugin.name);
    try std.testing.expectEqual(@as(usize, 1), plugin.items.len);
    const init = plugin.items[0].kind.sys;
    try std.testing.expectEqualStrings("init", init.name);
    try std.testing.expectEqual(@as(usize, 1), init.params.len);
    const commands = init.params[0].normal;
    try std.testing.expectEqualStrings("commands", commands.name);
    try std.testing.expect(commands.ty.* == .reference and commands.ty.reference.mutable);
    try std.testing.expectEqualStrings("Commands", commands.ty.reference.child.path.segments[0].name);

    const ui_node = tree.module.items[2];
    try std.testing.expectEqual(@as(usize, 2), ui_node.attributes.len);
    try std.testing.expectEqualStrings("plugin", ui_node.attributes[0].path.segments[0].name);
    try std.testing.expectEqualStrings("resource", ui_node.attributes[1].path.segments[0].name);
}

test "parses empty plugin bodies and newline-terminated external modules" {
    var tree = try expectAst(
        \\mod audio
        \\Ui <- plugin
    );
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 2), tree.module.items.len);
    try std.testing.expect(tree.module.items[0].kind.mod.items == null);
    try std.testing.expectEqual(@as(usize, 0), tree.module.items[1].kind.plugin_decl.items.len);
}

test "parses await query leases, disown statements, and row literals" {
    var tree = try expectAst(
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    commands.add_plugin(Ui)
        \\    disown commands
        \\    commands.add_row(Components, { camera_transform, camera, controller })
        \\    cube_mesh := CubeMesh
        \\    { 1 }
        \\    0
    );
    defer tree.deinit();

    const block = tree.module.items[0].kind.function.body.block;
    try std.testing.expectEqual(@as(usize, 7), block.entries.len);

    const lease = block.entries[0].stmt.*.binding.value;
    try std.testing.expect(lease.* == .prefix);
    try std.testing.expectEqual(ast.PrefixOp.await_, lease.prefix.op);
    try std.testing.expect(lease.prefix.operand.* == .query);
    const query_ty = lease.prefix.operand.query.ty;
    try std.testing.expect(query_ty.* == .reference and query_ty.reference.mutable);
    try std.testing.expectEqualStrings("Commands", query_ty.reference.child.path.segments[0].name);

    try std.testing.expect(block.entries[1].stmt.*.expr.* == .call);
    try std.testing.expect(block.entries[2].stmt.* == .disown);
    try std.testing.expectEqualStrings("commands", block.entries[2].stmt.disown.path.segments[0].name);

    const add_row = block.entries[3].stmt.*.expr.call;
    try std.testing.expectEqual(@as(usize, 2), add_row.args.len);
    try std.testing.expect(add_row.args[1].* == .row_literal);
    try std.testing.expectEqual(@as(usize, 3), add_row.args[1].row_literal.len);

    // `cube_mesh := CubeMesh` parses as a unit-struct constructor value.
    const cube = block.entries[4].stmt.*.binding.value;
    try std.testing.expect(cube.* == .path);
    try std.testing.expectEqualStrings("CubeMesh", cube.path.segments[0].name);

    // `{ 1 }` has no top-level comma, so it stays a block expression.
    try std.testing.expect(block.entries[5].stmt.*.expr.* == .block);
}

test "parses table ellipsis with component attributes" {
    var tree = try expectAst(
        \\@Components
        \\Camera <- struct
        \\    yaw: f32
        \\    pitch: f32
        \\Components <- table
        \\    entity_id: usize,
        \\    ... # automatically collects all @Components types
    );
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 2), tree.module.items.len);
    const camera = tree.module.items[0];
    try std.testing.expectEqual(@as(usize, 1), camera.attributes.len);
    try std.testing.expectEqualStrings("Components", camera.attributes[0].path.segments[0].name);
    const table = tree.module.items[1].kind.table_decl;
    try std.testing.expect(table.has_ellipsis);
    try std.testing.expectEqual(@as(usize, 1), table.fields.len);
    try std.testing.expectEqualStrings("entity_id", table.fields[0].name);
}

test "parses query presence filters and newline-separated sys parameters" {
    var tree = try expectAst(
        \\Components <- table
        \\    entity_id: usize
        \\move_camera <- sys (
        \\    input: &Input,
        \\    controllers: select &mut Camera, &mut CameraController from Components,
        \\):
        \\    ret
        \\spin_cube <- sys (
        \\    transforms: select &mut Transform from Components where has CubeMesh,
        \\    time: &Time,
        \\):
        \\    ret
        \\render_scene <- sys (
        \\    gpu: res &mut Gpu,
        \\    camera: &Camera,
        \\
        \\    cubes: select &CubeMesh, &Transform from Components
        \\    lights: select &PointLight from Components
        \\):
        \\    ret
    );
    defer tree.deinit();

    try std.testing.expectEqual(@as(usize, 4), tree.module.items.len);
    const move_camera = tree.module.items[1].kind.sys;
    try std.testing.expectEqual(@as(usize, 2), move_camera.params.len);
    const controllers = move_camera.params[1].query;
    try std.testing.expectEqual(@as(usize, 2), controllers.projections.len);
    try std.testing.expect(controllers.projections[0].mutable);
    try std.testing.expectEqualStrings("Camera", controllers.projections[0].path.segments[0].name);
    try std.testing.expectEqualStrings("CameraController", controllers.projections[1].path.segments[0].name);

    const spin = tree.module.items[2].kind.sys;
    const transforms = spin.params[0].query;
    try std.testing.expect(transforms.has != null);
    try std.testing.expect(transforms.filter == null);
    try std.testing.expectEqualStrings("CubeMesh", transforms.has.?.path.segments[0].name);

    const render = tree.module.items[3].kind.sys;
    try std.testing.expectEqual(@as(usize, 4), render.params.len);
    try std.testing.expect(render.params[0] == .resource);
    try std.testing.expectEqual(@as(usize, 2), render.params[2].query.projections.len);
    try std.testing.expectEqual(@as(usize, 1), render.params[3].query.projections.len);
    try std.testing.expectEqualStrings("lights", render.params[3].query.name);
}

test "parses empty trigger bodies and rejects stray field assignment" {
    var tree = try expectAst(
        \\Init <- trigger
        \\DeInit <- trigger
        \\run <- () -> i32:
        \\    ret 0
    );
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 3), tree.module.items.len);
    try std.testing.expectEqual(@as(usize, 0), tree.module.items[0].kind.trigger_decl.fields.len);

    const diagnostic = try expectParseDiagnostic(
        \\S <- struct
        \\    pitch: f32
        \\make <- () -> S:
        \\    S {
        \\        pitch: = 0.0
        \\    }
    );
    try std.testing.expect(diagnostic.message.len > 0);

    const row_diagnostic = try expectParseDiagnostic(
        \\f <- () -> i32:
        \\    { a, b c }
    );
    try std.testing.expect(row_diagnostic.message.len > 0);
}

test "parses derive attributes and turbofish decode calls" {
    var tree = try expectAst(
        \\@derive(Serialize, Deserialize)
        \\Point <- struct
        \\    x: f32
        \\    name: str
        \\decode <- () -> Point = json_decode::<Point>("{}")
    );
    defer tree.deinit();

    const item = tree.module.items[0];
    try std.testing.expectEqual(@as(usize, 1), item.attributes.len);
    try std.testing.expectEqualStrings("derive", item.attributes[0].path.segments[0].name);
    try std.testing.expectEqual(@as(usize, 2), item.attributes[0].args.len);
    try std.testing.expectEqualStrings("Serialize", item.attributes[0].args[0].path.segments[0].name);
    try std.testing.expectEqualStrings("Deserialize", item.attributes[0].args[1].path.segments[0].name);

    const call = tree.module.items[1].kind.function.body.expr.call;
    try std.testing.expectEqualStrings("json_decode", call.callee.path.segments[0].name);
    try std.testing.expectEqual(@as(usize, 1), call.callee.path.segments[0].args.len);
    try std.testing.expectEqualStrings("Point", call.callee.path.segments[0].args[0].path.segments[0].name);
}

test "parses method turbofish type arguments" {
    var tree = try expectAst(
        \\f <- (commands: &mut Commands, e: i64) -> !nil:
        \\    commands.remove_component::<Held>(e)
        \\    ret
    );
    defer tree.deinit();
    const block = tree.module.items[0].kind.function.body.block;
    const entry = block.entries[0];
    const call = switch (entry) {
        .stmt => |stmt| stmt.expr.call,
        .item => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), call.type_args.len);
    try std.testing.expectEqualStrings("Held", call.type_args[0].path.segments[0].name);
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
}
