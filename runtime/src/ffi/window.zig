//! Cross-platform window management through SDL3 [sdl3].
//!
//! SDL is used for window creation, event delivery, and platform-specific
//! Vulkan surface creation.  Window creation and event pumping must run on the
//! process's main thread on platforms with that requirement (macOS in
//! particular); this is documented for JITed callers.

const std = @import("std");
const abi = @import("abi.zig");
const io_mod = @import("io.zig");
const handles = @import("handles.zig");

pub const c = @import("sdl.zig").c;

pub const Flags = packed struct(u64) {
    resizable: bool = false,
    hidden: bool = false,
    high_dpi: bool = false,
    vulkan: bool = false,
    borderless: bool = false,
    fullscreen: bool = false,
    _: u58 = 0,
};

pub const Event = struct {
    type: u32,
    window_id: u32,
    data1: i32,
    data2: i32,
};

pub const Window = struct {
    handle: *c.SDL_Window,
    id: u32,
    should_close: bool = false,
    vulkan: bool = false,

    pub fn create(title: []const u8, width: i32, height: i32, flags: Flags, driver: ?[]const u8) !Window {
        try ensureVideo(driver);

        const title_z = try std.heap.c_allocator.dupeZ(u8, title);
        defer std.heap.c_allocator.free(title_z);

        var sdl_flags: c.SDL_WindowFlags = 0;
        if (flags.resizable) sdl_flags |= c.SDL_WINDOW_RESIZABLE;
        if (flags.hidden) sdl_flags |= c.SDL_WINDOW_HIDDEN;
        if (flags.high_dpi) sdl_flags |= c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        if (flags.vulkan) sdl_flags |= c.SDL_WINDOW_VULKAN;
        if (flags.borderless) sdl_flags |= c.SDL_WINDOW_BORDERLESS;
        if (flags.fullscreen) sdl_flags |= c.SDL_WINDOW_FULLSCREEN;

        const handle = c.SDL_CreateWindow(title_z.ptr, width, height, sdl_flags) orelse {
            abi.setErrorFmt("SDL_CreateWindow: {s}", .{sdlError()});
            return error.WindowCreateFailed;
        };
        const id = c.SDL_GetWindowID(handle);
        return .{ .handle = handle, .id = id, .vulkan = flags.vulkan };
    }

    pub fn destroy(self: *Window) void {
        c.SDL_DestroyWindow(self.handle);
        self.handle = undefined;
    }

    pub fn setTitle(self: *Window, title: []const u8) !void {
        const title_z = try std.heap.c_allocator.dupeZ(u8, title);
        defer std.heap.c_allocator.free(title_z);
        if (!c.SDL_SetWindowTitle(self.handle, title_z.ptr)) {
            abi.setErrorFmt("SDL_SetWindowTitle: {s}", .{sdlError()});
            return error.WindowOperationFailed;
        }
    }

    /// Width and height in physical pixels, suitable for a Vulkan extent.
    pub fn pixelSize(self: *Window) !struct { width: i32, height: i32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        if (!c.SDL_GetWindowSizeInPixels(self.handle, &w, &h)) {
            abi.setErrorFmt("SDL_GetWindowSizeInPixels: {s}", .{sdlError()});
            return error.WindowOperationFailed;
        }
        return .{ .width = w, .height = h };
    }

    pub fn show(self: *Window) void {
        _ = c.SDL_ShowWindow(self.handle);
    }

    pub fn hide(self: *Window) void {
        _ = c.SDL_HideWindow(self.handle);
    }

    pub fn setResizable(self: *Window, resizable: bool) void {
        _ = c.SDL_SetWindowResizable(self.handle, resizable);
    }
};

var video_mutex: io_mod.Mutex = .{};
var video_initialized = false;

fn ensureVideo(driver: ?[]const u8) !void {
    video_mutex.lock();
    defer video_mutex.unlock();

    if (video_initialized) return;

    if (driver) |name| {
        const name_z = std.heap.c_allocator.dupeZ(u8, name) catch return error.OutOfMemory;
        defer std.heap.c_allocator.free(name_z);
        if (!c.SDL_SetHint(c.SDL_HINT_VIDEO_DRIVER, name_z.ptr)) {
            abi.setErrorFmt("SDL_SetHint(SDL_VIDEO_DRIVER): {s}", .{sdlError()});
        }
    }

    if (!c.SDL_InitSubSystem(c.SDL_INIT_VIDEO)) {
        abi.setErrorFmt("SDL_InitSubSystem(VIDEO): {s}", .{sdlError()});
        return error.SDLInitFailed;
    }
    video_initialized = true;
}

/// Tear down SDL video for tests that need to switch display drivers.
pub fn shutdownVideo() void {
    video_mutex.lock();
    defer video_mutex.unlock();
    if (video_initialized) {
        c.SDL_QuitSubSystem(c.SDL_INIT_VIDEO);
        video_initialized = false;
    }
}

/// Poll one pending SDL event.  Window close requests also mark the matching
/// handle for cooperative shutdown.
pub fn pollEvent(reg: *Registry) ?Event {
    var event: c.SDL_Event = undefined;
    if (!c.SDL_PollEvent(&event)) return null;

    const kind: u32 = @intCast(event.type);
    var result: Event = .{
        .type = kind,
        .window_id = 0,
        .data1 = 0,
        .data2 = 0,
    };

    if (kind == c.SDL_EVENT_QUIT) {
        reg.mutex.lock();
        var it = reg.map.valueIterator();
        while (it.next()) |window| window.*.should_close = true;
        reg.mutex.unlock();
    } else if (kind >= c.SDL_EVENT_WINDOW_FIRST and kind <= c.SDL_EVENT_WINDOW_LAST) {
        result.window_id = @intCast(event.window.windowID);
        result.data1 = @intCast(event.window.data1);
        result.data2 = @intCast(event.window.data2);
        if (kind == c.SDL_EVENT_WINDOW_CLOSE_REQUESTED) {
            if (reg.get(result.window_id)) |window| window.should_close = true;
        }
    } else if (kind >= c.SDL_EVENT_KEY_DOWN and kind <= c.SDL_EVENT_TEXT_INPUT) {
        result.window_id = @intCast(event.key.windowID);
        result.data1 = @intCast(event.key.key);
        result.data2 = @intCast(event.key.scancode);
    }
    return result;
}

pub fn sdlError() []const u8 {
    const text = c.SDL_GetError();
    if (text == null) return "unknown SDL error";
    return std.mem.span(text);
}

pub const Registry = handles.Table(Window);
pub var registry: Registry = .{};

test "SDL3 creates and destroys a hidden window" {
    abi.clearError();
    var window = Window.create("engine7 test", 320, 200, .{
        .hidden = true,
        .resizable = true,
    }, null) catch |err| {
        // Headless CI without a display or SDL video driver: skip.
        std.debug.print("skipping window test: {s} ({s})\n", .{ @errorName(err), abi.lastError() });
        windowShutdownVideoForTest();
        return;
    };
    defer windowShutdownVideoForTest();
    defer window.destroy();

    const size = try window.pixelSize();
    try std.testing.expect(size.width > 0 and size.height > 0);
    try window.setTitle("engine7 test renamed");
    window.hide();
    window.show();

    const id = try registry.create(window);
    defer _ = registry.remove(id);
    try std.testing.expect(registry.get(id) != null);

    var event: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
    event.type = c.SDL_EVENT_USER + 1;
    try std.testing.expect(c.SDL_PushEvent(&event));
    var found = false;
    var guard: usize = 0;
    while (guard < 64) : (guard += 1) {
        const polled = pollEvent(&registry) orelse break;
        if (polled.type == c.SDL_EVENT_USER + 1) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

fn windowShutdownVideoForTest() void {
    shutdownVideo();
}
