//! Low-level text rasterization for the e7 engine via SDL3_ttf.
//!
//! This module keeps only the ABI-facing pieces: a font handle registry,
//! UTF-8 text measurement, and text rendered into the existing image registry
//! as tightly packed top-down RGBA8 (transparent background, alpha from the
//! blended glyph coverage).  Rasterized text therefore reuses
//! `e7_image_width`/`e7_image_height`/`e7_image_pixels`/`e7_image_free`, which
//! the renderer's texture upload path already understands.
//!
//! ## Exported ABI
//!
//! ```text
//! e7_font_load(path: str, size: i64)   -> u64 font handle, 0 on failure
//! e7_font_free(handle)                 -> i32, 0 on success
//! e7_text_measure(font, text: str)     -> i64 packed (width << 32) | height
//! e7_text_image(font, text: str, r, g, b) -> u64 image handle, 0 on failure
//! ```
//!
//! `size` is the font point size (integer for the e7 ABI).  `path` is an
//! ordinary filesystem path (the runtime does not bundle fonts); callers pass
//! a system font path or an asset path that SDL3_ttf can open.

const std = @import("std");
const aggregate = @import("aggregate.zig");
const image = @import("image.zig");
const io_mod = @import("ffi/io.zig");
const abi = @import("ffi/abi.zig");
const Symbol = abi.Symbol;

const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
});

const allocator = std.heap.c_allocator;

pub const Font = struct {
    handle: *c.TTF_Font,
};

var registry_mutex: io_mod.Mutex = .{};
var registry: std.AutoHashMapUnmanaged(u64, *Font) = .empty;
var next_handle: u64 = 1;
var ttf_initialized = false;

/// Extract bytes from an e7 `str` aggregate (`[len, bytes...]`).
fn e7StringBytes(str: i64) ?[]const u8 {
    if (str == 0) return null;
    const len = @as([*]const i64, @ptrFromInt(@as(usize, @intCast(str))))[0];
    if (len < 0) return null;
    if (len == 0) return &.{};
    const bytes: [*]const u8 = @ptrFromInt(@as(usize, @intCast(str + 8)));
    return bytes[0..@intCast(len)];
}

fn ensureTtfLocked() bool {
    if (ttf_initialized) return true;
    if (!c.TTF_Init()) {
        abi.setErrorFmt("TTF_Init: {s}", .{std.mem.span(c.SDL_GetError())});
        return false;
    }
    ttf_initialized = true;
    return true;
}

fn fontForHandle(handle: u64) ?*Font {
    return registry.get(handle);
}

/// Load a TrueType/OpenType font at `size` points.  Returns 0 on failure.
pub export fn e7_font_load(path: i64, size: i64) callconv(.c) i64 {
    if (size <= 0) return 0;
    const path_bytes = e7StringBytes(path) orelse return 0;
    if (path_bytes.len == 0 or path_bytes.len > 4096) return 0;

    registry_mutex.lock();
    defer registry_mutex.unlock();
    if (!ensureTtfLocked()) return 0;

    const path_z = allocator.dupeZ(u8, path_bytes) catch return 0;
    defer allocator.free(path_z);
    const size_f: f32 = @floatFromInt(size);
    const handle = c.TTF_OpenFont(path_z.ptr, size_f) orelse {
        abi.setErrorFmt("TTF_OpenFont({s}): {s}", .{ path_bytes, std.mem.span(c.SDL_GetError()) });
        return 0;
    };

    const font = allocator.create(Font) catch {
        c.TTF_CloseFont(handle);
        return 0;
    };
    font.* = .{ .handle = handle };
    if (next_handle == 0 or next_handle == std.math.maxInt(u64)) {
        allocator.destroy(font);
        c.TTF_CloseFont(handle);
        return 0;
    }
    const id = next_handle;
    next_handle += 1;
    registry.put(allocator, id, font) catch {
        allocator.destroy(font);
        c.TTF_CloseFont(handle);
        return 0;
    };
    return @intCast(id);
}

pub export fn e7_font_free(handle: i64) callconv(.c) i32 {
    if (handle <= 0) return 1;
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const entry = registry.fetchRemove(@intCast(handle)) orelse return 1;
    const font = entry.value;
    c.TTF_CloseFont(font.handle);
    allocator.destroy(font);
    return 0;
}

/// Measure UTF-8 `text` in `font`.  Returns `(width << 32) | height` in pixels
/// (both zero for an invalid handle); use shifts/masks on the e7 side.
pub export fn e7_text_measure(font_handle: i64, text_value: i64) callconv(.c) i64 {
    if (font_handle <= 0) return 0;
    const text = e7StringBytes(text_value) orelse return 0;
    registry_mutex.lock();
    defer registry_mutex.unlock();
    if (!ensureTtfLocked()) return 0;
    const font = fontForHandle(@intCast(font_handle)) orelse return 0;
    var width: c_int = 0;
    var height: c_int = 0;
    if (!c.TTF_GetStringSize(font.handle, text.ptr, text.len, &width, &height)) return 0;
    const w: u32 = @intCast(@max(width, 0));
    const h: u32 = @intCast(@max(height, 0));
    return (@as(i64, w) << 32) | @as(i64, h);
}

/// Rasterize UTF-8 `text` with `font` into a new RGBA8 image handle.
/// The background is transparent; `r`/`g`/`b` are 0..255 glyph colour.
pub export fn e7_text_image(font_handle: i64, text_value: i64, r: i64, g: i64, b: i64) callconv(.c) i64 {
    if (font_handle <= 0) return 0;
    const text = e7StringBytes(text_value) orelse return 0;
    if (text.len == 0) return 0;
    registry_mutex.lock();
    defer registry_mutex.unlock();
    if (!ensureTtfLocked()) return 0;
    const font = fontForHandle(@intCast(font_handle)) orelse return 0;

    const color = c.SDL_Color{
        .r = @intCast(std.math.clamp(r, 0, 255)),
        .g = @intCast(std.math.clamp(g, 0, 255)),
        .b = @intCast(std.math.clamp(b, 0, 255)),
        .a = 255,
    };
    const surface = c.TTF_RenderText_Blended(font.handle, text.ptr, text.len, color);
    if (surface == null) {
        abi.setErrorFmt("TTF_RenderText_Blended: {s}", .{std.mem.span(c.SDL_GetError())});
        return 0;
    }
    defer c.SDL_DestroySurface(surface);
    if (surface[0].w <= 0 or surface[0].h <= 0) return 0;

    const converted = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_RGBA32);
    if (converted == null) {
        abi.setErrorFmt("SDL_ConvertSurface(RGBA32): {s}", .{std.mem.span(c.SDL_GetError())});
        return 0;
    }
    defer c.SDL_DestroySurface(converted);

    const width: usize = @intCast(converted[0].w);
    const height: usize = @intCast(converted[0].h);
    const byte_count = width * height * 4;
    const pixels = allocator.alloc(u8, byte_count) catch return 0;
    errdefer allocator.free(pixels);

    const source: [*]const u8 = @ptrCast(converted[0].pixels.?);
    const pitch: usize = @intCast(converted[0].pitch);
    for (0..height) |row| {
        @memcpy(pixels[row * width * 4 ..][0 .. width * 4], source[row * pitch ..][0 .. width * 4]);
    }

    const handle = image.registerRgba(@intCast(width), @intCast(height), pixels) orelse return 0;
    return @intCast(handle);
}

pub fn symbols() [4]Symbol {
    return .{
        .{ .name = "e7_font_load", .address = @intFromPtr(&e7_font_load) },
        .{ .name = "e7_font_free", .address = @intFromPtr(&e7_font_free) },
        .{ .name = "e7_text_measure", .address = @intFromPtr(&e7_text_measure) },
        .{ .name = "e7_text_image", .address = @intFromPtr(&e7_text_image) },
    };
}

/// Candidate system fonts used by the headless test (first that exists wins).
pub const test_font_paths = [_][]const u8{
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/TTF/LiberationSans-Regular.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/FreeSans.ttf",
};

fn firstExistingFont() ?[]const u8 {
    for (test_font_paths) |path| {
        std.Io.Dir.cwd().access(io_mod.io(), path, .{}) catch continue;
        return path;
    }
    return null;
}

fn strForTest(bytes: []const u8) i64 {
    return aggregate.e7_str_new(@intCast(@intFromPtr(bytes.ptr)), @intCast(bytes.len));
}

test "font loading, measurement, and text rasterization" {
    const font_path = firstExistingFont() orelse {
        std.debug.print("skipping text test: no system TrueType font found\n", .{});
        return;
    };
    const path_value = strForTest(font_path);

    // Missing fonts fail cleanly.
    const missing = strForTest("/nonexistent/engine7-font.ttf");
    try std.testing.expectEqual(@as(i64, 0), e7_font_load(missing, 24));

    const font = e7_font_load(path_value, 32);
    if (font == 0) {
        std.debug.print("skipping text test: TTF_OpenFont failed ({s})\n", .{abi.lastError()});
        return;
    }

    const hello = "Hello, e7!";
    const hello_value = strForTest(hello);
    const measured = e7_text_measure(font, hello_value);
    try std.testing.expect(measured != 0);
    const width: u32 = @intCast((measured >> 32) & 0xffff_ffff);
    const height: u32 = @intCast(measured & 0xffff_ffff);
    try std.testing.expect(width > 0 and height > 0);

    const text_image = e7_text_image(font, hello_value, 240, 240, 240);
    try std.testing.expect(text_image != 0);
    defer _ = image.e7_image_free(text_image);

    const image_width = image.e7_image_width(text_image);
    const image_height = image.e7_image_height(text_image);
    try std.testing.expect(image_width > 0 and image_height > 0);
    const pixel_str = image.e7_image_pixels(text_image);
    const pixel_len = aggregate.e7_str_len(pixel_str);
    try std.testing.expectEqual(
        @as(i64, image_width * image_height * 4),
        pixel_len,
    );

    // The glyph pixels are opaque somewhere while most of the background stays
    // transparent; both a nonzero alpha count and some clear pixels must exist.
    const pixels: [*]const u8 = @ptrFromInt(@as(usize, @intCast(pixel_str + 8)));
    var opaque_count: usize = 0;
    var transparent: usize = 0;
    var index: usize = 3;
    while (index < @as(usize, @intCast(pixel_len))) : (index += 4) {
        if (pixels[index] > 0) opaque_count += 1 else transparent += 1;
    }
    try std.testing.expect(opaque_count > 0);
    try std.testing.expect(transparent > 0);

    // First free succeeds; a second free / any later use is rejected.
    try std.testing.expectEqual(@as(i32, 0), e7_font_free(font));
    try std.testing.expectEqual(@as(i32, 1), e7_font_free(font));
    try std.testing.expectEqual(@as(i64, 0), e7_text_measure(font, hello_value));
}
