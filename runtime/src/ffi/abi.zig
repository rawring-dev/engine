//! Stable C ABI vocabulary shared by runtime intrinsics and JITed modules.
//!
//! Most exported `e7_*` functions return a `Status` as `i32`; constructors
//! return an opaque `u64` handle (`0` on failure).  Functions that produce
//! bytes write a malloc-owned pointer and length through out-parameters; the
//! caller releases them with `e7_free`.

const std = @import("std");

/// A host address exposed to JITed modules under a stable symbol name.
pub const Symbol = struct {
    name: []const u8,
    address: usize,
    callable: bool = true,
};

pub const Status = enum(i32) {
    ok = 0,
    invalid_argument = 1,
    out_of_memory = 2,
    not_found = 3,
    permission_denied = 4,
    io_error = 5,
    timeout = 6,
    closed = 7,
    unsupported = 8,
    busy = 9,
    would_block = 10,
    not_ready = 11,
    denied = 12,
    network = 13,
    protocol = 14,
    internal = 15,
    _,
};

pub fn code(status: Status) i32 {
    return @intFromEnum(status);
}

threadlocal var error_buffer: [1024]u8 = undefined;
threadlocal var error_len: usize = 0;

/// Record a diagnostic for the current thread.  The slice is copied.
pub fn setError(message: []const u8) void {
    const n = @min(message.len, error_buffer.len);
    @memcpy(error_buffer[0..n], message[0..n]);
    error_len = n;
}

pub fn setErrorFmt(comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&error_buffer, fmt, args) catch {
        error_len = 0;
        return;
    };
    error_len = text.len;
}

pub fn clearError() void {
    error_len = 0;
}

/// Pointer and length of the current thread's last diagnostic.  Valid until
/// the next runtime FFI call on the same thread; callers must copy the bytes.
pub fn lastError() []const u8 {
    return error_buffer[0..error_len];
}

/// Map common Zig errors onto the stable status vocabulary.
pub fn fromError(err: anyerror) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.FileNotFound, error.NotDir, error.NoSuchFile => .not_found,
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        error.Timeout => .timeout,
        error.ConnectionClosed, error.EndOfStream, error.SocketNotConnected => .closed,
        error.WouldBlock => .would_block,
        error.Unsupported, error.NotSupported => .unsupported,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.NetworkUnreachable,
        error.HostUnreachable,
        => .network,
        error.InvalidArgument, error.InvalidAddress, error.NameTooLong, error.InvalidHandle => .invalid_argument,
        error.SandboxUnavailable => .not_ready,
        else => .io_error,
    };
}

pub fn fail(err: anyerror) i32 {
    setErrorFmt("{s}", .{@errorName(err)});
    return code(fromError(err));
}

/// Free a buffer previously returned by an intrinsic.
pub export fn e7_free(ptr: ?*anyopaque) void {
    if (ptr) |p| std.c.free(p);
}

/// Allocate a buffer owned by the JITed caller; release with `e7_free`.
pub export fn e7_alloc(size: usize) callconv(.c) ?*anyopaque {
    if (size == 0) return null;
    return std.c.malloc(size);
}

/// Return the current thread's last runtime error.  The pointer remains valid
/// until the next runtime call on this thread.
pub export fn e7_last_error(out_ptr: ?*?[*]const u8, out_len: ?*usize) callconv(.c) i32 {
    if (out_ptr) |p| p.* = error_buffer[0..error_len].ptr;
    if (out_len) |p| p.* = error_len;
    return code(if (error_len == 0) .ok else .internal);
}

/// Copy bytes with an explicit length, avoiding a dependency on libc's
/// `memcpy` symbol being exported to the JIT.
pub export fn e7_memcpy(dst: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) i32 {
    if (len == 0) return code(.ok);
    if (dst == null or src == null) return code(.invalid_argument);
    const d: [*]u8 = @ptrCast(dst.?);
    const s: [*]const u8 = @ptrCast(src.?);
    @memcpy(d[0..len], s[0..len]);
    return code(.ok);
}

/// Runtime ABI version.  Bump when exported signatures change.
pub export fn e7_version() callconv(.c) i32 {
    return 1;
}

test "status and diagnostic buffer" {
    clearError();
    try std.testing.expectEqual(@as(usize, 0), lastError().len);
    setError("hello");
    try std.testing.expectEqualStrings("hello", lastError());
    try std.testing.expectEqual(@as(i32, 5), fail(error.InputOutput));
    try std.testing.expectEqualStrings("InputOutput", lastError());
    try std.testing.expectEqual(Status.not_found, fromError(error.FileNotFound));
}
