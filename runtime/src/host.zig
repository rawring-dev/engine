//! Host-side frame control and capture for the e7 engine.
//!
//! This module contains no SDL/Vulkan code: it tracks the headless flag, the
//! deterministic frame limit, and the last captured RGBA frame.  e7 engine code
//! calls the exported functions through compiler intrinsics; `engine-run` sets
//! options and reads the capture.

const std = @import("std");
const abi = @import("ffi/abi.zig");
const io_mod = @import("ffi/io.zig");

const Symbol = abi.Symbol;

pub const Capture = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *Capture) void {
        std.heap.c_allocator.free(self.pixels);
        self.* = undefined;
    }
};

const State = struct {
    mutex: io_mod.Mutex = .{},
    headless: bool = false,
    max_frames: i64 = 0,
    capture_enabled: bool = false,
    frames: i64 = 0,
    quit: bool = false,
    capture: ?Capture = null,
};

var state: State = .{};

fn freeCaptureLocked() void {
    if (state.capture) |*capture| capture.deinit();
    state.capture = null;
}

pub fn reset() void {
    state.mutex.lock();
    defer state.mutex.unlock();
    freeCaptureLocked();
    state.headless = false;
    state.max_frames = 0;
    state.capture_enabled = false;
    state.frames = 0;
    state.quit = false;
}

pub fn setHeadless(enabled: bool) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    state.headless = enabled;
}

pub fn setMaxFrames(limit: i64) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    state.max_frames = limit;
}

pub fn setCaptureEnabled(enabled: bool) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    state.capture_enabled = enabled;
}

pub fn frames() i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    return state.frames;
}

pub fn takeCapture() ?Capture {
    state.mutex.lock();
    defer state.mutex.unlock();
    const snapshot = state.capture orelse return null;
    state.capture = null;
    return snapshot;
}

pub fn shouldClose() bool {
    state.mutex.lock();
    defer state.mutex.unlock();
    return state.quit or (state.max_frames > 0 and state.frames >= state.max_frames);
}

pub fn noteFrame() void {
    state.mutex.lock();
    defer state.mutex.unlock();
    state.frames += 1;
}

pub fn storeCapture(pixels_ptr: i64, width: i64, height: i64) i32 {
    if (pixels_ptr == 0 or width <= 0 or height <= 0) return @intFromEnum(abi.Status.invalid_argument);
    state.mutex.lock();
    defer state.mutex.unlock();
    if (!state.capture_enabled) return @intFromEnum(abi.Status.ok);
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const byte_count = std.math.mul(usize, w, h) catch return @intFromEnum(abi.Status.out_of_memory);
    const pixel_count = std.math.mul(usize, byte_count, 4) catch return @intFromEnum(abi.Status.out_of_memory);
    freeCaptureLocked();
    const bytes = std.heap.c_allocator.alloc(u8, pixel_count) catch return @intFromEnum(abi.Status.out_of_memory);
    @memcpy(bytes, @as([*]const u8, @ptrFromInt(@as(usize, @intCast(pixels_ptr))))[0..pixel_count]);
    state.capture = .{ .width = @intCast(w), .height = @intCast(h), .pixels = bytes };
    return @intFromEnum(abi.Status.ok);
}

pub export fn e7_host_headless() callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    return @intFromBool(state.headless);
}

pub export fn e7_host_should_close() callconv(.c) i64 {
    return @intFromBool(shouldClose());
}

pub export fn e7_host_note_frame() callconv(.c) void {
    noteFrame();
}

pub export fn e7_host_capture(pixels: i64, width: i64, height: i64) callconv(.c) i64 {
    return storeCapture(pixels, width, height);
}

pub fn writePpm(io: std.Io, path: []const u8, capture: Capture) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var header_buffer: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "P6\n{d} {d}\n255\n", .{ capture.width, capture.height });
    try file.writeStreamingAll(io, header);
    // Captures come from the e7 Vulkan swapchain in BGRA8 order; PPM wants RGB.
    var rgb: [3]u8 = undefined;
    var index: usize = 0;
    while (index + 3 < capture.pixels.len) : (index += 4) {
        rgb = .{ capture.pixels[index + 2], capture.pixels[index + 1], capture.pixels[index] };
        try file.writeStreamingAll(io, &rgb);
    }
}

pub fn captureHasContent(capture: Capture) bool {
    if (capture.pixels.len < 8) return false;
    const r = capture.pixels[0];
    const g = capture.pixels[1];
    const b = capture.pixels[2];
    var differing: usize = 0;
    var index: usize = 0;
    while (index + 3 < capture.pixels.len) : (index += 4) {
        if (capture.pixels[index] != r or capture.pixels[index + 1] != g or capture.pixels[index + 2] != b) {
            differing += 1;
            if (differing >= 64) return true;
        }
    }
    return false;
}

pub fn symbols() [4]Symbol {
    return .{
        .{ .name = "e7_host_headless", .address = @intFromPtr(&e7_host_headless) },
        .{ .name = "e7_host_should_close", .address = @intFromPtr(&e7_host_should_close) },
        .{ .name = "e7_host_note_frame", .address = @intFromPtr(&e7_host_note_frame) },
        .{ .name = "e7_host_capture", .address = @intFromPtr(&e7_host_capture) },
    };
}
