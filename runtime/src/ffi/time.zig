//! Monotonic clock and sleep helpers used by FFI timeouts.
//!
//! Zig 0.16 routes clocks through `std.Io`, which requires threading an Io
//! value through every call.  The C ABI is synchronous and has no Io argument,
//! so this module uses the platform monotonic clock directly.

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

const c = if (is_windows) @cImport({
    @cInclude("windows.h");
}) else @cImport({
    @cInclude("time.h");
    @cInclude("errno.h");
});

var win_frequency: i64 = 0;

/// Monotonic nanoseconds.  Values are comparable within one process.
pub fn nowNs() u64 {
    if (is_windows) {
        if (win_frequency == 0) {
            var freq: c.LARGE_INTEGER = undefined;
            _ = c.QueryPerformanceFrequency(&freq);
            win_frequency = if (freq.QuadPart > 0) freq.QuadPart else 1;
        }
        var counter: c.LARGE_INTEGER = undefined;
        _ = c.QueryPerformanceCounter(&counter);
        const ticks = counter.QuadPart;
        // Split before multiplying so long uptimes cannot overflow u64.
        const seconds = @divTrunc(ticks, win_frequency);
        const remainder = @mod(ticks, win_frequency);
        return @intCast(seconds * std.time.ns_per_s + @divTrunc(remainder * std.time.ns_per_s, win_frequency));
    } else {
        var ts: c.struct_timespec = undefined;
        if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
        return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s +
            @as(u64, @intCast(ts.tv_nsec));
    }
}

/// Wall-clock nanoseconds since the Unix epoch, used for certificates and logs.
pub fn unixNs() u64 {
    if (is_windows) {
        // FILETIME stores 100ns intervals since 1601-01-01.
        var ft: c.FILETIME = undefined;
        c.GetSystemTimeAsFileTime(&ft);
        const ticks = (@as(u64, @intCast(ft.dwHighDateTime)) << 32) |
            @as(u64, @intCast(ft.dwLowDateTime));
        const epoch_delta: u64 = 11644473600 * std.time.ns_per_s / 100;
        if (ticks < epoch_delta) return 0;
        return (ticks - epoch_delta) * 100;
    } else {
        var ts: c.struct_timespec = undefined;
        if (c.clock_gettime(c.CLOCK_REALTIME, &ts) != 0) return 0;
        return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s +
            @as(u64, @intCast(ts.tv_nsec));
    }
}

pub fn sleepNs(ns: u64) void {
    if (ns == 0) return;
    if (is_windows) {
        const ms = ns / std.time.ns_per_ms;
        const clamped = std.math.clamp(ms, 1, std.math.maxInt(c_uint) - 1);
        c.Sleep(@intCast(clamped));
        return;
    }
    var req: c.struct_timespec = .{
        .tv_sec = @intCast(ns / std.time.ns_per_s),
        .tv_nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: c.struct_timespec = undefined;
    while (c.nanosleep(&req, &rem) != 0) {
        req = rem;
    }
}

pub fn sleepMs(ms: u64) void {
    sleepNs(ms * std.time.ns_per_ms);
}

test "monotonic clock advances" {
    const a = nowNs();
    sleepNs(2 * std.time.ns_per_ms);
    const b = nowNs();
    try std.testing.expect(b >= a);
    try std.testing.expect(unixNs() > 1_600_000_000 * std.time.ns_per_s);
}
