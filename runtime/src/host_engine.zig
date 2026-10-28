//! SDL/Vulkan-free engine host helpers still required by e7.
//!
//! SDL windows and the Vulkan scene renderer are owned by e7 platform code,
//! which binds those libraries dynamically through the generic C FFI.  The
//! runtime keeps only the helpers that must run natively: a monotonic clock,
//! raw shader/asset file loading, and cwd-relative directory listing.  They
//! are registered with the JIT by `orc.Jit.addBytecode` and reached from e7
//! through the `host::*` native methods (compiler/src/native_methods.zig).

const std = @import("std");
const abi = @import("ffi/abi.zig");
const aggregate = @import("aggregate.zig");
const time_mod = @import("ffi/time.zig");
const io_mod = @import("ffi/io.zig");

const Symbol = abi.Symbol;

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

const DirEntry = struct {
    name: []u8,
    directory: bool,
};

fn entryLessThan(_: void, a: DirEntry, b: DirEntry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// List a cwd-relative directory in the same line format as the runtime
/// filesystem sandbox: one entry name per line, directories suffixed with `/`.
/// Entries are sorted by name so scans are deterministic.  The export returns
/// 0 for a missing or unreadable directory, which e7 treats as an empty
/// listing and keeps asset scans resilient to missing roots.
fn listDir(path: []const u8) ![]u8 {
    asset_mutex.lock();
    defer asset_mutex.unlock();
    if (asset_threaded == null) {
        asset_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    }
    const io = asset_threaded.?.io();
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const directory_path = if (trimmed.len == 0) "." else trimmed;
    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true });
    defer directory.close(io);

    var entries = std.ArrayList(DirEntry).empty;
    defer {
        for (entries.items) |entry| std.heap.c_allocator.free(entry.name);
        entries.deinit(std.heap.c_allocator);
    }
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        const name = std.heap.c_allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
        entries.append(std.heap.c_allocator, .{
            .name = name,
            .directory = entry.kind == .directory,
        }) catch {
            std.heap.c_allocator.free(name);
            return error.OutOfMemory;
        };
    }
    std.mem.sort(DirEntry, entries.items, {}, entryLessThan);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(std.heap.c_allocator);
    for (entries.items) |entry| {
        out.appendSlice(std.heap.c_allocator, entry.name) catch return error.OutOfMemory;
        if (entry.directory) out.append(std.heap.c_allocator, '/') catch return error.OutOfMemory;
        out.append(std.heap.c_allocator, '\n') catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(std.heap.c_allocator);
}

fn stringSlice(value: i64) []const u8 {
    const length = aggregate.e7_str_len(value);
    if (length <= 0) return &.{};
    const data: [*]const u8 = @ptrFromInt(@as(usize, @intCast(value + 8)));
    return data[0..@intCast(length)];
}

pub export fn e7_engine_time_now_ms() callconv(.c) i64 {
    return @intCast(time_mod.nowNs() / std.time.ns_per_ms);
}

/// Load a shader/asset file and return it as an e7 `str` aggregate.  The e7
/// engine owns the decision of which files to load and passes the resulting
/// SPIR-V strings to its e7-side scene module.
pub export fn e7_engine_read_shader(path: i64) callconv(.c) i64 {
    const text = stringSlice(path);
    const data = readAsset(text) catch return 0;
    defer std.heap.c_allocator.free(data);
    return aggregate.e7_str_new(@intCast(@intFromPtr(data.ptr)), @intCast(data.len));
}

/// List a cwd-relative directory as an e7 `str` in the runtime filesystem list
/// format (one name per line, directories suffixed with `/`).  Returns 0 when
/// the directory is missing or unreadable, which e7 treats as an empty listing.
pub export fn e7_engine_list_dir(path: i64) callconv(.c) i64 {
    const text = stringSlice(path);
    const listing = listDir(text) catch return 0;
    defer std.heap.c_allocator.free(listing);
    return aggregate.e7_str_new(@intCast(@intFromPtr(listing.ptr)), @intCast(listing.len));
}

pub fn symbols() [3]Symbol {
    return .{
        .{ .name = "e7_engine_time_now_ms", .address = @intFromPtr(&e7_engine_time_now_ms) },
        .{ .name = "e7_engine_read_shader", .address = @intFromPtr(&e7_engine_read_shader) },
        .{ .name = "e7_engine_list_dir", .address = @intFromPtr(&e7_engine_list_dir) },
    };
}
