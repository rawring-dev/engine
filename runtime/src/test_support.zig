//! Native assertion helpers for e7-authored tests.
//!
//! The `zig build test-e7` runner (`runtime/src/e7_test.zig`) compiles `.e7`
//! test sources through the normal compiler/JIT pipeline and registers the
//! symbols below with the JIT, so e7 test functions can call:
//!
//!     assert_eq_i64(actual, expected)
//!     assert_eq_bool(actual, expected)
//!     assert_i64_near(actual, expected, tolerance)
//!     assert_f32_near(actual, expected, tolerance)
//!     assert_str_eq(actual, expected)
//!     assert_fail()
//!
//! Helpers are named `e7_test_*` in the e7 intrinsic table (see
//! compiler/src/intrinsics.zig).  A failing helper records a human-readable
//! message in `State` and returns 1; the runner fails the test if any message
//! was recorded, even when the e7 function keeps executing.  The runner prints
//! the recorded messages after the test returns, prefixed with the test's file
//! and function name.

const std = @import("std");
const abi = @import("ffi/abi.zig");
const aggregate = @import("aggregate.zig");

pub const Symbol = abi.Symbol;

const State = struct {
    allocator: std.mem.Allocator = std.heap.c_allocator,
    /// Number of assertion helper invocations since the current test started.
    assertions: usize = 0,
    /// Human-readable failure messages for the current test.
    failures: std.ArrayList([]const u8) = .empty,

    fn reset(self: *State) void {
        self.assertions = 0;
        self.freeFailures();
    }

    fn freeFailures(self: *State) void {
        for (self.failures.items) |message| self.allocator.free(message);
        self.failures.clearRetainingCapacity();
    }

    fn record(self: *State, comptime format: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(self.allocator, format, args) catch return;
        self.failures.append(self.allocator, message) catch {
            self.allocator.free(message);
        };
    }
};

/// One process-wide state: e7 tests run on the calling thread, async tasks run
/// inline (the runner calls `e7_task_set_inline(1)`), so no locking is needed.
var state: State = .{};

/// Reset the assertion counters before running one test function.
pub fn reset() void {
    state.reset();
}

/// Assertions executed by the test that most recently ran.
pub fn assertionCount() usize {
    return state.assertions;
}

/// Recorded failure messages for the test that most recently ran.
pub fn failures() []const []const u8 {
    return state.failures.items;
}

fn bitsToFloat(bits: i64) f64 {
    return @bitCast(bits);
}

fn strBytes(handle: i64) []const u8 {
    const len = aggregate.e7_str_len(handle);
    if (len <= 0) return &.{};
    const data = aggregate.e7_str_data(handle);
    if (data == 0) return &.{};
    return @as([*]const u8, @ptrFromInt(@as(usize, @intCast(data))))[0..@intCast(len)];
}

fn escaped(allocator: std.mem.Allocator, bytes: []const u8) []const u8 {
    var out = std.ArrayList(u8).empty;
    for (bytes) |byte| {
        switch (byte) {
            '\n' => out.appendSlice(allocator, "\\n") catch return "<out of memory>",
            '\r' => out.appendSlice(allocator, "\\r") catch return "<out of memory>",
            '\t' => out.appendSlice(allocator, "\\t") catch return "<out of memory>",
            '"' => out.appendSlice(allocator, "\\\"") catch return "<out of memory>",
            '\\' => out.appendSlice(allocator, "\\\\") catch return "<out of memory>",
            else => out.append(allocator, byte) catch return "<out of memory>",
        }
    }
    return out.toOwnedSlice(allocator) catch "<out of memory>";
}

// ------------------------------------------------------------- assertions ---

pub export fn e7_test_assert_eq_i64(actual: i64, expected: i64) callconv(.c) i64 {
    state.assertions += 1;
    if (actual == expected) return 0;
    state.record("assert_eq_i64 failed: expected {d}, found {d}", .{ expected, actual });
    return 1;
}

pub export fn e7_test_assert_eq_bool(actual: i64, expected: i64) callconv(.c) i64 {
    state.assertions += 1;
    if ((actual != 0) == (expected != 0)) return 0;
    state.record("assert_eq_bool failed: expected {s}, found {s}", .{
        if (expected != 0) "true" else "false",
        if (actual != 0) "true" else "false",
    });
    return 1;
}

pub export fn e7_test_assert_i64_near(actual: i64, expected: i64, tolerance: i64) callconv(.c) i64 {
    state.assertions += 1;
    const delta = if (actual > expected) actual - expected else expected - actual;
    if (delta <= tolerance) return 0;
    state.record("assert_i64_near failed: expected {d} +/- {d}, found {d} (delta {d})", .{
        expected, tolerance, actual, delta,
    });
    return 1;
}

pub export fn e7_test_assert_f32_near(actual_bits: i64, expected_bits: i64, tolerance_bits: i64) callconv(.c) i64 {
    state.assertions += 1;
    const actual = bitsToFloat(actual_bits);
    const expected = bitsToFloat(expected_bits);
    const tolerance = bitsToFloat(tolerance_bits);
    if (!(tolerance >= 0)) {
        state.record("assert_f32_near failed: negative tolerance {d}", .{tolerance});
        return 1;
    }
    const delta = @abs(actual - expected);
    if (delta <= tolerance) return 0;
    state.record("assert_f32_near failed: expected {d} +/- {d}, found {d} (delta {d})", .{
        expected, tolerance, actual, delta,
    });
    return 1;
}

pub export fn e7_test_assert_str_eq(actual: i64, expected: i64) callconv(.c) i64 {
    state.assertions += 1;
    const actual_bytes = strBytes(actual);
    const expected_bytes = strBytes(expected);
    if (std.mem.eql(u8, actual_bytes, expected_bytes)) return 0;
    const actual_escaped = escaped(state.allocator, actual_bytes);
    defer if (!std.mem.eql(u8, actual_escaped, "<out of memory>")) state.allocator.free(actual_escaped);
    const expected_escaped = escaped(state.allocator, expected_bytes);
    defer if (!std.mem.eql(u8, expected_escaped, "<out of memory>")) state.allocator.free(expected_escaped);
    state.record("assert_str_eq failed: expected \"{s}\", found \"{s}\"", .{
        expected_escaped, actual_escaped,
    });
    return 1;
}

pub export fn e7_test_assert_fail() callconv(.c) i64 {
    state.assertions += 1;
    state.record("assert_fail: explicit test failure", .{});
    return 1;
}

pub fn symbols() [6]Symbol {
    return .{
        .{ .name = "e7_test_assert_eq_i64", .address = @intFromPtr(&e7_test_assert_eq_i64) },
        .{ .name = "e7_test_assert_eq_bool", .address = @intFromPtr(&e7_test_assert_eq_bool) },
        .{ .name = "e7_test_assert_i64_near", .address = @intFromPtr(&e7_test_assert_i64_near) },
        .{ .name = "e7_test_assert_f32_near", .address = @intFromPtr(&e7_test_assert_f32_near) },
        .{ .name = "e7_test_assert_str_eq", .address = @intFromPtr(&e7_test_assert_str_eq) },
        .{ .name = "e7_test_assert_fail", .address = @intFromPtr(&e7_test_assert_fail) },
    };
}

test "assertion helpers record failures and count success" {
    reset();
    defer reset();
    try std.testing.expectEqual(@as(i64, 0), e7_test_assert_eq_i64(7, 7));
    try std.testing.expectEqual(@as(i64, 1), e7_test_assert_eq_i64(7, 8));
    try std.testing.expectEqual(@as(i64, 0), e7_test_assert_eq_bool(1, 1));
    try std.testing.expectEqual(@as(i64, 1), e7_test_assert_eq_bool(0, 1));
    try std.testing.expectEqual(@as(i64, 0), e7_test_assert_i64_near(1000, 1004, 5));
    try std.testing.expectEqual(@as(i64, 1), e7_test_assert_i64_near(1000, 1010, 5));
    const half = @as(i64, @bitCast(@as(f64, 0.5)));
    const just_over = @as(i64, @bitCast(@as(f64, 0.5000001)));
    const tol = @as(i64, @bitCast(@as(f64, 0.001)));
    try std.testing.expectEqual(@as(i64, 0), e7_test_assert_f32_near(just_over, half, tol));
    try std.testing.expectEqual(@as(i64, 1), e7_test_assert_f32_near(half, just_over, 0));
    try std.testing.expectEqual(@as(i64, 1), e7_test_assert_fail());
    try std.testing.expectEqual(@as(usize, 9), assertionCount());
    try std.testing.expectEqual(@as(usize, 5), failures().len);
    try std.testing.expect(std.mem.indexOf(u8, failures()[0], "expected 8, found 7") != null);
}
