//! Process-wide `std.Io` service for runtime FFI.
//!
//! Zig 0.16 moved clocks, files, sockets, and synchronization onto `std.Io`.
//! The runtime exposes a synchronous C ABI, so it owns one threadsafe Io
//! implementation and shares it between windows, files, and networking.

const std = @import("std");

var threaded: std.Io.Threaded = undefined;
var state = std.atomic.Value(u8).init(0);

/// Return the process-wide Io implementation, initializing it on first use.
///
/// Initialization is serialized with a small atomic state machine because FFI
/// entry points may be called from JITed code on more than one host thread.
pub fn io() std.Io {
    if (state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
        threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
        state.store(2, .release);
    } else {
        while (state.load(.acquire) != 2) std.atomic.spinLoopHint();
    }
    return threaded.io();
}

/// Zig 0.16 mutex that uses the shared runtime Io for parking.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(io());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(io());
    }
};

test "shared io initializes once" {
    const a = io();
    const b = io();
    try std.testing.expectEqual(a.userdata, b.userdata);
}
