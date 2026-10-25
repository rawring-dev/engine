//! Native Vulkan 3D scene demo: a spinning cube, a point light, and a movable
//! first-person camera.
//!
//! Run from the repository root:
//!
//!     zig build run-scene
//!     zig build run-scene -- --frames 120
//!     zig build run-scene -- --headless --capture scene.ppm
//!
//! Controls: WASD moves on the ground plane, Q/E moves down/up, Shift is sprint,
//! mouse looks around (relative mouse mode), arrow keys also look, Esc or the
//! window close button exits.
//!
//! The demo creates a 960x540 resizable SDL3 window with Vulkan, compiles the
//! embedded SPIR-V from `runtime/shaders/` into the runtime `Scene` renderer,
//! and draws one indexed cube per frame.  When no display/GPU is available it
//! prints a skip message and exits successfully so build validation can run on
//! headless machines.

const std = @import("std");
const abi = @import("ffi/abi.zig");
const window_mod = @import("ffi/window.zig");
const renderer = @import("ffi/renderer.zig");
const time = @import("ffi/time.zig");
const shader_assets = @import("shader_assets");

const c = @import("ffi/sdl.zig").c;

const window_width = 960;
const window_height = 540;
const move_speed: f32 = 3.0;
const sprint_multiplier: f32 = 2.5;
const mouse_sensitivity: f32 = 0.0025;
const keyboard_look_speed: f32 = 1.6;
const max_frame_delta: f32 = 0.1;

const Options = struct {
    frames: u32 = 0,
    headless: bool = false,
    capture_path: ?[]const u8 = null,
    help: bool = false,
};

const Input = struct {
    forward: bool = false,
    back: bool = false,
    left: bool = false,
    right: bool = false,
    down: bool = false,
    up: bool = false,
    sprint: bool = false,
    look_left: bool = false,
    look_right: bool = false,
    look_up: bool = false,
    look_down: bool = false,
    mouse_dx: f32 = 0,
    mouse_dy: f32 = 0,
    should_close: bool = false,

    fn resetPerFrame(self: *Input) void {
        self.mouse_dx = 0;
        self.mouse_dy = 0;
    }
};

pub fn main(init: std.process.Init) !void {
    var options = Options{};
    var args = init.minimal.args.iterate();
    _ = args.next(); // program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--frames")) {
            const value = args.next() orelse {
                std.debug.print("scene_demo: --frames requires a count\n", .{});
                return error.InvalidArguments;
            };
            options.frames = std.fmt.parseInt(u32, value, 10) catch {
                std.debug.print("scene_demo: invalid frame count '{s}'\n", .{value});
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--headless")) {
            options.headless = true;
        } else if (std.mem.eql(u8, arg, "--capture")) {
            options.capture_path = args.next() orelse {
                std.debug.print("scene_demo: --capture requires a path\n", .{});
                return error.InvalidArguments;
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else {
            std.debug.print("scene_demo: unknown argument '{s}' (try --help)\n", .{arg});
            return error.InvalidArguments;
        }
    }

    if (options.help) {
        printHelp();
        return;
    }
    if (options.headless and options.frames == 0) options.frames = 3;

    run(init, options) catch |err| switch (err) {
        error.NoDisplay, error.NoVulkan => {
            // Headless CI: report and exit successfully so `zig build run-scene`
            // can still be used as a build/validation step.
            std.debug.print("scene_demo: skipping ({s})\n", .{abi.lastError()});
            return;
        },
        else => return err,
    };
}

fn run(init: std.process.Init, options: Options) !void {
    var window = window_mod.Window.create(
        "engine7 - Vulkan scene demo (WASD/QE move, mouse look, Esc quit)",
        window_width,
        window_height,
        .{ .vulkan = true, .resizable = true, .hidden = options.headless },
        null,
    ) catch {
        return error.NoDisplay;
    };
    defer window.destroy();
    defer window_mod.shutdownVideo();

    var scene = renderer.Scene.init(
        std.heap.c_allocator,
        &window,
        shader_assets.cube_vert_spv,
        shader_assets.cube_frag_spv,
    ) catch {
        return error.NoVulkan;
    };
    defer scene.deinit();

    std.debug.print("scene_demo: {s} renderer, {d}x{d} swapchain\n", .{
        scene.surface.formatName(),
        scene.size().width,
        scene.size().height,
    });
    if (!options.headless) {
        _ = c.SDL_SetWindowRelativeMouseMode(window.handle, true);
        std.debug.print(
            "scene_demo: WASD move, Q/E down/up, Shift sprint, mouse/arrows look, Esc quit\n",
            .{},
        );
    }

    var input = Input{};
    var camera = renderer.Camera{};
    scene.setCamera(camera.eye, camera.yaw, camera.pitch);

    var frame: u32 = 0;
    var last_ns = time.nowNs();
    var elapsed: f32 = 0;
    var last_pixels: ?[]u8 = null;
    defer if (last_pixels) |pixels| std.heap.c_allocator.free(pixels);

    while (true) {
        input.resetPerFrame();
        try pumpEvents(&window, &input);
        if (input.should_close) break;

        const now = time.nowNs();
        var delta: f32 = @as(f32, @floatFromInt(now - last_ns)) / @as(f32, std.time.ns_per_s);
        last_ns = now;
        if (delta > max_frame_delta) delta = max_frame_delta;
        elapsed += delta;

        applyLook(&camera, &input, delta);
        applyMovement(&camera, &input, delta);
        scene.setCamera(camera.eye, camera.yaw, camera.pitch);

        const spin = elapsed * 0.9;
        const light_angle = elapsed * 0.7 + 0.8;
        const light = renderer.Vec3{
            2.8 * @cos(light_angle),
            3.0,
            2.8 * @sin(light_angle),
        };

        if (options.headless) {
            if (last_pixels) |pixels| std.heap.c_allocator.free(pixels);
            last_pixels = try scene.captureFrame(spin, light);
        } else {
            try scene.draw(delta, spin, light);
            if (options.capture_path != null) {
                if (last_pixels) |pixels| std.heap.c_allocator.free(pixels);
                last_pixels = try scene.captureFrame(spin, light);
            }
        }

        frame += 1;
        if (options.frames != 0 and frame >= options.frames) break;
        if (!options.headless) {
            if (frame % 60 == 0) {
                // Keep the title fresh without reallocating every frame.
                var title_buf: [128]u8 = undefined;
                const title = std.fmt.bufPrint(&title_buf, "engine7 scene - frame {d} - {d}x{d}", .{
                    frame,
                    scene.size().width,
                    scene.size().height,
                }) catch "engine7 scene";
                window.setTitle(title) catch {};
            }
        }
    }

    if (options.capture_path) |path| {
        if (last_pixels == null) {
            last_pixels = try scene.captureFrame(elapsed * 0.9, .{ 2.6, 3.0, 2.6 });
        }
        try writePpm(init.io, path, last_pixels.?, scene.size().width, scene.size().height);
        std.debug.print("scene_demo: wrote {s} ({d} frames)\n", .{ path, frame });
    }
}

fn printHelp() void {
    std.debug.print(
        \\Usage: scene_demo [options]
        \\
        \\  --frames N       exit after N frames (default: run until closed)
        \\  --headless       hidden window, no mouse grab, 3 frames by default
        \\  --capture PATH   write the final frame as a binary PPM (P6) image
        \\  -h, --help       show this help
        \\
        \\Controls: WASD move, Q/E down/up, Shift sprint, mouse or arrow keys look,
        \\Esc or the window close button exits.
        \\
    , .{});
}

fn applyLook(camera: *renderer.Camera, input: *Input, delta: f32) void {
    camera.yaw += input.mouse_dx * mouse_sensitivity;
    camera.pitch -= input.mouse_dy * mouse_sensitivity;
    if (input.look_left) camera.yaw -= keyboard_look_speed * delta;
    if (input.look_right) camera.yaw += keyboard_look_speed * delta;
    if (input.look_up) camera.pitch += keyboard_look_speed * delta;
    if (input.look_down) camera.pitch -= keyboard_look_speed * delta;
    const limit: f32 = std.math.degreesToRadians(89.0);
    if (camera.pitch > limit) camera.pitch = limit;
    if (camera.pitch < -limit) camera.pitch = -limit;
}

fn applyMovement(camera: *renderer.Camera, input: *Input, delta: f32) void {
    const basis = renderer.cameraBasis(camera.yaw, 0.0);
    const ground_forward = renderer.Vec3{ basis.forward[0], 0.0, basis.forward[2] };
    const ground_right = renderer.Vec3{ basis.right[0], 0.0, basis.right[2] };

    var direction = renderer.Vec3{ 0, 0, 0 };
    if (input.forward) direction = add(direction, ground_forward);
    if (input.back) direction = sub(direction, ground_forward);
    if (input.right) direction = add(direction, ground_right);
    if (input.left) direction = sub(direction, ground_right);
    if (input.up) direction[1] += 1.0;
    if (input.down) direction[1] -= 1.0;

    const length = @sqrt(direction[0] * direction[0] + direction[1] * direction[1] + direction[2] * direction[2]);
    if (length <= 1e-6) return;
    const speed = move_speed * (if (input.sprint) sprint_multiplier else 1.0) * delta;
    for (0..3) |i| camera.eye[i] += direction[i] / length * speed;
}

fn add(a: renderer.Vec3, b: renderer.Vec3) renderer.Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn sub(a: renderer.Vec3, b: renderer.Vec3) renderer.Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn pumpEvents(window: *window_mod.Window, input: *Input) !void {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        const kind: u32 = @intCast(event.type);
        switch (kind) {
            c.SDL_EVENT_QUIT => input.should_close = true,
            c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                if (event.window.windowID == window.id) input.should_close = true;
            },
            c.SDL_EVENT_MOUSE_MOTION => {
                input.mouse_dx += event.motion.xrel;
                input.mouse_dy += event.motion.yrel;
            },
            c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                const pressed = event.key.down;
                if (event.key.windowID != window.id) continue;
                switch (event.key.key) {
                    c.SDLK_ESCAPE => {
                        if (pressed) input.should_close = true;
                    },
                    c.SDLK_W => input.forward = pressed,
                    c.SDLK_S => input.back = pressed,
                    c.SDLK_A => input.left = pressed,
                    c.SDLK_D => input.right = pressed,
                    c.SDLK_Q => input.down = pressed,
                    c.SDLK_E => input.up = pressed,
                    c.SDLK_LEFT => input.look_left = pressed,
                    c.SDLK_RIGHT => input.look_right = pressed,
                    c.SDLK_UP => input.look_up = pressed,
                    c.SDLK_DOWN => input.look_down = pressed,
                    c.SDLK_LSHIFT, c.SDLK_RSHIFT => input.sprint = pressed,
                    else => {},
                }
            },
            else => {},
        }
    }
}

fn writePpm(io: std.Io, path: []const u8, pixels: []const u8, width: u32, height: u32) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height });
    try file.writeStreamingAll(io, header);
    var rgb: [3]u8 = undefined;
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        rgb = .{ pixels[i], pixels[i + 1], pixels[i + 2] };
        try file.writeStreamingAll(io, &rgb);
    }
}
