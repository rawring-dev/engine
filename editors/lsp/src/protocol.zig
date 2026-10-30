//! LSP JSON-RPC transport and value helpers.
//!
//! This module is the only place that knows about the wire format:
//! `Content-Length` framing, JSON escaping, LSP positions (0-based line and
//! UTF-16 code-unit character offsets), and `file:` URI conversion.
//!
//! Wire details follow the JSON-RPC 2.0 specification [jsonrpc] and the
//! Language Server Protocol 3.17 specification [lsp].
//!
//! The compiler front end reports byte-based 1-based line/column locations;
//! `offsetToPosition` / `positionToOffset` translate between that world and
//! the LSP world.  Keep every offset <-> position conversion here.

const std = @import("std");

/// Hard ceiling on a single JSON-RPC body.  LSP messages are small, so a
/// larger `Content-Length` means a broken client; rejecting it up front keeps
/// an untrusted header from forcing a huge allocation.
pub const max_content_length: usize = 32 * 1024 * 1024;

/// Cap on one header line.  Real LSP headers are a few dozen bytes; the cap
/// keeps a peer that never sends a newline from growing our state without
/// bound.
const max_header_line_length: usize = 8 * 1024;

/// Longest textual form of an `f64` in decimal notation; used to size stack
/// buffers when formatting numbers.  `{d}` can expand subnormals to ~330 bytes.
const max_float_text_length: usize = 512;

/// LSP position: zero-based line, zero-based UTF-16 code unit within the line.
pub const Position = struct {
    line: u32 = 0,
    character: u32 = 0,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

// ---------------------------------------------------------------------------
// Content-Length framing
// ---------------------------------------------------------------------------

/// Reads one `Content-Length` framed JSON message.
///
/// Header parsing is deliberately tolerant because editor clients disagree on
/// the details: header names are case-insensitive, both `\r\n` and bare `\n`
/// line endings are accepted, and headers other than `Content-Length` (such as
/// `Content-Type`) are ignored.
///
/// Returns `null` when the stream ends before a body starts.  A bare EOF means
/// the client closed the connection; a truncated header line means it went away
/// mid-write.  Both are treated as "stop serving" rather than fatal errors so
/// that a crashed editor cannot take the server down with it.
///
/// The body must be valid UTF-8 (`std.json` would otherwise accept arbitrary
/// bytes inside strings) and is parsed with `alloc_always`, so the returned
/// value owns copies of every string and the caller may free the wire buffer.
///
/// Errors: `HeaderTooLong`, `MalformedHeader`, `MissingContentLength`,
/// `InvalidContentLength`, `ContentTooLarge`, `TruncatedBody`, `InvalidUtf8`,
/// plus the errors from `std.json.parseFromSlice` for malformed JSON.
pub fn readMessage(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
) !?std.json.Parsed(std.json.Value) {
    var content_length: ?usize = null;
    var line: [max_header_line_length]u8 = undefined;
    var line_len: usize = 0;

    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            // see doc comment: EOF before a body is a graceful shutdown
            error.EndOfStream => return null,
            error.ReadFailed => return error.ReadFailed,
        };

        if (byte != '\n') {
            if (line_len == line.len) return error.HeaderTooLong;
            line[line_len] = byte;
            line_len += 1;
            continue;
        }

        var text = line[0..line_len];
        line_len = 0;
        if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
        if (text.len == 0) break; // blank line: headers are done

        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return error.MalformedHeader;
        const name = std.mem.trim(u8, text[0..colon], " \t");
        const value = std.mem.trim(u8, text[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (value.len == 0) return error.InvalidContentLength;
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
        }
    }

    const body_len = content_length orelse return error.MissingContentLength;
    if (body_len > max_content_length) return error.ContentTooLarge;

    const body = try allocator.alloc(u8, body_len);
    defer allocator.free(body);
    // readSliceAll keeps reading until the whole body arrives, so a body split
    // across many small stdin reads is handled without busy-looping.
    reader.readSliceAll(body) catch |err| switch (err) {
        error.EndOfStream => return error.TruncatedBody,
        error.ReadFailed => return error.ReadFailed,
    };

    if (!std.unicode.utf8ValidateSlice(body)) return error.InvalidUtf8;

    return try std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
    });
}

/// Writes one `Content-Length` framed JSON message (header + body).
pub fn writeMessage(writer: *std.Io.Writer, json: []const u8) !void {
    try writeContentLengthHeader(writer, json.len);
    try writer.writeAll(json);
}

/// Writes a JSON-RPC success response whose `result` is the raw JSON text.
pub fn writeResponse(
    writer: *std.Io.Writer,
    id: std.json.Value,
    result_json: []const u8,
) !void {
    const prefix = "{\"jsonrpc\":\"2.0\",\"id\":";
    const middle = ",\"result\":";
    const suffix = "}";
    const body_len = prefix.len + jsonValueLen(id) + middle.len + result_json.len + suffix.len;
    try writeContentLengthHeader(writer, body_len);
    try writer.writeAll(prefix);
    try writeJsonValue(writer, id);
    try writer.writeAll(middle);
    try writer.writeAll(result_json);
    try writer.writeAll(suffix);
}

/// Writes a JSON-RPC error response.
pub fn writeError(
    writer: *std.Io.Writer,
    id: std.json.Value,
    code: i32,
    message: []const u8,
) !void {
    const prefix = "{\"jsonrpc\":\"2.0\",\"id\":";
    const middle = ",\"error\":{\"code\":";
    const after_code = ",\"message\":";
    const suffix = "}}";
    var code_buf: [16]u8 = undefined;
    const code_text = std.fmt.bufPrint(&code_buf, "{d}", .{code}) catch unreachable;
    const body_len = prefix.len + jsonValueLen(id) + middle.len + code_text.len +
        after_code.len + jsonStringLen(message) + suffix.len;
    try writeContentLengthHeader(writer, body_len);
    try writer.writeAll(prefix);
    try writeJsonValue(writer, id);
    try writer.writeAll(middle);
    try writer.writeAll(code_text);
    try writer.writeAll(after_code);
    try writeJsonString(writer, message);
    try writer.writeAll(suffix);
}

/// Writes a JSON-RPC notification whose `params` is the raw JSON text.
pub fn writeNotification(
    writer: *std.Io.Writer,
    method: []const u8,
    params_json: []const u8,
) !void {
    const prefix = "{\"jsonrpc\":\"2.0\",\"method\":";
    const middle = ",\"params\":";
    const suffix = "}";
    const body_len = prefix.len + jsonStringLen(method) + middle.len + params_json.len + suffix.len;
    try writeContentLengthHeader(writer, body_len);
    try writer.writeAll(prefix);
    try writeJsonString(writer, method);
    try writer.writeAll(middle);
    try writer.writeAll(params_json);
    try writer.writeAll(suffix);
}

fn writeContentLengthHeader(writer: *std.Io.Writer, body_len: usize) !void {
    var buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "Content-Length: {d}\r\n\r\n", .{body_len}) catch unreachable;
    try writer.writeAll(header);
}

// ---------------------------------------------------------------------------
// JSON building
// ---------------------------------------------------------------------------

/// Appends JSON text to an `ArrayListUnmanaged(u8)` with correct escaping.
/// All request/response payload builders in `server.zig` use this type.
///
/// The envelope writers above deliberately avoid this type: they stream
/// straight to the output writer and compute the body length up front, so a
/// large `result` payload never needs a second full copy in memory.
pub const JsonOut = struct {
    buffer: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    pub fn init(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) JsonOut {
        return .{ .buffer = buffer, .allocator = allocator };
    }

    /// Appends raw, already-valid JSON text.
    pub fn writeAll(self: JsonOut, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    /// Appends one byte; a convenience for punctuation around values.
    pub fn writeByte(self: JsonOut, byte: u8) !void {
        try self.buffer.append(self.allocator, byte);
    }

    pub fn writeInt(self: JsonOut, value: anytype) !void {
        try appendFormattedInt(self, value);
    }

    pub fn writeBool(self: JsonOut, value: bool) !void {
        try appendBool(self, value);
    }

    /// Writes a correctly escaped JSON string, including surrounding quotes.
    pub fn writeString(self: JsonOut, value: []const u8) !void {
        try writeJsonString(self, value);
    }

    /// Writes an arbitrary parsed JSON value (client request ids, etc.).
    pub fn writeValue(self: JsonOut, value: std.json.Value) !void {
        try writeJsonValue(self, value);
    }
};

fn appendBool(sink: anytype, value: bool) !void {
    if (value) try sink.writeAll("true") else try sink.writeAll("false");
}

fn appendFormattedInt(sink: anytype, value: anytype) !void {
    // 40 bytes covers u128's 39-digit maximum; ids and diagnostics use far less.
    var buf: [40]u8 = undefined;
    try sink.writeAll(std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable);
}

fn writeJsonFloat(sink: anytype, value: f64) !void {
    // JSON has no NaN/Infinity literals.  Values from parsed JSON are always
    // finite, but `JsonOut` is public, so degrade to `null` instead of emitting
    // invalid JSON.
    if (!std.math.isFinite(value)) return sink.writeAll("null");
    var buf: [max_float_text_length]u8 = undefined;
    try sink.writeAll(std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable);
}

/// Writes a JSON string with quotes, escaping `"`, `\`, the common control
/// shortcuts and all other control bytes (`\u00xx`).  Non-ASCII bytes are
/// copied through untouched: JSON strings are UTF-8, and copying is cheaper
/// than decoding and re-encoding.
fn writeJsonString(sink: anytype, value: []const u8) !void {
    try sink.writeAll("\"");
    var run_start: usize = 0;
    for (value, 0..) |c, i| {
        const replacement: ?[]const u8 = if (c == '"')
            "\\\""
        else if (c == '\\')
            "\\\\"
        else if (c == '\n')
            "\\n"
        else if (c == '\r')
            "\\r"
        else if (c == '\t')
            "\\t"
        else
            null;

        if (replacement) |escaped| {
            if (i > run_start) try sink.writeAll(value[run_start..i]);
            try sink.writeAll(escaped);
            run_start = i + 1;
        } else if (c < 0x20) {
            if (i > run_start) try sink.writeAll(value[run_start..i]);
            var buf: [6]u8 = undefined;
            try sink.writeAll(std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable);
            run_start = i + 1;
        }
    }
    if (run_start < value.len) try sink.writeAll(value[run_start..]);
    try sink.writeAll("\"");
}

/// Writes a parsed JSON value in compact form.
fn writeJsonValue(sink: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try sink.writeAll("null"),
        .bool => |b| try appendBool(sink, b),
        .integer => |i| try appendFormattedInt(sink, i),
        .float => |f| try writeJsonFloat(sink, f),
        // Already-valid number text produced by the parser; copy verbatim so
        // arbitrary-precision numbers survive a round trip.
        .number_string => |s| try sink.writeAll(s),
        .string => |s| try writeJsonString(sink, s),
        .array => |arr| {
            try sink.writeAll("[");
            for (arr.items, 0..) |item, i| {
                if (i != 0) try sink.writeAll(",");
                try writeJsonValue(sink, item);
            }
            try sink.writeAll("]");
        },
        .object => |obj| {
            try sink.writeAll("{");
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try sink.writeAll(",");
                first = false;
                try writeJsonString(sink, entry.key_ptr.*);
                try sink.writeAll(":");
                try writeJsonValue(sink, entry.value_ptr.*);
            }
            try sink.writeAll("}");
        },
    }
}

// Lengths below must stay in lockstep with the writers above: the envelope
// functions size `Content-Length` from them before streaming the body.

fn jsonStringLen(value: []const u8) usize {
    var len: usize = 2; // surrounding quotes
    for (value) |c| {
        len += if (c == '"' or c == '\\' or c == '\n' or c == '\r' or c == '\t')
            2
        else if (c < 0x20)
            6
        else
            1;
    }
    return len;
}

fn jsonFloatLen(value: f64) usize {
    if (!std.math.isFinite(value)) return 4; // written as `null`
    var buf: [max_float_text_length]u8 = undefined;
    return (std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable).len;
}

fn jsonIntLen(value: anytype) usize {
    var buf: [40]u8 = undefined;
    return (std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable).len;
}

fn jsonValueLen(value: std.json.Value) usize {
    return switch (value) {
        .null => 4,
        .bool => |b| if (b) 4 else 5,
        .integer => |i| jsonIntLen(i),
        .float => |f| jsonFloatLen(f),
        .number_string => |s| s.len,
        .string => |s| jsonStringLen(s),
        .array => |arr| blk: {
            var len: usize = 2;
            for (arr.items, 0..) |item, i| {
                if (i != 0) len += 1;
                len += jsonValueLen(item);
            }
            break :blk len;
        },
        .object => |obj| blk: {
            var len: usize = 2;
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) len += 1;
                first = false;
                len += jsonStringLen(entry.key_ptr.*) + 1 + jsonValueLen(entry.value_ptr.*);
            }
            break :blk len;
        },
    };
}

// ---------------------------------------------------------------------------
// Position conversion
// ---------------------------------------------------------------------------

/// Converts a byte offset into an LSP position.  Clamps to `source.len`.
///
/// Lines are separated by `\n`; a preceding `\r` belongs to the terminator and
/// is not counted as line content (so positions never point past the text of a
/// CRLF line).  A lone `\r` is treated as ordinary content.
///
/// The character offset is measured in UTF-16 code units, so a non-BMP
/// codepoint counts as two.  Invalid UTF-8 bytes each count as one unit, which
/// keeps the result monotonic even for a buffer that is being edited into
/// invalid UTF-8 mid-keystroke.
pub fn offsetToPosition(source: []const u8, offset: usize) Position {
    const clamped = @min(offset, source.len);
    const prefix = source[0..clamped];
    const line = std.mem.count(u8, prefix, "\n");
    const line_start = if (std.mem.lastIndexOfScalar(u8, prefix, '\n')) |nl| nl + 1 else 0;

    var tail = source[line_start..clamped];
    if (clamped < source.len and source[clamped] == '\n' and
        tail.len > 0 and tail[tail.len - 1] == '\r')
    {
        tail = tail[0 .. tail.len - 1];
    }

    var character: usize = 0;
    var i: usize = 0;
    while (i < tail.len) {
        const c = tail[i];
        if (c < 0x80) { // fast path: ASCII is one byte and one code unit
            i += 1;
            character += 1;
            continue;
        }

        const seq_len = std.unicode.utf8ByteSequenceLength(c) catch {
            i += 1;
            character += 1;
            continue;
        };
        if (i + seq_len > tail.len) {
            i += 1;
            character += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(tail[i..][0..seq_len]) catch {
            i += 1;
            character += 1;
            continue;
        };
        i += seq_len;
        character += if (codepoint > 0xFFFF) 2 else 1;
    }

    return .{ .line = @intCast(line), .character = @intCast(character) };
}

/// Converts an LSP position into a byte offset.  Clamps to `source.len`.
///
/// Out-of-range lines clamp to the end of the source; characters past the end
/// of a line clamp to the end of that line's text (before the terminator).  A
/// character pointing into the middle of a surrogate pair clamps to the start
/// of that codepoint, so the returned offset is always on a codepoint boundary
/// (except for invalid UTF-8, counted one byte per code unit).
pub fn positionToOffset(source: []const u8, position: Position) usize {
    var offset: usize = 0;
    var line: u32 = 0;
    while (line < position.line) : (line += 1) {
        const newline = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse return source.len;
        offset = newline + 1;
    }

    var character: u32 = 0;
    while (character < position.character and offset < source.len) {
        const c = source[offset];
        if (c == '\n') break;
        if (c == '\r' and offset + 1 < source.len and source[offset + 1] == '\n') break;
        if (c < 0x80) { // fast path: ASCII is one byte and one code unit
            offset += 1;
            character += 1;
            continue;
        }

        const seq_len = std.unicode.utf8ByteSequenceLength(c) catch {
            offset += 1;
            character += 1;
            continue;
        };
        if (offset + seq_len > source.len) {
            offset += 1;
            character += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(source[offset..][0..seq_len]) catch {
            offset += 1;
            character += 1;
            continue;
        };
        const units: u32 = if (codepoint > 0xFFFF) 2 else 1;
        if (character + units > position.character) break; // never split a surrogate pair
        offset += seq_len;
        character += units;
    }
    return offset;
}

// ---------------------------------------------------------------------------
// URI helpers
// ---------------------------------------------------------------------------

/// Converts a `file:` URI to a filesystem path (percent-decoded).
/// Returns a slice allocated with `allocator`.
///
/// Accepted forms: `file:///abs/path`, `file://localhost/abs/path` and
/// `file:/abs/path`.  Other authorities are rejected rather than silently
/// mapped to a local path, and query/fragment components are treated as part of
/// the path (unlike HTTP, `file:` URIs carry them encoded, see `pathToUri`).
pub fn uriToPath(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    if (uri.len < 5 or !std.ascii.eqlIgnoreCase(uri[0..5], "file:")) return error.NotFileUri;
    var rest = uri[5..];

    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidUri;
        const authority = rest[0..slash];
        // An empty authority is the normal `file:///...` form; some clients
        // spell it out as `file://localhost/...`.
        if (authority.len != 0 and !std.ascii.eqlIgnoreCase(authority, "localhost")) {
            return error.UnsupportedAuthority;
        }
        rest = rest[slash..];
    } else if (rest.len > 0 and rest[0] != '/') {
        // `file:relative` is not a valid absolute file URI.
        return error.InvalidUri;
    }

    if (rest.len == 0) return error.InvalidUri;

    const decoded = try allocator.alloc(u8, rest.len);
    errdefer allocator.free(decoded);
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) {
        if (rest[i] == '%') {
            if (i + 2 >= rest.len) return error.InvalidPercentEncoding;
            const hi = hexDigitValue(rest[i + 1]) orelse return error.InvalidPercentEncoding;
            const lo = hexDigitValue(rest[i + 2]) orelse return error.InvalidPercentEncoding;
            decoded[n] = hi << 4 | lo;
            n += 1;
            i += 3;
        } else {
            decoded[n] = rest[i];
            n += 1;
            i += 1;
        }
    }
    return try allocator.realloc(decoded, n);
}

/// Converts an absolute filesystem path to a `file:` URI using a
/// (conservative) percent encoding for characters that are unsafe in a URI.
///
/// Only RFC 3986 unreserved characters and `/` are emitted literally; every
/// other byte (including non-ASCII UTF-8 bytes) is `%XX`-escaped, which makes
/// the result round-trip through `uriToPath` unchanged.
pub fn pathToUri(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '/') return error.NotAbsolutePath;

    const hex = "0123456789ABCDEF";
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "file://");
    // Worst case every byte becomes `%XX`; reserving once avoids repeated growth.
    try out.ensureTotalCapacity(allocator, "file://".len + path.len * 3);
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~' or c == '/') {
            try out.append(allocator, c);
        } else {
            try out.appendSlice(allocator, &.{ '%', hex[c >> 4], hex[c & 0x0f] });
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn hexDigitValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Asserts `wire` is one framed message with `expected_body` as the body.
fn expectFramedBody(wire: []const u8, expected_body: []const u8) !void {
    const header_end = std.mem.indexOf(u8, wire, "\r\n\r\n") orelse
        return error.TestUnexpectedResult;
    const body = wire[header_end + 4 ..];
    try testing.expectEqualStrings(expected_body, body);

    var buf: [64]u8 = undefined;
    const expected_header = try std.fmt.bufPrint(&buf, "Content-Length: {d}", .{body.len});
    try testing.expectEqualStrings(expected_header, wire[0..header_end]);
}

/// Wires `body` into a fresh `Content-Length` frame for readMessage tests.
fn frame(
    buffer: []u8,
    headers: []const u8,
    body: []const u8,
) ![]const u8 {
    return try std.fmt.bufPrint(buffer, "{s}Content-Length: {d}\r\n\r\n{s}", .{ headers, body.len, body });
}

test "readMessage: round trip through writeMessage" {
    const body = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"hello\"}";
    var wire: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&wire);
    try writeMessage(&writer, body);
    try expectFramedBody(writer.buffered(), body);

    var reader: std.Io.Reader = .fixed(writer.buffered());
    var parsed = (try readMessage(&reader, testing.allocator)) orelse
        return error.TestUnexpectedResult;
    defer parsed.deinit();

    try testing.expectEqual(@as(i64, 7), parsed.value.object.get("id").?.integer);
    try testing.expectEqualStrings("hello", parsed.value.object.get("method").?.string);
}

test "readMessage: EOF before a message returns null" {
    var empty: std.Io.Reader = .fixed("");
    try testing.expect(try readMessage(&empty, testing.allocator) == null);

    // A client that dies mid-header leaves a truncated line behind; that is a
    // shutdown, not a protocol error.
    var truncated: std.Io.Reader = .fixed("Content-Len");
    try testing.expect(try readMessage(&truncated, testing.allocator) == null);
}

test "readMessage: consumes back-to-back messages from one stream" {
    var wire_buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&wire_buf);
    try writeMessage(&writer, "{\"id\":1}");
    try writeMessage(&writer, "{\"id\":2}");
    var reader: std.Io.Reader = .fixed(writer.buffered());

    var first = (try readMessage(&reader, testing.allocator)) orelse
        return error.TestUnexpectedResult;
    defer first.deinit();
    try testing.expectEqual(@as(i64, 1), first.value.object.get("id").?.integer);

    var second = (try readMessage(&reader, testing.allocator)) orelse
        return error.TestUnexpectedResult;
    defer second.deinit();
    try testing.expectEqual(@as(i64, 2), second.value.object.get("id").?.integer);

    try testing.expect(try readMessage(&reader, testing.allocator) == null);
}

test "readMessage: accepts CRLF, bare LF, mixed-case names, extra headers" {
    const body = "{\"ok\":true}";

    var crlf_buf: [128]u8 = undefined;
    var crlf: std.Io.Reader = .fixed(try frame(&crlf_buf, "", body));
    var a = (try readMessage(&crlf, testing.allocator)) orelse return error.TestUnexpectedResult;
    defer a.deinit();
    try testing.expect(a.value.object.get("ok").?.bool);

    var lf_buf: [128]u8 = undefined;
    const lf_wire = try std.fmt.bufPrint(&lf_buf, "CONTENT-LENGTH: {d}\n\n{s}", .{ body.len, body });
    var lf: std.Io.Reader = .fixed(lf_wire);
    var b = (try readMessage(&lf, testing.allocator)) orelse return error.TestUnexpectedResult;
    defer b.deinit();
    try testing.expect(b.value.object.get("ok").?.bool);

    var extra_buf: [192]u8 = undefined;
    var extra: std.Io.Reader = .fixed(try frame(
        &extra_buf,
        "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nX-Ignored: yes\r\n",
        body,
    ));
    var c = (try readMessage(&extra, testing.allocator)) orelse return error.TestUnexpectedResult;
    defer c.deinit();
    try testing.expect(c.value.object.get("ok").?.bool);
}

test "readMessage: rejects malformed and incomplete headers" {
    var no_colon: std.Io.Reader = .fixed("NotAHeader\r\n\r\n");
    try testing.expectError(error.MalformedHeader, readMessage(&no_colon, testing.allocator));

    var no_length: std.Io.Reader = .fixed("Content-Type: application/json\r\n\r\n");
    try testing.expectError(error.MissingContentLength, readMessage(&no_length, testing.allocator));

    var empty_length: std.Io.Reader = .fixed("Content-Length:\r\n\r\n");
    try testing.expectError(error.InvalidContentLength, readMessage(&empty_length, testing.allocator));

    var bad_length: std.Io.Reader = .fixed("Content-Length: twelve\r\n\r\n");
    try testing.expectError(error.InvalidContentLength, readMessage(&bad_length, testing.allocator));

    var overflow_length: std.Io.Reader = .fixed("Content-Length: 99999999999999999999999\r\n\r\n");
    try testing.expectError(error.InvalidContentLength, readMessage(&overflow_length, testing.allocator));
}

test "readMessage: rejects oversized Content-Length without allocating" {
    var wire_buf: [128]u8 = undefined;
    const wire = try std.fmt.bufPrint(
        &wire_buf,
        "Content-Length: {d}\r\n\r\n",
        .{max_content_length + 1},
    );
    var reader: std.Io.Reader = .fixed(wire);
    try testing.expectError(error.ContentTooLarge, readMessage(&reader, testing.allocator));
}

test "readMessage: rejects a truncated body" {
    var reader: std.Io.Reader = .fixed("Content-Length: 10\r\n\r\nabc");
    try testing.expectError(error.TruncatedBody, readMessage(&reader, testing.allocator));
}

test "readMessage: rejects invalid UTF-8 in the body" {
    const wire = "Content-Length: 3\r\n\r\n\"\xff\"";
    var reader: std.Io.Reader = .fixed(wire);
    try testing.expectError(error.InvalidUtf8, readMessage(&reader, testing.allocator));
}

test "writeMessage: Content-Length counts UTF-8 bytes, not codepoints" {
    var wire: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&wire);
    // Not a JSON message, but framing must not care about the contents.
    // "h" + "é" (2 UTF-8 bytes) + "llo" is 7 bytes, but only 6 code units.
    try writeMessage(&writer, "h\u{00e9}llo");
    try expectFramedBody(writer.buffered(), "h\u{00e9}llo");
}

test "JsonOut: escapes strings" {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(testing.allocator);
    const out = JsonOut.init(&buffer, testing.allocator);

    try out.writeString("quote \" backslash \\ newline \n cr \r tab \t ctrl \x01");
    try testing.expectEqualStrings(
        "\"quote \\\" backslash \\\\ newline \\n cr \\r tab \\t ctrl \\u0001\"",
        buffer.items,
    );

    buffer.clearRetainingCapacity();
    // Non-ASCII is valid UTF-8 in JSON and must survive byte-for-byte.
    try out.writeString("h\u{00e9}llo \u{1F600}");
    try testing.expectEqualStrings("\"h\u{00e9}llo \u{1F600}\"", buffer.items);
}

test "JsonOut: writes every JSON value kind" {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(testing.allocator);
    const out = JsonOut.init(&buffer, testing.allocator);

    try out.writeAll("[");
    try out.writeValue(.null);
    try out.writeAll(",");
    try out.writeValue(.{ .bool = true });
    try out.writeAll(",");
    try out.writeValue(.{ .bool = false });
    try out.writeAll(",");
    try out.writeValue(.{ .integer = -42 });
    try out.writeAll(",");
    try out.writeValue(.{ .float = 1.5 });
    try out.writeAll(",");
    try out.writeValue(.{ .string = "a\"b" });
    try out.writeAll(",");
    try out.writeValue(.{ .number_string = "1e100" });
    try out.writeAll(",");
    try out.writeAll("{\"k\":");
    try out.writeValue(.{ .integer = 0 });
    try out.writeAll("}]");

    try testing.expectEqualStrings(
        "[null,true,false,-42,1.5,\"a\\\"b\",1e100,{\"k\":0}]",
        buffer.items,
    );

    // Arrays/objects come from the parser in practice; write a parsed value
    // back out and check the compact serialization (key order is insertion
    // order, which `StringArrayHashMap` preserves).
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"a\":[1,true,null],\"b\":{\"c\":\"d\"}}",
        .{},
    );
    defer parsed.deinit();
    buffer.clearRetainingCapacity();
    try out.writeValue(parsed.value);
    try testing.expectEqualStrings("{\"a\":[1,true,null],\"b\":{\"c\":\"d\"}}", buffer.items);

    // writeInt/writeBool/writeString convenience wrappers.
    buffer.clearRetainingCapacity();
    try out.writeInt(@as(u32, 9));
    try out.writeBool(true);
    try out.writeString("x");
    try testing.expectEqualStrings("9true\"x\"", buffer.items);
}

test "writeResponse: envelopes a result and frames it correctly" {
    var wire: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&wire);
    try writeResponse(&writer, .{ .integer = 3 }, "{\"ok\":true}");
    try expectFramedBody(
        writer.buffered(),
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true}}",
    );

    // The framed output must be readable by our own reader.
    var reader: std.Io.Reader = .fixed(writer.buffered());
    var parsed = (try readMessage(&reader, testing.allocator)) orelse
        return error.TestUnexpectedResult;
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 3), parsed.value.object.get("id").?.integer);
    try testing.expect(parsed.value.object.get("result").?.object.get("ok").?.bool);
}

test "writeResponse: string ids with escapes still frame correctly" {
    var wire: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&wire);
    try writeResponse(&writer, .{ .string = "id \"1\"" }, "null");
    try expectFramedBody(
        writer.buffered(),
        "{\"jsonrpc\":\"2.0\",\"id\":\"id \\\"1\\\"\",\"result\":null}",
    );
}

test "writeError: escapes the message and frames correctly" {
    var wire: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&wire);
    try writeError(&writer, .{ .integer = 1 }, -32602, "bad \"arg\"\n");
    try expectFramedBody(
        writer.buffered(),
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"bad \\\"arg\\\"\\n\"}}",
    );
}

test "writeNotification: frames method and raw params" {
    var wire: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&wire);
    try writeNotification(&writer, "textDocument/publishDiagnostics", "{\"diagnostics\":[]}");
    try expectFramedBody(
        writer.buffered(),
        "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\"," ++
            "\"params\":{\"diagnostics\":[]}}",
    );
}

test "offsetToPosition: ASCII" {
    const source = "abc\ndef\nghi";
    try testing.expectEqual(Position{ .line = 0, .character = 0 }, offsetToPosition(source, 0));
    try testing.expectEqual(Position{ .line = 0, .character = 2 }, offsetToPosition(source, 2));
    // An offset at the newline is the end of the line's text.
    try testing.expectEqual(Position{ .line = 0, .character = 3 }, offsetToPosition(source, 3));
    try testing.expectEqual(Position{ .line = 1, .character = 0 }, offsetToPosition(source, 4));
    try testing.expectEqual(Position{ .line = 2, .character = 0 }, offsetToPosition(source, 8));
    try testing.expectEqual(Position{ .line = 2, .character = 3 }, offsetToPosition(source, source.len));
    // Out-of-range offsets clamp.
    try testing.expectEqual(Position{ .line = 2, .character = 3 }, offsetToPosition(source, 1000));
}

test "offsetToPosition: counts UTF-16 code units for multi-byte and non-BMP text" {
    // "é" is 2 bytes / 1 code unit; the emoji is 4 bytes / 2 code units.
    const source = "\u{00e9}\u{1F600}x\nab";
    try testing.expectEqual(Position{ .line = 0, .character = 0 }, offsetToPosition(source, 0));
    try testing.expectEqual(Position{ .line = 0, .character = 1 }, offsetToPosition(source, 2));
    try testing.expectEqual(Position{ .line = 0, .character = 3 }, offsetToPosition(source, 6));
    try testing.expectEqual(Position{ .line = 0, .character = 4 }, offsetToPosition(source, 7));
    try testing.expectEqual(Position{ .line = 1, .character = 0 }, offsetToPosition(source, 8));
    try testing.expectEqual(Position{ .line = 1, .character = 1 }, offsetToPosition(source, 9));
    try testing.expectEqual(Position{ .line = 1, .character = 2 }, offsetToPosition(source, source.len));
}

test "positionToOffset: ASCII, clamping and line ends" {
    const source = "abc\ndef\nghi";
    try testing.expectEqual(@as(usize, 0), positionToOffset(source, .{ .line = 0, .character = 0 }));
    try testing.expectEqual(@as(usize, 2), positionToOffset(source, .{ .line = 0, .character = 2 }));
    try testing.expectEqual(@as(usize, 3), positionToOffset(source, .{ .line = 0, .character = 3 }));
    try testing.expectEqual(@as(usize, 4), positionToOffset(source, .{ .line = 1, .character = 0 }));
    try testing.expectEqual(@as(usize, 9), positionToOffset(source, .{ .line = 2, .character = 1 }));
    // Character past the end of a line clamps to the line end.
    try testing.expectEqual(@as(usize, 3), positionToOffset(source, .{ .line = 0, .character = 99 }));
    // Line past the end clamps to the source length.
    try testing.expectEqual(source.len, positionToOffset(source, .{ .line = 9, .character = 0 }));
    try testing.expectEqual(source.len, positionToOffset(source, .{ .line = 2, .character = 99 }));
}

test "positionToOffset: never splits surrogate pairs" {
    const source = "\u{00e9}\u{1F600}x\nab";
    try testing.expectEqual(@as(usize, 0), positionToOffset(source, .{ .line = 0, .character = 0 }));
    try testing.expectEqual(@as(usize, 2), positionToOffset(source, .{ .line = 0, .character = 1 }));
    // Character 2 is the low half of the emoji's surrogate pair: snap back to
    // the start of the codepoint.
    try testing.expectEqual(@as(usize, 2), positionToOffset(source, .{ .line = 0, .character = 2 }));
    try testing.expectEqual(@as(usize, 6), positionToOffset(source, .{ .line = 0, .character = 3 }));
    try testing.expectEqual(@as(usize, 7), positionToOffset(source, .{ .line = 0, .character = 4 }));
    try testing.expectEqual(@as(usize, 8), positionToOffset(source, .{ .line = 1, .character = 0 }));
    try testing.expectEqual(source.len, positionToOffset(source, .{ .line = 1, .character = 99 }));
}

test "position conversion: CRLF round trips" {
    const source = "abc\r\ndef";
    try testing.expectEqual(Position{ .line = 0, .character = 3 }, offsetToPosition(source, 3));
    // The `\n` of a CRLF sits at the end of the line's text, not one past it.
    try testing.expectEqual(Position{ .line = 0, .character = 3 }, offsetToPosition(source, 4));
    try testing.expectEqual(Position{ .line = 1, .character = 0 }, offsetToPosition(source, 5));
    try testing.expectEqual(Position{ .line = 1, .character = 3 }, offsetToPosition(source, source.len));

    try testing.expectEqual(@as(usize, 3), positionToOffset(source, .{ .line = 0, .character = 3 }));
    try testing.expectEqual(@as(usize, 3), positionToOffset(source, .{ .line = 0, .character = 4 }));
    try testing.expectEqual(@as(usize, 5), positionToOffset(source, .{ .line = 1, .character = 0 }));
    try testing.expectEqual(@as(usize, 8), positionToOffset(source, .{ .line = 1, .character = 3 }));

    for ([_]Position{
        .{ .line = 0, .character = 0 },
        .{ .line = 0, .character = 3 },
        .{ .line = 1, .character = 0 },
        .{ .line = 1, .character = 3 },
    }) |position| {
        try testing.expectEqual(position, offsetToPosition(source, positionToOffset(source, position)));
    }
}

test "uriToPath: decodes file URIs" {
    const allocator = testing.allocator;

    const plain = try uriToPath(allocator, "file:///tmp/main.tri");
    defer allocator.free(plain);
    try testing.expectEqualStrings("/tmp/main.tri", plain);

    const spaced = try uriToPath(allocator, "file:///tmp/a%20b.tri");
    defer allocator.free(spaced);
    try testing.expectEqualStrings("/tmp/a b.tri", spaced);

    const localhost = try uriToPath(allocator, "file://localhost/tmp/x");
    defer allocator.free(localhost);
    try testing.expectEqualStrings("/tmp/x", localhost);

    const unicode = try uriToPath(allocator, "file:///tmp/h%C3%A9llo");
    defer allocator.free(unicode);
    try testing.expectEqualStrings("/tmp/h\u{00e9}llo", unicode);

    // An escaped percent sign must decode exactly once.
    const percent = try uriToPath(allocator, "file:///tmp/100%25");
    defer allocator.free(percent);
    try testing.expectEqualStrings("/tmp/100%", percent);

    // Schemes are case-insensitive.
    const upper = try uriToPath(allocator, "FILE:///tmp/x");
    defer allocator.free(upper);
    try testing.expectEqualStrings("/tmp/x", upper);
}

test "uriToPath: rejects non-file and remote authority URIs" {
    const allocator = testing.allocator;
    try testing.expectError(error.NotFileUri, uriToPath(allocator, "https://example.com/x"));
    try testing.expectError(error.UnsupportedAuthority, uriToPath(allocator, "file://example.com/x"));
    try testing.expectError(error.InvalidUri, uriToPath(allocator, "file:relative"));
    try testing.expectError(error.InvalidPercentEncoding, uriToPath(allocator, "file:///tmp/a%2"));
    try testing.expectError(error.InvalidPercentEncoding, uriToPath(allocator, "file:///tmp/a%zz"));
}

test "pathToUri: encodes unsafe bytes and round trips" {
    const allocator = testing.allocator;

    const plain = try pathToUri(allocator, "/tmp/main.tri");
    defer allocator.free(plain);
    try testing.expectEqualStrings("file:///tmp/main.tri", plain);

    const tricky = "/tmp/h\u{00e9}llo world/100% #1.tri";
    const encoded = try pathToUri(allocator, tricky);
    defer allocator.free(encoded);
    try testing.expectEqualStrings(
        "file:///tmp/h%C3%A9llo%20world/100%25%20%231.tri",
        encoded,
    );

    const decoded = try uriToPath(allocator, encoded);
    defer allocator.free(decoded);
    try testing.expectEqualStrings(tricky, decoded);
}

test "pathToUri: rejects relative paths" {
    try testing.expectError(error.NotAbsolutePath, pathToUri(testing.allocator, "tmp/main.tri"));
    try testing.expectError(error.NotAbsolutePath, pathToUri(testing.allocator, ""));
}
