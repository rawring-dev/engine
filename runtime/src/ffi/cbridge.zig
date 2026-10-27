//! Generic C FFI bridge callable from e7 source.
//!
//! e7 has no extern-declaration syntax, so platform libraries bind symbols with
//! `e7_cffi_bind(library: str, symbol: str)` and invoke the returned address
//! through `e7_ffi_callN`.  Binding is cached by (library, symbol); the library
//! is loaded once and stays loaded for the process lifetime.
//!
//! The wrappers pass all arguments as 64-bit slots.  This matches the engine's
//! integer-scaled ABI and lets e7 strings/aggregates be forwarded as opaque
//! handles when the callee understands the runtime aggregate layout.

const std = @import("std");
const abi = @import("abi.zig");
const dl = @import("dl.zig");
const io_mod = @import("io.zig");

const Symbol = abi.Symbol;

fn e7StringBytes(value: i64) ?[]const u8 {
    if (value == 0) return null;
    const len = @as([*]const i64, @ptrFromInt(@as(usize, @intCast(value))))[0];
    if (len < 0) return null;
    if (len == 0) return &.{};
    const bytes: [*]const u8 = @ptrFromInt(@as(usize, @intCast(value + 8)));
    return bytes[0..@intCast(len)];
}

const BindLibrary = struct {
    library: dl.Library,
    symbols: std.StringHashMapUnmanaged(usize) = .empty,
};

var bind_mutex: io_mod.Mutex = .{};
var bind_libraries: std.StringHashMapUnmanaged(*BindLibrary) = .empty;

fn adoptBindLibrary(library: dl.Library) ?*BindLibrary {
    const allocator = std.heap.c_allocator;
    const entry = allocator.create(BindLibrary) catch {
        var copy = library;
        copy.close();
        return null;
    };
    entry.* = .{ .library = library };
    return entry;
}

fn openBindCandidate(directory: ?[]const u8, candidate: []const u8) ?*BindLibrary {
    const allocator = std.heap.c_allocator;
    if (directory) |dir| {
        const joined = std.fs.path.join(allocator, &.{ dir, candidate }) catch null;
        if (joined) |path| {
            defer allocator.free(path);
            if (dl.Library.open(path, .{})) |library| return adoptBindLibrary(library) else |_| {}
        }
    }
    if (dl.Library.open(candidate, .{})) |library| return adoptBindLibrary(library) else |_| {}
    return null;
}

fn bindLibrary(name: []const u8) ?*BindLibrary {
    if (name.len == 0) {
        const library = dl.Library.open("", .{}) catch return null;
        return adoptBindLibrary(library);
    }

    const allocator = std.heap.c_allocator;
    var exe_dir: ?[]u8 = null;
    defer if (exe_dir) |dir| allocator.free(dir);

    if (std.mem.indexOfAny(u8, name, "/\\") == null) {
        if (std.process.executableDirPathAlloc(io_mod.io(), allocator)) |dir_z| {
            defer allocator.free(dir_z);
            exe_dir = allocator.dupe(u8, dir_z) catch null;
        } else |_| {}
    }

    if (exe_dir) |dir| {
        if (std.fs.path.join(allocator, &.{ dir, name })) |path| {
            defer allocator.free(path);
            if (dl.Library.open(path, .{})) |library| return adoptBindLibrary(library) else |_| {}
        } else |_| {}
    }
    if (dl.Library.open(name, .{})) |library| return adoptBindLibrary(library) else |_| {}

    const suffixes = [_][]const u8{ ".so", ".dylib", ".dll" };
    const prefixes = [_][]const u8{ "lib", "" };
    for (prefixes) |prefix| {
        for (suffixes) |suffix| {
            const candidate = std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, name, suffix }) catch continue;
            defer allocator.free(candidate);
            if (openBindCandidate(exe_dir, candidate)) |entry| return entry;
        }
    }
    return null;
}

/// Resolve `symbol` in `library` once and cache the address.  A bare library
/// name is searched next to the executable first, then through the platform
/// loader; an empty name means the current process.
pub export fn e7_cffi_bind(library: i64, symbol: i64) callconv(.c) i64 {
    abi.clearError();
    const lib_name = e7StringBytes(library) orelse {
        abi.setError("e7_cffi_bind: invalid library string");
        return 0;
    };
    const sym_name = e7StringBytes(symbol) orelse {
        abi.setError("e7_cffi_bind: invalid symbol string");
        return 0;
    };

    bind_mutex.lock();
    defer bind_mutex.unlock();

    const entry = bind_libraries.get(lib_name) orelse create: {
        const created = bindLibrary(lib_name) orelse {
            abi.setErrorFmt("e7_cffi_bind: cannot load library '{s}'", .{lib_name});
            return 0;
        };
        const key = std.heap.c_allocator.dupe(u8, lib_name) catch {
            var copy = created.library;
            copy.close();
            std.heap.c_allocator.destroy(created);
            abi.setError("e7_cffi_bind: out of memory");
            return 0;
        };
        bind_libraries.put(std.heap.c_allocator, key, created) catch {
            std.heap.c_allocator.free(key);
            var copy = created.library;
            copy.close();
            std.heap.c_allocator.destroy(created);
            abi.setError("e7_cffi_bind: out of memory");
            return 0;
        };
        break :create created;
    };

    if (entry.symbols.get(sym_name)) |address| return @intCast(address);
    const address = entry.library.symbol(sym_name) catch |err| {
        abi.setErrorFmt("e7_cffi_bind: {s} in '{s}': {s}", .{ sym_name, lib_name, @errorName(err) });
        return 0;
    };
    const key = std.heap.c_allocator.dupe(u8, sym_name) catch return @intCast(address);
    entry.symbols.put(std.heap.c_allocator, key, address) catch {
        std.heap.c_allocator.free(key);
    };
    return @intCast(address);
}

pub fn call0(address: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call0(@intCast(address));
}
pub fn call1(address: u64, a0: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call1(@intCast(address), @intCast(a0));
}
pub fn call2(address: u64, a0: u64, a1: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call2(@intCast(address), @intCast(a0), @intCast(a1));
}
pub fn call3(address: u64, a0: u64, a1: u64, a2: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call3(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2));
}
pub fn call4(address: u64, a0: u64, a1: u64, a2: u64, a3: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call4(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3));
}
pub fn call5(address: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call5(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3), @intCast(a4));
}
pub fn call6(address: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call6(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3), @intCast(a4), @intCast(a5));
}
pub fn call7(address: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call7(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3), @intCast(a4), @intCast(a5), @intCast(a6));
}
pub fn callF32_2(address: u64, a0: u64, value: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.callF32_2(@intCast(address), @intCast(a0), @bitCast(value));
}

pub fn call8(address: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64, a7: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call8(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3), @intCast(a4), @intCast(a5), @intCast(a6), @intCast(a7));
}
pub fn call9(address: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64, a7: u64, a8: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call9(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3), @intCast(a4), @intCast(a5), @intCast(a6), @intCast(a7), @intCast(a8));
}
pub fn call10(address: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64, a7: u64, a8: u64, a9: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call10(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3), @intCast(a4), @intCast(a5), @intCast(a6), @intCast(a7), @intCast(a8), @intCast(a9));
}
pub fn call11(address: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64, a7: u64, a8: u64, a9: u64, a10: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call11(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3), @intCast(a4), @intCast(a5), @intCast(a6), @intCast(a7), @intCast(a8), @intCast(a9), @intCast(a10));
}
pub fn call12(address: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64, a7: u64, a8: u64, a9: u64, a10: u64, a11: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call12(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3), @intCast(a4), @intCast(a5), @intCast(a6), @intCast(a7), @intCast(a8), @intCast(a9), @intCast(a10), @intCast(a11));
}
pub fn call13(address: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64, a7: u64, a8: u64, a9: u64, a10: u64, a11: u64, a12: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call13(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3), @intCast(a4), @intCast(a5), @intCast(a6), @intCast(a7), @intCast(a8), @intCast(a9), @intCast(a10), @intCast(a11), @intCast(a12));
}
pub fn call14(address: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64, a7: u64, a8: u64, a9: u64, a10: u64, a11: u64, a12: u64, a13: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call14(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3), @intCast(a4), @intCast(a5), @intCast(a6), @intCast(a7), @intCast(a8), @intCast(a9), @intCast(a10), @intCast(a11), @intCast(a12), @intCast(a13));
}
pub fn call15(address: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64, a7: u64, a8: u64, a9: u64, a10: u64, a11: u64, a12: u64, a13: u64, a14: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call15(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3), @intCast(a4), @intCast(a5), @intCast(a6), @intCast(a7), @intCast(a8), @intCast(a9), @intCast(a10), @intCast(a11), @intCast(a12), @intCast(a13), @intCast(a14));
}
pub fn call16(address: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64, a6: u64, a7: u64, a8: u64, a9: u64, a10: u64, a11: u64, a12: u64, a13: u64, a14: u64, a15: u64) callconv(.c) u64 {
    abi.clearError();
    return dl.call16(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3), @intCast(a4), @intCast(a5), @intCast(a6), @intCast(a7), @intCast(a8), @intCast(a9), @intCast(a10), @intCast(a11), @intCast(a12), @intCast(a13), @intCast(a14), @intCast(a15));
}

const names = [_][]const u8{
    "e7_cffi_bind",
    "e7_ffi_call0",
    "e7_ffi_call1",
    "e7_ffi_call2",
    "e7_ffi_call3",
    "e7_ffi_call4",
    "e7_ffi_call5",
    "e7_ffi_call6",
    "e7_ffi_call7",
    "e7_ffi_call_f32_2",
    "e7_ffi_call8",
    "e7_ffi_call9",
    "e7_ffi_call10",
    "e7_ffi_call11",
    "e7_ffi_call12",
    "e7_ffi_call13",
    "e7_ffi_call14",
    "e7_ffi_call15",
    "e7_ffi_call16",
};

pub fn symbols() [names.len]Symbol {
    return .{
        .{ .name = "e7_cffi_bind", .address = @intFromPtr(&e7_cffi_bind) },
        .{ .name = "e7_ffi_call0", .address = @intFromPtr(&call0) },
        .{ .name = "e7_ffi_call1", .address = @intFromPtr(&call1) },
        .{ .name = "e7_ffi_call2", .address = @intFromPtr(&call2) },
        .{ .name = "e7_ffi_call3", .address = @intFromPtr(&call3) },
        .{ .name = "e7_ffi_call4", .address = @intFromPtr(&call4) },
        .{ .name = "e7_ffi_call5", .address = @intFromPtr(&call5) },
        .{ .name = "e7_ffi_call6", .address = @intFromPtr(&call6) },
        .{ .name = "e7_ffi_call7", .address = @intFromPtr(&call7) },
        .{ .name = "e7_ffi_call_f32_2", .address = @intFromPtr(&callF32_2) },
        .{ .name = "e7_ffi_call8", .address = @intFromPtr(&call8) },
        .{ .name = "e7_ffi_call9", .address = @intFromPtr(&call9) },
        .{ .name = "e7_ffi_call10", .address = @intFromPtr(&call10) },
        .{ .name = "e7_ffi_call11", .address = @intFromPtr(&call11) },
        .{ .name = "e7_ffi_call12", .address = @intFromPtr(&call12) },
        .{ .name = "e7_ffi_call13", .address = @intFromPtr(&call13) },
        .{ .name = "e7_ffi_call14", .address = @intFromPtr(&call14) },
        .{ .name = "e7_ffi_call15", .address = @intFromPtr(&call15) },
        .{ .name = "e7_ffi_call16", .address = @intFromPtr(&call16) },
    };
}
