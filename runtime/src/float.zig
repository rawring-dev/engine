//! Float helpers for e7: the JIT ABI passes floats as the bit pattern of an
//! f64 in an i64 slot.  All helpers use f64 internally regardless of the e7
//! type spelling (`f32`/`f64`); e7 keeps a single runtime float representation
//! and narrows only at external ABIs that request it.
//!
//! Symbols are compiler-known (`compiler/src/intrinsics.zig`) and registered
//! with the JIT through `orc.Jit.addBytecode` via `float.symbols()`.  Boolean
//! results are 0/1 i64s; `e7_f32_to_i64` truncates toward zero and clamps to
//! the i64 range; `e7_f32_to_milli` rounds `value * 1000` to the nearest int.

const std = @import("std");
const abi = @import("ffi/abi.zig");

pub const Symbol = abi.Symbol;

fn fromBits(bits: i64) f64 {
    return @bitCast(bits);
}

fn toBits(value: f64) i64 {
    return @bitCast(value);
}

fn boolBits(value: bool) i64 {
    return if (value) 1 else 0;
}

fn toI64(value: f64) i64 {
    if (std.math.isNan(value)) return 0;
    const min: f64 = @floatFromInt(std.math.minInt(i64));
    const max: f64 = @floatFromInt(std.math.maxInt(i64));
    const clamped = std.math.clamp(value, min, max);
    return @intFromFloat(clamped);
}

// ----------------------------------------------------------- arithmetic ------

pub export fn e7_f32_add(a: i64, b: i64) callconv(.c) i64 {
    return toBits(fromBits(a) + fromBits(b));
}

pub export fn e7_f32_sub(a: i64, b: i64) callconv(.c) i64 {
    return toBits(fromBits(a) - fromBits(b));
}

pub export fn e7_f32_mul(a: i64, b: i64) callconv(.c) i64 {
    return toBits(fromBits(a) * fromBits(b));
}

pub export fn e7_f32_div(a: i64, b: i64) callconv(.c) i64 {
    return toBits(fromBits(a) / fromBits(b));
}

pub export fn e7_f32_neg(a: i64) callconv(.c) i64 {
    return toBits(-fromBits(a));
}

// ---------------------------------------------------------- comparisons ------

pub export fn e7_f32_eq(a: i64, b: i64) callconv(.c) i64 {
    return boolBits(fromBits(a) == fromBits(b));
}

pub export fn e7_f32_ne(a: i64, b: i64) callconv(.c) i64 {
    return boolBits(fromBits(a) != fromBits(b));
}

pub export fn e7_f32_lt(a: i64, b: i64) callconv(.c) i64 {
    return boolBits(fromBits(a) < fromBits(b));
}

pub export fn e7_f32_le(a: i64, b: i64) callconv(.c) i64 {
    return boolBits(fromBits(a) <= fromBits(b));
}

pub export fn e7_f32_gt(a: i64, b: i64) callconv(.c) i64 {
    return boolBits(fromBits(a) > fromBits(b));
}

pub export fn e7_f32_ge(a: i64, b: i64) callconv(.c) i64 {
    return boolBits(fromBits(a) >= fromBits(b));
}

// ---------------------------------------------------------------- math -------

pub export fn e7_f32_sin(a: i64) callconv(.c) i64 {
    return toBits(@sin(fromBits(a)));
}

pub export fn e7_f32_cos(a: i64) callconv(.c) i64 {
    return toBits(@cos(fromBits(a)));
}

pub export fn e7_f32_sqrt(a: i64) callconv(.c) i64 {
    return toBits(@sqrt(fromBits(a)));
}

pub export fn e7_f32_abs(a: i64) callconv(.c) i64 {
    return toBits(@abs(fromBits(a)));
}

pub export fn e7_f32_clamp(value: i64, minimum: i64, maximum: i64) callconv(.c) i64 {
    return toBits(std.math.clamp(fromBits(value), fromBits(minimum), fromBits(maximum)));
}

// ------------------------------------------------------------ conversion -----

pub export fn e7_f32_from_i64(value: i64) callconv(.c) i64 {
    return toBits(@floatFromInt(value));
}

pub export fn e7_f32_to_i64(value: i64) callconv(.c) i64 {
    return toI64(fromBits(value));
}

/// Round `value * 1000` to the nearest i64 (e.g. 1.2345 -> 1235).
pub export fn e7_f32_to_milli(value: i64) callconv(.c) i64 {
    return toI64(@round(fromBits(value) * 1000.0));
}

/// Convert an integer milli-units value to a float (e.g. 1235 -> 1.235).
pub export fn e7_f32_from_milli(value: i64) callconv(.c) i64 {
    return toBits(@as(f64, @floatFromInt(value)) / 1000.0);
}

pub fn symbols() [20]Symbol {
    return .{
        .{ .name = "e7_f32_add", .address = @intFromPtr(&e7_f32_add) },
        .{ .name = "e7_f32_sub", .address = @intFromPtr(&e7_f32_sub) },
        .{ .name = "e7_f32_mul", .address = @intFromPtr(&e7_f32_mul) },
        .{ .name = "e7_f32_div", .address = @intFromPtr(&e7_f32_div) },
        .{ .name = "e7_f32_neg", .address = @intFromPtr(&e7_f32_neg) },
        .{ .name = "e7_f32_eq", .address = @intFromPtr(&e7_f32_eq) },
        .{ .name = "e7_f32_ne", .address = @intFromPtr(&e7_f32_ne) },
        .{ .name = "e7_f32_lt", .address = @intFromPtr(&e7_f32_lt) },
        .{ .name = "e7_f32_le", .address = @intFromPtr(&e7_f32_le) },
        .{ .name = "e7_f32_gt", .address = @intFromPtr(&e7_f32_gt) },
        .{ .name = "e7_f32_ge", .address = @intFromPtr(&e7_f32_ge) },
        .{ .name = "e7_f32_sin", .address = @intFromPtr(&e7_f32_sin) },
        .{ .name = "e7_f32_cos", .address = @intFromPtr(&e7_f32_cos) },
        .{ .name = "e7_f32_sqrt", .address = @intFromPtr(&e7_f32_sqrt) },
        .{ .name = "e7_f32_abs", .address = @intFromPtr(&e7_f32_abs) },
        .{ .name = "e7_f32_clamp", .address = @intFromPtr(&e7_f32_clamp) },
        .{ .name = "e7_f32_from_i64", .address = @intFromPtr(&e7_f32_from_i64) },
        .{ .name = "e7_f32_to_i64", .address = @intFromPtr(&e7_f32_to_i64) },
        .{ .name = "e7_f32_to_milli", .address = @intFromPtr(&e7_f32_to_milli) },
        .{ .name = "e7_f32_from_milli", .address = @intFromPtr(&e7_f32_from_milli) },
    };
}

test "float helpers round-trip and compute" {
    const bits = e7_f32_from_i64(5);
    // 5.0 / 2.0 + 1.0 = 3.5
    const half = e7_f32_div(bits, e7_f32_from_i64(2));
    const three_point_five = e7_f32_add(half, e7_f32_from_i64(1));
    try std.testing.expectEqual(@as(i64, 3500), e7_f32_to_milli(three_point_five));
    try std.testing.expectEqual(@as(i64, 3), e7_f32_to_i64(three_point_five));
    try std.testing.expectEqual(@as(i64, 1), e7_f32_lt(half, three_point_five));
    try std.testing.expectEqual(@as(i64, 1000), e7_f32_to_milli(e7_f32_sin(e7_f32_from_milli(1571))));
    try std.testing.expectEqual(@as(i64, 1000), e7_f32_to_milli(e7_f32_cos(e7_f32_from_i64(0))));
    try std.testing.expectEqual(@as(i64, 3000), e7_f32_to_milli(e7_f32_sqrt(e7_f32_from_i64(9))));
    try std.testing.expectEqual(@as(i64, 2500), e7_f32_to_milli(e7_f32_abs(e7_f32_neg(e7_f32_from_milli(2500)))));
    try std.testing.expectEqual(@as(i64, 0), e7_f32_to_milli(e7_f32_clamp(e7_f32_from_i64(-5), e7_f32_from_i64(0), e7_f32_from_i64(1))));
}
