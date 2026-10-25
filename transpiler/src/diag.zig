//! Diagnostic collection for the e7s -> Slang transpiler.

const std = @import("std");
const ast = @import("compiler").ast;

pub const Diagnostic = struct {
    offset: usize = 0,
    line: usize = 1,
    column: usize = 1,
    message: []const u8,
};

pub const List = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,
    failed: bool = false,

    pub fn init(allocator: std.mem.Allocator) List {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *List) void {
        for (self.items.items) |diagnostic| self.allocator.free(diagnostic.message);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *List, span: ast.Span, comptime fmt: []const u8, args: anytype) !void {
        self.failed = true;
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(message);
        try self.items.append(self.allocator, .{
            .offset = span.offset,
            .line = span.line,
            .column = span.column,
            .message = message,
        });
    }

    pub fn toOwnedSlice(self: *List) ![]Diagnostic {
        return self.items.toOwnedSlice(self.allocator);
    }

    pub fn freeSlice(allocator: std.mem.Allocator, diagnostics: []Diagnostic) void {
        for (diagnostics) |diagnostic| allocator.free(diagnostic.message);
        allocator.free(diagnostics);
    }
};
