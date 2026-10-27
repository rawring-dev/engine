//! Compiler-known external intrinsics callable from e7 by name.
//!
//! There is no extern-declaration syntax in the surface language.  A call such
//! as `e7_engine_time_now_ms()` resolves here, is type-checked against this
//! table, and lowers to a bytecode `runtime_call` to the matching `e7_*`
//! symbol.  Units that cross the ABI boundary are integer scaled (see
//! per-function comments) so e7 does not need float arithmetic.
//!
//! The only remaining engine host helpers are SDL/Vulkan-free; they live in
//! `runtime/src/host_engine.zig` and are registered with the JIT through
//! `host_engine.symbols()`.  SDL/Vulkan are bound by e7 platform code through
//! the generic C FFI.

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
    /// e7 `[f32]` vector (aggregate handle); mesh upload vertex data.
    f32_vec_,
    /// e7 `[i32]` vector (aggregate handle); mesh upload indices.
    i32_vec_,
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
/// Per-object shape draw: kind (0 box, 1 sphere, 2 capsule, 3 plane),
/// position/scale milli-units, Y rotation milli-radians, RGB tint milli.
pub const scene_shape_units = "kind, position/scale milli-units, angle milli-radians, rgb tint milli";
/// Material/textured draw: as scene_shape_units plus a texture id.
pub const scene_textured_units = "kind, position/scale milli-units, angle milli-radians, rgb tint milli, texture id";
/// Custom mesh draw: mesh id, position/scale milli-units, angle milli-radians,
/// rgb tint milli, texture id.
pub const scene_custom_units = "mesh id, position/scale milli-units, angle milli-radians, rgb tint milli, texture id";

pub const functions = [_]Function{
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
    // Host frame control/capture for the e7 engine.
    .{ .name = "e7_host_headless", .params = &.{}, .result = .i64_ },
    .{ .name = "e7_host_should_close", .params = &.{}, .result = .i64_ },
    .{ .name = "e7_host_note_frame", .params = &.{}, .result = .unit },
    .{ .name = "e7_host_capture", .params = &.{ .any_, .i64_, .i64_ }, .result = .i64_ },

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
    .{ .name = "e7_image_from_argb", .params = &.{ .u64_, .i64_, .i64_, .i64_ }, .result = .u64_ },

    // Generic text/parsing helpers used by e7 libraries (engine/obj.e7).
    .{ .name = "e7_str_lines", .params = &.{.str_}, .result = .str_vec_ },
    .{ .name = "e7_str_fields", .params = &.{.str_}, .result = .str_vec_ },
    .{ .name = "e7_str_split", .params = &.{ .str_, .str_ }, .result = .str_vec_ },
    .{ .name = "e7_parse_i64", .params = &.{.str_}, .result = .i64_ },
    .{ .name = "e7_parse_f32", .params = &.{.str_}, .result = .float_ },
    // Generic vector append: result type matches the vector argument; the
    // value argument is checked against its element type.
    .{ .name = "e7_vec_push", .params = &.{ .any_, .any_ }, .result = .any_ },

    // Generic C FFI bridge used by e7 platform libraries.  Arguments are raw
    // 64-bit slots, so strings/vectors are passed as their runtime handles.
    .{ .name = "e7_cffi_bind", .params = &.{ .str_, .str_ }, .result = .u64_ },
    .{ .name = "e7_str_data", .params = &.{.any_}, .result = .u64_ },
    .{ .name = "e7_cstr", .params = &.{.str_}, .result = .u64_ },
    .{ .name = "e7_memcpy", .params = &.{ .any_, .any_, .any_ }, .result = .unit },
    .{ .name = "e7_handle", .params = &.{.any_}, .result = .u64_ },
    .{ .name = "e7_store_f32", .params = &.{ .any_, .float_ }, .result = .unit },
    .{ .name = "e7_str_len", .params = &.{.any_}, .result = .i64_ },
    .{ .name = "e7_str_new", .params = &.{ .u64_, .i64_ }, .result = .str_ },
    .{ .name = "e7_alloc_bytes", .params = &.{.i64_}, .result = .u64_ },
    .{ .name = "e7_free_ptr", .params = &.{.any_}, .result = .unit },
    .{ .name = "e7_load_i64", .params = &.{.any_}, .result = .i64_ },
    .{ .name = "e7_store_i64", .params = &.{ .any_, .any_ }, .result = .unit },
    .{ .name = "e7_load_u8", .params = &.{.any_}, .result = .i64_ },
    .{ .name = "e7_store_u8", .params = &.{ .any_, .any_ }, .result = .unit },
    .{ .name = "e7_load_u16", .params = &.{.any_}, .result = .i64_ },
    .{ .name = "e7_store_u16", .params = &.{ .any_, .any_ }, .result = .unit },
    .{ .name = "e7_load_u32", .params = &.{.any_}, .result = .i64_ },
    .{ .name = "e7_store_u32", .params = &.{ .any_, .any_ }, .result = .unit },
    .{ .name = "e7_load_u64", .params = &.{.any_}, .result = .i64_ },
    .{ .name = "e7_store_u64", .params = &.{ .any_, .any_ }, .result = .unit },
    .{ .name = "e7_ffi_call0", .params = &.{.any_}, .result = .u64_ },
    .{ .name = "e7_ffi_call1", .params = &.{ .any_, .any_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call2", .params = &.{ .any_, .any_, .any_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call3", .params = &.{ .any_, .any_, .any_, .any_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call4", .params = &.{ .any_, .any_, .any_, .any_, .any_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call5", .params = &.{ .any_, .any_, .any_, .any_, .any_, .any_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call6", .params = &.{ .any_, .any_, .any_, .any_, .any_, .any_, .any_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call7", .params = &.{ .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call_f32_2", .params = &.{ .any_, .any_, .float_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call8", .params = &.{ .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call9", .params = &.{ .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call10", .params = &.{ .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call11", .params = &.{ .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call12", .params = &.{ .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call13", .params = &.{ .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call14", .params = &.{ .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call15", .params = &.{ .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_ }, .result = .u64_ },
    .{ .name = "e7_ffi_call16", .params = &.{ .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_, .any_ }, .result = .u64_ },
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
}
