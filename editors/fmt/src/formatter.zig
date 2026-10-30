//! `e7-fmt`: formatter for the engine7 surface language.
//!
//! Pipeline:
//!   1. normalize line endings, trailing whitespace, tabs, and the final
//!      newline;
//!   2. lex/parse.  Invalid source keeps rule 1 only;
//!   3. convert `:=` mutable bindings to `<-` when the semantic analyzer never
//!      saw the binding mutated (project-aware when a project index/path is
//!      supplied), then re-analyze to make sure the rewrite did not introduce
//!      diagnostics;
//!   4. run the token-aware layout pass (`layout.zig`) for 80-column wrapping
//!      and spacing normalization;
//!   5. re-parse/re-analyze the result; if layout output stopped parsing or
//!      gained diagnostics, fall back to the pre-layout text.
//!
//! The formatter never reorders declarations, rewrites expressions, or edits
//! strings.  Its only structural changes are the `:=` -> `<-` rewrite and the
//! line breaks/indentation produced by the layout pass (including the
//! indented-assignment-value syntax).

const std = @import("std");
const compiler = @import("compiler");
const analysis = @import("analysis");
const project = @import("project");
const layout = @import("layout.zig");

pub const max_line_length: usize = 80;
pub const indent_width: usize = 4;

pub const Options = struct {
    /// Absolute path of the file, when known (enables project-aware analysis).
    path: ?[]const u8 = null,
    /// Workspace project index, when available.
    project_index: ?*project.Index = null,
    /// Convert `:=` to `<-` for bindings that are never mutated.
    convert_mutable_bindings: bool = true,
    /// Enforce the line length limit.
    wrap_lines: bool = true,
};

pub const Unformatted = layout.Unformatted;

pub const Result = struct {
    allocator: std.mem.Allocator,
    /// Formatted text (owned), always newline-terminated when non-empty.
    text: []u8,
    /// True when `text` differs from the input.
    changed: bool,
    /// False when the input could not be lexed/parsed; only whitespace
    /// normalization was applied.
    parse_ok: bool,
    /// Number of `:=` -> `<-` conversions kept.
    conversions: usize,
    /// Number of source lines split by the layout pass.
    wrapped: usize,
    /// Lines that remain over the limit (owned slice).
    unformatted: []Unformatted,
    /// True when the layout pass produced text that no longer parsed or that
    /// gained diagnostics, so it was discarded.
    layout_fallback: bool = false,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.text);
        self.allocator.free(self.unformatted);
        self.* = undefined;
    }
};

/// Formats one source buffer.  Never fails on invalid e7: the result reports
/// `parse_ok = false` and contains only whitespace-normalized text.
pub fn format(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
) !Result {
    const normalized = try normalizeSource(allocator, source);
    errdefer allocator.free(normalized);

    if (!parses(allocator, normalized)) {
        return .{
            .allocator = allocator,
            .text = normalized,
            .changed = !std.mem.eql(u8, normalized, source),
            .parse_ok = false,
            .conversions = 0,
            .wrapped = 0,
            .unformatted = try allocator.alloc(Unformatted, 0),
        };
    }

    var baseline = try analyzeSource(allocator, normalized, options);
    defer baseline.deinit();

    // `working` is the owned text the layout pass runs on.
    var working: []u8 = normalized;
    errdefer allocator.free(working);
    var conversions: usize = 0;

    if (options.convert_mutable_bindings) {
        const rewrite = try applyConversions(allocator, working, baseline.mutable_candidates);
        if (rewrite.count == 0) {
            allocator.free(rewrite.text);
        } else {
            var after = try analyzeSource(allocator, rewrite.text, options);
            defer after.deinit();
            if (after.diagnostics.len > baseline.diagnostics.len) {
                // The candidate pass missed a mutation the analyzer enforces;
                // keep every binding mutable.
                allocator.free(rewrite.text);
            } else {
                allocator.free(working);
                working = rewrite.text;
                conversions = rewrite.count;
            }
        }
    }
    defer allocator.free(working);

    var final_text: []u8 = try allocator.dupe(u8, working);
    errdefer allocator.free(final_text);
    var unformatted: []Unformatted = try allocator.alloc(Unformatted, 0);
    errdefer allocator.free(unformatted);
    var wrapped: usize = 0;
    var layout_fallback = false;

    if (options.wrap_lines) {
        var layout_result = layout.format(allocator, working, .{}) catch return error.OutOfMemory;
        defer layout_result.deinit();
        if (layout_result.fallback or !parses(allocator, layout_result.text)) {
            layout_fallback = true;
        } else {
            var laid_out = try analyzeSource(allocator, layout_result.text, options);
            defer laid_out.deinit();
            if (laid_out.diagnostics.len > baseline.diagnostics.len) {
                layout_fallback = true;
            } else {
                allocator.free(final_text);
                final_text = try allocator.dupe(u8, layout_result.text);
                allocator.free(unformatted);
                unformatted = try allocator.dupe(Unformatted, layout_result.unformatted);
                wrapped = layout_result.wrapped;
            }
        }
    }

    return .{
        .allocator = allocator,
        .text = final_text,
        .changed = !std.mem.eql(u8, final_text, source),
        .parse_ok = true,
        .conversions = conversions,
        .wrapped = wrapped,
        .unformatted = unformatted,
        .layout_fallback = layout_fallback,
    };
}

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------

/// Normalizes CRLF to LF, strips trailing whitespace, expands tabs outside
/// string literals, and guarantees exactly one final newline.
fn normalizeSource(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    // CRLF first so all later offsets and the lexer see plain LF.
    var without_cr: std.ArrayListUnmanaged(u8) = .empty;
    defer without_cr.deinit(allocator);
    try without_cr.ensureTotalCapacity(allocator, source.len);
    for (source) |byte| {
        if (byte == '\r') continue;
        without_cr.appendAssumeCapacity(byte);
    }
    const plain = without_cr.items;

    // String literal spans are the only places tabs are content, not layout.
    const string_spans = try lexStringSpans(allocator, plain);
    defer allocator.free(string_spans);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, plain.len + 1);

    var column: usize = 0;
    var span_index: usize = 0;
    var index: usize = 0;
    while (index < plain.len) : (index += 1) {
        const byte = plain[index];
        const in_string = span_index < string_spans.len and
            index >= string_spans[span_index].start and
            index < string_spans[span_index].end;
        if (!in_string) {
            while (span_index < string_spans.len and index >= string_spans[span_index].end) span_index += 1;
        }

        if (byte == '\n') {
            trimTrailingSpace(&out);
            out.appendAssumeCapacity('\n');
            column = 0;
            continue;
        }
        if (byte == '\t' and !in_string) {
            const width = 4 - (column % 4);
            for (0..width) |_| out.appendAssumeCapacity(' ');
            column += width;
            continue;
        }
        out.appendAssumeCapacity(byte);
        column += 1;
    }

    // Exactly one final newline; trim a trailing blank run.
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') _ = out.pop();
    if (out.items.len > 0) out.appendAssumeCapacity('\n');

    return out.toOwnedSlice(allocator);
}

fn trimTrailingSpace(buffer: *std.ArrayListUnmanaged(u8)) void {
    while (buffer.items.len > 0 and
        (buffer.items[buffer.items.len - 1] == ' ' or buffer.items[buffer.items.len - 1] == '\t'))
    {
        _ = buffer.pop();
    }
}

const Span = struct { start: usize, end: usize };

fn lexStringSpans(allocator: std.mem.Allocator, source: []const u8) ![]Span {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const lexed = compiler.lexer.lex(arena.allocator(), source) catch return allocator.alloc(Span, 0);
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    errdefer spans.deinit(allocator);
    for (lexed.tokens) |token| {
        if (token.kind != .string_lit) continue;
        try spans.append(allocator, .{ .start = token.offset, .end = token.offset + token.lexeme.len });
    }
    return spans.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Analysis
// ---------------------------------------------------------------------------

fn parses(allocator: std.mem.Allocator, source: []const u8) bool {
    const result = compiler.parser.parse(allocator, source) catch return false;
    var tree = switch (result) {
        .ast => |tree| tree,
        .diagnostic => return false,
    };
    tree.deinit();
    return true;
}

fn analyzeSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
) !analysis.Document {
    return analysis.Document.initWithOptions(allocator, source, .{
        .path = options.path,
        .project = options.project_index,
        .phase = .full,
    });
}

// ---------------------------------------------------------------------------
// `:=` -> `<-`
// ---------------------------------------------------------------------------

const Rewrite = struct {
    text: []u8,
    count: usize,
};

/// Replaces the `:=` operator of every candidate binding with `<-`.
///
/// Candidate declarations are located by scanning the token stream from the
/// declaration offset the analyzer recorded.  `:=` and `<-` are both two bytes,
/// so surrounding offsets stay stable.
fn applyConversions(
    allocator: std.mem.Allocator,
    source: []const u8,
    candidates: []const analysis.MutableCandidate,
) !Rewrite {
    if (candidates.len == 0) {
        return .{ .text = try allocator.dupe(u8, source), .count = 0 };
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const lexed = compiler.lexer.lex(arena.allocator(), source) catch {
        return .{ .text = try allocator.dupe(u8, source), .count = 0 };
    };
    if (lexed.diagnostic != null) {
        return .{ .text = try allocator.dupe(u8, source), .count = 0 };
    }
    const tokens = lexed.tokens;

    var offsets: std.ArrayListUnmanaged(usize) = .empty;
    defer offsets.deinit(allocator);
    for (candidates) |candidate| {
        if (findBindMutableToken(tokens, candidate)) |offset| {
            if (std.mem.indexOfScalar(usize, offsets.items, offset) == null) {
                try offsets.append(allocator, offset);
            }
        }
    }
    if (offsets.items.len == 0) {
        return .{ .text = try allocator.dupe(u8, source), .count = 0 };
    }
    std.mem.sort(usize, offsets.items, {}, std.sort.asc(usize));

    const text = try allocator.dupe(u8, source);
    errdefer allocator.free(text);
    for (offsets.items) |offset| {
        if (offset + 2 > text.len) continue;
        if (!std.mem.eql(u8, text[offset .. offset + 2], ":=")) continue;
        text[offset] = '<';
        text[offset + 1] = '-';
    }
    return .{ .text = text, .count = offsets.items.len };
}

/// Finds the `bind_mutable` token for one candidate declaration.
fn findBindMutableToken(tokens: []const compiler.syntax.Token, candidate: analysis.MutableCandidate) ?usize {
    // Start at the first token at/after the declaration offset.
    var start: usize = 0;
    while (start < tokens.len and tokens[start].offset < candidate.offset) : (start += 1) {}
    if (start >= tokens.len) return null;

    // Attributes may precede the name, so search forward a bounded amount for
    // the declared identifier; then require `:=` before the line ends.
    var index = start;
    const limit = @min(tokens.len, start + 128);
    while (index < limit) : (index += 1) {
        const token = tokens[index];
        if (token.kind == .eof) return null;
        if (token.kind != .identifier) continue;
        if (!std.mem.eql(u8, token.lexeme, candidate.name)) continue;

        var next = index + 1;
        while (next < tokens.len) : (next += 1) {
            switch (tokens[next].kind) {
                .newline, .indent, .dedent, .semicolon, .eof => break,
                .bind_mutable => return tokens[next].offset,
                // Another declaration operator means this occurrence was not
                // the binding we were looking for (e.g. a function or an
                // immutable binding with the same name).
                .bind_immutable => break,
                else => {},
            }
        }
        return null;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "normalizes whitespace, tabs, and the final newline" {
    const source = "f <- () -> i32:\r\n\tx := 1   \r\n\tret x\r\n\r\n";
    var result = try format(testing.allocator, source, .{ .wrap_lines = false, .convert_mutable_bindings = false });
    defer result.deinit();

    try testing.expect(result.parse_ok);
    try testing.expect(std.mem.endsWith(u8, result.text, "\n"));
    try testing.expect(!std.mem.endsWith(u8, result.text, "\n\n"));
    try testing.expect(std.mem.indexOf(u8, result.text, "\r") == null);
    try testing.expect(std.mem.indexOf(u8, result.text, "\t") == null);
    try testing.expect(std.mem.indexOf(u8, result.text, "    x := 1\n") != null);
    try testing.expect(result.changed); // CRLF, trailing spaces, tabs, and the extra blank line changed
}

test "parse errors only get whitespace normalization" {
    const source = "f <- (\n";
    var result = try format(testing.allocator, source, .{});
    defer result.deinit();
    try testing.expect(!result.parse_ok);
    try testing.expectEqual(@as(usize, 0), result.conversions);
    try testing.expectEqualStrings("f <- (\n", result.text);
}

test "converts never-mutated mutable bindings" {
    const source =
        \\f <- () -> i32:
        \\    kept := 1
        \\    changed := 2
        \\    changed = 3
        \\    ret kept + changed
    ;
    var result = try format(testing.allocator, source, .{ .wrap_lines = false });
    defer result.deinit();

    try testing.expect(result.parse_ok);
    try testing.expectEqual(@as(usize, 1), result.conversions);
    try testing.expect(std.mem.indexOf(u8, result.text, "kept <- 1") != null);
    try testing.expect(std.mem.indexOf(u8, result.text, "changed := 2") != null);
}

test "keeps bindings mutated through mutable borrows" {
    const source =
        \\g <- (x: &mut i32) -> nil:
        \\    ret nil
        \\f <- () -> i32:
        \\    value := 1
        \\    g(&mut value)
        \\    ret value
    ;
    var result = try format(testing.allocator, source, .{ .wrap_lines = false });
    defer result.deinit();
    try testing.expectEqual(@as(usize, 0), result.conversions);
    try testing.expect(std.mem.indexOf(u8, result.text, "value := 1") != null);
}

test "keeps bindings mutated through field assignment" {
    const source =
        \\S <- struct
        \\    v: i32
        \\f <- () -> i32:
        \\    s := S { v: 0 }
        \\    s.v = 1
        \\    ret s.v
    ;
    var result = try format(testing.allocator, source, .{ .wrap_lines = false });
    defer result.deinit();
    try testing.expect(result.parse_ok);
    try testing.expectEqual(@as(usize, 0), result.conversions);
}

test "keeps bindings used with mutating method receivers" {
    const source =
        \\Builder <- struct
        \\    count: i32
        \\impl Builder:
        \\    pub bump <- (builder: &mut Builder) -> i32:
        \\        builder.count = builder.count + 1
        \\        ret builder.count
        \\f <- () -> i32:
        \\    builder := Builder { count: 0 }
        \\    ret builder.bump()
    ;
    var result = try format(testing.allocator, source, .{ .wrap_lines = false });
    defer result.deinit();
    try testing.expect(result.parse_ok);
    try testing.expectEqual(@as(usize, 0), result.conversions);
}
