//! Native PTY transport and compile staging. Editor policy belongs to e7.
const std = @import("std");
const aggregate = @import("aggregate.zig");
const image = @import("image.zig");
const Symbol = @import("ffi/abi.zig").Symbol;
const c = @cImport({
    @cInclude("SDL3/SDL.h");
});
extern fn e7_terminal_alive() c_int;
extern fn e7_terminal_open([*:0]const u8) c_int;
extern fn e7_terminal_close() void;
extern fn e7_terminal_focus(c_int) void;
extern fn e7_terminal_input([*]const u8, usize) void;
extern fn e7_terminal_resize(c_int, c_int) void;
extern fn e7_terminal_event(?*const anyopaque) void;
extern fn e7_terminal_frame() ?*c.SDL_Surface;
extern fn e7_terminal_status() [*:0]const u8;
extern fn e7_terminal_saved() c_long;
extern fn e7_terminal_text([*]u8, usize) usize;

pub var initial_file: []const u8 = "";
pub var apply_callback: ?*const fn () bool = null;
pub var check_callback: ?*const fn () bool = null;
pub var diagnostic: []const u8 = "Reload is available in editor-run";
pub fn close() void {
    e7_terminal_close();
}
fn bytes(value: i64) []const u8 {
    const n = aggregate.e7_str_len(value);
    if (n <= 0) return "";
    return @as([*]const u8, @ptrFromInt(@as(usize, @intCast(value + 8))))[0..@intCast(n)];
}
fn string(value: []const u8) i64 {
    return aggregate.e7_str_new(@intCast(@intFromPtr(value.ptr)), @intCast(value.len));
}
pub export fn e7_editor_open(path: i64) callconv(.c) i64 {
    const name = bytes(path);
    if (std.mem.indexOfScalar(u8, name, 0) != null) return -1;
    const z = std.heap.c_allocator.dupeZ(u8, name) catch return -1;
    defer std.heap.c_allocator.free(z);
    return e7_terminal_open(z);
}
pub export fn e7_editor_input(text: i64) callconv(.c) void {
    const b = bytes(text);
    e7_terminal_input(b.ptr, b.len);
}
pub export fn e7_editor_focus(value: i64) callconv(.c) void {
    e7_terminal_focus(@intFromBool(value != 0));
}
pub export fn e7_editor_event(event: i64) callconv(.c) void {
    if (event != 0) e7_terminal_event(@ptrFromInt(@as(usize, @intCast(event))));
}
pub export fn e7_editor_resize(w: i64, h: i64) callconv(.c) void {
    e7_terminal_resize(@intCast(std.math.clamp(w, 96, 1920)), @intCast(std.math.clamp(h, 68, 1700)));
}
pub export fn e7_editor_image() callconv(.c) i64 {
    const surface = e7_terminal_frame() orelse return 0;
    return image.e7_image_from_argb(@intCast(@intFromPtr(surface.pixels)), surface.w, surface.h, surface.pitch);
}
pub export fn e7_editor_status() callconv(.c) i64 {
    return string(std.mem.span(e7_terminal_status()));
}
pub export fn e7_editor_check() callconv(.c) i64 {
    return if (check_callback) |check| @intFromBool(check()) else 0;
}
pub export fn e7_editor_diagnostic() callconv(.c) i64 {
    return string(diagnostic);
}
pub export fn e7_editor_saved() callconv(.c) i64 {
    return e7_terminal_saved();
}
pub export fn e7_editor_initial_file() callconv(.c) i64 {
    return string(initial_file);
}
pub export fn e7_editor_alive() callconv(.c) i64 {
    return e7_terminal_alive();
}
pub export fn e7_editor_apply() callconv(.c) i64 {
    return if (apply_callback) |apply| @intFromBool(apply()) else 0;
}
pub fn symbols() [13]Symbol {
    return .{
        .{ .name = "e7_editor_apply", .address = @intFromPtr(&e7_editor_apply) },
        .{ .name = "e7_editor_initial_file", .address = @intFromPtr(&e7_editor_initial_file) },
        .{ .name = "e7_editor_alive", .address = @intFromPtr(&e7_editor_alive) },
        .{ .name = "e7_editor_saved", .address = @intFromPtr(&e7_editor_saved) },
        .{ .name = "e7_editor_open", .address = @intFromPtr(&e7_editor_open) },
        .{ .name = "e7_editor_input", .address = @intFromPtr(&e7_editor_input) },
        .{ .name = "e7_editor_focus", .address = @intFromPtr(&e7_editor_focus) },
        .{ .name = "e7_editor_event", .address = @intFromPtr(&e7_editor_event) },
        .{ .name = "e7_editor_resize", .address = @intFromPtr(&e7_editor_resize) },
        .{ .name = "e7_editor_image", .address = @intFromPtr(&e7_editor_image) },
        .{ .name = "e7_editor_status", .address = @intFromPtr(&e7_editor_status) },
        .{ .name = "e7_editor_check", .address = @intFromPtr(&e7_editor_check) },
        .{ .name = "e7_editor_diagnostic", .address = @intFromPtr(&e7_editor_diagnostic) },
    };
}

test "embedded Neovim loads e7 syntax, edits and saves through the PTY" {
    const io = @import("ffi/io.zig").io();
    const path = ".zig-cache/embedded-editor-test.e7";
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    try file.writeStreamingAll(io, "pub sample <- () -> i64 = 7\n");
    file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer close();
    try std.testing.expectEqual(@as(c_int, 0), e7_terminal_open(path));
    e7_terminal_resize(640, 340);
    var buffer: [32768]u8 = undefined;
    var found = false;
    for (0..200) |_| {
        _ = e7_terminal_frame();
        const n = e7_terminal_text(&buffer, buffer.len);
        if (std.mem.indexOf(u8, buffer[0..n], "pub sample") != null) {
            found = true;
            break;
        }
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(found);
    const generation = e7_terminal_saved();
    const input = "\x1b:call setline(1, '# edited in embedded Neovim ' . &filetype . ':' . &shiftwidth . ':' . exists('b:current_syntax'))\r:w\r";
    e7_terminal_input(input, input.len);
    var saved = false;
    for (0..100) |_| {
        _ = e7_terminal_frame();
        const content = try std.Io.Dir.cwd().readFileAlloc(io, path, std.testing.allocator, .limited(4096));
        saved = std.mem.startsWith(u8, content, "# edited in embedded Neovim engine7:4:1");
        std.testing.allocator.free(content);
        if (saved) break;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(saved);
    for (0..100) |_| {
        _ = e7_terminal_frame();
        if (e7_terminal_saved() > generation) break;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(e7_terminal_saved() > generation);
}
