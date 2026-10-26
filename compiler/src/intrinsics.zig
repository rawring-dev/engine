//! Compiler-known external intrinsics callable from e7 by name.
//!
//! There is no extern-declaration syntax in the surface language.  A call such
//! as `e7_engine_window_create("engine7", 960, 540)` resolves here, is
//! type-checked against this table, and lowers to a bytecode `runtime_call` to
//! the matching `e7_*` symbol.  Units that cross the ABI boundary are integer
//! scaled (see per-function comments) so e7 does not need float arithmetic.
//!
//! Runtime symbols live in `runtime/src/engine.zig` (window/scene helpers) and
//! are registered with the JIT through `engine.symbols()`.

const std = @import("std");

pub const ValueType = enum {
    /// Signed 64-bit integer (`i64` / `isize`).
    i64_,
    /// Unsigned 64-bit integer (`u64` / `usize`).
    u64_,
    /// Signed 32-bit integer (`i32`).
    i32_,
    bool_,
    /// f64-bit-pattern float value (e7 `f32`/`f64` share this representation).
    float_,
    /// Runtime string value (aggregate handle).
    str_,
    unit,
};

pub const Function = struct {
    name: []const u8,
    params: []const ValueType,
    result: ValueType,
    /// Human-readable units for the integer-scaled ABI.
    units: []const u8 = "",
};

/// `title` is an e7 string value.
pub const window_create_units = "width/height in pixels";
/// Scene camera: x/y/z are world units x1000; yaw/pitch are degrees x1000.
pub const scene_camera_units = "eye xyz in milli-units, yaw/pitch in milli-degrees";
/// Scene draw: delta in milliseconds; cube angle in milli-radians; light xyz
/// in milli-units.
pub const scene_draw_units = "delta_ms, cube angle milli-radians, light xyz milli-units";

pub const functions = [_]Function{
    .{
        .name = "e7_engine_window_create",
        .params = &.{ .str_, .i32_, .i32_ },
        .result = .u64_,
        .units = window_create_units,
    },
    .{
        .name = "e7_engine_window_pump",
        .params = &.{.u64_},
        .result = .i64_,
    },
    .{
        .name = "e7_engine_window_should_close",
        .params = &.{.u64_},
        .result = .i64_,
    },
    .{
        .name = "e7_engine_window_destroy",
        .params = &.{.u64_},
        .result = .i64_,
    },
    .{
        .name = "e7_engine_time_now_ms",
        .params = &.{},
        .result = .i64_,
    },
    .{
        // e7 loads the SPIR-V bytes (asset/read_shader) and passes the strings.
        .name = "e7_engine_read_shader",
        .params = &.{.str_},
        .result = .str_,
    },
    .{
        .name = "e7_engine_scene_create",
        .params = &.{ .u64_, .str_, .str_ },
        .result = .u64_,
    },
    .{
        .name = "e7_engine_scene_destroy",
        .params = &.{.u64_},
        .result = .i64_,
    },
    .{
        .name = "e7_engine_scene_resize",
        .params = &.{ .u64_, .i32_, .i32_ },
        .result = .i64_,
    },
    .{
        .name = "e7_engine_scene_set_camera",
        .params = &.{ .u64_, .i64_, .i64_, .i64_, .i64_, .i64_ },
        .result = .i64_,
        .units = scene_camera_units,
    },
    .{
        .name = "e7_engine_scene_draw",
        .params = &.{ .u64_, .i64_, .i64_, .i64_, .i64_, .i64_ },
        .result = .i64_,
        .units = scene_draw_units,
    },
    .{
        .name = "e7_engine_should_close",
        .params = &.{},
        .result = .i64_,
    },
    .{
        // Logical key codes: 0 W, 1 S, 2 A, 3 D, 4 E, 5 Q, 6 Shift, 7-10 arrows.
        .name = "e7_engine_key_down",
        .params = &.{.i64_},
        .result = .i64_,
    },
    .{
        // Accumulated horizontal mouse motion in pixels; reading clears it.
        .name = "e7_engine_mouse_dx",
        .params = &.{},
        .result = .i64_,
    },
    .{
        // Accumulated vertical mouse motion in pixels; reading clears it.
        .name = "e7_engine_mouse_dy",
        .params = &.{},
        .result = .i64_,
    },

    // Float helpers: values are f64 bit patterns stored in i64 slots.
    .{ .name = "e7_f32_add", .params = &.{ .float_, .float_ }, .result = .float_ },
    .{ .name = "e7_f32_sub", .params = &.{ .float_, .float_ }, .result = .float_ },
    .{ .name = "e7_f32_mul", .params = &.{ .float_, .float_ }, .result = .float_ },
    .{ .name = "e7_f32_div", .params = &.{ .float_, .float_ }, .result = .float_ },
    .{ .name = "e7_f32_neg", .params = &.{.float_}, .result = .float_ },
    .{ .name = "e7_f32_eq", .params = &.{ .float_, .float_ }, .result = .bool_ },
    .{ .name = "e7_f32_ne", .params = &.{ .float_, .float_ }, .result = .bool_ },
    .{ .name = "e7_f32_lt", .params = &.{ .float_, .float_ }, .result = .bool_ },
    .{ .name = "e7_f32_le", .params = &.{ .float_, .float_ }, .result = .bool_ },
    .{ .name = "e7_f32_gt", .params = &.{ .float_, .float_ }, .result = .bool_ },
    .{ .name = "e7_f32_ge", .params = &.{ .float_, .float_ }, .result = .bool_ },
    .{ .name = "e7_f32_sin", .params = &.{.float_}, .result = .float_ },
    .{ .name = "e7_f32_cos", .params = &.{.float_}, .result = .float_ },
    .{ .name = "e7_f32_sqrt", .params = &.{.float_}, .result = .float_ },
    .{ .name = "e7_f32_abs", .params = &.{.float_}, .result = .float_ },
    .{ .name = "e7_f32_clamp", .params = &.{ .float_, .float_, .float_ }, .result = .float_ },
    .{ .name = "e7_f32_from_i64", .params = &.{.i64_}, .result = .float_ },
    .{ .name = "e7_f32_to_i64", .params = &.{.float_}, .result = .i64_ },
    .{ .name = "e7_f32_to_milli", .params = &.{.float_}, .result = .i64_ },
    .{ .name = "e7_f32_from_milli", .params = &.{.i64_}, .result = .float_ },
};

pub fn lookup(name: []const u8) ?Function {
    for (functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}
