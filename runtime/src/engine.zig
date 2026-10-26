//! E7-visible engine intrinsics: hidden/visible SDL window, embedded-shader
//! Vulkan scene, monotonic time, and a deterministic frame limiter.
//!
//! These symbols are compiler-known (see `compiler/src/intrinsics.zig`) and are
//! registered with the JIT by `orc.Jit.addBytecode`.  The engine helpers keep
//! the C ABI small: window/scene handles are u64, everything else is an i64.
//! Renderer-facing f32 values cross the boundary integer-scaled, and e7 converts
//! with the `e7_f32_*` helpers:
//!
//!   * positions/eye/light: milli-units (world units x1000)
//!   * camera yaw/pitch:    milli-degrees (degrees x1000)
//!   * scene delta:         milliseconds
//!   * cube angle:          milli-radians (radians x1000)
//!
//! This module is deliberately *low level*: it owns SDL window/scene handles,
//! event pumping, raw key/mouse state, the monotonic clock, the frame limiter,
//! and capture.  All camera/input policy (sensitivity, pitch clamps, movement
//! basis, frame delta) lives in `engine/main.e7`, which reads the raw state via
//! `e7_engine_key_down`, `e7_engine_mouse_dx`, and `e7_engine_mouse_dy` and
//! pushes its camera back through `e7_engine_scene_set_camera` with milli-unit
//! integers.
//!
//! `--headless` hides the SDL window; rendering still goes through the
//! offscreen capture target, so a frame can be captured and checked without a
//! display.  The frame limiter is host-configured (`setMaxFrames`) and polled
//! once per frame from e7 via `e7_engine_should_close()`, which captures the
//! current scene before signalling shutdown when the limit is reached.

const std = @import("std");
const abi = @import("ffi/abi.zig");
const window_mod = @import("ffi/window.zig");
const renderer = @import("ffi/renderer.zig");
const time_mod = @import("ffi/time.zig");
const io_mod = @import("ffi/io.zig");
const aggregate = @import("aggregate.zig");
const sdl = @import("ffi/sdl.zig");
const c = sdl.c;

/// Clamp one SDL mouse-motion event.  Relative mode should produce small
/// deltas, but focus/window-manager transitions can report a single huge jump.
/// Per-frame look policy (sensitivity, total clamp) lives in e7.
const look_delta_limit: f32 = 250.0;

/// Logical action codes shared by SDL key mapping, `e7_engine_key_down`, and
/// the headless input tests.
pub const Key = enum(i64) {
    forward = 0, // W
    back = 1, // S
    left = 2, // A
    right = 3, // D
    up = 4, // E
    down = 5, // Q
    sprint = 6, // Shift
    look_left = 7, // Left arrow
    look_right = 8, // Right arrow
    look_up = 9, // Up arrow
    look_down = 10, // Down arrow
    jump = 11, // Space
};

const key_count = 12;

/// Raw device state only: which logical keys are held and how far the mouse
/// moved since the previous query.  e7 turns this into camera motion.
const InputState = struct {
    keys: [key_count]bool = [_]bool{false} ** key_count,
    mouse_dx: f32 = 0.0,
    mouse_dy: f32 = 0.0,
};

pub const Symbol = abi.Symbol;

pub const Error = error{ InvalidHandle, WindowCreateFailed, SceneCreateFailed, OutOfMemory };

pub const Capture = struct {
    /// RGBA8 pixels, owned by the caller.
    pixels: []u8,
    width: u32,
    height: u32,

    pub fn deinit(self: *Capture) void {
        std.heap.c_allocator.free(self.pixels);
        self.* = undefined;
    }
};

const State = struct {
    mutex: io_mod.Mutex = .{},
    headless: bool = true,
    capture_enabled: bool = false,
    /// 0 means "run until the window closes".
    max_frames: i64 = 0,
    frames: i64 = 0,
    quit_requested: bool = false,
    capture: ?Capture = null,
    last_window: u64 = 0,
    last_scene: u64 = 0,
    /// First host-visible failure (window/scene creation) for diagnostics.
    last_failure: ?[]const u8 = null,
    input: InputState = .{},
    scene_draws: i64 = 0,
    scene_boxes: i64 = 0,
};

var state: State = .{};

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

fn clearCaptureLocked() void {
    if (state.capture) |*capture| capture.deinit();
    state.capture = null;
}

fn check(status: i32) i64 {
    return if (status == 0) 0 else -1;
}

fn milli(value: i64) f32 {
    return @as(f32, @floatFromInt(value)) / 1000.0;
}

fn milliDegreesToRadians(value: i64) f32 {
    return std.math.degreesToRadians(milli(value));
}

fn setKeyLocked(key: Key, pressed: bool) void {
    state.input.keys[@intCast(@intFromEnum(key))] = pressed;
}

fn mapSdlKey(keycode: u32) ?Key {
    return switch (keycode) {
        c.SDLK_W => .forward,
        c.SDLK_S => .back,
        c.SDLK_A => .left,
        c.SDLK_D => .right,
        c.SDLK_E => .up,
        c.SDLK_Q => .down,
        c.SDLK_LSHIFT, c.SDLK_RSHIFT => .sprint,
        c.SDLK_LEFT => .look_left,
        c.SDLK_RIGHT => .look_right,
        c.SDLK_UP => .look_up,
        c.SDLK_DOWN => .look_down,
        c.SDLK_SPACE => .jump,
        else => null,
    };
}

/// Drain SDL events into the engine input state.  Requires `state.mutex`.
fn pumpEventsLocked(window_handle: i64) void {
    const window = window_mod.registry.get(@intCast(window_handle)) orelse {
        state.quit_requested = true;
        return;
    };
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        const kind: u32 = @intCast(event.type);
        switch (kind) {
            c.SDL_EVENT_QUIT => window.should_close = true,
            c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                if (event.window.windowID == window.id) window.should_close = true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                if (event.motion.windowID != window.id) continue;
                // Only accumulate relative look while the window owns the
                // pointer/focus.  Focus changes can otherwise inject a large
                // synthetic delta that looks like the cube teleporting around
                // the camera.
                if ((c.SDL_GetWindowFlags(window.handle) & c.SDL_WINDOW_INPUT_FOCUS) == 0) continue;
                state.input.mouse_dx += @max(-look_delta_limit, @min(event.motion.xrel, look_delta_limit));
                state.input.mouse_dy += @max(-look_delta_limit, @min(event.motion.yrel, look_delta_limit));
            },
            c.SDL_EVENT_WINDOW_FOCUS_LOST => {
                state.input.mouse_dx = 0.0;
                state.input.mouse_dy = 0.0;
            },
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                if (event.key.windowID != window.id) continue;
                const pressed = event.key.down;
                if (event.key.key == c.SDLK_ESCAPE) {
                    if (pressed) state.quit_requested = true;
                    continue;
                }
                if (mapSdlKey(event.key.key)) |key| setKeyLocked(key, pressed);
            },
            else => {},
        }
    }
}

/// Headless tests: synthesize key/mouse input without an SDL device.
pub fn injectKeyForTest(code: i64, pressed: bool) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    if (code < 0 or code > @intFromEnum(Key.jump)) return;
    setKeyLocked(@enumFromInt(code), pressed);
}

pub fn injectMouseDeltaForTest(dx: i64, dy: i64) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    state.input.mouse_dx += @floatFromInt(dx);
    state.input.mouse_dy += @floatFromInt(dy);
}

/// Extract the bytes of an e7 `str` value (aggregate: [len, bytes...]).
fn stringSlice(value: i64) []const u8 {
    const length = aggregate.e7_str_len(value);
    if (length <= 0) return &.{};
    const data: [*]const u8 = @ptrFromInt(@as(usize, @intCast(value + 8)));
    return data[0..@intCast(length)];
}

// ---------------------------------------------------------------- host API ---

/// Reset frame counters, quit state, and captured pixels.  Configure the
/// limiter after this.
pub fn reset() void {
    state.mutex.lock();
    defer state.mutex.unlock();
    clearCaptureLocked();
    state.frames = 0;
    state.quit_requested = false;
    state.last_window = 0;
    state.last_scene = 0;
    state.max_frames = 0;
    state.capture_enabled = false;
    state.headless = true;
    state.last_failure = null;
    state.input = .{};
    state.scene_draws = 0;
    state.scene_boxes = 0;
}

/// Human-readable first failure observed by the engine intrinsics, if any.
pub fn lastFailure() ?[]const u8 {
    state.mutex.lock();
    defer state.mutex.unlock();
    return state.last_failure;
}

pub fn setHeadless(headless: bool) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    state.headless = headless;
}

pub fn setMaxFrames(max_frames: i64) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    state.max_frames = max_frames;
}

pub fn setCaptureEnabled(enabled: bool) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    state.capture_enabled = enabled;
}

pub const RenderStats = struct {
    /// Frames opened with `e7_engine_scene_begin_frame`.
    scene_draws: i64,
    /// Box draws recorded across all frames (`draw_box` plus `draw_mesh`).
    scene_boxes: i64,
};

pub fn renderStats() RenderStats {
    state.mutex.lock();
    defer state.mutex.unlock();
    return .{ .scene_draws = state.scene_draws, .scene_boxes = state.scene_boxes };
}

pub fn frames() i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    return state.frames;
}

/// Take ownership of the captured frame, if the frame limiter captured one.
pub fn takeCapture() ?Capture {
    state.mutex.lock();
    defer state.mutex.unlock();
    const capture = state.capture orelse return null;
    state.capture = null;
    return capture;
}

pub fn requestQuit() void {
    state.mutex.lock();
    defer state.mutex.unlock();
    state.quit_requested = true;
}

/// Release any engine-owned SDL/Vulkan state at process exit.
pub fn shutdown() void {
    var scene_handle: u64 = 0;
    var window_handle: u64 = 0;
    {
        state.mutex.lock();
        defer state.mutex.unlock();
        clearCaptureLocked();
        scene_handle = state.last_scene;
        window_handle = state.last_window;
        state.last_scene = 0;
        state.last_window = 0;
        state.quit_requested = false;
    }
    // Call the exported teardown paths without holding the state mutex: they
    // take it themselves.
    if (scene_handle != 0) _ = e7_engine_scene_destroy(@intCast(scene_handle));
    if (window_handle != 0) _ = e7_engine_window_destroy(@intCast(window_handle));
    window_mod.shutdownVideo();
}

fn captureLocked() void {
    if (!state.capture_enabled or state.capture != null or state.last_scene == 0) return;
    const scene = renderer.registry.get(state.last_scene) orelse return;
    // Replay every object recorded by the last frame so multi-object scenes are
    // captured in full; `captureRecordedFrame` falls back to the legacy cube.
    const pixels = scene.captureRecordedFrame() catch return;
    state.capture = .{ .pixels = pixels, .width = scene.size().width, .height = scene.size().height };
}

/// Write a captured RGBA frame as a binary PPM (P6) image.
pub fn writePpm(io: std.Io, path: []const u8, capture: Capture) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var header_buffer: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "P6\n{d} {d}\n255\n", .{ capture.width, capture.height });
    try file.writeStreamingAll(io, header);
    var rgb: [3]u8 = undefined;
    var index: usize = 0;
    while (index + 3 < capture.pixels.len) : (index += 4) {
        rgb = .{ capture.pixels[index], capture.pixels[index + 1], capture.pixels[index + 2] };
        try file.writeStreamingAll(io, &rgb);
    }
}

/// True when any pixel has non-zero RGB data (used by tests and the host).
pub fn captureIsNonBlack(capture: Capture) bool {
    var index: usize = 0;
    while (index + 3 < capture.pixels.len) : (index += 4) {
        if (capture.pixels[index] != 0 or capture.pixels[index + 1] != 0 or capture.pixels[index + 2] != 0) return true;
    }
    return false;
}

/// True when at least one pixel differs from the frame's clear/background
/// colour (first pixel).  This distinguishes "the scene rendered geometry"
/// from "only the clear colour was written".
pub fn captureHasContent(capture: Capture) bool {
    if (capture.pixels.len < 8) return false;
    const background_r = capture.pixels[0];
    const background_g = capture.pixels[1];
    const background_b = capture.pixels[2];
    var differing: usize = 0;
    var index: usize = 0;
    while (index + 3 < capture.pixels.len) : (index += 4) {
        if (capture.pixels[index] != background_r or
            capture.pixels[index + 1] != background_g or
            capture.pixels[index + 2] != background_b)
        {
            differing += 1;
            if (differing >= 64) return true;
        }
    }
    return false;
}

// ------------------------------------------------------- JIT-visible ABI -----

pub export fn e7_engine_window_create(title: i64, width: i64, height: i64) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const text = stringSlice(title);
    const window = window_mod.Window.create(text, @intCast(width), @intCast(height), .{
        .vulkan = true,
        .resizable = true,
        .hidden = state.headless,
    }, null) catch {
        state.last_failure = "SDL window creation failed (no display?)";
        return 0;
    };
    const handle = window_mod.registry.create(window) catch {
        var owned = window;
        owned.destroy();
        return 0;
    };
    state.last_window = handle;
    if (!state.headless) {
        var created = window;
        created.show();
        _ = c.SDL_SetWindowRelativeMouseMode(created.handle, true);
    }
    return @intCast(handle);
}

/// Drain pending SDL events for the window; returns 1 when it should close
/// (window close request, or a host `requestQuit`).
pub export fn e7_engine_window_pump(handle: i64) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    pumpEventsLocked(handle);
    if (state.quit_requested) return 1;
    const window = window_mod.registry.get(@intCast(handle)) orelse return 1;
    return if (window.should_close) 1 else 0;
}

/// Logical key state (see `Key` codes: 0 W, 1 S, 2 A, 3 D, 4 E, 5 Q, 6 Shift,
/// 7-10 arrow look, 11 Space).  Returns 1 when held.
pub export fn e7_engine_key_down(code: i64) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    if (code < 0 or code > @intFromEnum(Key.jump)) return 0;
    return @intFromBool(state.input.keys[@intCast(code)]);
}

/// Accumulated horizontal mouse motion in pixels since the previous read;
/// reading clears the horizontal accumulator.
pub export fn e7_engine_mouse_dx() callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const dx: i64 = @intFromFloat(state.input.mouse_dx);
    state.input.mouse_dx = 0.0;
    return dx;
}

/// Accumulated vertical mouse motion in pixels since the previous read;
/// reading clears the vertical accumulator.
pub export fn e7_engine_mouse_dy() callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const dy: i64 = @intFromFloat(state.input.mouse_dy);
    state.input.mouse_dy = 0.0;
    return dy;
}

pub export fn e7_engine_window_should_close(handle: i64) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    if (state.quit_requested) return 1;
    const window = window_mod.registry.get(@intCast(handle)) orelse return 1;
    return if (window.should_close) 1 else 0;
}

pub export fn e7_engine_window_destroy(handle: i64) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const value = window_mod.registry.remove(@intCast(handle)) orelse return -1;
    var window = value;
    window.destroy();
    if (state.last_window == @as(u64, @intCast(handle))) state.last_window = 0;
    return 0;
}

pub export fn e7_engine_time_now_ms() callconv(.c) i64 {
    return @intCast(time_mod.nowNs() / std.time.ns_per_ms);
}

/// Load a shader/asset file and return it as an e7 `str` aggregate.  The e7
/// engine owns the decision of which files to load and passes the resulting
/// SPIR-V strings to `e7_engine_scene_create`.
pub export fn e7_engine_read_shader(path: i64) callconv(.c) i64 {
    const text = stringSlice(path);
    const data = readAsset(text) catch return 0;
    defer std.heap.c_allocator.free(data);
    return aggregate.e7_str_new(@intCast(@intFromPtr(data.ptr)), @intCast(data.len));
}

pub export fn e7_engine_scene_create(
    window_handle: i64,
    vert_spv: i64,
    frag_spv: i64,
) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const window = window_mod.registry.get(@intCast(window_handle)) orelse {
        state.last_failure = "scene create: invalid window handle";
        return 0;
    };
    const vert_len = aggregate.e7_str_len(vert_spv);
    const frag_len = aggregate.e7_str_len(frag_spv);
    if (vert_len <= 0 or frag_len <= 0) return 0;
    const vert_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(vert_spv + 8)));
    const frag_ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(frag_spv + 8)));
    var scene = renderer.Scene.init(
        std.heap.c_allocator,
        window,
        vert_ptr[0..@intCast(vert_len)],
        frag_ptr[0..@intCast(frag_len)],
    ) catch {
        state.last_failure = "Vulkan scene creation failed (no Vulkan device?)";
        return 0;
    };
    const handle = renderer.registry.create(scene) catch {
        scene.deinit();
        return 0;
    };
    state.last_scene = handle;
    return @intCast(handle);
}

pub export fn e7_engine_scene_destroy(handle: i64) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const value = renderer.registry.remove(@intCast(handle)) orelse return -1;
    var scene = value;
    scene.deinit();
    if (state.last_scene == @as(u64, @intCast(handle))) state.last_scene = 0;
    return 0;
}

pub export fn e7_engine_scene_resize(handle: i64, width: i64, height: i64) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const scene = renderer.registry.get(@intCast(handle)) orelse return -1;
    scene.resize(@intCast(width), @intCast(height)) catch return -1;
    return 0;
}

pub export fn e7_engine_scene_set_camera(
    handle: i64,
    eye_x_milli: i64,
    eye_y_milli: i64,
    eye_z_milli: i64,
    yaw_milli_degrees: i64,
    pitch_milli_degrees: i64,
) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const scene = renderer.registry.get(@intCast(handle)) orelse return -1;
    scene.setCamera(
        .{ milli(eye_x_milli), milli(eye_y_milli), milli(eye_z_milli) },
        milliDegreesToRadians(yaw_milli_degrees),
        milliDegreesToRadians(pitch_milli_degrees),
    );
    return 0;
}

pub export fn e7_engine_scene_set_cube_angle(handle: i64, angle_milli_radians: i64) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const scene = renderer.registry.get(@intCast(handle)) orelse return -1;
    scene.spin = milli(angle_milli_radians);
    return 0;
}

pub export fn e7_engine_scene_set_light(
    handle: i64,
    x_milli: i64,
    y_milli: i64,
    z_milli: i64,
    r_milli: i64,
    g_milli: i64,
    b_milli: i64,
    intensity_milli: i64,
) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const scene = renderer.registry.get(@intCast(handle)) orelse return -1;
    scene.setLight(
        .{ milli(x_milli), milli(y_milli), milli(z_milli) },
        .{ milli(r_milli), milli(g_milli), milli(b_milli), milli(intensity_milli) },
    );
    return 0;
}

pub export fn e7_engine_scene_begin_frame(handle: i64) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const scene = renderer.registry.get(@intCast(handle)) orelse return -1;
    scene.beginFrame() catch return -1;
    state.scene_draws += 1;
    return 0;
}

pub export fn e7_engine_scene_draw_mesh(handle: i64) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const scene = renderer.registry.get(@intCast(handle)) orelse return -1;
    if (scene.frame_index == null) return -1;
    scene.drawMesh();
    state.scene_boxes += 1;
    return 0;
}

/// Draw one box in the frame opened by `e7_engine_scene_begin_frame`.
/// Position and scale are milli-units (world units x1000), the Y rotation is
/// milli-radians.  Returns 0 on success, -1 when there is no active frame or
/// the per-frame object limit (`renderer.max_objects`, 64) is reached.
pub export fn e7_engine_scene_draw_box(
    handle: i64,
    x_milli: i64,
    y_milli: i64,
    z_milli: i64,
    sx_milli: i64,
    sy_milli: i64,
    sz_milli: i64,
    angle_milli_radians: i64,
) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const scene = renderer.registry.get(@intCast(handle)) orelse return -1;
    scene.drawBox(.{
        .position = .{ milli(x_milli), milli(y_milli), milli(z_milli) },
        .scale = .{ milli(sx_milli), milli(sy_milli), milli(sz_milli) },
        .angle = milli(angle_milli_radians),
    }) catch return -1;
    state.scene_boxes += 1;
    return 0;
}

pub export fn e7_engine_scene_end_frame(handle: i64) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const scene = renderer.registry.get(@intCast(handle)) orelse return -1;
    scene.endFrame() catch return -1;
    return 0;
}

/// Called once per frame from e7; increments the frame counter, captures a
/// frame when the configured limit is reached, and reports shutdown.
pub export fn e7_engine_should_close() callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    if (state.quit_requested) return 1;
    state.frames += 1;
    if (state.max_frames > 0 and state.frames >= state.max_frames) {
        state.quit_requested = true;
        captureLocked();
        return 1;
    }
    return 0;
}

pub fn symbols() [20]Symbol {
    return .{
        .{ .name = "e7_engine_window_create", .address = @intFromPtr(&e7_engine_window_create) },
        .{ .name = "e7_engine_window_pump", .address = @intFromPtr(&e7_engine_window_pump) },
        .{ .name = "e7_engine_window_should_close", .address = @intFromPtr(&e7_engine_window_should_close) },
        .{ .name = "e7_engine_window_destroy", .address = @intFromPtr(&e7_engine_window_destroy) },
        .{ .name = "e7_engine_time_now_ms", .address = @intFromPtr(&e7_engine_time_now_ms) },
        .{ .name = "e7_engine_read_shader", .address = @intFromPtr(&e7_engine_read_shader) },
        .{ .name = "e7_engine_scene_create", .address = @intFromPtr(&e7_engine_scene_create) },
        .{ .name = "e7_engine_scene_destroy", .address = @intFromPtr(&e7_engine_scene_destroy) },
        .{ .name = "e7_engine_scene_resize", .address = @intFromPtr(&e7_engine_scene_resize) },
        .{ .name = "e7_engine_scene_set_camera", .address = @intFromPtr(&e7_engine_scene_set_camera) },
        .{ .name = "e7_engine_scene_set_cube_angle", .address = @intFromPtr(&e7_engine_scene_set_cube_angle) },
        .{ .name = "e7_engine_scene_set_light", .address = @intFromPtr(&e7_engine_scene_set_light) },
        .{ .name = "e7_engine_scene_begin_frame", .address = @intFromPtr(&e7_engine_scene_begin_frame) },
        .{ .name = "e7_engine_scene_draw_mesh", .address = @intFromPtr(&e7_engine_scene_draw_mesh) },
        .{ .name = "e7_engine_scene_draw_box", .address = @intFromPtr(&e7_engine_scene_draw_box) },
        .{ .name = "e7_engine_scene_end_frame", .address = @intFromPtr(&e7_engine_scene_end_frame) },
        .{ .name = "e7_engine_should_close", .address = @intFromPtr(&e7_engine_should_close) },
        .{ .name = "e7_engine_key_down", .address = @intFromPtr(&e7_engine_key_down) },
        .{ .name = "e7_engine_mouse_dx", .address = @intFromPtr(&e7_engine_mouse_dx) },
        .{ .name = "e7_engine_mouse_dy", .address = @intFromPtr(&e7_engine_mouse_dy) },
    };
}

test "engine frame limiter captures a headless frame" {
    reset();
    defer shutdown();
    setHeadless(true);
    setMaxFrames(2);
    setCaptureEnabled(true);

    const title_text = "engine7 test";
    const title = aggregate.e7_str_new(@intCast(@intFromPtr(title_text.ptr)), title_text.len);
    const window = e7_engine_window_create(title, 320, 200);
    try std.testing.expect(window != 0);
    const vert_path = "engine/shaders/cube.vert.spv";
    const frag_path = "engine/shaders/cube.frag.spv";
    const vert_str = aggregate.e7_str_new(@intCast(@intFromPtr(vert_path.ptr)), vert_path.len);
    const frag_str = aggregate.e7_str_new(@intCast(@intFromPtr(frag_path.ptr)), frag_path.len);
    const vert = e7_engine_read_shader(vert_str);
    const frag = e7_engine_read_shader(frag_str);
    const scene = e7_engine_scene_create(window, vert, frag);
    try std.testing.expect(scene != 0);

    // The runtime only reports raw input; synthetic state stands in for SDL.
    injectKeyForTest(@intFromEnum(Key.forward), true);
    injectMouseDeltaForTest(100, -40);
    try std.testing.expectEqual(@as(i64, 1), e7_engine_key_down(@intFromEnum(Key.forward)));
    try std.testing.expectEqual(@as(i64, 100), e7_engine_mouse_dx());
    try std.testing.expectEqual(@as(i64, -40), e7_engine_mouse_dy());
    // Reads are destructive, so the next frame starts from zero.
    try std.testing.expectEqual(@as(i64, 0), e7_engine_mouse_dx());
    try std.testing.expectEqual(@as(i64, 0), e7_engine_mouse_dy());
    injectKeyForTest(@intFromEnum(Key.forward), false);
    try std.testing.expectEqual(@as(i64, 0), e7_engine_key_down(@intFromEnum(Key.forward)));
    try std.testing.expectEqual(@as(i64, 0), e7_engine_scene_set_camera(scene, 0, 1800, 5500, 0, -140));

    var frame: i64 = 0;
    while (frame < 2) : (frame += 1) {
        try std.testing.expectEqual(@as(i64, 0), e7_engine_scene_set_cube_angle(scene, frame * 1000));
        try std.testing.expectEqual(@as(i64, 0), e7_engine_scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000));
        try std.testing.expectEqual(@as(i64, 0), e7_engine_scene_begin_frame(scene));
        try std.testing.expectEqual(@as(i64, 0), e7_engine_scene_draw_mesh(scene));
        try std.testing.expectEqual(@as(i64, 0), e7_engine_scene_end_frame(scene));
        _ = e7_engine_should_close();
    }
    var capture = takeCapture() orelse return error.TestUnexpectedResult;
    defer capture.deinit();
    try std.testing.expect(capture.width > 0 and capture.height > 0);
    try std.testing.expect(captureIsNonBlack(capture));
    try std.testing.expectEqual(@as(i64, 1), e7_engine_should_close());
}

test "engine draw_box records one draw per box and captures them" {
    reset();
    defer shutdown();
    setHeadless(true);
    setMaxFrames(1);
    setCaptureEnabled(true);

    const title_text = "engine7 multi-box test";
    const title = aggregate.e7_str_new(@intCast(@intFromPtr(title_text.ptr)), title_text.len);
    const window = e7_engine_window_create(title, 320, 240);
    if (window == 0) {
        std.debug.print("skipping engine draw_box test (no display)\n", .{});
        return;
    }
    const vert_path = "engine/shaders/cube.vert.spv";
    const frag_path = "engine/shaders/cube.frag.spv";
    const vert_str = aggregate.e7_str_new(@intCast(@intFromPtr(vert_path.ptr)), vert_path.len);
    const frag_str = aggregate.e7_str_new(@intCast(@intFromPtr(frag_path.ptr)), frag_path.len);
    const vert = e7_engine_read_shader(vert_str);
    const frag = e7_engine_read_shader(frag_str);
    const scene = e7_engine_scene_create(window, vert, frag);
    if (scene == 0) {
        std.debug.print("skipping engine draw_box test (no Vulkan)\n", .{});
        return;
    }

    try std.testing.expectEqual(@as(i64, 0), e7_engine_scene_set_camera(scene, 0, 1800, 5500, 0, -140));
    try std.testing.expectEqual(@as(i64, 0), e7_engine_scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000));
    try std.testing.expectEqual(@as(i64, 0), e7_engine_scene_begin_frame(scene));

    // plane + player + ball + 3 cubes, as in the engine demo rows.
    const boxes = [_][7]i64{
        .{ 0, 0, 0, 50000, 100, 50000, 0 }, // plane: 100 x 0.2 x 100
        .{ 0, 1200, 5000, 400, 1000, 400, 0 }, // player capsule proxy
        .{ 1600, 2000, 4000, 500, 500, 500, 0 }, // ball proxy
        .{ -2000, 500, 0, 500, 500, 500, 0 },
        .{ -2000, 1500, 0, 500, 500, 500, 0 },
        .{ -2000, 2500, 0, 500, 500, 500, 0 },
    };
    for (boxes) |box| {
        try std.testing.expectEqual(@as(i64, 0), e7_engine_scene_draw_box(
            scene,
            box[0],
            box[1],
            box[2],
            box[3],
            box[4],
            box[5],
            box[6],
        ));
    }
    const stats = renderStats();
    try std.testing.expectEqual(@as(i64, 6), stats.scene_boxes);
    try std.testing.expectEqual(@as(i64, 1), stats.scene_draws);

    try std.testing.expectEqual(@as(i64, 0), e7_engine_scene_end_frame(scene));
    // Hitting the frame limit captures the scene (all recorded boxes replayed).
    try std.testing.expectEqual(@as(i64, 1), e7_engine_should_close());

    var capture = takeCapture() orelse return error.TestUnexpectedResult;
    defer capture.deinit();
    try std.testing.expectEqual(@as(u32, 320), capture.width);
    try std.testing.expect(captureIsNonBlack(capture));
    try std.testing.expect(captureHasContent(capture));
}
