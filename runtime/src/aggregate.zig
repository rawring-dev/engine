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

pub export fn e7_map_get(map: i64, key: i64) callconv(.c) i64 {
    if (map == 0) return 0;
    const len = slots(map)[0];
    const entries: [*]i64 = @ptrFromInt(@as(usize, @intCast(slots(map)[2])));
    var i: usize = 0;
    while (i < @as(usize, @intCast(len))) : (i += 1) {
        if (entries[i * 2] == key) return entries[i * 2 + 1];
    }
    return 0;
}

pub export fn e7_map_get_str(map: i64, key: i64) callconv(.c) i64 {
    if (map == 0) return 0;
    const len = slots(map)[0];
    const entries: [*]i64 = @ptrFromInt(@as(usize, @intCast(slots(map)[2])));
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

pub fn symbols() [21]Symbol {
    return .{
        .{ .name = "e7_alloc_i64", .address = @intFromPtr(&e7_alloc_i64) },
        .{ .name = "e7_load_i64", .address = @intFromPtr(&e7_load_i64) },
        .{ .name = "e7_store_i64", .address = @intFromPtr(&e7_store_i64) },
        .{ .name = "e7_load_u8", .address = @intFromPtr(&e7_load_u8) },
        .{ .name = "e7_store_u8", .address = @intFromPtr(&e7_store_u8) },
        .{ .name = "e7_str_new", .address = @intFromPtr(&e7_str_new) },
        .{ .name = "e7_str_concat", .address = @intFromPtr(&e7_str_concat) },
        .{ .name = "e7_str_len", .address = @intFromPtr(&e7_str_len) },
        .{ .name = "e7_str_eq", .address = @intFromPtr(&e7_str_eq) },
        .{ .name = "e7_vec_new", .address = @intFromPtr(&e7_vec_new) },
        .{ .name = "e7_vec_len", .address = @intFromPtr(&e7_vec_len) },
        .{ .name = "e7_vec_get", .address = @intFromPtr(&e7_vec_get) },
        .{ .name = "e7_vec_set", .address = @intFromPtr(&e7_vec_set) },
        .{ .name = "e7_vec_row", .address = @intFromPtr(&e7_vec_row) },
        .{ .name = "e7_vec_binary", .address = @intFromPtr(&e7_vec_binary) },
        .{ .name = "e7_vec_scalar", .address = @intFromPtr(&e7_vec_scalar) },
        .{ .name = "e7_map_new", .address = @intFromPtr(&e7_map_new) },
        .{ .name = "e7_map_get", .address = @intFromPtr(&e7_map_get) },
        .{ .name = "e7_map_set", .address = @intFromPtr(&e7_map_set) },
        .{ .name = "e7_map_get_str", .address = @intFromPtr(&e7_map_get_str) },
        .{ .name = "e7_map_set_str", .address = @intFromPtr(&e7_map_set_str) },
    };
}
