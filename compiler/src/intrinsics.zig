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
    /// Runtime vector of string values (`[str]` aggregate handle).
    str_vec_,
    /// Placeholder for generic intrinsics whose type is derived from another
    /// argument (`e7_vec_push`).
    any_,
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
/// Per-object box draw: position/scale in milli-units, Y rotation in
/// milli-radians.
pub const scene_box_units = "position/scale milli-units, angle milli-radians";

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
        .name = "e7_engine_scene_set_cube_angle",
        .params = &.{ .u64_, .i64_ },
        .result = .i64_,
        .units = "cube angle in milli-radians",
    },
    .{
        .name = "e7_engine_scene_set_light",
        .params = &.{ .u64_, .i64_, .i64_, .i64_, .i64_, .i64_, .i64_, .i64_ },
        .result = .i64_,
        .units = "position milli-units; colour/intensity milli",
    },
    .{
        .name = "e7_engine_scene_begin_frame",
        .params = &.{.u64_},
        .result = .i64_,
    },
    .{
        .name = "e7_engine_scene_draw_mesh",
        .params = &.{.u64_},
        .result = .i64_,
    },
    .{
        .name = "e7_engine_scene_draw_box",
        .params = &.{ .u64_, .i64_, .i64_, .i64_, .i64_, .i64_, .i64_, .i64_ },
        .result = .i64_,
        .units = scene_box_units,
    },
    .{
        .name = "e7_engine_scene_end_frame",
        .params = &.{.u64_},
        .result = .i64_,
    },
    .{
        .name = "e7_engine_should_close",
        .params = &.{},
        .result = .i64_,
    },
    .{
        // Logical key codes: 0 W, 1 S, 2 A, 3 D, 4 E, 5 Q, 6 Shift, 7-10 arrows, 11 Space.
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

    // Low-level image loading (PNG/JPEG -> RGBA8); see runtime/src/image.zig.
    .{ .name = "e7_image_load", .params = &.{.str_}, .result = .u64_ },
    .{ .name = "e7_image_width", .params = &.{.u64_}, .result = .i64_ },
    .{ .name = "e7_image_height", .params = &.{.u64_}, .result = .i64_ },
    .{ .name = "e7_image_pixels", .params = &.{.u64_}, .result = .str_ },
    .{ .name = "e7_image_free", .params = &.{.u64_}, .result = .i32_ },

    // Generic text/parsing helpers used by e7 libraries (engine/obj.e7).
    .{ .name = "e7_str_lines", .params = &.{.str_}, .result = .str_vec_ },
    .{ .name = "e7_str_fields", .params = &.{.str_}, .result = .str_vec_ },
    .{ .name = "e7_str_split", .params = &.{ .str_, .str_ }, .result = .str_vec_ },
    .{ .name = "e7_parse_i64", .params = &.{.str_}, .result = .i64_ },
    .{ .name = "e7_parse_f32", .params = &.{.str_}, .result = .float_ },
    // Generic vector append: result type matches the vector argument; the
    // value argument is checked against its element type.
    .{ .name = "e7_vec_push", .params = &.{ .any_, .any_ }, .result = .any_ },
};

pub fn lookup(name: []const u8) ?Function {
    for (functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

test "compiler-known intrinsics map to bytecode runtime calls with matching arity" {
    const bytecode = @import("bytecode.zig");
    for (functions) |function| {
        const runtime = bytecode.RuntimeFunction.fromSymbol(function.name) orelse {
            std.debug.print("no RuntimeFunction for intrinsic {s}\n", .{function.name});
            return error.TestUnexpectedResult;
        };
        if (runtime.arity() != @as(u16, @intCast(function.params.len))) {
            std.debug.print("arity mismatch for {s}: intrinsic {d}, bytecode {d}\n", .{
                function.name,
                function.params.len,
                runtime.arity(),
            });
            return error.TestUnexpectedResult;
        }
    }
    // The multi-object scene draw is registered with 8 i64 arguments:
    // handle + position xyz + scale xyz + Y angle.
    const draw_box = lookup("e7_engine_scene_draw_box").?;
    try std.testing.expectEqual(@as(usize, 8), draw_box.params.len);
    try std.testing.expectEqual(ValueType.i64_, draw_box.result);
}
