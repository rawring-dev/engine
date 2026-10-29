//! Atomic publication of function/task redirects. Code owners retain generations
//! until session shutdown, so readers may safely keep addresses after unlocking.
const std = @import("std");
const Mutex = @import("ffi/io.zig").Mutex;
pub const Table = std.AutoHashMapUnmanaged(usize, usize);
var mutex: Mutex = .{};
var targets: Table = .empty;
var active = std.atomic.Value(bool).init(false);
var table_allocator: std.mem.Allocator = std.heap.c_allocator;

pub fn resolve(entry: usize) usize {
    if (!active.load(.acquire)) return entry;
    mutex.lock();
    defer mutex.unlock();
    return targets.get(entry) orelse entry;
}

/// Higher-order values are native addresses, so they remain meaningful when a
/// later compiler generation assigns different bytecode function indices.
pub export fn e7_code_resolve(entry: i64) callconv(.c) i64 {
    if (entry <= 0) return 0;
    return @intCast(resolve(@intCast(entry)));
}

/// Takes ownership of an already-complete table. No fallible work at commit.
pub fn publish(allocator: std.mem.Allocator, next: *Table) void {
    mutex.lock();
    defer mutex.unlock();
    targets.deinit(table_allocator);
    targets = next.*;
    table_allocator = allocator;
    next.* = .empty;
    active.store(targets.count() != 0, .release);
}

pub fn reset() void {
    var empty: Table = .empty;
    publish(std.heap.c_allocator, &empty);
}

test "redirect publication replaces rather than chains generations" {
    defer reset();
    var table: Table = .empty;
    try table.put(std.testing.allocator, 100, 200);
    publish(std.testing.allocator, &table);
    try std.testing.expectEqual(@as(usize, 200), resolve(100));
    try std.testing.expectEqual(@as(usize, 300), resolve(300));
    try table.put(std.testing.allocator, 100, 300);
    try table.put(std.testing.allocator, 200, 300);
    publish(std.testing.allocator, &table);
    try std.testing.expectEqual(@as(usize, 300), resolve(100));
    try std.testing.expectEqual(@as(usize, 300), resolve(200));
}
