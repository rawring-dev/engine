//! SDL/Vulkan-free engine host helpers still required by e7.
//!
//! SDL windows and the Vulkan scene renderer are owned by e7 platform code,
//! which binds those libraries dynamically through the generic C FFI.  The
//! runtime keeps only the two helpers that must run natively: a monotonic
//! clock and raw shader/asset file loading.  Both are compiler-known
//! intrinsics (see `compiler/src/intrinsics.zig`) and are registered with the
//! JIT by `orc.Jit.addBytecode`.

const std = @import("std");
const abi = @import("ffi/abi.zig");
const aggregate = @import("aggregate.zig");
const time_mod = @import("ffi/time.zig");
const io_mod = @import("ffi/io.zig");

const Symbol = abi.Symbol;

// Shader/asset loading is driven by e7 through `e7_engine_read_shader`; the
// runtime only provides the raw file read and wraps the bytes in an e7 string.
var asset_threaded: ?std.Io.Threaded = null;
var asset_mutex: io_mod.Mutex = .{};

fn readAsset(path: []const u8) ![]u8 {
    asset_mutex.lock();
    defer asset_mutex.unlock();
    if (asset_threaded == null) {
        asset_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    }
    return std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        asset_threaded.?.io(),
        path,
        std.heap.c_allocator,
        .limited(64 * 1024 * 1024),
    );
}

fn stringSlice(value: i64) []const u8 {
    const length = aggregate.e7_str_len(value);
    if (length <= 0) return &.{};
    const data: [*]const u8 = @ptrFromInt(@as(usize, @intCast(value + 8)));
    return data[0..@intCast(length)];
}

pub export fn e7_engine_time_now_ms() callconv(.c) i64 {
    return @intCast(time_mod.nowNs() / std.time.ns_per_ms);
}

/// Load a shader/asset file and return it as an e7 `str` aggregate.  The e7
/// engine owns the decision of which files to load and passes the resulting
/// SPIR-V strings to its e7-side scene module.
pub export fn e7_engine_read_shader(path: i64) callconv(.c) i64 {
    const text = stringSlice(path);
    const data = readAsset(text) catch return 0;
    defer std.heap.c_allocator.free(data);
    return aggregate.e7_str_new(@intCast(@intFromPtr(data.ptr)), @intCast(data.len));
}

pub fn symbols() [2]Symbol {
    return .{
        .{ .name = "e7_engine_time_now_ms", .address = @intFromPtr(&e7_engine_time_now_ms) },
        .{ .name = "e7_engine_read_shader", .address = @intFromPtr(&e7_engine_read_shader) },
    };
}
