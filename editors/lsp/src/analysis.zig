//! Compiler front-end adapter for the e7 language server.
//!
//! Everything semantic lives here: running the lexer/parser/semantic analyzer,
//! converting compiler diagnostics to LSP ranges, and building the document
//! symbol index used by `documentSymbol`, `hover`, `completion`, and
//! `definition`.
//!
//! `Document` borrows its `source` slice; the caller (the server document
//! store) owns the buffer and must keep it alive for the document's lifetime.
//! All returned slices are owned by the document's arena and stay valid until
//! `deinit`.
//!
//! Scope: the index covers top-level items, nested `mod`/`plugin` items,
//! aggregate fields, enum variants, trait/impl methods, and top-level bindings.
//! Resolution is intentionally document-local: the server reports on the file
//! that is open, and cross-file `mod`/`use` resolution is a documented
//! limitation rather than a source of false diagnostics.

const std = @import("std");
const compiler = @import("compiler");
const protocol = @import("protocol");
const project = @import("project");

const ast = compiler.ast;
const lexer = compiler.lexer;
const parser = compiler.parser;
const semantic = compiler.semantic;
const syntax = compiler.syntax;

pub const Position = protocol.Position;
pub const Range = protocol.Range;

pub const Severity = enum(u8) {
    err = 1,
    warning = 2,
    information = 3,
    hint = 4,
};

pub const Diagnostic = struct {
    range: Range,
    severity: Severity = .err,
    message: []const u8,
};

/// LSP `SymbolKind` for document symbols.
pub const SymbolKind = enum(u8) {
    file = 1,
    module = 2,
    namespace = 3,
    class = 5,
    method = 6,
    property = 7,
    field = 8,
    enum_ = 10,
    interface = 11,
    function = 12,
    variable = 13,
    constant = 14,
    enum_member = 22,
    struct_ = 23,
    type_parameter = 26,
};

/// LSP `CompletionItemKind`.
pub const CompletionKind = enum(u8) {
    method = 2,
    function = 3,
    field = 5,
    variable = 6,
    class = 7,
    interface = 8,
    module = 9,
    property = 10,
    keyword = 14,
    constant = 21,
    enum_ = 13,
    enum_member = 20,
    struct_ = 22,
    type_parameter = 25,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    /// Full declaration range.
    range: Range,
    /// Name identifier range.
    selection: Range,
    /// One-line declaration header shown in hovers and symbol details,
    /// allocated in the document arena.
    detail: ?[]const u8 = null,
    /// Index into `Document.symbols` of the enclosing symbol, if any.
    parent: ?u32 = null,
};

pub const CompletionItem = struct {
    label: []const u8,
    kind: CompletionKind,
    detail: ?[]const u8 = null,
};

/// A `:=` binding the analyzer never saw mutated.  The formatter rewrites the
/// declaration operator to `<-`.
pub const MutableCandidate = struct {
    name: []const u8,
    /// Byte offset of the declaration in `Document.source`.
    offset: usize,
};

pub const Hover = struct {
    /// Markdown contents, allocated in the document arena.
    markdown: []const u8,
    range: Range,
};

pub const Location = struct {
    range: Range,
};

/// Primitive scalar type names that are built in but not reserved words.
/// Kept in sync with `editors/README.md` and `compiler/src/syntax.zig`.
const primitive_types = [_][]const u8{
    "i8",     "i16", "i32", "i64",  "i128", "isize",
    "u8",     "u16", "u32", "u64",  "u128", "usize",
    "f16",    "f32", "f64", "f128", "bool", "str",
    "String",
};

const max_detail_len = 160;

/// When diagnostics are refreshed.
///
/// `.change` is the keystroke path: lexing/parsing and the symbol index stay
/// current, but multi-file semantic analysis is skipped for documents that
/// belong to a project (it is the expensive part and its results are refreshed
/// on save).  `.full` runs semantics as well; the server uses it for
/// open/save and for standalone buffers.
pub const Phase = enum { change, full };

pub const Options = struct {
    /// Absolute path of the open document, when the client supplied a file URI.
    path: ?[]const u8 = null,
    /// Workspace project index, when the server has one.
    project: ?*project.Index = null,
    phase: Phase = .full,
};

/// Reserved words as a runtime-iterable array (`syntax.keywords` is a tuple).
const keyword_list = blk: {
    var names: [syntax.keywords.len][]const u8 = undefined;
    for (syntax.keywords, 0..) |keyword, index| names[index] = keyword[0];
    break :blk names;
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Borrowed from the caller; not freed by `deinit`.
    source: []const u8,
    /// Borrowed; only meaningful while `analyze` runs.
    path: ?[]const u8 = null,
    project_index: ?*project.Index = null,
    phase: Phase = .full,
    /// True for e7 test-suite sources compiled with the e7-test prelude
    /// (`tests/e7`): the harness injects `assert_*` helpers that are not
    /// visible to a standalone analysis.
    harness: bool = false,
    parsed: ?parser.Ast = null,
    tokens: []const syntax.Token = &.{},
    diagnostics: []Diagnostic = &.{},
    symbols: []Symbol = &.{},
    completions: []CompletionItem = &.{},
    /// Markdown hover text, parallel to `symbols`.
    hovers: []const []const u8 = &.{},
    /// Byte offset of each symbol's name token, parallel to `symbols`.
    name_offsets: []const usize = &.{},
    /// `:=` bindings that are safe to make immutable (formatter input).
    mutable_candidates: []const MutableCandidate = &.{},

    /// Lex, parse, and semantically analyze one buffer, then build the symbol
    /// index and completion list.  Never fails on invalid source: lexer,
    /// parser, and semantic problems become `diagnostics`.
    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Document {
        return initWithOptions(allocator, source, .{});
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        source: []const u8,
        options: Options,
    ) !Document {
        var self = Document{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .source = source,
            .path = options.path,
            .project_index = options.project,
            .phase = options.phase,
        };
        errdefer self.deinit();
        try self.analyze();
        return self;
    }

    pub fn deinit(self: *Document) void {
        if (self.parsed) |*tree| tree.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Lex, parse, and semantically analyze the buffer, then index it.
    fn analyze(self: *Document) !void {
        const arena_alloc = self.arena.allocator();
        var diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty;

        const lexed = try lexer.lex(arena_alloc, self.source);
        self.tokens = lexed.tokens;
        if (lexed.diagnostic) |diagnostic| {
            try diagnostics.append(arena_alloc, try self.diagnosticAt(
                diagnostic.offset,
                try arena_alloc.dupe(u8, diagnostic.message),
            ));
            self.diagnostics = try diagnostics.toOwnedSlice(arena_alloc);
            return;
        }

        const result = try parser.parse(self.allocator, self.source);
        switch (result) {
            .diagnostic => |diagnostic| {
                try diagnostics.append(arena_alloc, try self.diagnosticAt(
                    diagnostic.offset,
                    try arena_alloc.dupe(u8, diagnostic.message),
                ));
                self.diagnostics = try diagnostics.toOwnedSlice(arena_alloc);
                return;
            },
            .ast => |tree| self.parsed = tree,
        }
        self.harness = looksLikeTestSuite(self.source, self.parsed.?.module.items);

        if (self.phase == .full) try self.appendSemanticDiagnostics(&diagnostics);
        self.diagnostics = try diagnostics.toOwnedSlice(arena_alloc);

        try self.buildIndex();
    }

    /// Adds semantic diagnostics for the document.
    ///
    /// Multi-file project documents are analyzed as part of their project so
    /// that imported `mod` symbols resolve; only diagnostics owned by this
    /// file are kept.  Standalone buffers are analyzed on their own.  A project
    /// that cannot be loaded (for example while a dependency is mid-edit)
    /// contributes no semantic diagnostics rather than a storm of false
    /// "unknown symbol" errors.
    fn appendSemanticDiagnostics(
        self: *Document,
        diagnostics: *std.ArrayListUnmanaged(Diagnostic),
    ) !void {
        if (self.path) |path| {
            if (self.project_index) |index| {
                if (index.projectRoot(path)) |root| {
                    try self.appendProjectDiagnostics(diagnostics, index, root, path);
                    return;
                }
            }
        }
        try self.appendLocalDiagnostics(diagnostics);
    }

    /// Analyze the buffer on its own (no external modules).
    fn appendLocalDiagnostics(
        self: *Document,
        diagnostics: *std.ArrayListUnmanaged(Diagnostic),
    ) !void {
        const arena_alloc = self.arena.allocator();
        var analysis = try semantic.analyze(self.allocator, self.parsed.?.module);
        defer analysis.deinit();
        for (analysis.diagnostics) |diagnostic| {
            // The e7-test harness prepends its assertion prelude at compile
            // time, so these names are legitimately unknown to a plain
            // analysis of the suite file.
            if (self.harness and isHarnessPreludeDiagnostic(diagnostic.message)) continue;
            try diagnostics.append(arena_alloc, try self.diagnosticAt(
                diagnostic.span.offset,
                try arena_alloc.dupe(u8, diagnostic.message),
            ));
        }
        if (!(self.harness and try self.appendHarnessCandidates())) {
            try self.collectMutableCandidates(analysis.never_mutated_bindings, null);
        }
    }

    /// e7 test-suite modules are compiled by `e7-test` with their
    /// `# e7-test-source:` includes concatenated in front of the suite file.
    /// Those includes declare the types/methods the suite mutates, so analyze
    /// the same concatenation to classify mutable bindings correctly (the
    /// synthesized prelude is omitted; its names are equally unknown before
    /// and after formatting, so it does not affect the candidate set).
    ///
    /// Returns false when the document has no includes or they cannot be read;
    /// the caller then falls back to local analysis.
    fn appendHarnessCandidates(self: *Document) !bool {
        const path = self.path orelse return false;
        const source = self.source;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var include_sources: std.ArrayListUnmanaged([]const u8) = .empty;
        const directory = std.fs.path.dirname(path) orelse ".";
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            const prefix = "# e7-test-source:";
            if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
            const relative = std.mem.trim(u8, trimmed[prefix.len..], " \t");
            if (relative.len == 0) continue;
            const include_path = if (std.fs.path.isAbsolute(relative))
                try arena_alloc.dupe(u8, relative)
            else
                try std.fs.path.join(arena_alloc, &.{ directory, relative });
            var threaded = std.Io.Threaded.init(arena_alloc, .{});
            defer threaded.deinit();
            const io = threaded.io();
            const include_source = std.Io.Dir.cwd().readFileAlloc(
                io,
                include_path,
                arena_alloc,
                .limited(8 * 1024 * 1024),
            ) catch return false;
            try include_sources.append(arena_alloc, include_source);
        }
        if (include_sources.items.len == 0) return false;

        var combined: std.ArrayListUnmanaged(u8) = .empty;
        for (include_sources.items) |include_source| {
            try combined.appendSlice(arena_alloc, include_source);
            if (include_source.len == 0 or include_source[include_source.len - 1] != '\n') {
                try combined.append(arena_alloc, '\n');
            }
        }
        const prefix_len = combined.items.len;
        try combined.appendSlice(arena_alloc, source);

        const parsed = compiler.parser.parse(arena_alloc, combined.items) catch return false;
        var tree = switch (parsed) {
            .ast => |tree| tree,
            .diagnostic => return false,
        };
        defer tree.deinit();

        var harness_analysis = semantic.analyze(arena_alloc, tree.module) catch return false;
        defer harness_analysis.deinit();

        var candidates: std.ArrayListUnmanaged(MutableCandidate) = .empty;
        const document_arena = self.arena.allocator();
        for (harness_analysis.never_mutated_bindings) |binding| {
            if (binding.offset < prefix_len) continue;
            try candidates.append(document_arena, .{
                .name = try document_arena.dupe(u8, binding.name),
                .offset = binding.offset - prefix_len,
            });
        }
        self.mutable_candidates = try candidates.toOwnedSlice(document_arena);
        return true;
    }

    /// Copies analyzer mutation facts for bindings owned by this document into
    /// the document arena.  `loaded` filters module paths when analyzing a
    /// multi-file project.
    fn collectMutableCandidates(
        self: *Document,
        bindings: []const compiler.semantic.analyzer.MutableBindingInfo,
        loaded: ?*const project.Loaded,
    ) !void {
        const arena_alloc = self.arena.allocator();
        var candidates: std.ArrayListUnmanaged(MutableCandidate) = .empty;
        for (bindings) |binding| {
            if (loaded) |project_loaded| {
                if (self.path) |path| {
                    if (!project_loaded.ownsModulePath(path, binding.module_path)) continue;
                }
            }
            try candidates.append(arena_alloc, .{
                .name = try arena_alloc.dupe(u8, binding.name),
                .offset = binding.offset,
            });
        }
        self.mutable_candidates = try candidates.toOwnedSlice(arena_alloc);
    }

    /// Analyze the multi-file project rooted at `root` with the open buffer as
    /// an override, then keep only diagnostics owned by `path`.
    fn appendProjectDiagnostics(
        self: *Document,
        diagnostics: *std.ArrayListUnmanaged(Diagnostic),
        index: *project.Index,
        root: []const u8,
        path: []const u8,
    ) !void {
        const arena_alloc = self.arena.allocator();
        var loaded = index.load(self.allocator, root, .{ .path = path, .source = self.source }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            // Missing/cyclic/unparseable dependency: the editor buffer is
            // likely mid-edit.  Lexer/parser diagnostics for this file were
            // already published; skip project semantics until it is valid.
            else => return,
        };
        defer loaded.deinit();

        // Parser span maps are per module.  The analyzer keeps one pointer to
        // the root module's map, so merge every child module's spans into it;
        // AST pointers are globally unique, which makes the merge safe.  Without
        // this, statement-level diagnostics and the formatter's binding offsets
        // for module files would point at the enclosing item instead.
        const project_arena = loaded.root_ast.arena.allocator();
        for (loaded.module_asts) |*tree| {
            var spans = tree.module.spans.iterator();
            while (spans.next()) |entry| {
                try loaded.root_ast.module.spans.put(project_arena, entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        var analysis = semantic.analyze(self.allocator, loaded.root_ast.module) catch |err| switch (err) {
            error.OutOfMemory => return err,
        };
        defer analysis.deinit();

        for (analysis.diagnostics) |diagnostic| {
            if (!loaded.ownsModulePath(path, diagnostic.module_path)) continue;
            const source = loaded.sourceForModulePath(diagnostic.module_path) orelse continue;
            try diagnostics.append(arena_alloc, .{
                .range = rangeIn(source, diagnostic.span.offset),
                .severity = .err,
                .message = try arena_alloc.dupe(u8, diagnostic.message),
            });
        }
        try self.collectMutableCandidates(analysis.never_mutated_bindings, &loaded);
    }

    fn diagnosticAt(self: *const Document, byte_offset: usize, message: []const u8) !Diagnostic {
        return .{
            .range = self.rangeAt(byte_offset, 1),
            .severity = .err,
            .message = message,
        };
    }

    /// Range covering `len` bytes starting at `byte_offset`, clamped to one
    /// code point so a diagnostic never spills across a newline.
    fn rangeAt(self: *const Document, byte_offset: usize, len: usize) Range {
        const start = @min(byte_offset, self.source.len);
        const end = @min(start +| len, self.source.len);
        return .{
            .start = protocol.offsetToPosition(self.source, start),
            .end = protocol.offsetToPosition(self.source, end),
        };
    }

    /// Looks up the identifier token containing `byte_offset`.
    fn tokenAt(self: *const Document, byte_offset: usize) ?syntax.Token {
        for (self.tokens) |token| {
            if (token.kind != .identifier) continue;
            const end = token.offset + token.lexeme.len;
            if (byte_offset >= token.offset and byte_offset < end) return token;
            // Cursor immediately after the token (common for `foo<|>`) also
            // resolves to the token.
            if (byte_offset == end and token.lexeme.len > 0) return token;
        }
        return null;
    }

    fn tokenRange(self: *const Document, token: syntax.Token) Range {
        return self.rangeAt(token.offset, token.lexeme.len);
    }

    fn symbolIndexForToken(self: *const Document, token: syntax.Token) ?usize {
        // Prefer an exact declaration match so hovering a declaration shows
        // itself rather than an earlier reference with the same name.
        for (self.name_offsets, 0..) |offset, index| {
            if (offset == token.offset) return index;
        }
        for (self.symbols, 0..) |symbol, index| {
            if (std.mem.eql(u8, symbol.name, token.lexeme)) return index;
        }
        return null;
    }

    /// Hover for the identifier at `byte_offset`, if it resolves to a known
    /// declaration.
    pub fn hoverAt(self: *const Document, byte_offset: usize) ?Hover {
        const token = self.tokenAt(byte_offset) orelse return null;
        const index = self.symbolIndexForToken(token) orelse return null;
        return .{
            .markdown = self.hovers[index],
            .range = self.tokenRange(token),
        };
    }

    /// Same-document definition location for the identifier at `byte_offset`.
    pub fn definitionAt(self: *const Document, byte_offset: usize) ?Location {
        const token = self.tokenAt(byte_offset) orelse return null;
        const index = self.symbolIndexForToken(token) orelse return null;
        return .{ .range = self.symbols[index].selection };
    }

    /// Completion candidates for the cursor at `byte_offset`.
    ///
    /// Completion is intentionally context-free (keywords, built-in types, and
    /// every indexed declaration); the editor filters as the user types.
    pub fn completionsAt(self: *const Document, byte_offset: usize) []const CompletionItem {
        _ = byte_offset;
        return self.completions;
    }

    pub fn symbolAt(self: *const Document, byte_offset: usize) ?Symbol {
        const token = self.tokenAt(byte_offset) orelse return null;
        const index = self.symbolIndexForToken(token) orelse return null;
        return self.symbols[index];
    }

    // ------------------------------------------------------------------
    // Index construction
    // ------------------------------------------------------------------

    fn buildIndex(self: *Document) !void {
        if (self.parsed == null) return;
        var builder = Builder{
            .doc = self,
            .arena = self.arena.allocator(),
        };
        const tree = &self.parsed.?;
        try builder.collectItems(tree.module.items, null, 0, self.source.len);
        self.symbols = try builder.symbols.toOwnedSlice(builder.arena);
        self.hovers = try builder.hovers.toOwnedSlice(builder.arena);
        self.name_offsets = try builder.name_offsets.toOwnedSlice(builder.arena);
        try self.buildCompletions();
    }

    fn buildCompletions(self: *Document) !void {
        const arena_alloc = self.arena.allocator();
        var items: std.ArrayListUnmanaged(CompletionItem) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;

        for (keyword_list) |label| {
            if (label.len == 0) continue;
            const gop = try seen.getOrPut(arena_alloc, label);
            if (gop.found_existing) continue;
            try items.append(arena_alloc, .{
                .label = label,
                .kind = .keyword,
                .detail = "keyword",
            });
        }

        for (primitive_types) |label| {
            const gop = try seen.getOrPut(arena_alloc, label);
            if (gop.found_existing) continue;
            try items.append(arena_alloc, .{
                .label = label,
                .kind = .struct_,
                .detail = "built-in type",
            });
        }

        for (self.symbols) |symbol| {
            const gop = try seen.getOrPut(arena_alloc, symbol.name);
            if (gop.found_existing) continue;
            try items.append(arena_alloc, .{
                .label = symbol.name,
                .kind = completionKind(symbol.kind),
                .detail = symbolKindLabel(symbol.kind),
            });
        }

        self.completions = try items.toOwnedSlice(arena_alloc);
    }
};

/// True when `source` is an e7 test-suite module.  Such files are compiled by
/// the e7-test harness with a prepended prelude, so their `assert_*` calls are
/// not resolvable by a standalone semantic analysis.
fn looksLikeTestSuite(source: []const u8, items: []const *ast.Item) bool {
    if (std.mem.indexOf(u8, source, "# e7-test-source:") != null) return true;
    for (items) |item| {
        switch (item.kind) {
            .function => |decl| {
                if (std.mem.startsWith(u8, decl.name, "test_")) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Unknown-name diagnostic for a name injected by the e7-test prelude.
fn isHarnessPreludeDiagnostic(message: []const u8) bool {
    return std.mem.startsWith(u8, message, "unknown name `assert_") or
        std.mem.startsWith(u8, message, "unknown name `e7_test_");
}

/// One-code-point diagnostic range in an arbitrary source buffer.  Project
/// analysis can own diagnostics for several buffers, so the range is computed
/// against the owning buffer rather than the open document.
fn rangeIn(source: []const u8, byte_offset: usize) Range {
    const start = @min(byte_offset, source.len);
    const end = @min(start +| 1, source.len);
    return .{
        .start = protocol.offsetToPosition(source, start),
        .end = protocol.offsetToPosition(source, end),
    };
}

const Builder = struct {
    doc: *Document,
    arena: std.mem.Allocator,
    symbols: std.ArrayListUnmanaged(Symbol) = .empty,
    hovers: std.ArrayListUnmanaged([]const u8) = .empty,
    name_offsets: std.ArrayListUnmanaged(usize) = .empty,

    fn add(
        self: *Builder,
        name: []const u8,
        kind: SymbolKind,
        start: usize,
        end: usize,
        parent: ?u32,
    ) !u32 {
        const source = self.doc.source;
        const name_offset = findNameOffset(self.doc.tokens, name, start, end) orelse start;
        const name_end = @min(name_offset + name.len, source.len);
        const detail = try declarationLine(self.arena, source, name_offset);
        const hover = try std.fmt.allocPrint(self.arena, "```e7\n{s}\n```", .{detail});
        const index: u32 = @intCast(self.symbols.items.len);
        try self.symbols.append(self.arena, .{
            .name = name,
            .kind = kind,
            .range = self.doc.rangeAt(start, end -| start),
            .selection = self.doc.rangeAt(name_offset, name_end -| name_offset),
            .detail = detail,
            .parent = parent,
        });
        try self.hovers.append(self.arena, hover);
        try self.name_offsets.append(self.arena, name_offset);
        return index;
    }

    fn collectItems(
        self: *Builder,
        items: []const *ast.Item,
        parent: ?u32,
        start_bound: usize,
        end_bound: usize,
    ) !void {
        for (items, 0..) |item, index| {
            const item_start = self.itemOffset(item) orelse start_bound;
            const item_end = if (index + 1 < items.len)
                (self.itemOffset(items[index + 1]) orelse end_bound)
            else
                end_bound;
            const end = @max(item_end, item_start +| 1);

            switch (item.kind) {
                .function => |decl| {
                    _ = try self.add(decl.name, .function, item_start, end, parent);
                },
                .struct_decl => |decl| {
                    const symbol = try self.add(decl.name, .struct_, item_start, end, parent);
                    try self.collectFields(decl.fields, symbol, item_start, end);
                },
                .table_decl => |decl| {
                    const symbol = try self.add(decl.name, .struct_, item_start, end, parent);
                    try self.collectFields(decl.fields, symbol, item_start, end);
                },
                .trigger_decl => |decl| {
                    const symbol = try self.add(decl.name, .struct_, item_start, end, parent);
                    try self.collectFields(decl.fields, symbol, item_start, end);
                },
                .enum_decl => |decl| {
                    const symbol = try self.add(decl.name, .enum_, item_start, end, parent);
                    for (decl.variants) |variant| {
                        _ = try self.add(variant.name, .enum_member, item_start, end, symbol);
                    }
                },
                .trait_decl => |decl| {
                    const symbol = try self.add(decl.name, .interface, item_start, end, parent);
                    for (decl.methods) |method| {
                        _ = try self.add(method.name, .method, item_start, end, symbol);
                    }
                },
                .impl => |decl| {
                    const name = try implName(self.arena, decl);
                    const symbol = try self.add(name, .class, item_start, end, parent);
                    for (decl.methods) |method| {
                        _ = try self.add(method.function.name, .method, item_start, end, symbol);
                    }
                },
                .plugin_decl => |decl| {
                    const symbol = try self.add(decl.name, .module, item_start, end, parent);
                    try self.collectItems(decl.items, symbol, item_start, end);
                },
                .mod => |decl| {
                    const symbol = try self.add(decl.name, .module, item_start, end, parent);
                    if (decl.items) |inner| {
                        try self.collectItems(inner, symbol, item_start, end);
                    }
                },
                .sys => |decl| {
                    _ = try self.add(decl.name, .function, item_start, end, parent);
                },
                .binding => |decl| {
                    _ = try self.add(decl.name, .variable, item_start, end, parent);
                },
                .uninitialized => |decl| {
                    _ = try self.add(decl.name, .variable, item_start, end, parent);
                },
                .use => {},
            }
        }
    }

    fn collectFields(
        self: *Builder,
        fields: []const ast.Field,
        parent: u32,
        start: usize,
        end: usize,
    ) !void {
        for (fields) |field| {
            _ = try self.add(field.name, .field, start, end, parent);
        }
    }

    fn itemOffset(self: *const Builder, item: *ast.Item) ?usize {
        const tree = &self.doc.parsed.?;
        const span = tree.module.spans.get(@intFromPtr(item)) orelse return null;
        return span.offset;
    }
};

fn findNameOffset(tokens: []const syntax.Token, name: []const u8, start: usize, end: usize) ?usize {
    for (tokens) |token| {
        if (token.kind != .identifier) continue;
        if (token.offset < start or token.offset >= end) continue;
        if (std.mem.eql(u8, token.lexeme, name)) return token.offset;
    }
    return null;
}

/// First source line containing `offset`, trimmed and capped for display.
fn declarationLine(allocator: std.mem.Allocator, source: []const u8, offset: usize) ![]const u8 {
    const clamped = @min(offset, source.len);
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..clamped], '\n')) |newline| newline + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, source, clamped, '\n') orelse source.len;
    const line = std.mem.trim(u8, source[line_start..line_end], " \t\r");
    if (line.len <= max_detail_len) return allocator.dupe(u8, line);
    return std.fmt.allocPrint(allocator, "{s}…", .{line[0..max_detail_len]});
}

fn implName(allocator: std.mem.Allocator, decl: ast.ImplDecl) ![]const u8 {
    const target = typeLabel(decl.target);
    if (decl.trait_ty) |trait_ty| {
        return std.fmt.allocPrint(allocator, "impl {s} for {s}", .{ typeLabel(trait_ty), target });
    }
    return std.fmt.allocPrint(allocator, "impl {s}", .{target});
}

fn typeLabel(ty: *const ast.Type) []const u8 {
    return switch (ty.*) {
        .path => |path| if (path.segments.len > 0) path.segments[path.segments.len - 1].name else "?",
        .error_union => |value| typeLabel(value.value_type),
        .optional => |child| typeLabel(child),
        .reference => |child| typeLabel(child.child),
        .box => |child| typeLabel(child),
        .raw_pointer => |child| typeLabel(child),
        else => "?",
    };
}

fn completionKind(kind: SymbolKind) CompletionKind {
    return switch (kind) {
        .module, .namespace => .module,
        .struct_ => .struct_,
        .enum_ => .enum_,
        .interface => .interface,
        .method => .method,
        .function => .function,
        .field => .field,
        .variable => .variable,
        .enum_member => .enum_member,
        .type_parameter => .type_parameter,
        .class => .class,
        .file, .property, .constant => .variable,
    };
}

fn symbolKindLabel(kind: SymbolKind) []const u8 {
    return switch (kind) {
        .module => "module",
        .namespace => "namespace",
        .class => "impl",
        .method => "method",
        .property => "property",
        .field => "field",
        .enum_ => "enum",
        .interface => "trait",
        .function => "function",
        .variable => "binding",
        .constant => "constant",
        .enum_member => "variant",
        .struct_ => "type",
        .type_parameter => "type parameter",
        .file => "file",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectDiagnosticContains(doc: *const Document, needle: []const u8) !void {
    for (doc.diagnostics) |diagnostic| {
        if (std.mem.indexOf(u8, diagnostic.message, needle) != null) return;
    }
    for (doc.diagnostics) |diagnostic| {
        std.debug.print("diagnostic: {s}\n", .{diagnostic.message});
    }
    std.debug.print("missing diagnostic containing: {s}\n", .{needle});
    return error.TestUnexpectedResult;
}

fn findSymbol(doc: *const Document, name: []const u8) ?usize {
    for (doc.symbols, 0..) |symbol, index| {
        if (std.mem.eql(u8, symbol.name, name)) return index;
    }
    return null;
}

test "valid source has no diagnostics and indexes declarations" {
    const source =
        \\S <- struct
        \\    a: i32
        \\    b: i32
        \\add <- (x: i32, y: i32) -> i32:
        \\    ret x + y
        \\main <- () -> i32:
        \\    ret add(1, 2)
        \\
    ;
    var doc = try Document.init(testing.allocator, source);
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 0), doc.diagnostics.len);
    try testing.expect(findSymbol(&doc, "S") != null);
    try testing.expect(findSymbol(&doc, "add") != null);
    try testing.expect(findSymbol(&doc, "a") != null);

    const add = findSymbol(&doc, "add").?;
    try testing.expectEqual(SymbolKind.function, doc.symbols[add].kind);
    try testing.expectEqual(@as(u32, 3), doc.symbols[add].selection.start.line);
    try testing.expectEqual(@as(u32, 0), doc.symbols[add].selection.start.character);
}

test "semantic diagnostics become LSP diagnostics" {
    const source =
        \\f <- () -> i32:
        \\    x := 1
        \\    x = "no"
        \\    0
        \\
    ;
    var doc = try Document.init(testing.allocator, source);
    defer doc.deinit();

    try testing.expect(doc.diagnostics.len > 0);
    try expectDiagnosticContains(&doc, "type mismatch");
    // `x = "no"` is on line index 2 (zero based).
    try testing.expectEqual(@as(u32, 2), doc.diagnostics[0].range.start.line);
}

test "lexer and parser diagnostics become LSP diagnostics" {
    const source = "f <- () -> i32:\n\tret 0\n";
    var doc = try Document.init(testing.allocator, source);
    defer doc.deinit();
    try testing.expect(doc.diagnostics.len > 0);
    try testing.expect(doc.diagnostics[0].range.start.line == 1);
}

test "parse errors suppress semantic diagnostics" {
    const source = "f <- (\n";
    var doc = try Document.init(testing.allocator, source);
    defer doc.deinit();
    try testing.expect(doc.diagnostics.len >= 1);
    try testing.expectEqual(@as(usize, 0), doc.symbols.len);
}

test "hover resolves a call to its declaration" {
    const source =
        \\dot <- (a: i32, b: i32) -> i32:
        \\    ret a * b
        \\main <- () -> i32:
        \\    ret dot(2, 3)
        \\
    ;
    var doc = try Document.init(testing.allocator, source);
    defer doc.deinit();

    const call_offset = std.mem.indexOf(u8, source, "dot(2").?;
    const hover = doc.hoverAt(call_offset) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "dot") != null);
    try testing.expect(std.mem.indexOf(u8, hover.markdown, "```e7") != null);
}

test "definition resolves a reference to the declaration" {
    const source =
        \\dot <- (a: i32, b: i32) -> i32:
        \\    ret a * b
        \\main <- () -> i32:
        \\    ret dot(2, 3)
        \\
    ;
    var doc = try Document.init(testing.allocator, source);
    defer doc.deinit();

    const call_offset = std.mem.indexOf(u8, source, "dot(2").?;
    const location = doc.definitionAt(call_offset) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), location.range.start.line);
    try testing.expectEqual(@as(u32, 0), location.range.start.character);
}

test "completions include keywords, builtin types, and symbols" {
    const source =
        \\Point <- struct
        \\    x: f32
        \\origin <- () -> Point:
        \\    ret Point { x: 0.0 }
        \\
    ;
    var doc = try Document.init(testing.allocator, source);
    defer doc.deinit();

    var saw_keyword = false;
    var saw_builtin = false;
    var saw_symbol = false;
    for (doc.completions) |item| {
        if (std.mem.eql(u8, item.label, "struct")) saw_keyword = true;
        if (std.mem.eql(u8, item.label, "f32")) saw_builtin = true;
        if (std.mem.eql(u8, item.label, "Point")) saw_symbol = true;
    }
    try testing.expect(saw_keyword);
    try testing.expect(saw_builtin);
    try testing.expect(saw_symbol);
}
