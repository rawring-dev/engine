//! General-purpose C ABI dynamic-library FFI.
//!
//! Generated code can load a shared object (`.so`, `.dylib`, `.dll`), resolve
//! exported symbols by name, call integer/pointer signatures through small
//! trampolines, read or write data symbols, and unload the library.
//!
//! For arbitrary signatures the recommended path is to declare the C function
//! in LLVM IR and resolve it with `Jit.addLibrary`; LLVM then emits a correctly
//! typed call.  The trampolines here are for runtime-discovered functions whose
//! signature is a plain all-integer/all-pointer or all-double C ABI signature.
//! Struct-by-value, varargs, and mixed integer/float signatures need a typed IR
//! declaration.
//!
//! Loading a shared object executes native code with the full privileges of the
//! process.  The runtime does not sandbox this API.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const handles = @import("handles.zig");

const is_windows = builtin.os.tag == .windows;

const win = if (is_windows) @cImport({
    @cInclude("windows.h");
}) else struct {};

pub const Error = error{
    OpenFailed,
    SymbolNotFound,
    OutOfMemory,
    InvalidHandle,
    Unsupported,
};

pub const OpenFlags = packed struct(u32) {
    lazy: bool = true,
    global: bool = false,
    now: bool = false,
    _: u29 = 0,
};

pub const Library = struct {
    handle: *anyopaque,
    path: []u8,
    process: bool = false,
    flags: OpenFlags = .{},

    pub fn open(path: []const u8, flags: OpenFlags) Error!Library {
        const path_copy = std.heap.c_allocator.dupe(u8, path) catch return error.OutOfMemory;
        errdefer std.heap.c_allocator.free(path_copy);

        const path_z = std.heap.c_allocator.dupeZ(u8, path) catch return error.OutOfMemory;
        defer std.heap.c_allocator.free(path_z);

        if (is_windows) {
            const handle = if (path.len == 0)
                win.GetModuleHandleA(null)
            else
                win.LoadLibraryA(path_z.ptr);
            if (handle == null) {
                setWindowsError("LoadLibrary");
                return error.OpenFailed;
            }
            return .{
                .handle = @ptrCast(handle.?),
                .path = path_copy,
                .process = path.len == 0,
                .flags = flags,
            };
        }

        var mode = std.c.RTLD{
            .LAZY = flags.lazy,
            .NOW = flags.now,
            .GLOBAL = flags.global,
        };
        // POSIX requires one of LAZY/NOW; callers commonly pass zero flags.
        if (!mode.LAZY and !mode.NOW) mode.LAZY = true;

        const handle = std.c.dlopen(if (path.len == 0) null else path_z.ptr, mode) orelse {
            setPosixError("dlopen");
            return error.OpenFailed;
        };
        return .{
            .handle = handle,
            .path = path_copy,
            .process = path.len == 0,
            .flags = flags,
        };
    }

    pub fn symbol(self: *Library, name: []const u8) Error!usize {
        const name_z = std.heap.c_allocator.dupeZ(u8, name) catch return error.OutOfMemory;
        defer std.heap.c_allocator.free(name_z);

        if (is_windows) {
            const proc = win.GetProcAddress(@ptrCast(@alignCast(self.handle)), name_z.ptr) orelse {
                setWindowsError("GetProcAddress");
                return error.SymbolNotFound;
            };
            return @intFromPtr(proc);
        }

        _ = std.c.dlerror(); // clear stale diagnostics
        const proc = std.c.dlsym(self.handle, name_z.ptr) orelse {
            setPosixError("dlsym");
            return error.SymbolNotFound;
        };
        return @intFromPtr(proc);
    }

    pub fn close(self: *Library) void {
        if (!self.process) {
            if (is_windows) {
                _ = win.FreeLibrary(@ptrCast(@alignCast(self.handle)));
            } else {
                _ = std.c.dlclose(self.handle);
            }
        }
        if (self.path.len > 0) std.heap.c_allocator.free(self.path);
        self.path = &.{};
    }
};

fn setPosixError(what: []const u8) void {
    if (std.c.dlerror()) |message| {
        abi.setErrorFmt("{s}: {s}", .{ what, std.mem.span(message) });
    } else {
        abi.setErrorFmt("{s} failed", .{what});
    }
}

fn setWindowsError(what: []const u8) void {
    var buffer: [512]u8 = undefined;
    const code = win.GetLastError();
    const n = win.FormatMessageA(
        win.FORMAT_MESSAGE_FROM_SYSTEM | win.FORMAT_MESSAGE_IGNORE_INSERTS,
        null,
        code,
        0,
        &buffer,
        @intCast(buffer.len),
        null,
    );
    if (n > 0) {
        const message = std.mem.trim(u8, buffer[0..@intCast(n)], " \t\r\n");
        abi.setErrorFmt("{s}: {s} (error {d})", .{ what, message, code });
    } else {
        abi.setErrorFmt("{s} failed (error {d})", .{ what, code });
    }
}

// ------------------------------------------------------------ trampolines ----
//
// These are only ABI-correct for signatures consisting entirely of pointer /
// integer (`usize`) arguments or entirely of `double` arguments with the same
// return kind.  Anything else should be a typed LLVM call.

pub fn call0(address: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn () callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))();
}

pub fn call1(address: usize, a0: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0);
}

pub fn call2(address: usize, a0: usize, a1: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, a1);
}

pub fn call3(address: usize, a0: usize, a1: usize, a2: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, usize, usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2);
}

pub fn call4(address: usize, a0: usize, a1: usize, a2: usize, a3: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, usize, usize, usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2, a3);
}

pub fn call5(address: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, usize, usize, usize, usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2, a3, a4);
}

pub fn call6(address: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, usize, usize, usize, usize, usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2, a3, a4, a5);
}

pub fn callF64_0(address: usize) f64 {
    if (address == 0) return 0;
    const Fn = *const fn () callconv(.c) f64;
    return @as(Fn, @ptrFromInt(address))();
}

pub fn callF64_1(address: usize, a0: f64) f64 {
    if (address == 0) return 0;
    const Fn = *const fn (f64) callconv(.c) f64;
    return @as(Fn, @ptrFromInt(address))(a0);
}

pub fn callF64_2(address: usize, a0: f64, a1: f64) f64 {
    if (address == 0) return 0;
    const Fn = *const fn (f64, f64) callconv(.c) f64;
    return @as(Fn, @ptrFromInt(address))(a0, a1);
}

pub fn callF64_3(address: usize, a0: f64, a1: f64, a2: f64) f64 {
    if (address == 0) return 0;
    const Fn = *const fn (f64, f64, f64) callconv(.c) f64;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2);
}

pub fn callF64_4(address: usize, a0: f64, a1: f64, a2: f64, a3: f64) f64 {
    if (address == 0) return 0;
    const Fn = *const fn (f64, f64, f64, f64) callconv(.c) f64;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2, a3);
}

// ------------------------------------------------------------ data access ----

pub fn readBytes(address: usize, destination: []u8) Error!void {
    if (address == 0 and destination.len != 0) return error.SymbolNotFound;
    if (destination.len == 0) return;
    @memcpy(destination, @as([*]const u8, @ptrFromInt(address))[0..destination.len]);
}

pub fn writeBytes(address: usize, source: []const u8) Error!void {
    if (address == 0 and source.len != 0) return error.SymbolNotFound;
    if (source.len == 0) return;
    @memcpy(@as([*]u8, @ptrFromInt(address))[0..source.len], source);
}

pub const Registry = handles.Table(Library);
pub var registry: Registry = .{};

fn cLibraryName() ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => "libc.so.6",
        .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit => "libSystem.B.dylib",
        .windows => "msvcrt.dll",
        else => null,
    };
}

fn mathLibraryName() ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => "libm.so.6",
        .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit => "libSystem.B.dylib",
        .windows => "msvcrt.dll",
        else => null,
    };
}

test "load a system math library and call cos through a trampoline" {
    const name = mathLibraryName() orelse return error.SkipZigTest;
    var library = Library.open(name, .{}) catch |err| {
        std.debug.print("skipping dynamic library test: {s} ({s})\n", .{ @errorName(err), abi.lastError() });
        return;
    };
    defer library.close();

    const address = library.symbol("cos") catch |err| {
        std.debug.print("skipping dynamic symbol test: {s} ({s})\n", .{ @errorName(err), abi.lastError() });
        return;
    };
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), callF64_1(address, 0.0), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), callF64_1(address, std.math.pi / 2.0), 1e-12);
    try std.testing.expectError(error.SymbolNotFound, library.symbol("engine7_no_such_symbol"));
}

test "opening a missing library reports an error" {
    const result = Library.open("engine7-no-such-library.so", .{});
    try std.testing.expectError(error.OpenFailed, result);
}

test "data byte helpers reject a null address and copy bytes" {
    var bytes: [4]u8 = undefined;
    try std.testing.expectError(error.SymbolNotFound, readBytes(0, &bytes));
    try std.testing.expectError(error.SymbolNotFound, writeBytes(0, "x"));

    var source = [_]u8{ 1, 2, 3, 4 };
    var destination = [_]u8{0} ** 4;
    try readBytes(@intFromPtr(&source), &destination);
    try std.testing.expectEqualSlices(u8, &source, &destination);
    try writeBytes(@intFromPtr(&destination), &[_]u8{ 9, 8, 7, 6 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 8, 7, 6 }, &destination);
}

test "resolve and read a C library data symbol" {
    const name = cLibraryName() orelse return error.SkipZigTest;
    var library = Library.open(name, .{}) catch return;
    defer library.close();

    const address = library.symbol("stdout") catch return;
    var stream_pointer: usize = 0;
    try readBytes(address, std.mem.asBytes(&stream_pointer));
    try std.testing.expect(stream_pointer != 0);
}

test "the process handle resolves libc symbols" {
    if (is_windows) return;
    var library = Library.open("", .{}) catch return;
    defer library.close();

    const address = library.symbol("getpid") catch return;
    try std.testing.expect(call0(address) > 0);
    try std.testing.expect(library.process);
}

pub fn call7(address: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, usize, usize, usize, usize, usize, usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2, a3, a4, a5, a6);
}

pub fn call8(address: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize, a7: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, usize, usize, usize, usize, usize, usize, usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2, a3, a4, a5, a6, a7);
}

pub fn call9(address: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize, a7: usize, a8: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2, a3, a4, a5, a6, a7, a8);
}

pub fn call10(address: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize, a7: usize, a8: usize, a9: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9);
}

pub fn call11(address: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize, a7: usize, a8: usize, a9: usize, a10: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10);
}

pub fn call12(address: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize, a7: usize, a8: usize, a9: usize, a10: usize, a11: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11);
}

pub fn call13(address: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize, a7: usize, a8: usize, a9: usize, a10: usize, a11: usize, a12: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12);
}

pub fn call14(address: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize, a7: usize, a8: usize, a9: usize, a10: usize, a11: usize, a12: usize, a13: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13);
}

pub fn call15(address: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize, a7: usize, a8: usize, a9: usize, a10: usize, a11: usize, a12: usize, a13: usize, a14: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14);
}

pub fn call16(address: usize, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize, a7: usize, a8: usize, a9: usize, a10: usize, a11: usize, a12: usize, a13: usize, a14: usize, a15: usize) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15);
}

/// Call a C function whose second argument is a 32-bit float.  e7 passes floats
/// as f64 bits; this converts before entering C.
pub fn callF32_2(address: usize, a0: usize, value: f64) usize {
    if (address == 0) return 0;
    const Fn = *const fn (usize, f32) callconv(.c) usize;
    return @as(Fn, @ptrFromInt(address))(a0, @floatCast(value));
}
