//! Opaque integer handles for values that outlive a single FFI call.
//!
//! JITed code never sees host pointers.  It receives monotonically increasing
//! `u64` ids and every lookup validates the id against the owning table.

const std = @import("std");
const io_mod = @import("io.zig");

pub fn Table(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: io_mod.Mutex = .{},
        map: std.AutoHashMapUnmanaged(u64, *T) = .empty,
        next_id: u64 = 1,

        /// Insert a value and return its handle.  Zero is never a valid handle.
        pub fn create(self: *Self, value: T) !u64 {
            const allocator = std.heap.c_allocator;
            const item = try allocator.create(T);
            errdefer allocator.destroy(item);
            item.* = value;

            self.mutex.lock();
            defer self.mutex.unlock();

            const id = self.next_id;
            if (id == 0 or id == std.math.maxInt(u64)) return error.OutOfMemory;
            self.next_id += 1;
            try self.map.put(allocator, id, item);
            return id;
        }

        /// Adopt an existing heap allocation whose address is already published
        /// to callbacks.  The table owns the allocation from now on.
        pub fn adopt(self: *Self, pointer: *T) !u64 {
            self.mutex.lock();
            defer self.mutex.unlock();

            const id = self.next_id;
            if (id == 0 or id == std.math.maxInt(u64)) return error.OutOfMemory;
            self.next_id += 1;
            try self.map.put(std.heap.c_allocator, id, pointer);
            return id;
        }

        /// Borrow a pointer.  The pointer is valid until the handle is removed;
        /// callers must not close a handle concurrently with using it.
        pub fn get(self: *Self, id: u64) ?*T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.map.get(id);
        }

        /// Remove the mapping but keep ownership of the pointed-to value with
        /// the caller.  Used by types whose `deinit` destroys the allocation.
        pub fn detach(self: *Self, id: u64) ?*T {
            self.mutex.lock();
            defer self.mutex.unlock();
            const entry = self.map.fetchRemove(id) orelse return null;
            return entry.value;
        }

        /// Remove a handle and return the stored value by copy.
        pub fn remove(self: *Self, id: u64) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const entry = self.map.fetchRemove(id) orelse return null;
            const item = entry.value;
            const value = item.*;
            std.heap.c_allocator.destroy(item);
            return value;
        }

        pub fn count(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.map.count();
        }

        /// Remove and release every remaining handle using `cleanup`.
        pub fn clear(self: *Self, comptime cleanup: anytype) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            var it = self.map.valueIterator();
            while (it.next()) |item| {
                cleanup(item.*);
                std.heap.c_allocator.destroy(item.*);
            }
            self.map.deinit(std.heap.c_allocator);
            self.map = .empty;
        }
    };
}

test "handle table round-trip" {
    var table: Table(u32) = .{};
    const id = try table.create(42);
    try std.testing.expect(id != 0);
    try std.testing.expect(table.get(id) != null);
    try std.testing.expectEqual(@as(u32, 42), table.get(id).?.*);
    try std.testing.expectEqual(@as(?u32, 42), table.remove(id));
    try std.testing.expect(table.get(id) == null);
    try std.testing.expect(table.remove(id) == null);
}
