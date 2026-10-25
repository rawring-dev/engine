//! E7-visible engine intrinsics: hidden/visible SDL window, embedded-shader
//! Vulkan scene, monotonic time, and a deterministic frame limiter.
//!
//! These symbols are compiler-known (see `compiler/src/intrinsics.zig`) and are
//! registered with the JIT by `orc.Jit.addBytecode`.  The engine helpers keep
//! the C ABI small: window/scene handles are u64, everything else is an i64, and
//! f32 values cross the boundary integer-scaled so e7 needs no float arithmetic:
//!
//!   * positions/eye/light: milli-units (world units x1000)
//!   * camera yaw/pitch:    milli-degrees (degrees x1000)
//!   * scene delta:         milliseconds
//!   * cube angle:          milli-radians (radians x1000)
//!
//! Input is native: `e7_engine_window_pump` drains SDL events into an engine
//! input state (WASD/QE/arrows/Shift, mouse motion, close/Escape), and
//! `e7_engine_camera_update(scene, delta_ms)` applies FPS-style movement and
//! mouse look to the runtime camera, then pushes it to the scene.  `--headless`
//! hides the SDL window; rendering still goes through the offscreen capture
//! target, so a frame can be captured and checked without a display.
//! The frame limiter is host-configured (`setMaxFrames`) and polled once per
//! frame from e7 via `e7_engine_should_close()`, which captures the current
//! scene before signalling shutdown when the limit is reached.

const std = @import("std");
const abi = @import("ffi/abi.zig");
const window_mod = @import("ffi/window.zig");
const renderer = @import("ffi/renderer.zig");
const time_mod = @import("ffi/time.zig");
const io_mod = @import("ffi/io.zig");
const aggregate = @import("aggregate.zig");
const shader_assets = @import("shader_assets");
const sdl = @import("ffi/sdl.zig");
const c = sdl.c;

const move_speed: f32 = 3.0;
const sprint_multiplier: f32 = 2.5;
const mouse_sensitivity: f32 = 0.0025;
const keyboard_look_speed: f32 = 1.6;
const max_frame_delta_ms: i64 = 100;
/// Clamp one SDL mouse-motion event.  Relative mode should produce small
/// deltas, but focus/window-manager transitions can report a single huge jump.
const look_delta_limit: f32 = 250.0;
/// Clamp the accumulated per-frame look delta so a stalled frame cannot spin
/// the camera by an unbounded amount.
const max_look_delta: f32 = 600.0;

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
};

const InputState = struct {
    forward: bool = false,
    back: bool = false,
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
    sprint: bool = false,
    look_left: bool = false,
    look_right: bool = false,
    look_up: bool = false,
    look_down: bool = false,
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
    /// Runtime FPS camera; movement/mouse look are applied by
    /// `e7_engine_camera_update` so e7 needs no float arithmetic.
    camera: renderer.Camera = .{},
    input: InputState = .{},
    camera_updates: i64 = 0,
    scene_draws: i64 = 0,
};

var state: State = .{};

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
    switch (key) {
        .forward => state.input.forward = pressed,
        .back => state.input.back = pressed,
        .left => state.input.left = pressed,
        .right => state.input.right = pressed,
        .up => state.input.up = pressed,
        .down => state.input.down = pressed,
        .sprint => state.input.sprint = pressed,
        .look_left => state.input.look_left = pressed,
        .look_right => state.input.look_right = pressed,
        .look_up => state.input.look_up = pressed,
        .look_down => state.input.look_down = pressed,
    }
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

/// Apply the current input state to the runtime camera and push it to `scene`.
/// Requires `state.mutex`.
fn cameraUpdateLocked(scene_handle: i64, delta_ms: i64) void {
    const scene = renderer.registry.get(@intCast(scene_handle)) orelse return;
    const clamped_ms = @max(@as(i64, 0), @min(delta_ms, max_frame_delta_ms));
    const delta = @as(f32, @floatFromInt(clamped_ms)) / 1000.0;

    const mouse_dx = std.math.clamp(state.input.mouse_dx, -max_look_delta, max_look_delta);
    const mouse_dy = std.math.clamp(state.input.mouse_dy, -max_look_delta, max_look_delta);
    state.camera.yaw += mouse_dx * mouse_sensitivity;
    state.camera.pitch -= mouse_dy * mouse_sensitivity;
    state.input.mouse_dx = 0.0;
    state.input.mouse_dy = 0.0;
    if (state.input.look_left) state.camera.yaw -= keyboard_look_speed * delta;
    if (state.input.look_right) state.camera.yaw += keyboard_look_speed * delta;
    if (state.input.look_up) state.camera.pitch += keyboard_look_speed * delta;
    if (state.input.look_down) state.camera.pitch -= keyboard_look_speed * delta;
    const pitch_limit = std.math.degreesToRadians(89.0);
    state.camera.pitch = std.math.clamp(state.camera.pitch, -pitch_limit, pitch_limit);

    const basis = renderer.cameraBasis(state.camera.yaw, 0.0);
    const ground_forward = renderer.Vec3{ basis.forward[0], 0.0, basis.forward[2] };
    const ground_right = renderer.Vec3{ basis.right[0], 0.0, basis.right[2] };
    var direction = renderer.Vec3{ 0.0, 0.0, 0.0 };
    if (state.input.forward) direction = vecAdd(direction, ground_forward);
    if (state.input.back) direction = vecSub(direction, ground_forward);
    if (state.input.right) direction = vecAdd(direction, ground_right);
    if (state.input.left) direction = vecSub(direction, ground_right);
    if (state.input.up) direction[1] += 1.0;
    if (state.input.down) direction[1] -= 1.0;
    const length = @sqrt(direction[0] * direction[0] + direction[1] * direction[1] + direction[2] * direction[2]);
    if (length > 1e-6) {
        const speed = move_speed * (if (state.input.sprint) sprint_multiplier else 1.0) * delta;
        for (0..3) |axis| state.camera.eye[axis] += direction[axis] / length * speed;
    }
    scene.setCamera(state.camera.eye, state.camera.yaw, state.camera.pitch);
}

fn vecAdd(a: renderer.Vec3, b: renderer.Vec3) renderer.Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn vecSub(a: renderer.Vec3, b: renderer.Vec3) renderer.Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

/// Headless tests: synthesize key/mouse input without an SDL device.
pub fn injectKeyForTest(code: i64, pressed: bool) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    if (code < 0 or code > @intFromEnum(Key.look_down)) return;
    setKeyLocked(@enumFromInt(code), pressed);
}

pub fn injectMouseDeltaForTest(dx: i64, dy: i64) void {
    state.mutex.lock();
    defer state.mutex.unlock();
    state.input.mouse_dx += @floatFromInt(dx);
    state.input.mouse_dy += @floatFromInt(dy);
}

pub fn cameraForTest() renderer.Camera {
    state.mutex.lock();
    defer state.mutex.unlock();
    return state.camera;
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
    state.camera = .{};
    state.input = .{};
    state.camera_updates = 0;
    state.scene_draws = 0;
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

pub const RenderStats = struct { camera_updates: i64, scene_draws: i64 };

pub fn renderStats() RenderStats {
    state.mutex.lock();
    defer state.mutex.unlock();
    return .{ .camera_updates = state.camera_updates, .scene_draws = state.scene_draws };
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
    const pixels = scene.captureFrame(scene.spin, scene.light_position) catch return;
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
/// 7-10 arrow look).  Returns 1 when held.
pub export fn e7_engine_key_down(code: i64) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    if (code < 0 or code > @intFromEnum(Key.look_down)) return 0;
    return switch (@as(Key, @enumFromInt(code))) {
        .forward => @intFromBool(state.input.forward),
        .back => @intFromBool(state.input.back),
        .left => @intFromBool(state.input.left),
        .right => @intFromBool(state.input.right),
        .up => @intFromBool(state.input.up),
        .down => @intFromBool(state.input.down),
        .sprint => @intFromBool(state.input.sprint),
        .look_left => @intFromBool(state.input.look_left),
        .look_right => @intFromBool(state.input.look_right),
        .look_up => @intFromBool(state.input.look_up),
        .look_down => @intFromBool(state.input.look_down),
    };
}

/// Accumulated mouse motion since the previous read, packed as
/// `(dy << 32) | (dx & 0xffffffff)` in pixels; reading clears it.
pub export fn e7_engine_mouse_delta() callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const dx: i32 = @intFromFloat(state.input.mouse_dx);
    const dy: i32 = @intFromFloat(state.input.mouse_dy);
    state.input.mouse_dx = 0.0;
    state.input.mouse_dy = 0.0;
    return (@as(i64, dy) << 32) | @as(i64, @intCast(@as(u32, @bitCast(dx))));
}

/// Apply native/engine input to the FPS camera and push it to the scene.
/// `delta_ms` is clamped to [0, 100] for stable movement after stalls.
pub export fn e7_engine_camera_update(scene: i64, delta_ms: i64) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    if (renderer.registry.get(@intCast(scene)) == null) return -1;
    cameraUpdateLocked(scene, delta_ms);
    state.camera_updates += 1;
    return 0;
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

pub export fn e7_engine_scene_create(window_handle: i64) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const window = window_mod.registry.get(@intCast(window_handle)) orelse {
        state.last_failure = "scene create: invalid window handle";
        return 0;
    };
    var scene = renderer.Scene.init(
        std.heap.c_allocator,
        window,
        shader_assets.cube_vert_spv,
        shader_assets.cube_frag_spv,
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

pub export fn e7_engine_scene_draw(
    handle: i64,
    delta_milliseconds: i64,
    cube_angle_milli_radians: i64,
    light_x_milli: i64,
    light_y_milli: i64,
    light_z_milli: i64,
) callconv(.c) i64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    const scene = renderer.registry.get(@intCast(handle)) orelse return -1;
    scene.draw(
        milli(delta_milliseconds),
        milli(cube_angle_milli_radians),
        .{ milli(light_x_milli), milli(light_y_milli), milli(light_z_milli) },
    ) catch return -1;
    state.scene_draws += 1;
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

pub fn symbols() [14]Symbol {
    return .{
        .{ .name = "e7_engine_window_create", .address = @intFromPtr(&e7_engine_window_create) },
        .{ .name = "e7_engine_window_pump", .address = @intFromPtr(&e7_engine_window_pump) },
        .{ .name = "e7_engine_window_should_close", .address = @intFromPtr(&e7_engine_window_should_close) },
        .{ .name = "e7_engine_window_destroy", .address = @intFromPtr(&e7_engine_window_destroy) },
        .{ .name = "e7_engine_time_now_ms", .address = @intFromPtr(&e7_engine_time_now_ms) },
        .{ .name = "e7_engine_scene_create", .address = @intFromPtr(&e7_engine_scene_create) },
        .{ .name = "e7_engine_scene_destroy", .address = @intFromPtr(&e7_engine_scene_destroy) },
        .{ .name = "e7_engine_scene_resize", .address = @intFromPtr(&e7_engine_scene_resize) },
        .{ .name = "e7_engine_scene_set_camera", .address = @intFromPtr(&e7_engine_scene_set_camera) },
        .{ .name = "e7_engine_scene_draw", .address = @intFromPtr(&e7_engine_scene_draw) },
        .{ .name = "e7_engine_should_close", .address = @intFromPtr(&e7_engine_should_close) },
        .{ .name = "e7_engine_key_down", .address = @intFromPtr(&e7_engine_key_down) },
        .{ .name = "e7_engine_mouse_delta", .address = @intFromPtr(&e7_engine_mouse_delta) },
        .{ .name = "e7_engine_camera_update", .address = @intFromPtr(&e7_engine_camera_update) },
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
    const scene = e7_engine_scene_create(window);
    try std.testing.expect(scene != 0);

    try std.testing.expectEqual(@as(i64, 0), e7_engine_scene_set_camera(scene, 0, 1500, 6000, 0, 0));
    // Synthetic input drives the runtime camera (headless has no SDL device).
    const camera_before = cameraForTest();
    injectKeyForTest(@intFromEnum(Key.forward), true);
    injectMouseDeltaForTest(100, 0);
    try std.testing.expectEqual(@as(i64, 0), e7_engine_camera_update(scene, 100));
    injectKeyForTest(@intFromEnum(Key.forward), false);
    const camera_after = cameraForTest();
    try std.testing.expect(camera_after.eye[2] < camera_before.eye[2]);
    try std.testing.expect(camera_after.yaw > camera_before.yaw);

    var frame: i64 = 0;
    while (frame < 2) : (frame += 1) {
        try std.testing.expectEqual(@as(i64, 0), e7_engine_scene_draw(scene, 16, frame * 1000, 2600, 3000, 2600));
        _ = e7_engine_should_close();
    }
    var capture = takeCapture() orelse return error.TestUnexpectedResult;
    defer capture.deinit();
    try std.testing.expect(capture.width > 0 and capture.height > 0);
    try std.testing.expect(captureIsNonBlack(capture));
    try std.testing.expectEqual(@as(i64, 1), e7_engine_should_close());
}
