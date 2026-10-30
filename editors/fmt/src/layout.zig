//! Token-aware line layout for engine7 source: 80-column wrapping and
//! whitespace/spacing normalization.
//!
//! `format` assumes its input has already been normalized for line endings,
//! trailing whitespace, tabs, and the final newline (see `formatter.zig`).  It
//! lexes the source to find strings/comments and bracket depth, then:
//!
//!   * breaks lines longer than `max_line_length` at safe positions inside
//!     existing `()`, `[]`, and `{}` (layout is suppressed inside brackets),
//!     indenting continuations by `indent_width`;
//!   * for overlong binding/assignment lines, prefers the indented-value form
//!     (`name <op>` followed by the right-hand side one level deeper), then
//!     wraps that right-hand side; if it still cannot fit because it has no
//!     bracket breakpoint, the value is parenthesized as a last resort
//!     (parentheses are transparent in the AST);
//!   * for overlong expression contexts that have no bracket breakpoint
//!     (`if`, `elif`, `while`, `match`, `ret`, `disown`, `for ... in`),
//!     inserts a parenthesized group and breaks inside it;
//!   * wraps an unbracketed struct/row field value in parentheses as a last
//!     resort (field values at brace-only depth have no breakpoint);
//!   * reflows overlong `#` comment lines on word boundaries, repeating `#`;
//!   * normalizes spacing for commas, semicolons, colons, assignment/binding/
//!     arrow operators, and unambiguous binary operators.
//!
//! Strings and unbreakable tokens are never modified, and nothing is inserted
//! or removed except the parentheses described above.  If the generated output
//! fails to lex/parse, `format` degrades to progressively more conservative
//! passes and finally returns the original source unchanged with
//! `fallback = true`, so callers can always trust the result.
//!
//! The pass is idempotent: formatting its own output yields the same text and
//! `wrapped == 0` on the second run.

const std = @import("std");
const compiler = @import("compiler");

const syntax = compiler.syntax;
const TokenKind = syntax.TokenKind;
const Token = syntax.Token;

pub const Options = struct {
    max_line_length: usize = 80,
    indent_width: usize = 4,
};

/// One line the formatter could not bring under the limit.
pub const Unformatted = struct {
    /// 1-based line number in the formatted output.
    line: usize,
    /// Static explanation, e.g. "long string literal".
    reason: []const u8,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    /// Formatted text (owned); at least one trailing newline when non-empty.
    text: []u8,
    /// Number of source lines that were split.
    wrapped: usize,
    /// Lines that remain over the limit, in output order (owned slice).
    unformatted: []Unformatted,
    /// True when the pass produced text that did not re-parse; `text` is then
    /// an owned copy of the input.
    fallback: bool,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.text);
        self.allocator.free(self.unformatted);
        self.* = undefined;
    }
};

pub fn format(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
) !Result {
    if (source.len == 0) {
        return .{
            .allocator = allocator,
            .text = try allocator.dupe(u8, source),
            .wrapped = 0,
            .unformatted = try allocator.alloc(Unformatted, 0),
            .fallback = false,
        };
    }

    // Wrapping can uncover new overlong lines (an indented value's right-hand
    // side, or a continuation line that just moved).  Iterate to a fixed point
    // so a single call really does leave every safe breakpoint taken.
    const max_rounds = 8;

    var current: []u8 = try allocator.dupe(u8, source);
    errdefer allocator.free(current);

    // Try the full formatter first, then progressively more conservative
    // layouts.  A pass whose output does not re-parse is discarded, which
    // keeps a single unsupported construct from losing the whole file.
    for ([_]Mode{ .full, .no_brace, .brackets_only, .spacing_only }) |mode| {
        if (!std.mem.eql(u8, current, source)) {
            allocator.free(current);
            current = &.{};
            current = try allocator.dupe(u8, source);
        }
        var total_wrapped: usize = 0;
        var round: usize = 0;
        while (round < max_rounds) : (round += 1) {
            const lexed = compiler.lexer.lex(allocator, current) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LexFailed => break,
            };
            defer allocator.free(lexed.tokens);
            if (lexed.diagnostic != null) break;

            var engine = try Engine.init(allocator, current, lexed.tokens, options);
            defer engine.deinit();
            engine.run(mode) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (engine.out_line > 0) engine.out.append(allocator, '\n') catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            const candidate = engine.out.toOwnedSlice(allocator) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (!try parses(allocator, candidate)) {
                allocator.free(candidate);
                break;
            }

            total_wrapped += engine.wrapped;
            const changed = !std.mem.eql(u8, candidate, current);
            if (!changed) {
                allocator.free(candidate);
                const unformatted = try engine.unformatted.toOwnedSlice(allocator);
                return .{
                    .allocator = allocator,
                    .text = current,
                    .wrapped = total_wrapped,
                    .unformatted = unformatted,
                    .fallback = false,
                };
            }
            allocator.free(current);
            current = candidate;
        }
    }

    allocator.free(current);
    current = &.{};
    return fallbackResult(allocator, source);
}

fn fallbackResult(allocator: std.mem.Allocator, source: []const u8) !Result {
    return .{
        .allocator = allocator,
        .text = try allocator.dupe(u8, source),
        .wrapped = 0,
        .unformatted = try allocator.alloc(Unformatted, 0),
        .fallback = true,
    };
}

fn parses(allocator: std.mem.Allocator, text: []const u8) !bool {
    const result = compiler.parser.parse(allocator, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    switch (result) {
        .ast => |ast_value| {
            var ast = ast_value;
            ast.deinit();
            return true;
        },
        .diagnostic => return false,
    }
}

// ---------------------------------------------------------------------------
// Layout engine
// ---------------------------------------------------------------------------

const Mode = enum {
    /// Every strategy: indented values, bracket breaks, if/else branch
    /// splitting, and inserted parentheses.
    full,
    /// Every strategy except breaks inside `{}` (used when a brace break in a
    /// declaration list would not re-parse).
    no_brace,
    /// Breaks inside existing `()`/`[]` only (no inserted tokens, no braces).
    brackets_only,
    /// Spacing and comments normalization only; lines are never wrapped.
    spacing_only,
};

/// Per-token layout facts computed once for the whole file.
const TokenInfo = struct {
    /// Total bracket depth before/after the token (`()`, `[]`, `{}` all count).
    depth_before: i32,
    depth_after: i32,
    /// Depth counting only `()`/`[]`: the lexer suppresses newlines there, so
    /// breaking at any token boundary inside them is token-stream-safe.
    paren_before: i32,
    paren_after: i32,
    /// Depth counting only `{}`: newlines are real tokens there, safe only
    /// after `{`/`,`/`;` and at block separators.
    brace_after: i32,
    /// Whether a space should precede the token (normalized spacing).
    space_before: bool,
    /// A symbolic prefix operator (`-x`, `*T`, `&mut T`, `!E`, `?T`) attaches
    /// to its operand rather than being surrounded by spaces.
    prefix: bool,
    /// Token appears inside a `use` declaration (its brace trees keep Rust
    /// style `::{a, b}` with no inner spaces).
    in_use_tree: bool,
    /// Indent of the line that opened the innermost `()`/`[]` group, or 0 at
    /// depth zero.  Used to align wrapped continuations with their siblings.
    group_indent: usize,
};

const Piece = struct {
    kind: TokenKind,
    lexeme: []const u8,
    space_before: bool,
    depth_before: i32,
    depth_after: i32,
    paren_before: i32,
    paren_after: i32,
    brace_after: i32,
    /// Indent of the line that opened the enclosing `()`/`[]` group (0 at
    /// depth zero); continuation lines align to it plus one indent width.
    group_indent: usize,
    width: u32,
    /// The operator may end a line (binary position, not a prefix operator).
    break_kind: bool,
};

const Engine = struct {
    allocator: std.mem.Allocator,
    options: Options,
    source: []const u8,
    tokens: []const Token,
    infos: []TokenInfo = &.{},
    /// Leading-space count for each physical source line (index 1-based).
    line_indents: []usize = &.{},

    mode: Mode = .full,
    allow_brace_breaks: bool = true,
    /// Output text; lines separated by `\n`, no trailing newline yet.
    out: std.ArrayListUnmanaged(u8) = .empty,
    out_line: usize = 0,
    wrapped: usize = 0,
    unformatted: std.ArrayListUnmanaged(Unformatted) = .empty,

    fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        all_tokens: []const Token,
        options: Options,
    ) !Engine {
        // Virtual layout tokens carry no source text; drop them once so every
        // later index refers to a real token.
        var real_count: usize = 0;
        for (all_tokens) |token| {
            if (!isVirtual(token.kind)) real_count += 1;
        }
        const real = try allocator.alloc(Token, real_count);
        var index: usize = 0;
        for (all_tokens) |token| {
            if (isVirtual(token.kind)) continue;
            real[index] = token;
            index += 1;
        }
        return .{
            .allocator = allocator,
            .options = options,
            .source = source,
            .tokens = real,
        };
    }

    fn deinit(self: *Engine) void {
        if (self.tokens.len > 0) self.allocator.free(self.tokens);
        if (self.infos.len > 0) self.allocator.free(self.infos);
        if (self.line_indents.len > 0) self.allocator.free(self.line_indents);
        self.out.deinit(self.allocator);
        self.unformatted.deinit(self.allocator);
        self.* = undefined;
    }

    fn run(self: *Engine, mode: Mode) !void {
        self.mode = mode;
        self.allow_brace_breaks = mode == .full;
        self.out.clearRetainingCapacity();
        self.out_line = 0;
        self.wrapped = 0;
        self.unformatted.clearRetainingCapacity();

        if (self.infos.len != self.tokens.len) {
            if (self.infos.len > 0) self.allocator.free(self.infos);
            self.infos = try self.allocator.alloc(TokenInfo, self.tokens.len);
            self.computeTokenInfo();
        }

        var rest = self.source;
        var line_no: usize = 0;
        var tok_pos: usize = 0;
        while (true) {
            line_no += 1;
            const newline = std.mem.indexOfScalar(u8, rest, '\n');
            const line_text = if (newline) |idx| rest[0..idx] else rest;
            try self.processLine(line_no, line_text, &tok_pos);
            const idx = newline orelse break;
            rest = rest[idx + 1 ..];
            if (rest.len == 0) break;
        }
    }

    // -- token facts --------------------------------------------------------

    fn computeTokenInfo(self: *Engine) void {
        // Line indents first: wrapping continuations align to the line that
        // opened the enclosing bracket group, not merely the current line.
        if (self.line_indents.len > 0) self.allocator.free(self.line_indents);
        var line_count: usize = 1;
        for (self.source) |byte| {
            if (byte == '\n') line_count += 1;
        }
        self.line_indents = self.allocator.alloc(usize, line_count + 1) catch return;
        @memset(self.line_indents, 0);
        {
            var line: usize = 1;
            var indent: usize = 0;
            var in_leading = true;
            for (self.source) |byte| {
                if (in_leading) {
                    if (byte == ' ') {
                        indent += 1;
                    } else {
                        in_leading = false;
                    }
                }
                if (byte == '\n') {
                    self.line_indents[line] = indent;
                    line += 1;
                    indent = 0;
                    in_leading = true;
                }
            }
            if (line <= line_count) self.line_indents[line] = indent;
        }

        var depth: i32 = 0;
        var paren: i32 = 0;
        var brace: i32 = 0;
        var use_on_line = false;
        var current_line: usize = 0;
        var group_stack: [256]usize = undefined;
        var group_depth: usize = 0;
        for (self.tokens, 0..) |tok, i| {
            if (tok.line != current_line) {
                current_line = tok.line;
                use_on_line = false;
            }
            if (tok.kind == .kw_use) use_on_line = true;

            const before = depth;
            const paren_before = paren;
            const group_indent: usize = if (group_depth > 0) group_stack[group_depth - 1] else 0;
            switch (tok.kind) {
                .lparen, .lbracket => {
                    depth += 1;
                    paren += 1;
                    if (group_depth < group_stack.len) {
                        group_stack[group_depth] = self.line_indents[@min(tok.line, self.line_indents.len - 1)];
                        group_depth += 1;
                    }
                },
                .lbrace => depth += 1,
                .rparen, .rbracket => {
                    depth = @max(0, depth - 1);
                    paren = @max(0, paren - 1);
                    if (group_depth > 0) group_depth -= 1;
                },
                .rbrace => depth = @max(0, depth - 1),
                else => {},
            }
            self.infos[i] = .{
                .depth_before = before,
                .depth_after = depth,
                .paren_before = paren_before,
                .paren_after = paren,
                .brace_after = brace,
                .space_before = false,
                .prefix = false,
                .in_use_tree = use_on_line,
                .group_indent = group_indent,
            };
            if (tok.kind == .lbrace) brace += 1;
            if (tok.kind == .rbrace) brace = @max(0, brace - 1);
        }

        for (self.tokens, 0..) |tok, i| {
            const prev: ?Token = if (i == 0) null else self.tokens[i - 1];
            const has_prev = prev != null;
            const prev_ends_expr = if (prev) |p| canEndExpression(p.kind) else false;
            const prefix = switch (tok.kind) {
                .minus, .star, .amp, .pipe, .question => !prev_ends_expr,
                .bang => true,
                else => false,
            };
            var space = false;
            if (has_prev) {
                const p = prev.?;
                const gap_has_space = self.gapHasSpace(p, tok);
                space = spaceBetween(p.kind, tok.kind, prefix, self.infos[i - 1].prefix, gap_has_space);
                // `use` trees keep Rust style `::{a, b}` (no inner spaces).
                const in_use = self.infos[i].in_use_tree and self.infos[i - 1].in_use_tree;
                if (!in_use) {
                    // Braces are special: single-line struct/row literals read
                    // better as `{ field: value }`; empty braces stay `{}`.
                    // A `{` ending a line or a `}` starting one is unaffected
                    // because leading/trailing inter-token spaces are ignored
                    // at line boundaries.
                    if (p.kind == .lbrace and tok.kind != .rbrace) space = true;
                    if (tok.kind == .rbrace) space = p.kind != .lbrace;
                }
            }
            self.infos[i].space_before = space;
            self.infos[i].prefix = prefix;
        }
    }

    fn gapHasSpace(self: *const Engine, prev: Token, cur: Token) bool {
        const start = prev.offset + prev.lexeme.len;
        if (start >= cur.offset) return false;
        const gap = self.source[start..cur.offset];
        // Newlines and comments separate tokens; only horizontal space matters.
        if (std.mem.indexOfScalar(u8, gap, '\n') != null) return false;
        return gap.len > 0;
    }

    // -- one physical line --------------------------------------------------

    fn processLine(self: *Engine, line_no: usize, line_text: []const u8, tok_pos: *usize) !void {
        const indent = leadingSpaces(line_text);
        if (indent == line_text.len) {
            try self.emitLine("");
            return;
        }
        if (line_text[indent] == '#') {
            var pending = Pending.init(self.allocator);
            try self.wrapCommentLines(&pending, indent, line_text[indent..]);
            try self.finishPending(&pending, indent, null);
            return;
        }

        const comment_start = findCommentStart(line_text);
        const comment: ?[]const u8 = if (comment_start) |idx| line_text[idx..] else null;

        const tok_start = tok_pos.*;
        while (tok_pos.* < self.tokens.len and self.tokens[tok_pos.*].line == line_no) {
            tok_pos.* += 1;
        }
        const tok_end = tok_pos.*;
        if (tok_end == tok_start) {
            // Keep unlexable residue untouched rather than corrupting the file.
            try self.emitLine(line_text);
            return;
        }

        var pieces: std.ArrayListUnmanaged(Piece) = .empty;
        defer pieces.deinit(self.allocator);
        try pieces.ensureTotalCapacity(self.allocator, tok_end - tok_start);
        for (tok_start..tok_end) |i| {
            const tok = self.tokens[i];
            const info = self.infos[i];
            pieces.appendAssumeCapacity(.{
                .kind = tok.kind,
                .lexeme = tok.lexeme,
                .space_before = info.space_before,
                .depth_before = info.depth_before,
                .depth_after = info.depth_after,
                .paren_before = info.paren_before,
                .paren_after = info.paren_after,
                .brace_after = info.brace_after,
                .group_indent = info.group_indent,
                .width = @intCast(displayWidth(tok.lexeme)),
                .break_kind = isBreakKind(tok.kind, info.prefix),
            });
        }
        try self.layoutLine(indent, pieces.items, comment);
    }

    fn layoutLine(self: *Engine, indent: usize, pieces: []const Piece, comment: ?[]const u8) !void {
        const code_width = indent + piecesWidth(pieces);
        const comment_width: usize = if (comment) |c| 1 + displayWidth(c) else 0;
        const max = self.options.max_line_length;

        // `map[K, V] { ... }` literals do not tolerate layout tokens inside
        // their braces, so disable brace breakpoints for such a line.
        const saved_brace_breaks = self.allow_brace_breaks;
        defer self.allow_brace_breaks = saved_brace_breaks;
        if (lineHasMapLiteral(pieces)) self.allow_brace_breaks = false;

        if (code_width + comment_width <= max) {
            var pending = Pending.init(self.allocator);
            try pending.addPiecesLine(indent, pieces, null);
            try self.finishPending(&pending, indent, comment);
            return;
        }

        if (code_width <= max) {
            // Only the trailing comment is too long; keep the code as written and
            // move the comment above it rather than wrapping the statement.
            var pending = Pending.init(self.allocator);
            try pending.addPiecesLine(indent, pieces, null);
            try self.finishPending(&pending, indent, comment);
            return;
        }

        // `use` trees are the one place `{}` is not a statement/field list that
        // tolerates layout noise, and a overlong use line has no other safe
        // breakpoint, so leave it (and report it) instead of corrupting it.
        if (pieces[0].kind == .kw_use) {
            var pending = Pending.init(self.allocator);
            try pending.addPiecesLine(indent, pieces, "long use declaration");
            try self.finishPending(&pending, indent, comment);
            return;
        }

        switch (self.mode) {
            .spacing_only => {
                var pending = Pending.init(self.allocator);
                try pending.addPiecesLine(indent, pieces, overlongReason(pieces));
                try self.finishPending(&pending, indent, comment);
                return;
            },
            .brackets_only => {
                if (try self.tryBracketWrap(pieces, indent)) |pending| {
                    var p = pending;
                    try self.finishPending(&p, indent, comment);
                    return;
                }
            },
            .full, .no_brace => {
                // The indented-value style is the preferred layout for long
                // bindings and assignments, so it is tried first.
                if (try self.tryIndentedValue(pieces, indent)) |pending| {
                    var p = pending;
                    try self.finishPending(&p, indent, comment);
                    return;
                }
                if (try self.tryBranchSplit(pieces, indent)) |pending| {
                    var p = pending;
                    try self.finishPending(&p, indent, comment);
                    return;
                }
                if (try self.tryBracketWrap(pieces, indent)) |pending| {
                    var p = pending;
                    try self.finishPending(&p, indent, comment);
                    return;
                }
                if (try self.tryInsertParens(pieces, indent)) |pending| {
                    var p = pending;
                    try self.finishPending(&p, indent, comment);
                    return;
                }
                if (try self.tryFieldValueParens(pieces, indent)) |pending| {
                    var p = pending;
                    try self.finishPending(&p, indent, comment);
                    return;
                }
            },
        }

        var pending = Pending.init(self.allocator);
        try pending.addPiecesLine(indent, pieces, overlongReason(pieces));
        try self.finishPending(&pending, indent, comment);
    }

    // -- strategies ---------------------------------------------------------

    /// `name [":" type] (op)` followed by an indented value: the language
    /// accepts this form for bindings and assignments, and it is the preferred
    /// layout for overlong ones.
    fn tryIndentedValue(self: *Engine, pieces: []const Piece, indent: usize) !?Pending {
        const op = findAssignmentOperator(pieces) orelse return null;
        const head = pieces[0 .. op + 1];
        const rest = pieces[op + 1 ..];
        if (rest.len == 0) return null;

        var pending = try self.layoutPieces(head, indent);
        errdefer pending.deinit();
        if (pending.overlongCount(self.options.max_line_length) > 0) {
            pending.deinit();
            return null;
        }

        const value_indent = indent + self.options.indent_width;
        // The value now starts on its own line, one level deeper; any bracket
        // group it opens is opened *there*, so continuations inside it align to
        // that new indent rather than the original statement line.
        var adjusted = try self.retargetGroupIndent(rest, indent, value_indent);
        defer adjusted.deinit(self.allocator);

        var rest_pending = (try self.layoutBranchSplit(adjusted.items, value_indent)) orelse
            try self.layoutPieces(adjusted.items, value_indent);
        defer rest_pending.deinit();

        // Last resort: an unbracketed expression cannot break after an operator
        // at layout depth (a newline there would end the statement), so wrap it
        // in a parenthesized group and break inside that.  Existing braces/
        // branch layouts are preferred and not touched.
        if (self.mode == .full and
            rest_pending.overlongCount(self.options.max_line_length) > 0 and
            canParenthesizeValue(adjusted.items))
        {
            var wrapped = try self.wrapInParens(adjusted.items, value_indent);
            defer wrapped.deinit(self.allocator);
            var alt = try self.layoutPieces(wrapped.items, value_indent);
            if (alt.overlongCount(self.options.max_line_length) <
                rest_pending.overlongCount(self.options.max_line_length))
            {
                rest_pending.deinit();
                rest_pending = alt;
            } else {
                alt.deinit();
            }
        }

        try pending.append(&rest_pending);
        return pending;
    }

    /// Copies `pieces`, replacing the enclosing-group indent of every token that
    /// belonged to a group opened on the original line with `new_indent`.
    fn retargetGroupIndent(
        self: *Engine,
        pieces: []const Piece,
        old_line_indent: usize,
        new_indent: usize,
    ) !std.ArrayListUnmanaged(Piece) {
        var out: std.ArrayListUnmanaged(Piece) = .empty;
        errdefer out.deinit(self.allocator);
        try out.ensureTotalCapacity(self.allocator, pieces.len);
        for (pieces) |piece| {
            var adjusted = piece;
            // Only tokens genuinely inside a `()`/`[]` group move with the
            // value; brace-literal content stays at the base indent (newlines
            // inside `{}` are real tokens, so they must not gain a layout
            // INDENT level).
            if (adjusted.paren_before > 0 and adjusted.group_indent <= old_line_indent) {
                adjusted.group_indent = new_indent;
            }
            out.appendAssumeCapacity(adjusted);
        }
        return out;
    }

    /// Wraps a whole value expression in a fresh `( ... )` pair.
    fn wrapInParens(
        self: *Engine,
        pieces: []const Piece,
        indent: usize,
    ) !std.ArrayListUnmanaged(Piece) {
        var out: std.ArrayListUnmanaged(Piece) = .empty;
        errdefer out.deinit(self.allocator);
        try out.ensureTotalCapacity(self.allocator, pieces.len + 2);

        const base_depth = pieces[0].depth_before;
        const base_paren = pieces[0].paren_before;
        out.appendAssumeCapacity(.{
            .kind = .lparen,
            .lexeme = "(",
            .space_before = true,
            .depth_before = base_depth,
            .depth_after = base_depth + 1,
            .paren_before = base_paren,
            .paren_after = base_paren + 1,
            .brace_after = pieces[0].brace_after,
            .group_indent = indent,
            .width = 1,
            .break_kind = false,
        });
        for (pieces, 0..) |piece, i| {
            var shifted = piece;
            shifted.depth_before += 1;
            shifted.depth_after += 1;
            shifted.paren_before += 1;
            shifted.paren_after += 1;
            shifted.group_indent = indent;
            shifted.space_before = if (i == 0) false else piece.space_before;
            out.appendAssumeCapacity(shifted);
        }
        const last = pieces[pieces.len - 1];
        out.appendAssumeCapacity(.{
            .kind = .rparen,
            .lexeme = ")",
            .space_before = false,
            .depth_before = base_depth + 1,
            .depth_after = base_depth,
            .paren_before = base_paren + 1,
            .paren_after = base_paren,
            .brace_after = last.brace_after,
            .group_indent = indent,
            .width = 1,
            .break_kind = false,
        });
        return out;
    }

    /// Splits `if cond: a else: b` across lines at top-level `else`/`elif`.
    fn tryBranchSplit(self: *Engine, pieces: []const Piece, indent: usize) !?Pending {
        var pending = (try self.layoutBranchSplit(pieces, indent)) orelse return null;
        errdefer pending.deinit();
        if (pending.overlongCount(self.options.max_line_length) > 0) {
            pending.deinit();
            return null;
        }
        return pending;
    }

    fn layoutBranchSplit(self: *Engine, pieces: []const Piece, indent: usize) !?Pending {
        var boundaries: [16]usize = undefined;
        var boundary_count: usize = 0;
        if (pieces.len == 0) return null;
        const base_depth = pieces[0].depth_before;
        for (pieces, 0..) |piece, i| {
            if (i == 0 or piece.depth_before != base_depth) continue;
            if (piece.kind != .kw_else and piece.kind != .kw_elif) continue;
            if (boundary_count == boundaries.len) break;
            boundaries[boundary_count] = i;
            boundary_count += 1;
        }
        if (boundary_count == 0) return null;

        var pending = Pending.init(self.allocator);
        errdefer pending.deinit();
        var start: usize = 0;
        var index: usize = 0;
        while (true) {
            const end = if (index < boundary_count) boundaries[index] else pieces.len;
            var segment = try self.layoutPieces(pieces[start..end], indent);
            defer segment.deinit();
            try pending.append(&segment);
            start = end;
            index += 1;
            if (start >= pieces.len) break;
        }
        return pending;
    }

    fn tryBracketWrap(self: *Engine, pieces: []const Piece, indent: usize) !?Pending {
        var pending = try self.layoutPieces(pieces, indent);
        errdefer pending.deinit();
        if (pending.lines.items.len <= 1) {
            pending.deinit();
            return null;
        }
        if (pending.overlongCount(self.options.max_line_length) > 0) {
            pending.deinit();
            return null;
        }
        return pending;
    }

    /// Wraps an overlong control-flow expression by inserting parentheses
    /// around it (`if (`, `while (`, `ret (`, `for x in (`, ...).
    fn tryInsertParens(self: *Engine, pieces: []const Piece, indent: usize) !?Pending {
        const wrap = findControlWrap(pieces) orelse return null;
        if (wrap.close_at <= wrap.open_at) return null;
        // Already parenthesized: breaking inside existing brackets would have
        // been tried already.
        const first_expr = pieces[wrap.open_at];
        if (isOpener(first_expr.kind)) return null;

        var inserted: std.ArrayListUnmanaged(Piece) = .empty;
        defer inserted.deinit(self.allocator);

        for (pieces[0..wrap.open_at]) |piece| try inserted.append(self.allocator, piece);
        const open_depth = pieces[wrap.open_at].depth_before;
        const open_paren = pieces[wrap.open_at].paren_after;
        try inserted.append(self.allocator, .{
            .kind = .lparen,
            .lexeme = "(",
            .space_before = true,
            .depth_before = open_depth,
            .depth_after = open_depth + 1,
            .paren_before = open_paren,
            .paren_after = open_paren + 1,
            .brace_after = pieces[wrap.open_at].brace_after,
            .group_indent = indent,
            .width = 1,
            .break_kind = false,
        });
        for (pieces[wrap.open_at..wrap.close_at], 0..) |piece, i| {
            var shifted = piece;
            shifted.depth_before += 1;
            shifted.depth_after += 1;
            shifted.paren_before += 1;
            shifted.paren_after += 1;
            // Expression tokens now sit directly inside the inserted parens; the
            // parens were opened on the line currently being wrapped.
            if (shifted.group_indent == 0) shifted.group_indent = indent;
            shifted.space_before = if (i == 0) false else piece.space_before;
            try inserted.append(self.allocator, shifted);
        }
        try inserted.append(self.allocator, .{
            .kind = .rparen,
            .lexeme = ")",
            .space_before = false,
            .depth_before = open_depth + 1,
            .depth_after = open_depth,
            .paren_before = open_paren + 1,
            .paren_after = open_paren,
            .brace_after = pieces[wrap.close_at - 1].brace_after,
            .group_indent = indent,
            .width = 1,
            .break_kind = false,
        });
        for (pieces[wrap.close_at..], 0..) |piece, i| {
            var copy = piece;
            if (i == 0) copy.space_before = false;
            try inserted.append(self.allocator, copy);
        }

        var pending = try self.layoutPieces(inserted.items, indent);
        errdefer pending.deinit();
        if (pending.lines.items.len <= 1) {
            pending.deinit();
            return null;
        }
        if (pending.overlongCount(self.options.max_line_length) > 0) {
            pending.deinit();
            return null;
        }
        return pending;
    }

    /// Last resort for a long struct/row literal field (`name: expr,`): the
    /// field value has no bracket breakpoint at brace-only depth, so wrap the
    /// value itself in parentheses (transparent in the AST) and break inside.
    fn tryFieldValueParens(self: *Engine, pieces: []const Piece, indent: usize) !?Pending {
        if (pieces.len < 4) return null;
        const base_depth = pieces[0].depth_before;
        if (pieces[0].paren_before != 0) return null;

        var colon: ?usize = null;
        for (pieces, 0..) |piece, i| {
            if (piece.depth_before == base_depth and piece.kind == .colon) {
                colon = i;
                break;
            }
        }
        const colon_index = colon orelse return null;
        var end = pieces.len;
        while (end > colon_index + 1 and
            pieces[end - 1].kind == .comma and
            pieces[end - 1].depth_before == base_depth)
        {
            end -= 1;
        }
        if (end <= colon_index + 1) return null;
        const value = pieces[colon_index + 1 .. end];
        if (!canParenthesizeValue(value)) return null;

        // Re-check whether the value already has a safe bracket breakpoint; if
        // it does, the normal bracket strategy wins.
        var has_group = false;
        for (value) |piece| {
            if (piece.paren_before > 0) has_group = true;
        }
        if (has_group) return null;

        var wrapped = try self.wrapInParens(value, indent);
        defer wrapped.deinit(self.allocator);

        var combined: std.ArrayListUnmanaged(Piece) = .empty;
        defer combined.deinit(self.allocator);
        try combined.ensureTotalCapacity(self.allocator, pieces.len + 2);
        for (pieces[0 .. colon_index + 1]) |piece| combined.appendAssumeCapacity(piece);
        for (wrapped.items) |piece| combined.appendAssumeCapacity(piece);
        for (pieces[end..]) |piece| combined.appendAssumeCapacity(piece);

        var pending = try self.layoutPieces(combined.items, indent);
        errdefer pending.deinit();
        if (pending.lines.items.len <= 1 or
            pending.overlongCount(self.options.max_line_length) > 0)
        {
            pending.deinit();
            return null;
        }
        return pending;
    }

    // -- greedy token layout ------------------------------------------------

    /// Lays `pieces` out greedily.  The first line keeps `first_indent`;
    /// continuation lines are indented by `indent_width`, except lines that
    /// start with a closing delimiter, which return to `first_indent`.
    fn layoutPieces(self: *Engine, pieces: []const Piece, first_indent: usize) !Pending {
        var pending = Pending.init(self.allocator);
        errdefer pending.deinit();
        if (pieces.len == 0) return pending;

        const max = self.options.max_line_length;
        var pos: usize = 0;
        var first_line = true;
        while (pos < pieces.len) {
            var indent = first_indent;
            if (!first_line) {
                // Inside `()`/`[]` the lexer suppresses newlines wholesale, so an
                // extra indent is free.  Elsewhere (e.g. inside `{}` lists) a
                // deeper line would emit a real INDENT token that the parser may
                // not pair with a DEDENT, so keep the base indent there.
                //
                // Align to the line that opened the enclosing group rather than
                // to the line being wrapped: when a long line is itself one
                // argument of an already-multiline call, its tail must line up
                // with the sibling arguments.
                indent = if (pieces[pos].group_indent > 0)
                    pieces[pos].group_indent + self.options.indent_width
                else
                    first_indent;
                if (isCloser(pieces[pos].kind)) indent = first_indent;
            }

            var content_width: usize = pieces[pos].width;
            var end = pos;
            while (end + 1 < pieces.len) {
                const next = pieces[end + 1];
                var add = next.width;
                if (next.space_before) add += 1;
                if (indent + content_width + add > max) break;
                content_width += add;
                end += 1;
            }

            var chosen: ?usize = null;
            var candidate = end;
            while (true) {
                if (candidate > pos and pieceIsBreakpoint(pieces, candidate, self.allow_brace_breaks)) {
                    chosen = candidate;
                    break;
                }
                if (candidate == pos) break;
                candidate -= 1;
            }
            if (chosen == null) {
                // Nothing in the fitting window is a legal breakpoint: overflow
                // this line up to the next legal breakpoint instead of breaking
                // in an unsafe position.
                var next_break = pos + 1;
                while (next_break < pieces.len and !pieceIsBreakpoint(pieces, next_break, self.allow_brace_breaks)) {
                    next_break += 1;
                }
                chosen = if (next_break < pieces.len) next_break else pieces.len - 1;
            }
            const line_end = chosen.?;
            const chunk = pieces[pos .. line_end + 1];
            if (line_end + 1 == pieces.len and first_indent < indent and
                chunkHasCloser(chunk) and
                indent + piecesWidth(chunk) > max and
                first_indent + piecesWidth(chunk) <= max)
            {
                // Dedenting the final line that carries a closing delimiter
                // costs nothing inside brackets and can rescue a line that would
                // otherwise overflow.
                indent = first_indent;
            }
            const line_width = indent + piecesWidth(chunk);
            const reason: ?[]const u8 = if (line_width > max) overlongReason(chunk) else null;
            try pending.addPiecesLine(indent, chunk, reason);
            pos = line_end + 1;
            first_line = false;
        }
        return pending;
    }

    // -- comments -----------------------------------------------------------

    fn finishPending(self: *Engine, pending: *Pending, indent: usize, comment: ?[]const u8) !void {
        if (comment) |text| try self.attachComment(pending, indent, text);
        try self.emitPending(pending);
        pending.deinit();
    }

    fn attachComment(self: *Engine, pending: *Pending, indent: usize, comment: []const u8) !void {
        const width = displayWidth(comment);
        if (pending.lines.items.len > 0) {
            const last = pending.lines.items.len - 1;
            if (pending.widths.items[last] + 1 + width <= self.options.max_line_length) {
                try pending.appendToLast(" ", comment);
                return;
            }
        }
        // Too long to trail the code: move the comment to its own line directly
        // above.  Moving can make it a long comment line, so wrap it the same
        // way a standalone comment would be wrapped (this also keeps a second
        // formatting pass idempotent).
        var comment_pending = Pending.init(self.allocator);
        errdefer comment_pending.deinit();
        try self.wrapCommentLines(&comment_pending, indent, comment);
        try comment_pending.append(pending);
        pending.deinit();
        pending.* = comment_pending;
    }

    /// Adds one comment to `pending`, wrapping it on word boundaries when it
    /// exceeds the column limit.
    fn wrapCommentLines(
        self: *Engine,
        pending: *Pending,
        indent: usize,
        comment: []const u8,
    ) !void {
        const max = self.options.max_line_length;
        if (indent + displayWidth(comment) <= max) {
            try pending.addTextLine(indent, comment, null);
            return;
        }

        var body = comment[1..];
        if (body.len > 0 and body[0] == ' ') body = body[1..];

        var line: std.ArrayListUnmanaged(u8) = .empty;
        defer line.deinit(self.allocator);
        try appendSpaces(&line, self.allocator, indent);
        try line.appendSlice(self.allocator, "# ");

        var width = indent + 2;
        var has_word = false;
        var words = std.mem.splitScalar(u8, body, ' ');
        while (words.next()) |word| {
            if (word.len == 0) continue;
            const word_width = displayWidth(word);
            if (!has_word) {
                try line.appendSlice(self.allocator, word);
                width += word_width;
                has_word = true;
            } else if (width + 1 + word_width <= max) {
                try line.append(self.allocator, ' ');
                try line.appendSlice(self.allocator, word);
                width += 1 + word_width;
            } else {
                try flushCommentLine(pending, &line, width);
                try appendSpaces(&line, self.allocator, indent);
                try line.appendSlice(self.allocator, "# ");
                try line.appendSlice(self.allocator, word);
                width = indent + 2 + word_width;
                has_word = true;
            }
        }

        if (!has_word) {
            try pending.addTextLine(indent, "#", null);
            return;
        }
        try flushCommentLine(pending, &line, width);
    }

    fn flushCommentLine(
        pending: *Pending,
        line: *std.ArrayListUnmanaged(u8),
        width: usize,
    ) !void {
        const text = try pending.allocator.dupe(u8, line.items);
        try pending.addOwnedLine(text, width, null);
        line.clearRetainingCapacity();
    }

    // -- output -------------------------------------------------------------

    fn emitLine(self: *Engine, text: []const u8) !void {
        if (self.out_line > 0) try self.out.append(self.allocator, '\n');
        try self.out.appendSlice(self.allocator, text);
        self.out_line += 1;
    }

    fn emitIndented(self: *Engine, indent: usize, text: []const u8) !void {
        if (self.out_line > 0) try self.out.append(self.allocator, '\n');
        var i: usize = 0;
        while (i < indent) : (i += 1) try self.out.append(self.allocator, ' ');
        try self.out.appendSlice(self.allocator, text);
        self.out_line += 1;
    }

    fn emitPending(self: *Engine, pending: *Pending) !void {
        const max = self.options.max_line_length;
        for (pending.lines.items, 0..) |line, i| {
            try self.emitLine(line);
            if (pending.widths.items[i] > max) {
                try self.unformatted.append(self.allocator, .{
                    .line = self.out_line,
                    .reason = pending.reasons.items[i] orelse "line exceeds the column limit",
                });
            }
        }
        if (pending.lines.items.len > 1) self.wrapped += 1;
    }
};

// ---------------------------------------------------------------------------
// Pending line bundle
// ---------------------------------------------------------------------------

/// Lines produced by one source line before they are committed to the output.
/// Keeping them separate lets strategies be tried and discarded cheaply.
const Pending = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayListUnmanaged([]u8) = .empty,
    widths: std.ArrayListUnmanaged(usize) = .empty,
    reasons: std.ArrayListUnmanaged(?[]const u8) = .empty,

    fn init(allocator: std.mem.Allocator) Pending {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Pending) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
        self.widths.deinit(self.allocator);
        self.reasons.deinit(self.allocator);
        self.* = undefined;
    }

    fn overlongCount(self: *const Pending, max: usize) usize {
        var count: usize = 0;
        for (self.widths.items) |width| {
            if (width > max) count += 1;
        }
        return count;
    }

    fn addOwnedLine(self: *Pending, text: []u8, width: usize, reason: ?[]const u8) !void {
        errdefer self.allocator.free(text);
        try self.lines.append(self.allocator, text);
        try self.widths.append(self.allocator, width);
        try self.reasons.append(self.allocator, reason);
    }

    fn addTextLine(self: *Pending, indent: usize, text: []const u8, reason: ?[]const u8) !void {
        const text_width = displayWidth(text);
        const line = try self.allocator.alloc(u8, indent + text.len);
        var i: usize = 0;
        while (i < indent) : (i += 1) line[i] = ' ';
        @memcpy(line[indent..], text);
        try self.addOwnedLine(line, indent + text_width, reason);
    }

    /// Renders one line from layout pieces.  Column width is counted in
    /// Unicode scalar values (`Piece.width`), while the buffer copies the
    /// original token bytes.
    fn addPiecesLine(
        self: *Pending,
        indent: usize,
        pieces: []const Piece,
        reason: ?[]const u8,
    ) !void {
        var byte_len: usize = indent;
        for (pieces, 0..) |piece, index| {
            if (index > 0 and piece.space_before) byte_len += 1;
            byte_len += piece.lexeme.len;
        }
        const line = try self.allocator.alloc(u8, byte_len);
        var i: usize = 0;
        while (i < indent) : (i += 1) line[i] = ' ';
        var cursor: usize = indent;
        for (pieces, 0..) |piece, index| {
            if (index > 0 and piece.space_before) {
                line[cursor] = ' ';
                cursor += 1;
            }
            @memcpy(line[cursor..][0..piece.lexeme.len], piece.lexeme);
            cursor += piece.lexeme.len;
        }
        try self.addOwnedLine(line, indent + piecesWidth(pieces), reason);
    }

    fn appendToLast(self: *Pending, prefix: []const u8, text: []const u8) !void {
        const index = self.lines.items.len - 1;
        const old = self.lines.items[index];
        const old_width = self.widths.items[index];
        const combined = try self.allocator.alloc(u8, old.len + prefix.len + text.len);
        @memcpy(combined[0..old.len], old);
        @memcpy(combined[old.len..][0..prefix.len], prefix);
        @memcpy(combined[old.len + prefix.len ..], text);
        self.allocator.free(old);
        self.lines.items[index] = combined;
        self.widths.items[index] = old_width + displayWidth(prefix) + displayWidth(text);
    }

    /// Appends `other` after `self`, taking ownership of its lines.
    fn append(self: *Pending, other: *Pending) !void {
        for (other.lines.items, 0..) |line, i| {
            try self.lines.append(self.allocator, line);
            try self.widths.append(self.allocator, other.widths.items[i]);
            try self.reasons.append(self.allocator, other.reasons.items[i]);
        }
        other.lines.clearRetainingCapacity();
        other.widths.clearRetainingCapacity();
        other.reasons.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------------
// Token predicates and spacing rules
// ---------------------------------------------------------------------------

fn isVirtual(kind: TokenKind) bool {
    return switch (kind) {
        .newline, .indent, .dedent, .eof => true,
        else => false,
    };
}

fn canEndExpression(kind: TokenKind) bool {
    return switch (kind) {
        .identifier,
        .int_lit,
        .float_lit,
        .string_lit,
        .kw_true,
        .kw_false,
        .kw_nil,
        .kw_self,
        .kw_super,
        .rparen,
        .rbracket,
        .rbrace,
        .question,
        => true,
        else => false,
    };
}

fn isOpener(kind: TokenKind) bool {
    return switch (kind) {
        .lparen, .lbracket, .lbrace => true,
        else => false,
    };
}

fn isCloser(kind: TokenKind) bool {
    return switch (kind) {
        .rparen, .rbracket, .rbrace => true,
        else => false,
    };
}

fn isDotLike(kind: TokenKind) bool {
    return switch (kind) {
        .dot, .dotdot, .dotdot_eq, .ellipsis, .colon_colon => true,
        else => false,
    };
}

fn isAssignKind(kind: TokenKind) bool {
    return switch (kind) {
        .bind_immutable,
        .bind_mutable,
        .assign,
        .plus_assign,
        .minus_assign,
        .star_assign,
        .slash_assign,
        .percent_assign,
        => true,
        else => false,
    };
}

/// Operator kinds that may end a wrapped line (when not in prefix position).
fn isBreakKind(kind: TokenKind, prefix: bool) bool {
    return switch (kind) {
        .minus, .star, .amp, .pipe => !prefix,
        .plus,
        .slash,
        .percent,
        .assign,
        .bind_immutable,
        .bind_mutable,
        .arrow,
        .eq_eq,
        .bang_eq,
        .lt,
        .le,
        .gt,
        .ge,
        .plus_assign,
        .minus_assign,
        .star_assign,
        .slash_assign,
        .percent_assign,
        .kw_and,
        .kw_or,
        .kw_xor,
        => true,
        else => false,
    };
}

fn spaceBeforeLparen(prev: TokenKind) bool {
    return switch (prev) {
        .identifier, .kw_self, .kw_super, .rparen, .rbracket, .question => false,
        // Keywords that take an expression (or a pattern) before their `(`.
        .kw_if,
        .kw_elif,
        .kw_while,
        .kw_match,
        .kw_for,
        .kw_ret,
        .kw_disown,
        .kw_in,
        .kw_not,
        .kw_and,
        .kw_or,
        .kw_xor,
        .kw_sys,
        .kw_await,
        .kw_spawn,
        .kw_detach,
        .kw_cancel,
        .kw_else,
        .kw_as,
        .kw_mut,
        .kw_where,
        .kw_from,
        .kw_select,
        .kw_res,
        .kw_use,
        .kw_mod,
        .kw_pub,
        .kw_impl,
        .kw_trait,
        .kw_unsafe,
        .kw_loop,
        => true,
        // Attribute keywords (`@trigger(...)`) and other identifiers attach.
        else => !syntax.isKeywordKind(prev),
    };
}

fn spaceBeforeLbracket(prev: TokenKind) bool {
    return switch (prev) {
        .identifier, .kw_self, .kw_super, .rparen, .rbracket, .question => false,
        else => true,
    };
}

fn spaceBetween(
    prev: TokenKind,
    cur: TokenKind,
    cur_prefix: bool,
    prev_prefix: bool,
    gap_has_space: bool,
) bool {
    // `<` and `>` are ambiguous (generic argument vs comparison), so keep the
    // author's horizontal spacing around them.
    if (prev == .lt or prev == .gt or cur == .lt or cur == .gt) return gap_has_space;

    switch (cur) {
        .rparen, .rbracket, .rbrace, .comma, .semicolon, .colon => return false,
        else => {},
    }
    if (isDotLike(cur)) return false;

    switch (prev) {
        .lparen, .lbracket, .lbrace, .at => return false,
        else => {},
    }
    if (isDotLike(prev)) return false;
    if (prev_prefix) return false;

    if (cur == .question) return cur_prefix;
    if (cur == .lparen) return spaceBeforeLparen(prev);
    if (cur == .lbracket) return spaceBeforeLbracket(prev);
    return true;
}

// ---------------------------------------------------------------------------
// Breakpoints and context detection
// ---------------------------------------------------------------------------

fn pieceIsBreakpoint(pieces: []const Piece, index: usize, allow_brace_breaks: bool) bool {
    if (index + 1 >= pieces.len) return true;
    return pieceAllowsBreakAfter(pieces[index], allow_brace_breaks);
}

/// A breakpoint is only safe when the lexer will not turn the inserted newline
/// into a real token in an expression position:
///   * after `(`, `[`, `{`: the newline opens a list body or is suppressed;
///   * after `,` inside `()`/`[]` (suppressed) or `{}` (a field/row separator);
///   * after a binary operator only inside `()`/`[]`, where the lexer
///     suppresses newlines.
fn lineHasMapLiteral(pieces: []const Piece) bool {
    for (pieces, 0..) |piece, i| {
        if (piece.kind != .identifier or !std.mem.eql(u8, piece.lexeme, "map")) continue;
        if (i + 1 >= pieces.len or pieces[i + 1].kind != .lbracket) continue;
        for (pieces[i + 2 ..]) |rest| {
            if (rest.kind == .lbrace) return true;
            if (rest.kind == .semicolon) break;
        }
    }
    return false;
}

fn chunkHasCloser(chunk: []const Piece) bool {
    for (chunk) |piece| {
        if (isCloser(piece.kind)) return true;
    }
    return false;
}

fn pieceAllowsBreakAfter(piece: Piece, allow_brace_breaks: bool) bool {
    return switch (piece.kind) {
        .lparen, .lbracket => true,
        .lbrace => piece.paren_after > 0 or allow_brace_breaks,
        .comma => piece.paren_after > 0 or (allow_brace_breaks and piece.brace_after > 0),
        else => piece.break_kind and piece.paren_after > 0,
    };
}

fn piecesWidth(pieces: []const Piece) usize {
    var width: usize = 0;
    for (pieces, 0..) |piece, i| {
        if (i > 0 and piece.space_before) width += 1;
        width += piece.width;
    }
    return width;
}

fn overlongReason(pieces: []const Piece) []const u8 {
    if (pieces.len == 1 and pieces[0].kind == .string_lit) return "long string literal";
    for (pieces) |piece| {
        if (piece.kind == .string_lit and piece.width > 0) {
            // A single unbreakable string longer than the line: name the cause.
            if (piece.width >= 60) return "long string literal";
        }
    }
    if (pieces.len == 1) return "unbreakable token";
    return "no safe breakpoint under the column limit";
}

fn isControlKeyword(kind: TokenKind) bool {
    return switch (kind) {
        .kw_if, .kw_elif, .kw_while, .kw_match, .kw_for, .kw_ret, .kw_disown => true,
        else => false,
    };
}

const ControlWrap = struct {
    /// Index of the first expression token; the opening paren goes before it.
    open_at: usize,
    /// Index one past the last expression token; the closing paren goes here.
    close_at: usize,
};

/// A value expression may be wrapped in parentheses only when doing so cannot
/// disturb a layout construct that depends on real newlines (`if`/`match`
/// bodies) and when it is not already a bracketed value.
fn canParenthesizeValue(pieces: []const Piece) bool {
    if (pieces.len == 0) return false;
    switch (pieces[0].kind) {
        .lparen, .lbracket, .lbrace => return false,
        .kw_if, .kw_match, .kw_loop => return false,
        else => {},
    }
    const base_depth = pieces[0].depth_before;
    for (pieces) |piece| {
        if (piece.depth_before != base_depth) continue;
        switch (piece.kind) {
            .kw_else, .kw_elif, .semicolon => return false,
            else => {},
        }
    }
    return true;
}

fn findControlWrap(pieces: []const Piece) ?ControlWrap {
    if (pieces.len < 2) return null;
    if (!isControlKeyword(pieces[0].kind)) return null;
    const base_depth = pieces[0].depth_before;
    switch (pieces[0].kind) {
        .kw_ret, .kw_disown => return .{ .open_at = 1, .close_at = pieces.len },
        .kw_for => {
            var in_index: ?usize = null;
            for (pieces, 0..) |piece, i| {
                if (i == 0) continue;
                if (piece.depth_before != base_depth) continue;
                if (piece.kind == .kw_in) {
                    in_index = i;
                    break;
                }
            }
            const in_pos = in_index orelse return null;
            const open_at = in_pos + 1;
            if (open_at >= pieces.len) return null;
            var close_at = pieces.len;
            for (pieces[open_at..], open_at..) |piece, i| {
                if (piece.depth_before == base_depth and piece.kind == .colon) {
                    close_at = i;
                    break;
                }
            }
            if (close_at <= open_at) return null;
            return .{ .open_at = open_at, .close_at = close_at };
        },
        else => {
            const open_at: usize = 1;
            var close_at = pieces.len;
            for (pieces[open_at..], open_at..) |piece, i| {
                if (piece.depth_before == base_depth and piece.kind == .colon) {
                    close_at = i;
                    break;
                }
            }
            if (close_at <= open_at) return null;
            return .{ .open_at = open_at, .close_at = close_at };
        },
    }
}

fn findAssignmentOperator(pieces: []const Piece) ?usize {
    if (pieces.len < 3) return null;
    const base_depth = pieces[0].depth_before;
    switch (pieces[0].kind) {
        .at, .kw_pub, .kw_use, .kw_mod, .kw_impl, .kw_trait => return null,
        else => {},
    }
    for (pieces, 0..) |piece, i| {
        if (piece.depth_before != base_depth) continue;
        if (!isAssignKind(piece.kind)) continue;
        if (i == 0 or i + 1 >= pieces.len) return null;

        switch (piece.kind) {
            .bind_immutable => {
                switch (pieces[i + 1].kind) {
                    // Declaration keywords: `<-` here starts a function, sys, or
                    // aggregate declaration, where an indented value is invalid.
                    .kw_sys, .kw_struct, .kw_enum, .kw_table, .kw_trigger, .kw_plugin, .kw_trait, .kw_async => return null,
                    .lparen => {
                        const close = matchingClose(pieces, i + 1) orelse return null;
                        if (close + 1 < pieces.len and pieces[close + 1].kind == .arrow) return null;
                    },
                    else => {},
                }
            },
            .assign => {
                // A `->` before `=` means this is a function body, not an
                // assignment statement.
                for (pieces[0..i]) |earlier| {
                    if (earlier.kind == .arrow) return null;
                }
            },
            else => {},
        }

        // Multiple statements on one line are left alone.
        for (pieces[i + 1 ..]) |later| {
            if (later.kind == .semicolon and later.depth_before == base_depth) return null;
        }
        return i;
    }
    return null;
}

fn matchingClose(pieces: []const Piece, open_index: usize) ?usize {
    const open = pieces[open_index];
    const depth = open.depth_before;
    var i = open_index + 1;
    while (i < pieces.len) : (i += 1) {
        const piece = pieces[i];
        if (piece.depth_before == depth and isCloser(piece.kind)) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Small text helpers
// ---------------------------------------------------------------------------

fn leadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') count += 1;
    return count;
}

fn appendSpaces(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, count: usize) !void {
    try list.ensureUnusedCapacity(allocator, count);
    var i: usize = 0;
    while (i < count) : (i += 1) list.appendAssumeCapacity(' ');
}

/// Number of Unicode scalar values in `text` (the formatter's column unit).
fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (byte < 0x80) {
            width += 1;
            i += 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            width += 1;
            i += 1;
            continue;
        };
        if (i + seq_len > text.len) {
            width += 1;
            i += 1;
            continue;
        }
        if (std.unicode.utf8Decode(text[i..][0..seq_len])) |_| {
            width += 1;
        } else |_| {
            width += 1;
        }
        i += seq_len;
    }
    return width;
}

/// Finds the start of a trailing `#` comment, ignoring `#` inside strings.
fn findCommentStart(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len) {
        const byte = line[i];
        if (byte == '"' or byte == '\'') {
            const quote = byte;
            i += 1;
            while (i < line.len) {
                if (line[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (line[i] == quote) {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }
        if (byte == '#') return i;
        i += 1;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectFormatted(source: []const u8, expected: []const u8) !void {
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    try expectParses(result.text);
}

fn expectParses(text: []const u8) !void {
    const parsed = try compiler.parser.parse(testing.allocator, text);
    switch (parsed) {
        .ast => |ast_value| {
            var ast = ast_value;
            ast.deinit();
        },
        .diagnostic => return error.TestUnexpectedResult,
    }
}

test "short lines are preserved unchanged" {
    const source =
        \\x := 1
        \\
    ;
    const expected =
        \\x := 1
        \\
    ;
    try expectFormatted(source, expected);
}

test "spacing: normalizes operators, commas, brackets and paths" {
    const source =
        \\pub sample <- (a: i64) -> i64:
        \\    f ( a , b , c )
        \\    x:=1+2*3
        \\    y = -1 + 2 - -3
        \\    z.field = y
        \\    r := &mut x
        \\    s := foo::bar ( )
        \\    t := [ 1 , 2 , 3 ]
        \\    u := map[str,i64]{ "a" : 1 }
        \\    w := thing?
        \\    if x==1:
        \\        ret 0
        \\    ret a
        \\
    ;
    const expected =
        \\pub sample <- (a: i64) -> i64:
        \\    f(a, b, c)
        \\    x := 1 + 2 * 3
        \\    y = -1 + 2 - -3
        \\    z.field = y
        \\    r := &mut x
        \\    s := foo::bar()
        \\    t := [1, 2, 3]
        \\    u := map[str, i64] { "a": 1 }
        \\    w := thing?
        \\    if x == 1:
        \\        ret 0
        \\    ret a
        \\
    ;
    try expectFormatted(source, expected);
}

test "spacing: single-line brace literals keep one inner space on each side" {
    const source =
        \\use engine::gfx::{Renderer, Sampler};
        \\
        \\pub sample <- () -> i64:
        \\    a := Thing { id: 1 }
        \\    b := Row { x, y }
        \\    c := map[str, i64] { "k": 1 }
        \\    d := Thing {}
        \\    ret a.id
        \\
    ;
    const expected =
        \\use engine::gfx::{Renderer, Sampler};
        \\
        \\pub sample <- () -> i64:
        \\    a := Thing { id: 1 }
        \\    b := Row { x, y }
        \\    c := map[str, i64] { "k": 1 }
        \\    d := Thing {}
        \\    ret a.id
        \\
    ;
    try expectFormatted(source, expected);
}

test "wrap: long call arguments break inside the existing parentheses" {
    const source =
        \\pub sample <- () -> i64:
        \\    ret some_long_function_name(first_argument_name, second_argument_name, third_argument_name_here)
        \\
    ;
    const expected =
        \\pub sample <- () -> i64:
        \\    ret some_long_function_name(first_argument_name, second_argument_name,
        \\        third_argument_name_here)
        \\
    ;
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    try testing.expectEqual(@as(usize, 1), result.wrapped);
    try testing.expectEqual(@as(usize, 0), result.unformatted.len);
    try expectParses(result.text);
}

test "wrap: nested calls break greedily inside each call" {
    const source =
        \\pub sample <- () -> i64:
        \\    ret outer_function_name(inner_function_name(first_argument, second_argument), another_inner_function(third_argument, fourth_argument))
        \\
    ;
    const expected =
        \\pub sample <- () -> i64:
        \\    ret outer_function_name(inner_function_name(first_argument,
        \\        second_argument), another_inner_function(third_argument,
        \\        fourth_argument))
        \\
    ;
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    try testing.expectEqual(@as(usize, 1), result.wrapped);
    try testing.expectEqual(@as(usize, 0), result.unformatted.len);
    try expectParses(result.text);
}

test "wrap: sys parameter list" {
    const source =
        \\pub sample <- sys (read: res &Input, world: res &mut PhysicsWorld, spatial: res &mut SpatialMap, bodies: select &mut Transform, &mut RigidBody from Components):
        \\    ret
        \\
    ;
    const expected =
        \\pub sample <- sys (read: res &Input, world: res &mut PhysicsWorld,
        \\spatial: res &mut SpatialMap, bodies: select &mut Transform,
        \\&mut RigidBody from Components):
        \\    ret
        \\
    ;
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    try testing.expectEqual(@as(usize, 1), result.wrapped);
    try testing.expectEqual(@as(usize, 0), result.unformatted.len);
    try expectParses(result.text);
}

test "wrap: an existing parenthesized condition wraps before inserting parens" {
    const source =
        \\pub sample <- (gpu: Gpu, window: Window) -> i64:
        \\    if gpu.scene != 0 and (gpu.width != window.width or gpu.height != window.height):
        \\        ret 0
        \\    ret 1
        \\
    ;
    const expected =
        \\pub sample <- (gpu: Gpu, window: Window) -> i64:
        \\    if gpu.scene != 0 and (gpu.width != window.width or gpu.height !=
        \\        window.height):
        \\        ret 0
        \\    ret 1
        \\
    ;
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    try testing.expectEqual(@as(usize, 1), result.wrapped);
    try testing.expectEqual(@as(usize, 0), result.unformatted.len);
    try expectParses(result.text);
}

test "assignment: a long binding uses the indented-value form" {
    const source =
        \\pub sample <- () -> i64:
        \\    value := some_module::some_function(argument_one, argument_two, argument_three, four)
        \\    ret value
        \\
    ;
    const expected =
        \\pub sample <- () -> i64:
        \\    value :=
        \\        some_module::some_function(argument_one, argument_two, argument_three,
        \\            four)
        \\    ret value
        \\
    ;
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    try testing.expectEqual(@as(usize, 1), result.wrapped);
    try testing.expectEqual(@as(usize, 0), result.unformatted.len);
    try expectParses(result.text);
}

test "assignment: compound assignment also uses the indented-value form" {
    const source =
        \\pub sample <- (total: i64) -> i64:
        \\    total += some_module::some_function(argument_one, argument_two, argument_three)
        \\    ret total
        \\
    ;
    const expected =
        \\pub sample <- (total: i64) -> i64:
        \\    total +=
        \\        some_module::some_function(argument_one, argument_two, argument_three)
        \\    ret total
        \\
    ;
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    try testing.expectEqual(@as(usize, 1), result.wrapped);
    try testing.expectEqual(@as(usize, 0), result.unformatted.len);
    try expectParses(result.text);
}

test "assignment: an if/else value splits into one branch per line" {
    const source =
        \\pub sample <- (field: Field) -> [f32]:
        \\    colour <- if field.focused: [1.0, 1.0, 1.0, 1.0] else: [0.82, 0.86, 0.92, 1.0]
        \\    ret colour
        \\
    ;
    const expected =
        \\pub sample <- (field: Field) -> [f32]:
        \\    colour <-
        \\        if field.focused: [1.0, 1.0, 1.0, 1.0]
        \\        else: [0.82, 0.86, 0.92, 1.0]
        \\    ret colour
        \\
    ;
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    try testing.expectEqual(@as(usize, 1), result.wrapped);
    try testing.expectEqual(@as(usize, 0), result.unformatted.len);
    try expectParses(result.text);
}

test "declaration: a long function signature wraps parameters, not the body" {
    const source =
        \\pub has_image <- (assets: &ImageAssets, path: str) -> bool = assets.images.has_file(path)
        \\
    ;
    const expected =
        \\pub has_image <- (assets: &ImageAssets,
        \\path: str) -> bool = assets.images.has_file(path)
        \\
    ;
    try expectFormatted(source, expected);
}

test "parens: a long if condition is parenthesized and wrapped" {
    const source =
        \\pub sample <- (a: i64) -> i64:
        \\    if condition_one_name and condition_two_name and condition_three_name and condition_four_name:
        \\        ret 0
        \\    ret a
        \\
    ;
    const expected =
        \\pub sample <- (a: i64) -> i64:
        \\    if (condition_one_name and condition_two_name and condition_three_name and
        \\        condition_four_name):
        \\        ret 0
        \\    ret a
        \\
    ;
    try expectFormatted(source, expected);
}

test "parens: a long while condition is parenthesized and wrapped" {
    const source =
        \\pub sample <- (a: i64) -> i64:
        \\    while condition_one_name and condition_two_name and condition_three_name and condition_four_name:
        \\        ret 0
        \\    ret a
        \\
    ;
    const expected =
        \\pub sample <- (a: i64) -> i64:
        \\    while (condition_one_name and condition_two_name and
        \\        condition_three_name and condition_four_name):
        \\        ret 0
        \\    ret a
        \\
    ;
    try expectFormatted(source, expected);
}

test "parens: a long match subject is parenthesized and wrapped" {
    const source =
        \\pub sample <- (a: i64) -> i64:
        \\    match some_long_expression_name_that_is_quite_long_here_plus_some_more_stuff:
        \\        1: ret 0
        \\        2: ret 1
        \\
    ;
    const expected =
        \\pub sample <- (a: i64) -> i64:
        \\    match (
        \\        some_long_expression_name_that_is_quite_long_here_plus_some_more_stuff):
        \\        1: ret 0
        \\        2: ret 1
        \\
    ;
    try expectFormatted(source, expected);
}

test "parens: a long match subject with operators breaks after operators" {
    const source =
        \\pub sample <- (a: i64) -> i64:
        \\    match alpha_operand_name + beta_operand_name + gamma_operand_name + delta_operand_name:
        \\        1: ret 0
        \\        2: ret 1
        \\
    ;
    const expected =
        \\pub sample <- (a: i64) -> i64:
        \\    match (alpha_operand_name + beta_operand_name + gamma_operand_name +
        \\        delta_operand_name):
        \\        1: ret 0
        \\        2: ret 1
        \\
    ;
    try expectFormatted(source, expected);
}

test "parens: a long ret expression is parenthesized and wrapped" {
    const source =
        \\pub sample <- () -> i64:
        \\    ret a_very_long_expression_name_that_needs_wrapping_because_it_is_long + another_operand_name
        \\
    ;
    const expected =
        \\pub sample <- () -> i64:
        \\    ret (a_very_long_expression_name_that_needs_wrapping_because_it_is_long +
        \\        another_operand_name)
        \\
    ;
    try expectFormatted(source, expected);
}

test "parens: a long for iterable is parenthesized and wrapped" {
    const source =
        \\pub sample <- (a: i64) -> i64:
        \\    for value in some_collection_that_has_a_really_long_name_and_more_suffixes_here:
        \\        ret 0
        \\    ret a
        \\
    ;
    const expected =
        \\pub sample <- (a: i64) -> i64:
        \\    for value in (
        \\        some_collection_that_has_a_really_long_name_and_more_suffixes_here):
        \\        ret 0
        \\    ret a
        \\
    ;
    try expectFormatted(source, expected);
}

test "wrap: a long argument of an already-multiline call aligns with its siblings" {
    const source =
        \\pub sample <- () -> i64:
        \\    e7_engine_scene_draw_shape_rot(
        \\        gpu.scene, kind, px, py, pz, sx, sy, sz, rx, ry, rz, tr, tg, tb, texture_long_argument_here,
        \\    )
        \\    ret 0
        \\
    ;
    const expected =
        \\pub sample <- () -> i64:
        \\    e7_engine_scene_draw_shape_rot(
        \\        gpu.scene, kind, px, py, pz, sx, sy, sz, rx, ry, rz, tr, tg, tb,
        \\        texture_long_argument_here,
        \\    )
        \\    ret 0
        \\
    ;
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    // The wrapped tail must use the sibling indent (opener line indent + 4),
    // not the indent of the line being wrapped plus another level.
    var lines = std.mem.splitScalar(u8, result.text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "        texture_long_argument_here,")) return;
    }
    return error.TestUnexpectedResult;
}

test "iterative wrapping: a fragment created by the first split is wrapped again" {
    const source =
        \\pub sample <- () -> i64:
        \\    some_function_with_a_really_long_name(first_argument_name, second_argument_name, third_argument_name).field = some_value_expression_here_that_is_long
        \\    ret 0
        \\
    ;
    const expected =
        \\pub sample <- () -> i64:
        \\    some_function_with_a_really_long_name(first_argument_name,
        \\        second_argument_name, third_argument_name).field =
        \\        some_value_expression_here_that_is_long
        \\    ret 0
        \\
    ;
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    try testing.expectEqual(@as(usize, 1), result.wrapped);
    try testing.expectEqual(@as(usize, 0), result.unformatted.len);
    try expectParses(result.text);
    // The wrapped output is itself a fixed point.
    var again = try format(testing.allocator, result.text, .{});
    defer again.deinit();
    try testing.expectEqualStrings(result.text, again.text);
    try testing.expectEqual(@as(usize, 0), again.wrapped);
}

test "unformatted: a long use declaration is left alone and reported" {
    const source =
        \\use engine::gfx::{Renderer, RenderTarget, RenderPassDescriptor, TextureView, Sampler, ShaderModule};
        \\
    ;
    const expected =
        \\use engine::gfx::{Renderer, RenderTarget, RenderPassDescriptor, TextureView, Sampler, ShaderModule};
        \\
    ;
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    try testing.expectEqual(@as(usize, 0), result.wrapped);
    try testing.expectEqual(@as(usize, 1), result.unformatted.len);
    try testing.expectEqual(@as(usize, 1), result.unformatted[0].line);
    try testing.expectEqualStrings("long use declaration", result.unformatted[0].reason);
    try expectParses(result.text);
}

test "unformatted: a long disown expression with no breakpoint is reported" {
    const source =
        \\pub sample <- (commands: i64) -> i64:
        \\    disown commands_that_have_a_very_long_name_and_would_go_over_the_line_limit_here_ok
        \\    ret 0
        \\
    ;
    const expected =
        \\pub sample <- (commands: i64) -> i64:
        \\    disown commands_that_have_a_very_long_name_and_would_go_over_the_line_limit_here_ok
        \\    ret 0
        \\
    ;
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    try testing.expectEqual(@as(usize, 0), result.wrapped);
    try testing.expectEqual(@as(usize, 1), result.unformatted.len);
    try testing.expectEqual(@as(usize, 2), result.unformatted[0].line);
    try testing.expectEqualStrings("no safe breakpoint under the column limit", result.unformatted[0].reason);
}

test "unformatted: a long string literal is never split" {
    const source =
        \\pub sample <- () -> i64:
        \\    ret "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\
    ;
    const expected =
        \\pub sample <- () -> i64:
        \\    ret "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\
    ;
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    try testing.expectEqual(@as(usize, 0), result.wrapped);
    try testing.expectEqual(@as(usize, 1), result.unformatted.len);
    try testing.expectEqualStrings("long string literal", result.unformatted[0].reason);
    try expectParses(result.text);
}

test "assignment: an unbracketed long value falls back to a parenthesized group" {
    const source =
        \\pub sample <- () -> i64:
        \\    value := alpha_operand_name + beta_operand_name + gamma_operand_name + delta_operand_name
        \\    ret value
        \\
    ;
    const expected =
        \\pub sample <- () -> i64:
        \\    value :=
        \\        (alpha_operand_name + beta_operand_name + gamma_operand_name +
        \\            delta_operand_name)
        \\    ret value
        \\
    ;
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    try testing.expectEqual(@as(usize, 1), result.wrapped);
    try testing.expectEqual(@as(usize, 0), result.unformatted.len);
    try expectParses(result.text);
}

test "assignment: the parenthesized fallback breaks after operators" {
    const source =
        \\pub ray_plane <- (ray: Ray, normal: Vec3, offset: f32) -> RayHit:
        \\    denominator := normal.x * ray.direction.x + normal.y * ray.direction.y + normal.z * ray.direction.z
        \\    ret ray
        \\
    ;
    const expected =
        \\pub ray_plane <- (ray: Ray, normal: Vec3, offset: f32) -> RayHit:
        \\    denominator :=
        \\        (normal.x * ray.direction.x + normal.y * ray.direction.y + normal.z *
        \\            ray.direction.z)
        \\    ret ray
        \\
    ;
    try expectFormatted(source, expected);
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    var lines = std.mem.splitScalar(u8, result.text, '\n');
    while (lines.next()) |line| {
        try testing.expect(line.len <= 80);
    }
}

test "comments: an overlong comment line reflows on word boundaries" {
    const source =
        \\# This is a very long comment line that should be reflowed because it is longer than eighty columns for sure and more words here
        \\
    ;
    const expected =
        \\# This is a very long comment line that should be reflowed because it is longer
        \\# than eighty columns for sure and more words here
        \\
    ;
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    try testing.expectEqual(@as(usize, 0), result.unformatted.len);
    try testing.expectEqual(@as(usize, 1), result.wrapped);
    var lines = std.mem.splitScalar(u8, result.text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(line.len <= 80);
        try testing.expect(std.mem.startsWith(u8, line, "# "));
    }
}

test "comments: a short trailing comment keeps exactly one space" {
    const source =
        \\pub sample <- () -> i64:
        \\    x := 1  # note
        \\    ret x
        \\
    ;
    const expected =
        \\pub sample <- () -> i64:
        \\    x := 1 # note
        \\    ret x
        \\
    ;
    try expectFormatted(source, expected);
}

test "comments: a long trailing comment moves above the code" {
    const source =
        \\pub sample <- () -> i64:
        \\    x := 1  # trailing comment that is long enough to push this line over the eighty column limit easily
        \\    ret x
        \\
    ;
    const expected =
        \\pub sample <- () -> i64:
        \\    # trailing comment that is long enough to push this line over the eighty
        \\    # column limit easily
        \\    x := 1
        \\    ret x
        \\
    ;
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(expected, result.text);
    try testing.expectEqual(@as(usize, 0), result.unformatted.len);
    try testing.expectEqual(@as(usize, 1), result.wrapped);
    try expectParses(result.text);
}

test "width: line length counts code points, not bytes" {
    // 77 code points but ~150 UTF-8 bytes: this line must not be treated as long.
    const source = "x := \"" ++ ("\u{00e9}" ** 70) ++ "\"\n";
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.fallback);
    try testing.expectEqualStrings(source, result.text);
    try testing.expectEqual(@as(usize, 0), result.unformatted.len);
    try expectParses(result.text);
}

test "fallback: unparseable source is returned unchanged" {
    const source = "if\n";
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(result.fallback);
    try testing.expectEqualStrings(source, result.text);
    try testing.expectEqual(@as(usize, 0), result.wrapped);
    try testing.expectEqual(@as(usize, 0), result.unformatted.len);
}

test "idempotency: formatted output reformats to itself with zero wrapped lines" {
    const source =
        \\pub sample <- (field: Field) -> [f32]:
        \\    colour <- if field.focused: [1.0, 1.0, 1.0, 1.0] else: [0.82, 0.86, 0.92, 1.0]
        \\    ret colour
        \\
    ;
    var first = try format(testing.allocator, source, .{});
    defer first.deinit();
    try testing.expect(!first.fallback);

    var second = try format(testing.allocator, first.text, .{});
    defer second.deinit();
    try testing.expect(!second.fallback);
    try testing.expectEqualStrings(first.text, second.text);
    try testing.expectEqual(@as(usize, 0), second.wrapped);
    try testing.expectEqual(first.unformatted.len, second.unformatted.len);
}

test "field value: an unbracketed long field falls back to a parenthesized group" {
    const source =
        \\pub sample <- (rot: Mat3, diag: Vec3) -> Mat3:
        \\    ret Mat3 {
        \\        m00: rot.m00 * diag.x * rot.m00 + rot.m01 * diag.y * rot.m01 + rot.m02 * diag.z * rot.m02,
        \\        m11: rot.m10 * diag.x * rot.m10 + rot.m11 * diag.y * rot.m11 + rot.m12 * diag.z * rot.m12,
        \\    }
        \\
    ;
    const expected =
        \\pub sample <- (rot: Mat3, diag: Vec3) -> Mat3:
        \\    ret Mat3 {
        \\        m00: (rot.m00 * diag.x * rot.m00 + rot.m01 * diag.y * rot.m01 +
        \\            rot.m02 * diag.z * rot.m02),
        \\        m11: (rot.m10 * diag.x * rot.m10 + rot.m11 * diag.y * rot.m11 +
        \\            rot.m12 * diag.z * rot.m12),
        \\    }
        \\
    ;
    try expectFormatted(source, expected);
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.unformatted.len);
    var lines = std.mem.splitScalar(u8, result.text, '\n');
    while (lines.next()) |line| {
        try testing.expect(line.len <= 80);
    }
}
