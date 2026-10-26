//! JSON encode/decode for `@derive(Serialize, Deserialize)` structs.
//!
//! The compiler validates derived structs and embeds a compact schema string;
//! these helpers walk the e7 aggregate layout described by it.  Values use the
//! normal e7 representation:
//!
//!   * struct: pointer to `n` i64 slots (one per field, declaration order)
//!   * str: aggregate `[len, bytes...]`, accessed through `e7_str_*`
//!   * vector: aggregate `[rows, columns=0, elements...]`, `e7_vec_*`
//!   * bool/int: i64 slot value; float: f64 bit pattern in an i64 slot
//!
//! Schema grammar (compiler-generated, acyclic):
//!
//!   struct := '{' fields '}'
//!   fields := field (';' field)* | empty
//!   field  := name '=' type
//!   type   := 'b' | 'i' | 'f' | 's' | '[' type ']' | struct
//!
//! Export error handling is deliberately simple: unsupported values or malformed
//! JSON return handle 0.  The compiler rejects unsupported field types before
//! this layer is reachable for well-typed programs.

const std = @import("std");
const abi = @import("ffi/abi.zig");
const aggregate = @import("aggregate.zig");

pub const Symbol = abi.Symbol;

const allocator = std.heap.c_allocator;

pub const Error = error{
    InvalidSchema,
    InvalidJson,
    Unsupported,
    OutOfMemory,
};

fn stringBytes(handle: i64) ?[]const u8 {
    if (handle == 0) return &.{};
    const len = aggregate.e7_str_len(handle);
    if (len < 0) return null;
    if (len == 0) return &.{};
    const ptr: [*]const u8 = @ptrFromInt(@as(usize, @intCast(handle + 8)));
    return ptr[0..@intCast(len)];
}

fn newString(bytes: []const u8) i64 {
    const data: i64 = if (bytes.len == 0) 0 else @intCast(@intFromPtr(bytes.ptr));
    return aggregate.e7_str_new(data, @intCast(bytes.len));
}

// ------------------------------------------------------------- schema cursor ---

const SchemaCursor = struct {
    text: []const u8,
    pos: usize = 0,

    fn peek(self: *const SchemaCursor) ?u8 {
        if (self.pos >= self.text.len) return null;
        return self.text[self.pos];
    }

    fn advance(self: *SchemaCursor) ?u8 {
        if (self.pos >= self.text.len) return null;
        const ch = self.text[self.pos];
        self.pos += 1;
        return ch;
    }

    fn expect(self: *SchemaCursor, wanted: u8) Error!void {
        const ch = self.advance() orelse return error.InvalidSchema;
        if (ch != wanted) return error.InvalidSchema;
    }

    fn readFieldName(self: *SchemaCursor) Error![]const u8 {
        const start = self.pos;
        while (self.pos < self.text.len) : (self.pos += 1) {
            const ch = self.text[self.pos];
            if (ch == '=' or ch == ';' or ch == '}') break;
        }
        if (self.pos == start) return error.InvalidSchema;
        const name = self.text[start..self.pos];
        try self.expect('=');
        return name;
    }
};

/// Skip one schema type without a value (used to find the element type span for
/// vectors, including empty vectors).
fn skipType(cursor: *SchemaCursor) Error!void {
    const tag = cursor.advance() orelse return error.InvalidSchema;
    switch (tag) {
        'b', 'i', 'f', 's' => {},
        '[' => {
            try skipType(cursor);
            try cursor.expect(']');
        },
        '{' => {
            while (true) {
                if (cursor.peek() == '}') {
                    _ = cursor.advance();
                    return;
                }
                _ = try cursor.readFieldName();
                try skipType(cursor);
                if (cursor.peek() == ';') _ = cursor.advance();
            }
        },
        else => return error.InvalidSchema,
    }
}

// ------------------------------------------------------------------ encoding ---

fn appendFormatted(out: *std.ArrayList(u8), comptime format: []const u8, value: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, format, .{value});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn appendJsonString(out: *std.ArrayList(u8), bytes: []const u8) !void {
    try out.append(allocator, '"');
    for (bytes) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0c => try out.appendSlice(allocator, "\\f"),
            else => {
                if (byte < 0x20) {
                    try appendFormatted(out, "\\u{x:0>4}", byte);
                } else {
                    try out.append(allocator, byte);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

fn encodeType(out: *std.ArrayList(u8), cursor: *SchemaCursor, value: i64) Error!void {
    const tag = cursor.advance() orelse return error.InvalidSchema;
    switch (tag) {
        'b' => try out.appendSlice(allocator, if (value != 0) "true" else "false"),
        'i' => try appendFormatted(out, "{d}", value),
        'f' => {
            const number: f64 = @bitCast(value);
            if (!std.math.isFinite(number)) return error.Unsupported;
            try appendFormatted(out, "{d}", number);
        },
        's' => {
            const bytes = stringBytes(value) orelse return error.InvalidJson;
            try appendJsonString(out, bytes);
        },
        '[' => {
            const element_start = cursor.pos;
            var probe = SchemaCursor{ .text = cursor.text, .pos = element_start };
            try skipType(&probe);
            const element_end = probe.pos;
            const count = aggregate.e7_vec_len(value);
            if (count < 0) return error.InvalidJson;
            try out.append(allocator, '[');
            var index: i64 = 0;
            while (index < count) : (index += 1) {
                if (index > 0) try out.append(allocator, ',');
                var element_cursor = SchemaCursor{ .text = cursor.text, .pos = element_start };
                try encodeType(out, &element_cursor, aggregate.e7_vec_get(value, index));
                if (element_cursor.pos != element_end) return error.InvalidSchema;
            }
            try out.append(allocator, ']');
            cursor.pos = element_end;
            try cursor.expect(']');
        },
        '{' => {
            try out.append(allocator, '{');
            var fields: usize = 0;
            while (true) {
                if (cursor.peek() == '}') {
                    _ = cursor.advance();
                    break;
                }
                if (fields > 0) {
                    try out.append(allocator, ',');
                    try cursor.expect(';');
                }
                const name = try cursor.readFieldName();
                try appendJsonString(out, name);
                try out.append(allocator, ':');
                try encodeType(out, cursor, aggregate.e7_load_i64(value + @as(i64, @intCast(fields * 8))));
                fields += 1;
            }
            try out.append(allocator, '}');
        },
        else => return error.InvalidSchema,
    }
}

// ------------------------------------------------------------------ decoding ---

const JsonCursor = struct {
    text: []const u8,
    pos: usize = 0,

    fn skipWhitespace(self: *JsonCursor) void {
        while (self.pos < self.text.len) : (self.pos += 1) {
            switch (self.text[self.pos]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn peek(self: *JsonCursor) ?u8 {
        self.skipWhitespace();
        if (self.pos >= self.text.len) return null;
        return self.text[self.pos];
    }

    fn advance(self: *JsonCursor) ?u8 {
        self.skipWhitespace();
        if (self.pos >= self.text.len) return null;
        const ch = self.text[self.pos];
        self.pos += 1;
        return ch;
    }

    fn expect(self: *JsonCursor, wanted: u8) Error!void {
        const ch = self.advance() orelse return error.InvalidJson;
        if (ch != wanted) return error.InvalidJson;
    }

    fn expectKeyword(self: *JsonCursor, keyword: []const u8) Error!void {
        self.skipWhitespace();
        if (self.pos + keyword.len > self.text.len) return error.InvalidJson;
        if (!std.mem.eql(u8, self.text[self.pos..][0..keyword.len], keyword)) return error.InvalidJson;
        self.pos += keyword.len;
    }

    fn readNumberToken(self: *JsonCursor) Error![]const u8 {
        self.skipWhitespace();
        const start = self.pos;
        if (self.peek() == '-') _ = self.advance();
        var digits = false;
        while (self.pos < self.text.len) : (self.pos += 1) {
            switch (self.text[self.pos]) {
                '0'...'9' => digits = true,
                '.', 'e', 'E', '+', '-' => {},
                else => break,
            }
        }
        if (!digits) return error.InvalidJson;
        return self.text[start..self.pos];
    }

    fn readString(self: *JsonCursor) Error!std.ArrayList(u8) {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);
        try self.expect('"');
        while (true) {
            const ch = self.advance() orelse return error.InvalidJson;
            switch (ch) {
                '"' => {
                    return result;
                },
                '\\' => {
                    const escaped = self.advance() orelse return error.InvalidJson;
                    switch (escaped) {
                        '"' => try result.append(allocator, '"'),
                        '\\' => try result.append(allocator, '\\'),
                        '/' => try result.append(allocator, '/'),
                        'b' => try result.append(allocator, 0x08),
                        'f' => try result.append(allocator, 0x0c),
                        'n' => try result.append(allocator, '\n'),
                        'r' => try result.append(allocator, '\r'),
                        't' => try result.append(allocator, '\t'),
                        'u' => {
                            var code: u21 = 0;
                            for (0..4) |_| {
                                const digit = self.advance() orelse return error.InvalidJson;
                                const value = std.fmt.charToDigit(digit, 16) catch return error.InvalidJson;
                                code = code * 16 + value;
                            }
                            if (code >= 0xD800 and code <= 0xDFFF) return error.InvalidJson;
                            var buffer: [4]u8 = undefined;
                            const encoded = std.unicode.utf8Encode(code, &buffer) catch return error.InvalidJson;
                            try result.appendSlice(allocator, buffer[0..encoded]);
                        },
                        else => return error.InvalidJson,
                    }
                },
                else => try result.append(allocator, ch),
            }
        }
    }
};

fn countStructFields(schema: []const u8, start: usize) Error!usize {
    var pos = start;
    var depth: usize = 0;
    var fields: usize = 0;
    var has_content = false;
    while (pos < schema.len) : (pos += 1) {
        const ch = schema[pos];
        switch (ch) {
            '{', '[' => depth += 1,
            '}', ']' => {
                if (depth == 0) break;
                depth -= 1;
            },
            ';' => {
                if (depth == 0 and has_content) fields += 1;
            },
            else => {
                if (depth == 0) has_content = true;
            },
        }
    }
    if (has_content) fields += 1;
    return fields;
}

fn decodeType(schema: *SchemaCursor, json: *JsonCursor) Error!i64 {
    const tag = schema.advance() orelse return error.InvalidSchema;
    switch (tag) {
        'b' => {
            json.skipWhitespace();
            if (json.peek() == 't') {
                try json.expectKeyword("true");
                return 1;
            }
            try json.expectKeyword("false");
            return 0;
        },
        'i' => {
            const token = try json.readNumberToken();
            return std.fmt.parseInt(i64, token, 10) catch return error.InvalidJson;
        },
        'f' => {
            const token = try json.readNumberToken();
            const number = std.fmt.parseFloat(f64, token) catch return error.InvalidJson;
            return @bitCast(number);
        },
        's' => {
            var bytes = try json.readString();
            const str = newString(bytes.items);
            bytes.deinit(allocator);
            return str;
        },
        '[' => {
            const element_start = schema.pos;
            var probe = SchemaCursor{ .text = schema.text, .pos = element_start };
            try skipType(&probe);
            const element_end = probe.pos;
            var items = std.ArrayList(i64).empty;
            defer items.deinit(allocator);
            try json.expect('[');
            while (true) {
                if (json.peek() == ']') {
                    _ = json.advance();
                    break;
                }
                if (items.items.len > 0) try json.expect(',');
                var element_cursor = SchemaCursor{ .text = schema.text, .pos = element_start };
                const element = try decodeType(&element_cursor, json);
                if (element_cursor.pos != element_end) return error.InvalidSchema;
                try items.append(allocator, element);
            }
            const vector = aggregate.e7_vec_new(@intCast(items.items.len), 0);
            if (vector == 0 and items.items.len > 0) return error.OutOfMemory;
            for (items.items, 0..) |element, index| {
                aggregate.e7_vec_set(vector, @intCast(index), element);
            }
            schema.pos = element_end;
            try schema.expect(']');
            return vector;
        },
        '{' => {
            const field_count = try countStructFields(schema.text, schema.pos);
            const value = aggregate.e7_alloc_i64(@intCast(field_count));
            if (value == 0 and field_count > 0) return error.OutOfMemory;
            try json.expect('{');
            var index: usize = 0;
            while (index < field_count) : (index += 1) {
                if (index > 0) {
                    try json.expect(',');
                    try schema.expect(';');
                }
                const expected_name = try schema.readFieldName();
                var key = try json.readString();
                defer key.deinit(allocator);
                if (!std.mem.eql(u8, expected_name, key.items)) return error.InvalidJson;
                try json.expect(':');
                const decoded = try decodeType(schema, json);
                aggregate.e7_store_i64(value + @as(i64, @intCast(index * 8)), decoded);
            }
            try json.expect('}');
            try schema.expect('}');
            return value;
        },
        else => return error.InvalidSchema,
    }
}

// -------------------------------------------------------------- JIT-visible ---

/// `schema` and `text` are e7 `str` handles; result is an e7 `str` handle, or 0
/// if the value/schema is not encodable.
pub export fn e7_json_encode(schema: i64, value: i64) callconv(.c) i64 {
    const schema_bytes = stringBytes(schema) orelse return 0;
    if (schema_bytes.len == 0) return 0;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var cursor = SchemaCursor{ .text = schema_bytes };
    encodeType(&out, &cursor, value) catch return 0;
    if (cursor.pos != schema_bytes.len) return 0;
    return newString(out.items);
}

/// `schema` and `text` are e7 `str` handles; result is a derived struct handle,
/// or 0 on malformed JSON / schema mismatch.
pub export fn e7_json_decode(schema: i64, text: i64) callconv(.c) i64 {
    const schema_bytes = stringBytes(schema) orelse return 0;
    const text_bytes = stringBytes(text) orelse return 0;
    if (schema_bytes.len == 0) return 0;
    var schema_cursor = SchemaCursor{ .text = schema_bytes };
    var json_cursor = JsonCursor{ .text = text_bytes };
    const value = decodeType(&schema_cursor, &json_cursor) catch return 0;
    if (schema_cursor.pos != schema_bytes.len) return 0;
    return value;
}

pub fn symbols() [2]Symbol {
    return .{
        .{ .name = "e7_json_encode", .address = @intFromPtr(&e7_json_encode) },
        .{ .name = "e7_json_decode", .address = @intFromPtr(&e7_json_decode) },
    };
}

test "json encode/decode round-trips escaped strings" {
    const schema = newString("{name=s}");
    const value = aggregate.e7_alloc_i64(1);
    const name = newString("a\"b\nc");
    aggregate.e7_store_i64(value, name);

    const encoded = e7_json_encode(schema, value);
    try std.testing.expect(encoded != 0);
    const encoded_bytes = stringBytes(encoded).?;
    try std.testing.expectEqualStrings("{\"name\":\"a\\\"b\\nc\"}", encoded_bytes);

    const decoded = e7_json_decode(schema, encoded);
    try std.testing.expect(decoded != 0);
    const decoded_name = aggregate.e7_load_i64(decoded);
    try std.testing.expectEqualStrings("a\"b\nc", stringBytes(decoded_name).?);
}
