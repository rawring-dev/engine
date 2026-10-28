//! Compiler-known native methods: language-level spellings for the runtime
//! intrinsic ABI.
//!
//! Normal e7 code should not call `e7_*` intrinsics directly.  Instead it uses
//! the source forms documented here, which the compiler resolves and lowers to
//! exactly the same bytecode `runtime_call` that the intrinsic spelling would
//! produce.  Because the lowering is a table lookup in the compiler, the
//! runtime ABI does not grow and no e7 wrapper module is needed.
//!
//! Syntax is `namespace::method(args...)`:
//!
//!   f32::sin(x)             f32::parse(text)          f32::clamp(x, lo, hi)
//!   f32::to_milli(x)        f32::from_milli(m)        f32::from_i64(i)
//!   ptr::alloc(bytes)       ptr::free(p)              ptr::offset(p, delta)
//!   ptr::load_u32(p)        ptr::store_u64(p, value)  ptr::copy(dst, src, n)
//!   str::from_bytes(p, n)   str::data(s)              str::cstr(s)   str::len(s)
//!   ffi::bind(lib, symbol)  ffi::call4(fn, a, b, c, d)  ffi::handle(value)
//!   host::time_now_ms()     host::read_shader(path)   host::capture(pixels, w, h)
//!   image::load(path)       image::width(handle)      image::free(handle)
//!
//! The namespace names are ordinary identifiers in the grammar (`f32::sin` is
//! parsed as a two-segment path), so no parser changes are required.  A
//! user-defined qualified function with the same path takes precedence.
//!
//! ## Native-method boundary
//!
//! This table plus `intrinsics.zig` is the documented boundary between e7
//! source and the `e7_*` C ABI: engine/domain intrinsics that do not (yet) have
//! a source-level form stay reachable only through the explicit `e7_*` spelling
//! and the audit in `intrinsic_audit.zig` reports direct calls outside the
//! approved boundary.  When a domain intrinsic gains a native method here, its
//! `e7_*` spelling should no longer be used by engine code.

const std = @import("std");
const bytecode = @import("bytecode.zig");

/// Result/parameter spelling.  These mirror `intrinsics.ValueType` and add the
/// raw-pointer results native methods return (`ptr::alloc`, `str::data`,
/// `ptr::offset`) without extending the runtime ABI.
pub const Type = enum {
    i64_,
    u64_,
    i32_,
    bool_,
    float_,
    str_,
    str_vec_,
    any_,
    unit,
    /// `*raw u8`: an untyped byte pointer, the type of `ptr::alloc`,
    /// `ptr::offset`, `str::data`, and `str::cstr`.
    raw_u8,
};

const i64_ = Type.i64_;
const u64_ = Type.u64_;
const i32_ = Type.i32_;
const float_ = Type.float_;
const str_ = Type.str_;
const str_vec_ = Type.str_vec_;
const any_ = Type.any_;
const unit_ = Type.unit;
const raw_u8_ = Type.raw_u8;

/// How a native method lowers.  All but `byte_offset` emit a single
/// `runtime_call` to the method's `runtime` entry.
pub const Lowering = enum {
    /// One `runtime_call` with the method's argument count.
    runtime_call,
    /// `ptr::offset(pointer, bytes)` is unchecked byte-addressed pointer
    /// arithmetic (`pointer + bytes`, no pointee-size scaling).
    byte_offset,
};

pub const Method = struct {
    name: []const u8,
    params: []const Type,
    result: Type,
    runtime: ?bytecode.RuntimeFunction = null,
    lowering: Lowering = .runtime_call,
};

pub const Namespace = struct {
    name: []const u8,
    methods: []const Method,
};

const f32_methods = [_]Method{
    .{ .name = "parse", .params = &.{str_}, .result = float_, .runtime = .parse_f32 },
    .{ .name = "sin", .params = &.{float_}, .result = float_, .runtime = .float_sin },
    .{ .name = "cos", .params = &.{float_}, .result = float_, .runtime = .float_cos },
    .{ .name = "sqrt", .params = &.{float_}, .result = float_, .runtime = .float_sqrt },
    .{ .name = "abs", .params = &.{float_}, .result = float_, .runtime = .float_abs },
    .{ .name = "clamp", .params = &.{ float_, float_, float_ }, .result = float_, .runtime = .float_clamp },
    .{ .name = "to_milli", .params = &.{float_}, .result = i64_, .runtime = .float_to_milli },
    .{ .name = "from_milli", .params = &.{i64_}, .result = float_, .runtime = .float_from_milli },
    .{ .name = "to_i64", .params = &.{float_}, .result = i64_, .runtime = .float_to_i64 },
    .{ .name = "from_i64", .params = &.{i64_}, .result = float_, .runtime = .float_from_i64 },
};

const i64_methods = [_]Method{
    .{ .name = "parse", .params = &.{str_}, .result = i64_, .runtime = .parse_i64 },
};

const str_methods = [_]Method{
    .{ .name = "from_bytes", .params = &.{ any_, i64_ }, .result = str_, .runtime = .str_new },
    .{ .name = "data", .params = &.{str_}, .result = raw_u8_, .runtime = .str_data },
    .{ .name = "cstr", .params = &.{str_}, .result = raw_u8_, .runtime = .cstr },
    .{ .name = "len", .params = &.{str_}, .result = i64_, .runtime = .str_len },
    .{ .name = "lines", .params = &.{str_}, .result = str_vec_, .runtime = .str_lines },
    .{ .name = "fields", .params = &.{str_}, .result = str_vec_, .runtime = .str_fields },
    .{ .name = "split", .params = &.{ str_, str_ }, .result = str_vec_, .runtime = .str_split },
};

const ptr_methods = [_]Method{
    .{ .name = "alloc", .params = &.{i64_}, .result = raw_u8_, .runtime = .alloc_bytes },
    .{ .name = "free", .params = &.{any_}, .result = unit_, .runtime = .free_ptr },
    .{ .name = "copy", .params = &.{ any_, any_, any_ }, .result = unit_, .runtime = .memcpy },
    .{ .name = "offset", .params = &.{ any_, i64_ }, .result = raw_u8_, .lowering = .byte_offset },
    .{ .name = "load_i64", .params = &.{any_}, .result = i64_, .runtime = .load_i64 },
    .{ .name = "load_u8", .params = &.{any_}, .result = i64_, .runtime = .load_u8 },
    .{ .name = "load_u16", .params = &.{any_}, .result = i64_, .runtime = .load_u16 },
    .{ .name = "load_u32", .params = &.{any_}, .result = i64_, .runtime = .load_u32 },
    .{ .name = "load_u64", .params = &.{any_}, .result = i64_, .runtime = .load_u64 },
    .{ .name = "load_f32", .params = &.{any_}, .result = float_, .runtime = .load_f32 },
    .{ .name = "store_i64", .params = &.{ any_, any_ }, .result = unit_, .runtime = .store_i64 },
    .{ .name = "store_u8", .params = &.{ any_, any_ }, .result = unit_, .runtime = .store_u8 },
    .{ .name = "store_u16", .params = &.{ any_, any_ }, .result = unit_, .runtime = .store_u16 },
    .{ .name = "store_u32", .params = &.{ any_, any_ }, .result = unit_, .runtime = .store_u32 },
    .{ .name = "store_u64", .params = &.{ any_, any_ }, .result = unit_, .runtime = .store_u64 },
    .{ .name = "store_f32", .params = &.{ any_, float_ }, .result = unit_, .runtime = .store_f32 },
    // Alias for callers that keep a `usize` spelling; the ABI is identical.
    .{ .name = "load_usize", .params = &.{any_}, .result = i64_, .runtime = .load_u64 },
    .{ .name = "store_usize", .params = &.{ any_, any_ }, .result = unit_, .runtime = .store_u64 },
};

const ffi_methods = [_]Method{
    .{ .name = "bind", .params = &.{ str_, str_ }, .result = u64_, .runtime = .cffi_bind },
    .{ .name = "handle", .params = &.{any_}, .result = u64_, .runtime = .handle },
    .{ .name = "call0", .params = &.{any_}, .result = u64_, .runtime = .ffi_call0 },
    .{ .name = "call1", .params = &.{ any_, any_ }, .result = u64_, .runtime = .ffi_call1 },
    .{ .name = "call2", .params = &.{ any_, any_, any_ }, .result = u64_, .runtime = .ffi_call2 },
    .{ .name = "call3", .params = &.{ any_, any_, any_, any_ }, .result = u64_, .runtime = .ffi_call3 },
    .{ .name = "call4", .params = &.{ any_, any_, any_, any_, any_ }, .result = u64_, .runtime = .ffi_call4 },
    .{ .name = "call5", .params = &.{ any_, any_, any_, any_, any_, any_ }, .result = u64_, .runtime = .ffi_call5 },
    .{ .name = "call6", .params = &.{ any_, any_, any_, any_, any_, any_, any_ }, .result = u64_, .runtime = .ffi_call6 },
    .{ .name = "call7", .params = &.{ any_, any_, any_, any_, any_, any_, any_, any_ }, .result = u64_, .runtime = .ffi_call7 },
    .{ .name = "call_f32_2", .params = &.{ any_, any_, float_ }, .result = u64_, .runtime = .ffi_call_f32_2 },
    .{ .name = "call8", .params = &.{ any_, any_, any_, any_, any_, any_, any_, any_, any_ }, .result = u64_, .runtime = .ffi_call8 },
    .{ .name = "call9", .params = &.{ any_, any_, any_, any_, any_, any_, any_, any_, any_, any_ }, .result = u64_, .runtime = .ffi_call9 },
    .{ .name = "call10", .params = &.{ any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_ }, .result = u64_, .runtime = .ffi_call10 },
    .{ .name = "call11", .params = &.{ any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_ }, .result = u64_, .runtime = .ffi_call11 },
    .{ .name = "call12", .params = &.{ any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_ }, .result = u64_, .runtime = .ffi_call12 },
    .{ .name = "call13", .params = &.{ any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_ }, .result = u64_, .runtime = .ffi_call13 },
    .{ .name = "call14", .params = &.{ any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_ }, .result = u64_, .runtime = .ffi_call14 },
    .{ .name = "call15", .params = &.{ any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_ }, .result = u64_, .runtime = .ffi_call15 },
    .{ .name = "call16", .params = &.{ any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_, any_ }, .result = u64_, .runtime = .ffi_call16 },
};

const host_methods = [_]Method{
    .{ .name = "time_now_ms", .params = &.{}, .result = i64_, .runtime = .engine_time_now_ms },
    .{ .name = "read_shader", .params = &.{str_}, .result = str_, .runtime = .engine_read_shader },
    .{ .name = "headless", .params = &.{}, .result = i64_, .runtime = .host_headless },
    .{ .name = "should_close", .params = &.{}, .result = i64_, .runtime = .host_should_close },
    .{ .name = "note_frame", .params = &.{}, .result = unit_, .runtime = .host_note_frame },
    .{ .name = "capture", .params = &.{ any_, i64_, i64_ }, .result = i64_, .runtime = .host_capture },
};

const image_methods = [_]Method{
    .{ .name = "load", .params = &.{str_}, .result = u64_, .runtime = .image_load },
    .{ .name = "from_argb", .params = &.{ any_, i64_, i64_, i64_ }, .result = u64_, .runtime = .image_from_argb },
    .{ .name = "width", .params = &.{any_}, .result = i64_, .runtime = .image_width },
    .{ .name = "height", .params = &.{any_}, .result = i64_, .runtime = .image_height },
    .{ .name = "pixels", .params = &.{any_}, .result = str_, .runtime = .image_pixels },
    .{ .name = "free", .params = &.{any_}, .result = i32_, .runtime = .image_free },
};

const vec_methods = [_]Method{
    // The result type follows the vector argument; the analyzer special-cases
    // it the same way it does for the `e7_vec_push` intrinsic.
    .{ .name = "push", .params = &.{ any_, any_ }, .result = any_, .runtime = .vec_push },
};

pub const namespaces = [_]Namespace{
    .{ .name = "f32", .methods = &f32_methods },
    .{ .name = "i64", .methods = &i64_methods },
    .{ .name = "str", .methods = &str_methods },
    .{ .name = "ptr", .methods = &ptr_methods },
    .{ .name = "ffi", .methods = &ffi_methods },
    .{ .name = "host", .methods = &host_methods },
    .{ .name = "image", .methods = &image_methods },
    .{ .name = "vec", .methods = &vec_methods },
};

/// The documented namespaces of the native-method boundary.
pub fn isBoundaryNamespace(name: []const u8) bool {
    for (namespaces) |namespace| {
        if (std.mem.eql(u8, namespace.name, name)) return true;
    }
    return false;
}

pub fn lookup(namespace_name: []const u8, method_name: []const u8) ?*const Method {
    for (namespaces) |namespace| {
        if (!std.mem.eql(u8, namespace.name, namespace_name)) continue;
        for (namespace.methods) |*method| {
            if (std.mem.eql(u8, method.name, method_name)) return method;
        }
        return null;
    }
    return null;
}

test "every runtime-backed native method matches the bytecode arity" {
    for (namespaces) |namespace| {
        for (namespace.methods) |method| {
            const runtime = method.runtime orelse {
                try std.testing.expectEqual(Lowering.byte_offset, method.lowering);
                continue;
            };
            try std.testing.expectEqual(@as(usize, runtime.arity()), method.params.len);
        }
    }
}

test "native method names are unique per namespace" {
    for (namespaces) |namespace| {
        for (namespace.methods, 0..) |method, index| {
            for (namespace.methods[index + 1 ..]) |other| {
                try std.testing.expect(!std.mem.eql(u8, method.name, other.name));
            }
        }
    }
}
