//! Indentation-aware output writer used by the Slang emitter.

const std = @import("std");

pub const Writer = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    indent_level: usize = 0,
    line_started: bool = false,
    blank_pending: bool = false,

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Writer) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn indent(self: *Writer) void {
        self.indent_level += 1;
    }

    pub fn dedent(self: *Writer) void {
        std.debug.assert(self.indent_level > 0);
        self.indent_level -= 1;
    }

    fn startLine(self: *Writer) !void {
        if (self.line_started) return;
        var count: usize = self.indent_level * 4;
        while (count > 0) : (count -= 1) try self.buffer.append(self.allocator, ' ');
        self.line_started = true;
    }

    /// Emit one complete line of source.
    pub fn line(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try self.startLine();
        try self.buffer.print(self.allocator, fmt, args);
        try self.buffer.append(self.allocator, '\n');
        self.line_started = false;
    }

    /// Emit a line with no indentation (used for module headers and
    /// preprocessor-like lines).
    pub fn flushLine(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try self.buffer.print(self.allocator, fmt, args);
        try self.buffer.append(self.allocator, '\n');
        self.line_started = false;
    }

    /// Continue the current line without a newline.
    pub fn raw(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try self.startLine();
        try self.buffer.print(self.allocator, fmt, args);
    }

    pub fn rawNoIndent(self: *Writer, text: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, text);
        self.line_started = false;
    }

    /// Remove one trailing blank line, if present.  Used before closing a
    /// namespace so the brace hugs the last member.
    pub fn trimBlank(self: *Writer) void {
        const len = self.buffer.items.len;
        if (len >= 2 and self.buffer.items[len - 1] == '\n' and self.buffer.items[len - 2] == '\n') {
            _ = self.buffer.pop();
        }
    }

    pub fn blank(self: *Writer) !void {
        if (self.buffer.items.len == 0) return;
        if (self.buffer.items[self.buffer.items.len - 1] != '\n') return;
        const len = self.buffer.items.len;
        if (len >= 2 and self.buffer.items[len - 2] == '\n') return;
        try self.buffer.append(self.allocator, '\n');
    }

    /// Collapse trailing blank lines so a generated file ends with exactly one
    /// newline.  Callers use this before `take`.
    pub fn finish(self: *Writer) void {
        while (self.buffer.items.len >= 2 and
            self.buffer.items[self.buffer.items.len - 1] == '\n' and
            self.buffer.items[self.buffer.items.len - 2] == '\n')
        {
            _ = self.buffer.pop();
        }
    }

    pub fn take(self: *Writer) ![]u8 {
        return self.buffer.toOwnedSlice(self.allocator);
    }

    pub fn slice(self: *const Writer) []const u8 {
        return self.buffer.items;
    }
};

test "writer indents and avoids duplicate blank lines" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();

    try w.line("struct Foo {{", .{});
    w.indent();
    try w.line("float x;", .{});
    w.dedent();
    try w.line("}};", .{});
    try w.blank();
    try w.blank();
    try w.line("// end", .{});

    try std.testing.expectEqualStrings(
        \\struct Foo {
        \\    float x;
        \\};
        \\
        \\// end
        \\
    , w.slice());
}
