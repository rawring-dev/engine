//! Low-level image loading for the e7 engine.
//!
//! `e7_image_load(path)` decodes a PNG or JPEG file (sniffed by magic bytes)
//! into tightly packed, top-down RGBA8 pixels and returns an opaque handle.
//! The e7 side wraps the handle in an `Image` value; all higher-level policy
//! (which assets to load, when to free them) lives in `engine/assets.e7`.
//!
//! PNG uses libpng's simplified `png_image` memory API.  JPEG uses libjpeg-turbo
//! (`tjDecompress*`), which reports errors as return codes instead of calling
//! `exit` through libjpeg's default error manager.
//!
//! ## Exported ABI (all pointers are e7 aggregate values / i64 addresses)
//!
//! ```text
//! e7_image_load(path: str)     -> u64 handle, 0 on failure
//! e7_image_width(handle)       -> i64, 0 for invalid handles
//! e7_image_height(handle)      -> i64
//! e7_image_pixels(handle)      -> str view of width*height*4 RGBA bytes
//! e7_image_free(handle)        -> i32, 0 on success
//! ```
//!
//! Pixels are copied into the returned `str`, so the e7 value is independent of
//! the image handle's lifetime.  Handles are monotonically increasing and
//! validated on every call.

const std = @import("std");
const aggregate = @import("aggregate.zig");
const io_mod = @import("ffi/io.zig");
const Symbol = @import("intrinsics.zig").Symbol;

const c = @cImport({
    @cInclude("png.h");
    @cInclude("turbojpeg.h");
});

/// Decoded image owned by the handle registry.
pub const Image = struct {
    width: u32,
    height: u32,
    /// Tightly packed, top-down RGBA8, length = width*height*4.
    pixels: []u8,
};

var registry_mutex: io_mod.Mutex = .{};
var registry: std.AutoHashMapUnmanaged(u64, *Image) = .empty;
var next_handle: u64 = 1;

fn allocator() std.mem.Allocator {
    return std.heap.c_allocator;
}

fn e7StringBytes(str: i64) ?[]const u8 {
    if (str == 0) return null;
    const len = @as([*]const i64, @ptrFromInt(@as(usize, @intCast(str))))[0];
    if (len < 0) return null;
    if (len == 0) return &.{};
    const bytes: [*]const u8 = @ptrFromInt(@as(usize, @intCast(str + 8)));
    return bytes[0..@intCast(len)];
}

fn readFile(path: []const u8) ?[]u8 {
    return std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io_mod.io(),
        path,
        allocator(),
        .limited(64 * 1024 * 1024),
    ) catch null;
}

fn decodePng(bytes: []const u8) ?Image {
    var image: c.png_image = std.mem.zeroes(c.png_image);
    image.version = c.PNG_IMAGE_VERSION;
    if (c.png_image_begin_read_from_memory(
        &image,
        @ptrCast(bytes.ptr),
        bytes.len,
    ) == 0) return null;
    defer c.png_image_free(&image);

    if (image.width == 0 or image.height == 0) return null;
    image.format = c.PNG_FORMAT_RGBA;
    const width: usize = @intCast(image.width);
    const height: usize = @intCast(image.height);
    const byte_count = std.math.mul(usize, width, height) catch return null;
    const pixel_count = std.math.mul(usize, byte_count, 4) catch return null;
    const pixels = allocator().alloc(u8, pixel_count) catch return null;
    const ok = c.png_image_finish_read(&image, null, pixels.ptr, 0, null);
    if (ok == 0) {
        allocator().free(pixels);
        return null;
    }
    return .{
        .width = image.width,
        .height = image.height,
        .pixels = pixels,
    };
}

fn decodeJpeg(bytes: []const u8) ?Image {
    if (bytes.len < 4) return null;
    const decompressor = c.tjInitDecompress() orelse return null;
    defer _ = c.tjDestroy(decompressor);

    var width: c_int = 0;
    var height: c_int = 0;
    var subsampling: c_int = 0;
    var colorspace: c_int = 0;
    if (c.tjDecompressHeader3(
        decompressor,
        @ptrCast(bytes.ptr),
        @intCast(bytes.len),
        &width,
        &height,
        &subsampling,
        &colorspace,
    ) != 0) return null;
    if (width <= 0 or height <= 0) return null;

    const pixel_count = std.math.mul(
        usize,
        @intCast(width),
        std.math.mul(usize, @intCast(height), 4) catch return null,
    ) catch return null;
    const pixels = allocator().alloc(u8, pixel_count) catch return null;
    if (c.tjDecompress2(
        decompressor,
        @ptrCast(bytes.ptr),
        @intCast(bytes.len),
        pixels.ptr,
        width,
        0,
        height,
        c.TJPF_RGBA,
        0,
    ) != 0) {
        allocator().free(pixels);
        return null;
    }
    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .pixels = pixels,
    };
}

fn decodeImage(bytes: []const u8) ?Image {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) {
        return decodePng(bytes);
    }
    if (bytes.len >= 2 and bytes[0] == 0xff and bytes[1] == 0xd8) {
        return decodeJpeg(bytes);
    }
    // Unknown container: try PNG first, then JPEG, so extension-less assets work.
    if (decodePng(bytes)) |image| return image;
    return decodeJpeg(bytes);
}

fn imageForHandle(handle: u64) ?*Image {
    return registry.get(handle);
}

pub export fn e7_image_load(path: i64) callconv(.c) i64 {
    const path_bytes = e7StringBytes(path) orelse return 0;
    if (path_bytes.len == 0) return 0;
    const bytes = readFile(path_bytes) orelse return 0;
    defer allocator().free(bytes);

    const decoded = decodeImage(bytes) orelse return 0;
    const image = allocator().create(Image) catch {
        allocator().free(decoded.pixels);
        return 0;
    };
    image.* = decoded;

    registry_mutex.lock();
    defer registry_mutex.unlock();
    if (next_handle == 0 or next_handle == std.math.maxInt(u64)) {
        const pixels = image.pixels;
        allocator().destroy(image);
        allocator().free(pixels);
        return 0;
    }
    const handle = next_handle;
    next_handle += 1;
    registry.put(allocator(), handle, image) catch {
        const pixels = image.pixels;
        allocator().destroy(image);
        allocator().free(pixels);
        return 0;
    };
    return @intCast(handle);
}

pub export fn e7_image_width(handle: i64) callconv(.c) i64 {
    if (handle <= 0) return 0;
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const image = imageForHandle(@intCast(handle)) orelse return 0;
    return @intCast(image.width);
}

pub export fn e7_image_height(handle: i64) callconv(.c) i64 {
    if (handle <= 0) return 0;
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const image = imageForHandle(@intCast(handle)) orelse return 0;
    return @intCast(image.height);
}

/// Pixel data as an e7 `str` aggregate (a copy of the RGBA8 bytes).
pub export fn e7_image_pixels(handle: i64) callconv(.c) i64 {
    if (handle <= 0) return 0;
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const image = imageForHandle(@intCast(handle)) orelse return 0;
    return aggregate.e7_str_new(
        @intCast(@intFromPtr(image.pixels.ptr)),
        @intCast(image.pixels.len),
    );
}

pub export fn e7_image_free(handle: i64) callconv(.c) i32 {
    if (handle <= 0) return 1;
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const entry = registry.fetchRemove(@intCast(handle)) orelse return 1;
    const image = entry.value;
    allocator().free(image.pixels);
    allocator().destroy(image);
    return 0;
}

pub fn symbols() [5]Symbol {
    return .{
        .{ .name = "e7_image_load", .address = @intFromPtr(&e7_image_load) },
        .{ .name = "e7_image_width", .address = @intFromPtr(&e7_image_width) },
        .{ .name = "e7_image_height", .address = @intFromPtr(&e7_image_height) },
        .{ .name = "e7_image_pixels", .address = @intFromPtr(&e7_image_pixels) },
        .{ .name = "e7_image_free", .address = @intFromPtr(&e7_image_free) },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn loadFixture(
    dir: std.Io.Dir,
    io: std.Io,
    sub_path: []const u8,
    data: []const u8,
) !i64 {
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
    const absolute = try dir.realPathFileAlloc(io, sub_path, allocator());
    defer allocator().free(absolute);
    const path = aggregate.e7_str_new(
        @intCast(@intFromPtr(absolute.ptr)),
        @intCast(absolute.len),
    );
    return e7_image_load(path);
}

test "loads the checked-in PNG and exposes RGBA pixels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const handle = try loadFixture(
        tmp.dir,
        std.testing.io,
        "cube.png",
        @embedFile("testdata/cube.png"),
    );
    try std.testing.expect(handle != 0);
    defer _ = e7_image_free(handle);

    try std.testing.expectEqual(@as(i64, 2), e7_image_width(handle));
    try std.testing.expectEqual(@as(i64, 2), e7_image_height(handle));

    const pixels = e7_image_pixels(handle);
    try std.testing.expect(pixels != 0);
    try std.testing.expectEqual(@as(i64, 16), aggregate.e7_str_len(pixels));
    const bytes: [*]const u8 = @ptrFromInt(@as(usize, @intCast(pixels + 8)));
    // Generated fixture: red, green, blue, translucent white (top-left to
    // bottom-right, row-major).
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, bytes[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, bytes[8..12]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 128 }, bytes[12..16]);

    try std.testing.expectEqual(@as(i32, 0), e7_image_free(handle));
    try std.testing.expectEqual(@as(i64, 0), e7_image_width(handle));
}

test "loads the checked-in JPEG fixture" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const handle = try loadFixture(
        tmp.dir,
        std.testing.io,
        "cube.jpg",
        @embedFile("testdata/cube.jpg"),
    );
    try std.testing.expect(handle != 0);
    defer _ = e7_image_free(handle);
    try std.testing.expectEqual(@as(i64, 2), e7_image_width(handle));
    try std.testing.expectEqual(@as(i64, 2), e7_image_height(handle));
    try std.testing.expectEqual(@as(i64, 16), aggregate.e7_str_len(e7_image_pixels(handle)));
}

test "invalid image handles and missing files are rejected" {
    try std.testing.expectEqual(@as(i64, 0), e7_image_width(0));
    try std.testing.expectEqual(@as(i64, 0), e7_image_height(-5));
    try std.testing.expectEqual(@as(i64, 0), e7_image_pixels(0));
    try std.testing.expectEqual(@as(i32, 1), e7_image_free(0));
    try std.testing.expectEqual(@as(i32, 1), e7_image_free(12345));

    const missing_path = "engine/assets/testdata/does-not-exist.png";
    const missing = aggregate.e7_str_new(
        @intCast(@intFromPtr(missing_path.ptr)),
        missing_path.len,
    );
    try std.testing.expectEqual(@as(i64, 0), e7_image_load(missing));
    try std.testing.expectEqual(@as(i64, 0), e7_image_load(0));
}
