//! Standard input/output FFI.
//!
//! Writes go directly to the OS handle (no userspace stdio buffering), so a
//! successful `e7_stdio_write` has handed the bytes to the kernel.  Input is
//! byte-oriented; line input is a convenience that reads until `\n`, strips a
//! trailing `\r`, and returns a partial line if the caller's buffer fills.

const std = @import("std");
const abi = @import("abi.zig");
const io_mod = @import("io.zig");

pub const Error = error{
    InvalidStream,
    ReadFailed,
    WriteFailed,
    OutOfMemory,
};

pub const Stream = enum(i32) {
    stdin = 0,
    stdout = 1,
    stderr = 2,
};

pub fn fromInt(value: i32) Error!Stream {
    return switch (value) {
        0 => .stdin,
        1 => .stdout,
        2 => .stderr,
        else => error.InvalidStream,
    };
}

pub fn handle(stream: Stream) std.Io.File {
    return switch (stream) {
        .stdin => std.Io.File.stdin(),
        .stdout => std.Io.File.stdout(),
        .stderr => std.Io.File.stderr(),
    };
}

/// Write all bytes to a file handle.
pub fn writeTo(file: std.Io.File, data: []const u8) Error!void {
    file.writeStreamingAll(io_mod.io(), data) catch return error.WriteFailed;
}

/// Read up to `buffer.len` bytes.  A return value of zero means end of stream.
pub fn readFrom(file: std.Io.File, buffer: []u8) Error!usize {
    if (buffer.len == 0) return 0;
    var buffers = [_][]u8{buffer};
    return file.readStreaming(io_mod.io(), &buffers) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => error.ReadFailed,
    };
}

/// Read one line into `buffer`, excluding the line terminator.  Returns `null`
/// at end of stream before any byte is read.  If the buffer fills first, the
/// returned line is a prefix and the next call continues at the next byte.
pub fn readLineFrom(file: std.Io.File, buffer: []u8) Error!?usize {
    if (buffer.len == 0) return 0;
    var length: usize = 0;

    while (length < buffer.len) {
        var byte: [1]u8 = undefined;
        const n = readFrom(file, &byte) catch |err| {
            if (length == 0) return err;
            break;
        };
        if (n == 0) {
            if (length == 0) return null;
            break;
        }
        if (byte[0] == '\n') break;
        buffer[length] = byte[0];
        length += 1;
    }

    if (length > 0 and buffer[length - 1] == '\r') length -= 1;
    return length;
}

pub fn write(stream: Stream, data: []const u8) Error!void {
    try writeTo(handle(stream), data);
}

pub fn read(stream: Stream, buffer: []u8) Error!usize {
    return readFrom(handle(stream), buffer);
}

pub fn readLine(stream: Stream, buffer: []u8) Error!?usize {
    return readLineFrom(handle(stream), buffer);
}

pub fn isTty(stream: Stream) bool {
    return handle(stream).isTty(io_mod.io()) catch false;
}

/// Flush is a no-op: the runtime writes directly to the OS handle.
pub fn flush(stream: Stream) Error!void {
    _ = stream;
}

test "stdio writes, reads, and splits lines through a file handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = io_mod.io();
    try tmp.dir.writeFile(io, .{ .sub_path = "lines.txt", .data = "one\ntwo\r\nthree" });

    var file = try tmp.dir.openFile(io, "lines.txt", .{});
    defer file.close(io);

    var buffer: [16]u8 = undefined;
    const first = (try readLineFrom(file, &buffer)).?;
    try std.testing.expectEqualStrings("one", buffer[0..first]);

    const second = (try readLineFrom(file, &buffer)).?;
    try std.testing.expectEqualStrings("two", buffer[0..second]);

    // readLineFrom consumes one byte at a time; the CRLF line leaves no stray
    // byte behind for the next call.
    const third = (try readLineFrom(file, &buffer)).?;
    try std.testing.expectEqualStrings("three", buffer[0..third]);
    try std.testing.expect((try readLineFrom(file, &buffer)) == null);

    {
        var output = try tmp.dir.createFile(io, "out.txt", .{});
        defer output.close(io);
        try writeTo(output, "written through stdio");
    }

    var input = try tmp.dir.openFile(io, "out.txt", .{});
    defer input.close(io);
    var read_buffer: [32]u8 = undefined;
    const count = try readFrom(input, &read_buffer);
    try std.testing.expectEqualStrings("written through stdio", read_buffer[0..count]);
}

test "stdio rejects unknown stream ids" {
    try std.testing.expectError(error.InvalidStream, fromInt(3));
    try std.testing.expectError(error.InvalidStream, fromInt(-1));
    try std.testing.expectEqual(Stream.stdout, try fromInt(1));
}
