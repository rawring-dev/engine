//! Heap representation for aggregate values passed through the JIT ABI.
//!
//! Scalars remain i64.  Aggregates are pointers to malloc-owned slots:
//!   struct:  [field0, field1, ...]
//!   vector:  [length, 0, element0, ...]
//!   matrix:  [rows, columns, element0, ...]
//!   string:  [length, bytes...]
//!   map:     [length, capacity, entries_ptr] with (key, value) pairs
//!
//! Every element slot is 64 bits, so layout and pointer arithmetic stay simple.

const std = @import("std");
const abi = @import("ffi/abi.zig");

pub const Symbol = abi.Symbol;
pub const vector_add: u8 = 0;
pub const vector_sub: u8 = 1;
pub const vector_mul: u8 = 2;
pub const vector_div: u8 = 3;

fn allocSlots(count: usize) i64 {
    if (count == 0) return 0;
    const bytes = std.math.mul(usize, count, @sizeOf(i64)) catch return 0;
    const ptr = std.c.malloc(bytes) orelse return 0;
    @memset(@as([*]u8, @ptrCast(ptr))[0..bytes], 0);
    return @intCast(@intFromPtr(ptr));
}

fn slots(ptr: i64) [*]i64 {
    return @ptrFromInt(@as(usize, @intCast(ptr)));
}

fn bytePtr(ptr: i64) [*]u8 {
    return @ptrFromInt(@as(usize, @intCast(ptr)));
}

pub export fn e7_alloc_i64(size: i64) callconv(.c) i64 {
    if (size <= 0) return 0;
    return allocSlots(@intCast(size));
}

pub export fn e7_load_i64(ptr: i64) callconv(.c) i64 {
    if (ptr == 0) return 0;
    return slots(ptr)[0];
}

pub export fn e7_store_i64(ptr: i64, value: i64) callconv(.c) void {
    if (ptr == 0) return;
    slots(ptr)[0] = value;
}

pub export fn e7_load_u8(ptr: i64) callconv(.c) i64 {
    if (ptr == 0) return 0;
    return bytePtr(ptr)[0];
}

pub export fn e7_store_u8(ptr: i64, value: i64) callconv(.c) void {
    if (ptr == 0) return;
    bytePtr(ptr)[0] = @intCast(value & 0xff);
}

pub export fn e7_str_new(data: i64, len: i64) callconv(.c) i64 {
    if (len < 0) return 0;
    const ptr = allocSlots(1 + @as(usize, @intCast(@divTrunc(len + 7, 8))));
    if (ptr == 0) return 0;
    slots(ptr)[0] = len;
    if (data != 0 and len > 0) {
        const src: [*]const u8 = @ptrFromInt(@as(usize, @intCast(data)));
        @memcpy(bytePtr(ptr + 8)[0..@intCast(len)], src[0..@intCast(len)]);
    }
    return ptr;
}

pub export fn e7_str_len(str: i64) callconv(.c) i64 {
    if (str == 0) return 0;
    return slots(str)[0];
}

pub export fn e7_str_concat(a: i64, b: i64) callconv(.c) i64 {
    const alen = if (a == 0) 0 else slots(a)[0];
    const blen = if (b == 0) 0 else slots(b)[0];
    const total = alen + blen;
    const ptr = allocSlots(1 + @as(usize, @intCast(@divTrunc(total + 7, 8))));
    if (ptr == 0) return 0;
    slots(ptr)[0] = total;
    if (a != 0 and alen > 0) @memcpy(bytePtr(ptr + 8)[0..@intCast(alen)], bytePtr(a + 8)[0..@intCast(alen)]);
    if (b != 0 and blen > 0) @memcpy(bytePtr(ptr + 8 + alen)[0..@intCast(blen)], bytePtr(b + 8)[0..@intCast(blen)]);
    return ptr;
}

pub export fn e7_str_slice(str: i64, start: i64, end: i64) callconv(.c) i64 {
    const len: i64 = if (str == 0) 0 else slots(str)[0];
    var first: i64 = @max(0, start);
    var last: i64 = @min(len, end);
    if (first > len) first = len;
    if (last < first) last = first;
    const count = last - first;
    if (count <= 0) return e7_str_new(0, 0);
    return e7_str_new(str + 8 + first, count);
}

pub export fn e7_str_char_at(str: i64, index: i64) callconv(.c) i64 {
    const len: i64 = if (str == 0) 0 else slots(str)[0];
    if (index < 0 or index >= len) return e7_str_new(0, 0);
    return e7_str_new(str + 8 + index, 1);
}

pub export fn e7_str_eq(a: i64, b: i64) callconv(.c) i64 {
    if (a == b) return 1;
    if (a == 0 or b == 0) return 0;
    const alen = slots(a)[0];
    const blen = slots(b)[0];
    if (alen != blen) return 0;
    if (alen == 0) return 1;
    const ab = bytePtr(a + 8);
    const bb = bytePtr(b + 8);
    for (0..@intCast(alen)) |i| if (ab[i] != bb[i]) return 0;
    return 1;
}

pub export fn e7_vec_new(rows: i64, columns: i64) callconv(.c) i64 {
    if (rows < 0 or columns < 0) return 0;
    const count = std.math.mul(usize, @intCast(rows), @intCast(columns)) catch return 0;
    const elements = if (columns == 0) @as(usize, @intCast(rows)) else count;
    const ptr = allocSlots(2 + elements);
    if (ptr == 0) return 0;
    slots(ptr)[0] = rows;
    slots(ptr)[1] = columns;
    return ptr;
}

pub export fn e7_vec_len(vec: i64) callconv(.c) i64 {
    if (vec == 0) return 0;
    return slots(vec)[0];
}

pub export fn e7_vec_get(vec: i64, index: i64) callconv(.c) i64 {
    if (vec == 0 or index < 0) return 0;
    const rows = slots(vec)[0];
    const cols = slots(vec)[1];
    const count = if (cols == 0) rows else rows * cols;
    if (index >= count) return 0;
    return slots(vec + 16)[@intCast(index)];
}

pub export fn e7_vec_set(vec: i64, index: i64, value: i64) callconv(.c) void {
    if (vec == 0 or index < 0) return;
    const rows = slots(vec)[0];
    const cols = slots(vec)[1];
    const count = if (cols == 0) rows else rows * cols;
    if (index >= count) return;
    slots(vec + 16)[@intCast(index)] = value;
}

pub export fn e7_vec_row(matrix: i64, row: i64) callconv(.c) i64 {
    if (matrix == 0 or row < 0) return 0;
    const rows = slots(matrix)[0];
    const cols = slots(matrix)[1];
    if (row >= rows) return 0;
    const result = e7_vec_new(cols, 0);
    if (result == 0) return 0;
    const src = slots(matrix + 16);
    const dst = slots(result + 16);
    const start: usize = @intCast(row * cols);
    for (0..@intCast(cols)) |i| dst[i] = src[start + i];
    return result;
}

pub export fn e7_vec_get2(matrix: i64, row: i64, column: i64) callconv(.c) i64 {
    if (matrix == 0 or row < 0 or column < 0) return 0;
    const rows = slots(matrix)[0];
    const cols = slots(matrix)[1];
    if (cols == 0 or row >= rows or column >= cols) return 0;
    return slots(matrix + 16)[@intCast(row * cols + column)];
}

pub export fn e7_vec_set2(matrix: i64, row: i64, column: i64, value: i64) callconv(.c) void {
    if (matrix == 0 or row < 0 or column < 0) return;
    const rows = slots(matrix)[0];
    const cols = slots(matrix)[1];
    if (cols == 0 or row >= rows or column >= cols) return;
    slots(matrix + 16)[@intCast(row * cols + column)] = value;
}

/// Copy `vector` into matrix row `row`.  Vectors whose length differs from the
/// matrix column count are ignored, matching the out-of-range reads/writes of
/// the scalar helpers.
pub export fn e7_vec_set_row(matrix: i64, row: i64, vector: i64) callconv(.c) void {
    if (matrix == 0 or row < 0 or vector == 0) return;
    const rows = slots(matrix)[0];
    const cols = slots(matrix)[1];
    if (cols == 0 or row >= rows) return;
    if (slots(vector)[1] != 0 or slots(vector)[0] != cols) return;
    const src = slots(vector + 16);
    const dst = slots(matrix + 16);
    const start: usize = @intCast(row * cols);
    for (0..@intCast(cols)) |i| dst[start + i] = src[i];
}

fn elementCount(rows: i64, cols: i64) i64 {
    return if (cols == 0) rows else rows * cols;
}

fn divInt(a: i64, b: i64) i64 {
    if (b == 0) return 0;
    return @divTrunc(a, b);
}

fn applyBinary(op: u8, a: i64, b: i64) i64 {
    return switch (op) {
        vector_add => a +% b,
        vector_sub => a -% b,
        vector_mul => a *% b,
        vector_div => divInt(a, b),
        else => 0,
    };
}

pub export fn e7_vec_binary(op: u8, a: i64, b: i64) callconv(.c) i64 {
    if (a == 0 or b == 0) return 0;
    const ar = slots(a)[0];
    const ac = slots(a)[1];
    const br = slots(b)[0];
    const bc = slots(b)[1];
    const ad = slots(a + 16);
    const bd = slots(b + 16);

    if (ac == 0 and bc == 0) {
        if (op == vector_mul) {
            var sum: i64 = 0;
            const n = @min(ar, br);
            for (0..@intCast(n)) |i| sum +%= ad[i] *% bd[i];
            return sum;
        }
        const n = @min(ar, br);
        const result = e7_vec_new(n, 0);
        if (result == 0) return 0;
        const rd = slots(result + 16);
        for (0..@intCast(n)) |i| rd[i] = applyBinary(op, ad[i], bd[i]);
        return result;
    }

    if (ac != 0 and bc != 0) {
        if (op == vector_mul) {
            if (ac != br) return 0;
            const result = e7_vec_new(ar, bc);
            if (result == 0) return 0;
            const rd = slots(result + 16);
            for (0..@intCast(ar)) |i| {
                for (0..@intCast(bc)) |j| {
                    var sum: i64 = 0;
                    for (0..@intCast(ac)) |k| {
                        sum +%= ad[i * @as(usize, @intCast(ac)) + k] *% bd[k * @as(usize, @intCast(bc)) + j];
                    }
                    rd[i * @as(usize, @intCast(bc)) + j] = sum;
                }
            }
            return result;
        }
        if (ar != br or ac != bc) return 0;
        const result = e7_vec_new(ar, ac);
        if (result == 0) return 0;
        const rd = slots(result + 16);
        for (0..@intCast(ar * ac)) |i| rd[i] = applyBinary(op, ad[i], bd[i]);
        return result;
    }

    if (ac != 0 and bc == 0) {
        if (ac != br) return 0;
        const result = e7_vec_new(ar, 0);
        if (result == 0) return 0;
        const rd = slots(result + 16);
        for (0..@intCast(ar)) |i| {
            var sum: i64 = 0;
            for (0..@intCast(ac)) |k| {
                sum +%= ad[i * @as(usize, @intCast(ac)) + k] *% bd[k];
            }
            rd[i] = sum;
        }
        return result;
    }

    if (ar != br) return 0;
    const result = e7_vec_new(bc, 0);
    if (result == 0) return 0;
    const rd = slots(result + 16);
    for (0..@intCast(bc)) |j| {
        var sum: i64 = 0;
        for (0..@intCast(ar)) |i| sum +%= ad[i] *% bd[i * @as(usize, @intCast(bc)) + j];
        rd[j] = sum;
    }
    return result;
}

pub export fn e7_vec_scalar(op: u8, vec: i64, scalar: i64) callconv(.c) i64 {
    if (vec == 0) return 0;
    const rows = slots(vec)[0];
    const cols = slots(vec)[1];
    const count = if (cols == 0) rows else rows * cols;
    const result = e7_vec_new(rows, cols);
    if (result == 0) return 0;
    const src = slots(vec + 16);
    const dst = slots(result + 16);
    const scalar_left = (op & 0x80) != 0;
    const base_op = op & 0x7f;
    for (0..@intCast(count)) |i| {
        dst[i] = if (scalar_left)
            applyBinary(base_op, scalar, src[i])
        else
            applyBinary(base_op, src[i], scalar);
    }
    return result;
}

pub export fn e7_map_new() callconv(.c) i64 {
    return allocSlots(3);
}

pub export fn e7_map_len(map: i64) callconv(.c) i64 {
    if (map == 0) return 0;
    return slots(map)[0];
}

fn mapEntryAt(map: i64, index: i64, column: usize) i64 {
    if (map == 0 or index < 0) return 0;
    const len = slots(map)[0];
    if (index >= len) return 0;
    const entries_ptr = slots(map)[2];
    if (entries_ptr == 0) return 0;
    const entries: [*]i64 = @ptrFromInt(@as(usize, @intCast(entries_ptr)));
    return entries[@as(usize, @intCast(index)) * 2 + column];
}

pub export fn e7_map_key_at(map: i64, index: i64) callconv(.c) i64 {
    return mapEntryAt(map, index, 0);
}

pub export fn e7_map_value_at(map: i64, index: i64) callconv(.c) i64 {
    return mapEntryAt(map, index, 1);
}

pub export fn e7_map_get(map: i64, key: i64) callconv(.c) i64 {
    if (map == 0) return 0;
    const len = slots(map)[0];
    const entries_ptr = slots(map)[2];
    if (entries_ptr == 0) return 0;
    const entries: [*]i64 = @ptrFromInt(@as(usize, @intCast(entries_ptr)));
    var i: usize = 0;
    while (i < @as(usize, @intCast(len))) : (i += 1) {
        if (entries[i * 2] == key) return entries[i * 2 + 1];
    }
    return 0;
}

pub export fn e7_map_get_str(map: i64, key: i64) callconv(.c) i64 {
    if (map == 0) return 0;
    const len = slots(map)[0];
    const entries_ptr = slots(map)[2];
    if (entries_ptr == 0) return 0;
    const entries: [*]i64 = @ptrFromInt(@as(usize, @intCast(entries_ptr)));
    var i: usize = 0;
    while (i < @as(usize, @intCast(len))) : (i += 1) {
        if (e7_str_eq(entries[i * 2], key) != 0) return entries[i * 2 + 1];
    }
    return 0;
}

pub export fn e7_map_set(map: i64, key: i64, value: i64) callconv(.c) void {
    if (map == 0) return;
    const len = slots(map)[0];
    var cap = slots(map)[1];
    var entries_ptr = slots(map)[2];
    var entries: [*]i64 = if (entries_ptr == 0) undefined else @ptrFromInt(@as(usize, @intCast(entries_ptr)));
    var i: usize = 0;
    while (i < @as(usize, @intCast(len))) : (i += 1) {
        if (entries[i * 2] == key) {
            entries[i * 2 + 1] = value;
            return;
        }
    }
    if (len >= cap) {
        const next_cap: i64 = if (cap == 0) 8 else cap * 2;
        const bytes = @as(usize, @intCast(next_cap)) * 2 * @sizeOf(i64);
        const raw = if (entries_ptr == 0)
            std.c.malloc(bytes)
        else
            std.c.realloc(@ptrFromInt(@as(usize, @intCast(entries_ptr))), bytes);
        const mem = raw orelse return;
        entries_ptr = @intCast(@intFromPtr(mem));
        slots(map)[2] = entries_ptr;
        slots(map)[1] = next_cap;
        cap = next_cap;
        entries = @ptrFromInt(@as(usize, @intCast(entries_ptr)));
    }
    entries[@intCast(len * 2)] = key;
    entries[@intCast(len * 2 + 1)] = value;
    slots(map)[0] = len + 1;
}

pub export fn e7_map_set_str(map: i64, key: i64, value: i64) callconv(.c) void {
    if (map == 0) return;
    const len = slots(map)[0];
    const entries: [*]i64 = if (slots(map)[2] == 0) undefined else @ptrFromInt(@as(usize, @intCast(slots(map)[2])));
    var i: usize = 0;
    while (i < @as(usize, @intCast(len))) : (i += 1) {
        if (e7_str_eq(entries[i * 2], key) != 0) {
            entries[i * 2 + 1] = value;
            return;
        }
    }
    e7_map_set(map, key, value);
}

// ---------------------------------------------------------------------------
// Generic text/parsing helpers used by e7 libraries (e.g. engine/obj.e7)
// ---------------------------------------------------------------------------

fn isFieldWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

/// Count non-overlapping tokens separated by ASCII whitespace.
fn countWhitespaceFields(bytes: []const u8) usize {
    var count: usize = 0;
    var in_token = false;
    for (bytes) |byte| {
        if (isFieldWhitespace(byte)) {
            in_token = false;
        } else if (!in_token) {
            in_token = true;
            count += 1;
        }
    }
    return count;
}

/// Split text on line endings into an e7 `[str]` vector.  A trailing final
/// newline does not add an empty final line; interior empty lines are kept.
pub export fn e7_str_lines(text: i64) callconv(.c) i64 {
    const length: usize = if (text == 0) 0 else @intCast(@max(slots(text)[0], 0));
    if (length == 0) return e7_vec_new(0, 0);
    const bytes = bytePtr(text + 8);
    var line_count: usize = 0;
    for (bytes[0..length]) |byte| {
        if (byte == '\n') line_count += 1;
    }
    if (bytes[length - 1] != '\n') line_count += 1;
    const result = e7_vec_new(@intCast(line_count), 0);
    if (result == 0) return 0;
    const elements = slots(result + 16);
    var start: usize = 0;
    var line_index: usize = 0;
    var index: usize = 0;
    while (index < length) : (index += 1) {
        if (bytes[index] != '\n') continue;
        var end = index;
        if (end > start and bytes[end - 1] == '\r') end -= 1;
        elements[line_index] = e7_str_new(
            text + 8 + @as(i64, @intCast(start)),
            @intCast(end - start),
        );
        line_index += 1;
        start = index + 1;
    }
    if (start < length) {
        var end = length;
        if (end > start and bytes[end - 1] == '\r') end -= 1;
        elements[line_index] = e7_str_new(
            text + 8 + @as(i64, @intCast(start)),
            @intCast(end - start),
        );
    }
    return result;
}

/// Split text on ASCII whitespace into an e7 `[str]` vector.  Leading/trailing
/// whitespace and repeated separators do not produce empty fields.
pub export fn e7_str_fields(text: i64) callconv(.c) i64 {
    const length: usize = if (text == 0) 0 else @intCast(@max(slots(text)[0], 0));
    if (length == 0) return e7_vec_new(0, 0);
    const bytes = bytePtr(text + 8);
    const field_count = countWhitespaceFields(bytes[0..length]);
    const result = e7_vec_new(@intCast(field_count), 0);
    if (result == 0) return 0;
    const elements = slots(result + 16);
    var field_index: usize = 0;
    var index: usize = 0;
    while (index < length) {
        while (index < length and isFieldWhitespace(bytes[index])) index += 1;
        if (index >= length) break;
        const start = index;
        while (index < length and !isFieldWhitespace(bytes[index])) index += 1;
        elements[field_index] = e7_str_new(
            text + 8 + @as(i64, @intCast(start)),
            @intCast(index - start),
        );
        field_index += 1;
    }
    return result;
}

/// Split text on a single-byte separator string into an e7 `[str]` vector.
/// Empty fields are preserved (`"1//2"` with "/" -> ["1", "", "2"]).  A
/// separator that is not exactly one byte returns an empty vector.
pub export fn e7_str_split(text: i64, separator: i64) callconv(.c) i64 {
    const separator_length: usize = if (separator == 0) 0 else @intCast(@max(slots(separator)[0], 0));
    if (separator_length != 1) return e7_vec_new(0, 0);
    const separator_byte = bytePtr(separator + 8)[0];
    const length: usize = if (text == 0) 0 else @intCast(@max(slots(text)[0], 0));
    if (length == 0) return e7_vec_new(0, 0);
    const bytes = bytePtr(text + 8);
    var piece_count: usize = 1;
    for (bytes[0..length]) |byte| {
        if (byte == separator_byte) piece_count += 1;
    }
    const result = e7_vec_new(@intCast(piece_count), 0);
    if (result == 0) return 0;
    const elements = slots(result + 16);
    var start: usize = 0;
    var piece_index: usize = 0;
    var index: usize = 0;
    while (index <= length) : (index += 1) {
        if (index != length and bytes[index] != separator_byte) continue;
        elements[piece_index] = e7_str_new(
            text + 8 + @as(i64, @intCast(start)),
            @intCast(index - start),
        );
        piece_index += 1;
        start = index + 1;
    }
    return result;
}

/// Parse an optionally signed decimal i64.  Surrounding ASCII whitespace is
/// ignored; malformed input and overflow return 0.
pub export fn e7_parse_i64(text: i64) callconv(.c) i64 {
    const length: usize = if (text == 0) 0 else @intCast(@max(slots(text)[0], 0));
    if (length == 0) return 0;
    const bytes = bytePtr(text + 8);
    var index: usize = 0;
    while (index < length and isFieldWhitespace(bytes[index])) index += 1;
    var negative = false;
    if (index < length and (bytes[index] == '+' or bytes[index] == '-')) {
        negative = bytes[index] == '-';
        index += 1;
    }
    const digit_start = index;
    var value: i64 = 0;
    while (index < length and bytes[index] >= '0' and bytes[index] <= '9') : (index += 1) {
        const digit: i64 = bytes[index] - '0';
        if (value > @divTrunc(std.math.maxInt(i64) - digit, 10)) return 0;
        value = value * 10 + digit;
    }
    if (index == digit_start) return 0;
    while (index < length and isFieldWhitespace(bytes[index])) index += 1;
    if (index != length) return 0;
    return if (negative) -value else value;
}

/// Parse an ASCII float into the e7 float representation (an f64 bit pattern
/// stored in an i64 slot).  Malformed input returns 0.0.
pub export fn e7_parse_f32(text: i64) callconv(.c) i64 {
    const length: usize = if (text == 0) 0 else @intCast(@max(slots(text)[0], 0));
    if (length == 0) return 0;
    const bytes = bytePtr(text + 8);
    var start: usize = 0;
    var end = length;
    while (start < end and isFieldWhitespace(bytes[start])) start += 1;
    while (end > start and isFieldWhitespace(bytes[end - 1])) end -= 1;
    if (start == end) return 0;
    const value = std.fmt.parseFloat(f64, bytes[start..end]) catch return 0;
    return @bitCast(value);
}

/// Append one element to a vector, returning a new vector (vectors are
/// immutable aggregates in e7: assign the result back).  Matrices and invalid
/// handles return 0.
pub export fn e7_vec_push(vec: i64, value: i64) callconv(.c) i64 {
    if (vec == 0) {
        // A missing aggregate (e.g. an absent map key) is treated as an empty
        // vector, which makes `list = e7_vec_push(list, value)` ergonomic.
        const created = e7_vec_new(1, 0);
        if (created == 0) return 0;
        slots(created + 16)[0] = value;
        return created;
    }
    const rows = slots(vec)[0];
    const columns = slots(vec)[1];
    if (rows < 0 or columns != 0) return 0;
    const result = e7_vec_new(rows + 1, 0);
    if (result == 0) return 0;
    const source = slots(vec + 16);
    const destination = slots(result + 16);
    const count: usize = @intCast(rows);
    for (0..count) |index| destination[index] = source[index];
    destination[count] = value;
    return result;
}

pub fn symbols() [46]Symbol {
    return .{
        .{ .name = "e7_alloc_i64", .address = @intFromPtr(&e7_alloc_i64) },
        .{ .name = "e7_load_i64", .address = @intFromPtr(&e7_load_i64) },
        .{ .name = "e7_store_i64", .address = @intFromPtr(&e7_store_i64) },
        .{ .name = "e7_load_u8", .address = @intFromPtr(&e7_load_u8) },
        .{ .name = "e7_store_u8", .address = @intFromPtr(&e7_store_u8) },
        .{ .name = "e7_str_new", .address = @intFromPtr(&e7_str_new) },
        .{ .name = "e7_str_concat", .address = @intFromPtr(&e7_str_concat) },
        .{ .name = "e7_str_len", .address = @intFromPtr(&e7_str_len) },
        .{ .name = "e7_str_slice", .address = @intFromPtr(&e7_str_slice) },
        .{ .name = "e7_str_char_at", .address = @intFromPtr(&e7_str_char_at) },
        .{ .name = "e7_str_eq", .address = @intFromPtr(&e7_str_eq) },
        .{ .name = "e7_str_data", .address = @intFromPtr(&e7_str_data) },
        .{ .name = "e7_cstr", .address = @intFromPtr(&e7_cstr) },
        .{ .name = "e7_memcpy", .address = @intFromPtr(&abi.e7_memcpy) },
        .{ .name = "e7_alloc_bytes", .address = @intFromPtr(&e7_alloc_bytes) },
        .{ .name = "e7_free_ptr", .address = @intFromPtr(&e7_free_ptr) },
        .{ .name = "e7_load_u16", .address = @intFromPtr(&e7_load_u16) },
        .{ .name = "e7_store_u16", .address = @intFromPtr(&e7_store_u16) },
        .{ .name = "e7_load_u32", .address = @intFromPtr(&e7_load_u32) },
        .{ .name = "e7_store_u32", .address = @intFromPtr(&e7_store_u32) },
        .{ .name = "e7_load_u64", .address = @intFromPtr(&e7_load_u64) },
        .{ .name = "e7_store_u64", .address = @intFromPtr(&e7_store_u64) },
        .{ .name = "e7_vec_new", .address = @intFromPtr(&e7_vec_new) },
        .{ .name = "e7_vec_len", .address = @intFromPtr(&e7_vec_len) },
        .{ .name = "e7_vec_get", .address = @intFromPtr(&e7_vec_get) },
        .{ .name = "e7_vec_set", .address = @intFromPtr(&e7_vec_set) },
        .{ .name = "e7_vec_row", .address = @intFromPtr(&e7_vec_row) },
        .{ .name = "e7_vec_get2", .address = @intFromPtr(&e7_vec_get2) },
        .{ .name = "e7_vec_set2", .address = @intFromPtr(&e7_vec_set2) },
        .{ .name = "e7_vec_set_row", .address = @intFromPtr(&e7_vec_set_row) },
        .{ .name = "e7_vec_binary", .address = @intFromPtr(&e7_vec_binary) },
        .{ .name = "e7_vec_scalar", .address = @intFromPtr(&e7_vec_scalar) },
        .{ .name = "e7_map_new", .address = @intFromPtr(&e7_map_new) },
        .{ .name = "e7_map_len", .address = @intFromPtr(&e7_map_len) },
        .{ .name = "e7_map_get", .address = @intFromPtr(&e7_map_get) },
        .{ .name = "e7_map_set", .address = @intFromPtr(&e7_map_set) },
        .{ .name = "e7_map_get_str", .address = @intFromPtr(&e7_map_get_str) },
        .{ .name = "e7_map_set_str", .address = @intFromPtr(&e7_map_set_str) },
        .{ .name = "e7_map_key_at", .address = @intFromPtr(&e7_map_key_at) },
        .{ .name = "e7_map_value_at", .address = @intFromPtr(&e7_map_value_at) },
        .{ .name = "e7_str_lines", .address = @intFromPtr(&e7_str_lines) },
        .{ .name = "e7_str_fields", .address = @intFromPtr(&e7_str_fields) },
        .{ .name = "e7_str_split", .address = @intFromPtr(&e7_str_split) },
        .{ .name = "e7_parse_i64", .address = @intFromPtr(&e7_parse_i64) },
        .{ .name = "e7_parse_f32", .address = @intFromPtr(&e7_parse_f32) },
        .{ .name = "e7_vec_push", .address = @intFromPtr(&e7_vec_push) },
    };
}

test "string slices, characters, and map entry accessors" {
    const text = e7_str_new(@intCast(@intFromPtr("abcdef".ptr)), 6);
    try std.testing.expectEqual(@as(i64, 6), e7_str_len(text));

    const slice = e7_str_slice(text, 1, 3);
    try std.testing.expectEqual(@as(i64, 2), e7_str_len(slice));
    try std.testing.expectEqualStrings("bc", bytePtr(slice + 8)[0..2]);

    const char = e7_str_char_at(text, 4);
    try std.testing.expectEqual(@as(i64, 1), e7_str_len(char));
    try std.testing.expectEqualStrings("e", bytePtr(char + 8)[0..1]);

    try std.testing.expectEqual(@as(i64, 0), e7_str_len(e7_str_char_at(text, 99)));
    try std.testing.expectEqual(@as(i64, 0), e7_str_len(e7_str_slice(text, 4, 2)));

    const clamped = e7_str_slice(text, -2, 99);
    try std.testing.expectEqual(@as(i64, 6), e7_str_len(clamped));
    try std.testing.expectEqualStrings("abcdef", bytePtr(clamped + 8)[0..6]);

    const map = e7_map_new();
    e7_map_set(map, 7, 70);
    e7_map_set(map, 9, 90);
    try std.testing.expectEqual(@as(i64, 2), e7_map_len(map));
    try std.testing.expectEqual(@as(i64, 7), e7_map_key_at(map, 0));
    try std.testing.expectEqual(@as(i64, 90), e7_map_value_at(map, 1));
    try std.testing.expectEqual(@as(i64, 0), e7_map_key_at(map, 5));
    try std.testing.expectEqual(@as(i64, 0), e7_map_value_at(map, -1));
}

test "matrix two-dimensional access and row assignment" {
    const matrix = e7_vec_new(2, 3);
    e7_vec_set(matrix, 0, 1);
    e7_vec_set(matrix, 1, 2);
    e7_vec_set(matrix, 2, 3);
    e7_vec_set(matrix, 3, 4);
    e7_vec_set(matrix, 4, 5);
    e7_vec_set(matrix, 5, 6);

    try std.testing.expectEqual(@as(i64, 1), e7_vec_get2(matrix, 0, 0));
    try std.testing.expectEqual(@as(i64, 2), e7_vec_get2(matrix, 0, 1));
    try std.testing.expectEqual(@as(i64, 6), e7_vec_get2(matrix, 1, 2));
    // Bounds: reads return 0 and writes are ignored.
    try std.testing.expectEqual(@as(i64, 0), e7_vec_get2(matrix, 2, 0));
    try std.testing.expectEqual(@as(i64, 0), e7_vec_get2(matrix, 0, 3));
    try std.testing.expectEqual(@as(i64, 0), e7_vec_get2(matrix, -1, 0));
    e7_vec_set2(matrix, 1, 0, 42);
    try std.testing.expectEqual(@as(i64, 42), e7_vec_get2(matrix, 1, 0));
    e7_vec_set2(matrix, 5, 0, 99);
    e7_vec_set2(matrix, 0, 5, 99);
    try std.testing.expectEqual(@as(i64, 42), e7_vec_get2(matrix, 1, 0));

    const row = e7_vec_new(3, 0);
    e7_vec_set(row, 0, 7);
    e7_vec_set(row, 1, 8);
    e7_vec_set(row, 2, 9);
    e7_vec_set_row(matrix, 0, row);
    try std.testing.expectEqual(@as(i64, 7), e7_vec_get2(matrix, 0, 0));
    try std.testing.expectEqual(@as(i64, 9), e7_vec_get2(matrix, 0, 2));

    // Wrong-width rows and out-of-range rows are ignored.
    const short = e7_vec_new(2, 0);
    e7_vec_set(short, 0, 100);
    e7_vec_set(short, 1, 101);
    e7_vec_set_row(matrix, 0, short);
    e7_vec_set_row(matrix, 7, row);
    try std.testing.expectEqual(@as(i64, 7), e7_vec_get2(matrix, 0, 0));
    try std.testing.expectEqual(@as(i64, 9), e7_vec_get2(matrix, 0, 2));
}

test "text helpers split lines, fields, and separator bytes" {
    const source = "one\ntwo\n\nthree\r\n";
    const text = e7_str_new(@intCast(@intFromPtr(source.ptr)), source.len);
    const lines = e7_str_lines(text);
    try std.testing.expectEqual(@as(i64, 4), e7_vec_len(lines));
    const expected = [_][]const u8{ "one", "two", "", "three" };
    for (expected, 0..) |want, index| {
        const line = e7_vec_get(lines, @intCast(index));
        try std.testing.expectEqual(@as(i64, @intCast(want.len)), e7_str_len(line));
        try std.testing.expectEqualStrings(want, bytePtr(line + 8)[0..want.len]);
    }

    const spaced = "  a  b\tc\n";
    const fields = e7_str_fields(e7_str_new(@intCast(@intFromPtr(spaced.ptr)), spaced.len));
    try std.testing.expectEqual(@as(i64, 3), e7_vec_len(fields));
    try std.testing.expectEqualStrings("a", bytePtr(e7_vec_get(fields, 0) + 8)[0..1]);
    try std.testing.expectEqualStrings("b", bytePtr(e7_vec_get(fields, 1) + 8)[0..1]);
    try std.testing.expectEqualStrings("c", bytePtr(e7_vec_get(fields, 2) + 8)[0..1]);

    const slash = "/";
    const face = "1//2";
    const parts = e7_str_split(
        e7_str_new(@intCast(@intFromPtr(face.ptr)), face.len),
        e7_str_new(@intCast(@intFromPtr(slash.ptr)), slash.len),
    );
    try std.testing.expectEqual(@as(i64, 3), e7_vec_len(parts));
    try std.testing.expectEqual(@as(i64, 1), e7_str_len(e7_vec_get(parts, 0)));
    try std.testing.expectEqual(@as(i64, 0), e7_str_len(e7_vec_get(parts, 1)));
    try std.testing.expectEqual(@as(i64, 1), e7_str_len(e7_vec_get(parts, 2)));
}

test "text helpers parse numbers and push vector elements" {
    const integer_text = " -42 ";
    try std.testing.expectEqual(
        @as(i64, -42),
        e7_parse_i64(e7_str_new(@intCast(@intFromPtr(integer_text.ptr)), integer_text.len)),
    );
    const bad_integer = "12x";
    try std.testing.expectEqual(
        @as(i64, 0),
        e7_parse_i64(e7_str_new(@intCast(@intFromPtr(bad_integer.ptr)), bad_integer.len)),
    );

    const float_text = "1.5";
    const bits = e7_parse_f32(e7_str_new(@intCast(@intFromPtr(float_text.ptr)), float_text.len));
    const value: f64 = @bitCast(bits);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), value, 1e-12);

    var vector = e7_vec_new(0, 0);
    vector = e7_vec_push(vector, 10);
    vector = e7_vec_push(vector, 20);
    try std.testing.expectEqual(@as(i64, 2), e7_vec_len(vector));
    try std.testing.expectEqual(@as(i64, 10), e7_vec_get(vector, 0));
    try std.testing.expectEqual(@as(i64, 20), e7_vec_get(vector, 1));
    const from_missing = e7_vec_push(0, 7);
    try std.testing.expectEqual(@as(i64, 1), e7_vec_len(from_missing));
    try std.testing.expectEqual(@as(i64, 7), e7_vec_get(from_missing, 0));
}

/// Raw byte allocation (`malloc`), distinct from slot-oriented `e7_alloc_i64`.
pub export fn e7_alloc_bytes(size: i64) callconv(.c) i64 {
    if (size <= 0) return 0;
    const bytes = @as(usize, @intCast(size));
    const ptr = std.c.malloc(bytes) orelse return 0;
    @memset(@as([*]u8, @ptrCast(ptr))[0..bytes], 0);
    return @intCast(@intFromPtr(ptr));
}

pub export fn e7_free_ptr(ptr: i64) callconv(.c) void {
    if (ptr == 0) return;
    std.c.free(@ptrFromInt(@as(usize, @intCast(ptr))));
}

/// Pointer to a string aggregate's first byte (not NUL-terminated).
pub export fn e7_str_data(str: i64) callconv(.c) i64 {
    if (str == 0) return 0;
    const len = slots(str)[0];
    if (len <= 0) return 0;
    return str + 8;
}

pub export fn e7_load_u16(ptr: i64) callconv(.c) i64 {
    if (ptr == 0) return 0;
    return @as(*align(1) const u16, @ptrFromInt(@as(usize, @intCast(ptr)))).*;
}

pub export fn e7_store_u16(ptr: i64, value: i64) callconv(.c) void {
    if (ptr == 0) return;
    @as(*align(1) u16, @ptrFromInt(@as(usize, @intCast(ptr)))).* = @truncate(@as(u64, @bitCast(value)));
}

pub export fn e7_load_u32(ptr: i64) callconv(.c) i64 {
    if (ptr == 0) return 0;
    return @as(*align(1) const u32, @ptrFromInt(@as(usize, @intCast(ptr)))).*;
}

pub export fn e7_store_u32(ptr: i64, value: i64) callconv(.c) void {
    if (ptr == 0) return;
    @as(*align(1) u32, @ptrFromInt(@as(usize, @intCast(ptr)))).* = @truncate(@as(u64, @bitCast(value)));
}

pub export fn e7_load_u64(ptr: i64) callconv(.c) i64 {
    if (ptr == 0) return 0;
    return @bitCast(@as(*align(1) const u64, @ptrFromInt(@as(usize, @intCast(ptr)))).*);
}

pub export fn e7_store_u64(ptr: i64, value: i64) callconv(.c) void {
    if (ptr == 0) return;
    @as(*align(1) u64, @ptrFromInt(@as(usize, @intCast(ptr)))).* = @bitCast(value);
}

/// Allocate a NUL-terminated copy of a string aggregate for C APIs.  The caller
/// owns the result and releases it with `e7_free_ptr`.
pub export fn e7_cstr(str: i64) callconv(.c) i64 {
    if (str == 0) return 0;
    const len = slots(str)[0];
    if (len < 0) return 0;
    const size = std.math.add(usize, @as(usize, @intCast(len)), 1) catch return 0;
    const raw = std.c.malloc(size) orelse return 0;
    const ptr: [*]u8 = @ptrCast(raw);
    if (len > 0) {
        const src: [*]const u8 = @ptrFromInt(@as(usize, @intCast(str + 8)));
        @memcpy(ptr[0..@intCast(len)], src[0..@intCast(len)]);
    }
    ptr[@intCast(len)] = 0;
    return @intCast(@intFromPtr(raw));
}
