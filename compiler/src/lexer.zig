//! Offside-rule lexer.
//!
//! Layout is Python-like: at bracket depth zero, a change in leading spaces
//! emits `indent`/`dedent` tokens.  Blank and comment-only lines do not affect
//! the indentation stack.  Tabs are rejected in indentation so that a file has
//! exactly one visual width per indentation level.
//!
//! Lexical classes are built with the `zpars` comptime parser-combinator
//! library [zpars]; the layout state machine is kept explicit because
//! indentation is context-sensitive across physical lines.  The offside
//! rule follows Python's layout convention [python]; parser combinators are
//! the standard monadic formulation [hutton1998].

const std = @import("std");
const zpars = @import("zpars");
const syntax = @import("syntax.zig");

const c = zpars.combinators;

const LexError = error{ OutOfMemory, LexFailed };

pub const Diagnostic = struct {
    offset: usize = 0,
    line: usize = 1,
    column: usize = 1,
    message: []const u8,
};

pub const Lexed = struct {
    tokens: []syntax.Token,
    diagnostic: ?Diagnostic = null,
};

pub fn lex(allocator: std.mem.Allocator, source: []const u8) LexError!Lexed {
    var lexer = Lexer{
        .allocator = allocator,
        .source = source,
    };
    const tokens = lexer.run() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LexFailed => {
            lexer.tokens.deinit(lexer.allocator);
            return .{
                .tokens = &.{},
                .diagnostic = lexer.diagnostic.?,
            };
        },
    };
    return .{ .tokens = tokens };
}

const Lexer = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    pos: usize = 0,
    line: usize = 1,
    column: usize = 1,
    tokens: std.ArrayList(syntax.Token) = .empty,
    indent_stack: [256]usize = blk: {
        var stack: [256]usize = undefined;
        stack[0] = 0;
        break :blk stack;
    },
    indent_depth: usize = 1,
    at_line_start: bool = true,
    line_has_code: bool = false,
    bracket_depth: usize = 0,
    diagnostic: ?Diagnostic = null,

    fn run(self: *Lexer) LexError![]syntax.Token {
        while (self.pos < self.source.len) {
            if (self.at_line_start and self.bracket_depth == 0) {
                try self.beginLine();
                if (self.pos >= self.source.len) break;
                // `beginLine` may have consumed a blank/comment line.
                if (self.at_line_start) continue;
            }

            const start_line = self.line;
            const start_col = self.column;
            const ch = self.source[self.pos];

            switch (ch) {
                ' ', '\t', '\r' => self.advance(),
                '\n' => try self.newline(),
                '#' => self.skipComment(),
                '"', '\'' => try self.string(ch, start_line, start_col),
                '0'...'9' => try self.number(start_line, start_col),
                '(', '[' => {
                    const kind: syntax.TokenKind = if (ch == '(') .lparen else .lbracket;
                    try self.emit(kind, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                    self.bracket_depth += 1;
                    self.advance();
                },
                ')', ']' => {
                    const kind: syntax.TokenKind = if (ch == ')') .rparen else .rbracket;
                    try self.emit(kind, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                    if (self.bracket_depth > 0) self.bracket_depth -= 1;
                    self.advance();
                },
                '{' => {
                    try self.emit(.lbrace, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                    self.advance();
                },
                '}' => {
                    try self.emit(.rbrace, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                    self.advance();
                },
                ';' => {
                    try self.emit(.semicolon, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                    self.advance();
                },
                '?' => {
                    try self.emit(.question, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                    self.advance();
                },
                '@' => {
                    try self.emit(.at, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                    self.advance();
                },
                '&' => {
                    try self.emit(.amp, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                    self.advance();
                },
                '|' => {
                    try self.emit(.pipe, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                    self.advance();
                },
                else => {
                    if (isIdentStart(ch)) {
                        try self.identifier(start_line, start_col);
                    } else if (try self.operator(start_line, start_col)) {
                        // consumed by operator()
                    } else if (ch == ':') {
                        try self.emit(.colon, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                        self.advance();
                    } else if (ch == ',') {
                        try self.emit(.comma, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                        self.advance();
                    } else if (ch == '.') {
                        try self.emit(.dot, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                        self.advance();
                    } else if (ch == '=') {
                        try self.emit(.assign, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                        self.advance();
                    } else if (ch == '!') {
                        try self.emit(.bang, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                        self.advance();
                    } else if (ch == '+') {
                        try self.emit(.plus, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                        self.advance();
                    } else if (ch == '-') {
                        try self.emit(.minus, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                        self.advance();
                    } else if (ch == '*') {
                        try self.emit(.star, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                        self.advance();
                    } else if (ch == '/') {
                        try self.emit(.slash, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                        self.advance();
                    } else if (ch == '%') {
                        try self.emit(.percent, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                        self.advance();
                    } else if (ch == '<') {
                        try self.emit(.lt, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                        self.advance();
                    } else if (ch == '>') {
                        try self.emit(.gt, self.source[self.pos..][0..1], start_line, start_col, self.pos);
                        self.advance();
                    } else {
                        return self.fail("unexpected character");
                    }
                },
            }
        }

        try self.finish();
        return self.tokens.toOwnedSlice(self.allocator);
    }

    fn beginLine(self: *Lexer) LexError!void {
        var indent: usize = 0;
        while (self.pos < self.source.len and self.source[self.pos] == ' ') {
            indent += 1;
            self.advance();
        }
        if (self.pos >= self.source.len) return;
        if (self.source[self.pos] == '\t') {
            return self.fail("tabs are not allowed in indentation");
        }
        if (self.source[self.pos] == '\n') {
            self.advance();
            return;
        }
        if (self.source[self.pos] == '#') {
            self.skipComment();
            return;
        }

        self.at_line_start = false;
        const current = self.indent_stack[self.indent_depth - 1];
        if (indent > current) {
            if (self.indent_depth == self.indent_stack.len) {
                return self.fail("indentation nesting is too deep");
            }
            self.indent_stack[self.indent_depth] = indent;
            self.indent_depth += 1;
            try self.emit(.indent, "", self.line, 1, self.pos);
        } else if (indent < current) {
            while (self.indent_depth > 1 and indent < self.indent_stack[self.indent_depth - 1]) {
                self.indent_depth -= 1;
                try self.emit(.dedent, "", self.line, 1, self.pos);
            }
            if (indent != self.indent_stack[self.indent_depth - 1]) {
                return self.fail("inconsistent dedent");
            }
        }
    }

    fn newline(self: *Lexer) LexError!void {
        if (self.bracket_depth > 0) {
            self.advance();
            return;
        }
        if (self.line_has_code) {
            try self.emit(.newline, "\n", self.line, self.column, self.pos);
            self.line_has_code = false;
        }
        self.advance();
        self.at_line_start = true;
    }

    fn finish(self: *Lexer) LexError!void {
        if (self.line_has_code) {
            try self.emit(.newline, "", self.line, self.column, self.pos);
            self.line_has_code = false;
        }
        while (self.indent_depth > 1) {
            self.indent_depth -= 1;
            try self.emit(.dedent, "", self.line, self.column, self.pos);
        }
        try self.emit(.eof, "", self.line, self.column, self.pos);
    }

    fn identifier(self: *Lexer, start_line: usize, start_col: usize) LexError!void {
        const rest = self.source[self.pos..];
        const parsed = Ident.parse(rest) orelse return self.fail("invalid identifier");
        const consumed = rest.len - parsed.rest.len;
        const text = parsed.value;
        const kind = syntax.keyword_map.get(text) orelse .identifier;
        try self.emit(kind, text, start_line, start_col, self.pos);
        self.advanceBy(consumed);
    }

    fn number(self: *Lexer, start_line: usize, start_col: usize) LexError!void {
        const rest = self.source[self.pos..];
        if (FloatLit.parse(rest)) |parsed| {
            const consumed = rest.len - parsed.rest.len;
            try self.emit(.float_lit, parsed.value, start_line, start_col, self.pos);
            self.advanceBy(consumed);
            return;
        }
        const parsed = IntLit.parse(rest) orelse return self.fail("invalid number");
        const consumed = rest.len - parsed.rest.len;
        try self.emit(.int_lit, parsed.value, start_line, start_col, self.pos);
        self.advanceBy(consumed);
    }

    fn string(self: *Lexer, quote: u8, start_line: usize, start_col: usize) LexError!void {
        const start = self.pos;
        self.advance();
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch == quote) {
                self.advance();
                try self.emit(.string_lit, self.source[start..self.pos], start_line, start_col, start);
                return;
            }
            if (ch == '\n') return self.fail("unterminated string literal");
            if (ch == '\\') {
                self.advance();
                if (self.pos >= self.source.len) return self.fail("unterminated escape");
                self.advance();
                continue;
            }
            self.advance();
        }
        return self.fail("unterminated string literal");
    }

    fn operator(self: *Lexer, start_line: usize, start_col: usize) LexError!bool {
        var len = @min(syntax.max_multi_operator_len, self.source.len - self.pos);
        while (len > 0) : (len -= 1) {
            const text = self.source[self.pos..][0..len];
            if (syntax.multi_operator_map.get(text)) |op| {
                try self.emit(op.kind, text, start_line, start_col, self.pos);
                self.advanceBy(len);
                return true;
            }
        }
        return false;
    }

    fn skipComment(self: *Lexer) void {
        while (self.pos < self.source.len and self.source[self.pos] != '\n') self.advance();
    }

    fn emit(
        self: *Lexer,
        kind: syntax.TokenKind,
        lexeme: []const u8,
        line: usize,
        column: usize,
        offset: usize,
    ) LexError!void {
        try self.tokens.append(self.allocator, .{
            .kind = kind,
            .lexeme = lexeme,
            .line = line,
            .column = column,
            .offset = offset,
        });
        switch (kind) {
            .newline, .indent, .dedent, .eof => {},
            else => self.line_has_code = true,
        }
    }

    fn advanceBy(self: *Lexer, count: usize) void {
        for (0..count) |_| self.advance();
    }

    fn advance(self: *Lexer) void {
        if (self.pos >= self.source.len) return;
        if (self.source[self.pos] == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        self.pos += 1;
    }

    fn fail(self: *Lexer, message: []const u8) error{LexFailed} {
        self.diagnostic = .{
            .offset = self.pos,
            .line = self.line,
            .column = self.column,
            .message = message,
        };
        return error.LexFailed;
    }
};

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn isDigitOrUnderscore(ch: u8) bool {
    return std.ascii.isDigit(ch) or ch == '_';
}

// ---------------------------------------------------------------------------
// zpars lexical classes
// ---------------------------------------------------------------------------

const Digits = c.Capture(c.Many(c.Char(isDigitOrUnderscore), .{ .min = 1, .max = 512 }));

const Ident = c.Capture(c.Seq(.{
    c.Char(isIdentStart),
    c.Many(c.Char(isIdentContinue), .{ .max = 1024 }),
}));

const Exponent = c.Seq(.{
    c.AnyOf("eE"),
    c.Optional(c.AnyOf("+-")),
    Digits,
});

const FloatLit = c.Capture(c.Seq(.{
    Digits,
    c.Literal("."),
    Digits,
    c.Optional(Exponent),
}));

const IntLit = c.Capture(c.Many(c.Char(isDigitOrUnderscore), .{ .min = 1, .max = 512 }));

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectKinds(tokens: []const syntax.Token, expected: []const syntax.TokenKind) !void {
    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, 0..) |kind, i| try std.testing.expectEqual(kind, tokens[i].kind);
}

test "layout tokens for a significant-indentation if" {
    const source =
        \\if x:
        \\    y + 1
        \\else:
        \\    y - 1
    ;
    const result = try lex(std.testing.allocator, source);
    defer std.testing.allocator.free(result.tokens);
    try std.testing.expect(result.diagnostic == null);
    try expectKinds(result.tokens, &.{
        .kw_if,      .identifier, .colon,   .newline, .indent,
        .identifier, .plus,       .int_lit, .newline, .dedent,
        .kw_else,    .colon,      .newline, .indent,  .identifier,
        .minus,      .int_lit,    .newline, .dedent,  .eof,
    });
}

test "blank and comment-only lines do not change layout" {
    const source =
        \\x <- 1
        \\
        \\# comment
        \\x + 2
    ;
    const result = try lex(std.testing.allocator, source);
    defer std.testing.allocator.free(result.tokens);
    try std.testing.expect(result.diagnostic == null);
    try expectKinds(result.tokens, &.{
        .identifier, .bind_immutable, .int_lit, .newline,
        .identifier, .plus,           .int_lit, .newline,
        .eof,
    });
}

test "lexes keywords, strings, floats, attributes, and ranges" {
    const source =
        \\@trigger(Update)
        \\if true and 1.5e2 >= 3:
        \\    f("hi\n", 0..=5)
    ;
    const result = try lex(std.testing.allocator, source);
    defer std.testing.allocator.free(result.tokens);
    try std.testing.expect(result.diagnostic == null);
    try expectKinds(result.tokens, &.{
        .at,     .kw_trigger, .lparen,    .identifier, .rparen, .newline,
        .kw_if,  .kw_true,    .kw_and,    .float_lit,  .ge,     .int_lit,
        .colon,  .newline,    .indent,    .identifier, .lparen, .string_lit,
        .comma,  .int_lit,    .dotdot_eq, .int_lit,    .rparen, .newline,
        .dedent, .eof,
    });
}

test "newlines inside brackets are ignored" {
    const source =
        \\f(
        \\  1,
        \\  2,
        \\)
    ;
    const result = try lex(std.testing.allocator, source);
    defer std.testing.allocator.free(result.tokens);
    try std.testing.expect(result.diagnostic == null);
    try expectKinds(result.tokens, &.{
        .identifier, .lparen,  .int_lit, .comma, .int_lit, .comma,
        .rparen,     .newline, .eof,
    });
}

test "tab indentation is rejected" {
    const result = try lex(std.testing.allocator, "if x:\n\ty\n");
    try std.testing.expect(result.diagnostic != null);
    try std.testing.expectEqual(@as(usize, 2), result.diagnostic.?.line);
}

test "inconsistent dedent is rejected" {
    const result = try lex(std.testing.allocator, "a\n  b\n c\n");
    try std.testing.expect(result.diagnostic != null);
}
