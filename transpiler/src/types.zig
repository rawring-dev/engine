//! e7 type -> Slang type mapping.
//!
//! e7s deliberately gives a Slang-flavoured meaning to a few e7 type forms:
//!   [T; 2..4]       -> T2..T4 vectors (float3, uint4, half2, ...)
//!   [T; R, C]       -> TRxC matrices (float4x4, ...)
//!   &T / &mut T     -> `in T` / `inout T` in parameter position only
//!   nil / () / !nil -> void in return position
//! Everything else is either emitted verbatim (paths/resources) or rejected
//! with a diagnostic.

const std = @import("std");
const ast = @import("compiler").ast;
const astx = @import("astx.zig");
const session_mod = @import("session.zig");
const Session = session_mod.Session;
pub const Error = session_mod.Error;

pub fn writeType(s: *Session, ty: *const ast.Type) Error!void {
    switch (ty.*) {
        .path => |path| try writePathType(s, path),
        .array => |array| try writeArrayType(s, array),
        .nil_type => return s.fail("`nil` is only valid as a function result type in e7s", .{}),
        .inferred_error => return s.fail("error result types (`!T`) are not supported in e7s; shaders have no error values", .{}),
        .error_union => return s.fail("error result types (`E!T`) are not supported in e7s", .{}),
        .optional => return s.fail("optionals (`?T`) are not supported in e7s", .{}),
        .reference => return s.fail("references are only supported as function parameters or trait receivers", .{}),
        .box => return s.fail("boxed pointers (`*T`) are not supported in e7s", .{}),
        .raw_pointer => return s.fail("raw pointers (`*raw T`) are not supported in e7s", .{}),
        .function => return s.fail("function types are not supported in e7s", .{}),
        .tuple => return s.fail("tuple types are not supported in e7s (use a struct)", .{}),
        .map => return s.fail("map types are not supported in e7s", .{}),
    }
}

/// Type in value/parameter position.  References are the one place e7s keeps
/// their e7 spelling while changing the meaning to Slang parameter modes.
pub fn writeParamType(s: *Session, ty: *const ast.Type) Error!void {
    switch (ty.*) {
        .reference => |reference| {
            try s.out.raw("{s}", .{if (reference.mutable) "inout " else "in "});
            try writeType(s, reference.child);
        },
        else => try writeType(s, ty),
    }
}

/// Type in function-result position.  e7's `nil`, `()` and `!nil` spell
/// "no value" and become Slang's `void`.
pub fn writeReturnType(s: *Session, ty: *const ast.Type) Error!void {
    switch (ty.*) {
        .nil_type => try s.out.raw("void", .{}),
        .tuple => |elements| {
            if (elements.len == 0) {
                try s.out.raw("void", .{});
            } else {
                return s.fail("tuple result types are not supported in e7s", .{});
            }
        },
        .inferred_error => |child| {
            switch (child.*) {
                .nil_type => try s.out.raw("void", .{}),
                else => return s.fail("error result types (`!T`) are not supported in e7s", .{}),
            }
        },
        .error_union => return s.fail("error result types (`E!T`) are not supported in e7s", .{}),
        else => try writeType(s, ty),
    }
}

pub fn isVoidResult(s: *Session, ty: *const ast.Type) bool {
    _ = s;
    return switch (ty.*) {
        .nil_type => true,
        .tuple => |elements| elements.len == 0,
        .inferred_error => |child| child.* == .nil_type,
        else => false,
    };
}

fn writePathType(s: *Session, path: ast.Path) Error!void {
    try writePathSegments(s, path, .type);
}

fn writeArrayType(s: *Session, array: ast.ArrayType) Error!void {
    if (array.columns) |columns_expr| {
        const rows = astx.intValue(array.length orelse {
            return s.fail("matrix type is missing its row count", .{});
        }) orelse return s.fail("matrix row count must be an integer literal", .{});
        const cols = astx.intValue(columns_expr) orelse
            return s.fail("matrix column count must be an integer literal", .{});
        const element = astx.scalarSlangNameOf(array.element) orelse
            return s.fail("matrix elements must be a scalar type in e7s", .{});
        if (rows < 2 or rows > 4 or cols < 2 or cols > 4) {
            return s.fail("e7s matrices must have 2-4 rows and 2-4 columns", .{});
        }
        try s.out.raw("{s}{d}x{d}", .{ element, rows, cols });
        return;
    }

    if (array.length) |length_expr| {
        const length = astx.intValue(length_expr) orelse
            return s.fail("fixed-size array length must be an integer literal", .{});
        if (length < 2 or length > 4) {
            return s.fail("e7s vectors must have 2-4 elements (`[T; N]` with N in 2..4)", .{});
        }
        const element = astx.scalarSlangNameOf(array.element) orelse
            return s.fail("vector elements must be a scalar type in e7s", .{});
        try s.out.raw("{s}{d}", .{ element, length });
        return;
    }

    return s.fail(
        "dynamic array types (`[T]`) are not Slang value types; use StructuredBuffer<T> or RWStructuredBuffer<T> for a shader resource",
        .{},
    );
}

pub const PathMode = enum { type, value };

/// Emit a (possibly generic/qualified) path.  e7 module roots and external
/// module names are stripped because Slang module imports bring declarations
/// into the global namespace; inline e7 modules become Slang namespaces and
/// keep their qualifier.
pub fn writePathSegments(s: *Session, path: ast.Path, mode: PathMode) Error!void {
    if (path.segments.len == 0) {
        return s.fail("empty path", .{});
    }

    var start: usize = 0;
    while (start + 1 < path.segments.len) {
        const name = path.segments[start].name;
        if (astx.isQualifierSegment(name) or s.program.isExternalModule(name)) {
            start += 1;
        } else break;
    }

    if (start >= path.segments.len) {
        return s.fail("path resolves to a module with no item name", .{});
    }

    if (mode == .type and start + 1 == path.segments.len and
        path.segments[start].args.len == 0)
    {
        const name = path.segments[start].name;
        if (std.mem.eql(u8, name, "str")) {
            return s.fail("string types are not supported in e7s", .{});
        }
        if (astx.scalarSlangName(name)) |mapped| {
            try s.out.raw("{s}", .{mapped});
            return;
        }
    }

    for (path.segments[start..], 0..) |segment, i| {
        if (i != 0) try s.out.raw("::", .{});
        var mapped_scalar: ?[]const u8 = null;
        if (mode == .type) mapped_scalar = astx.scalarSlangName(segment.name);
        if (mapped_scalar) |mapped| {
            if (segment.args.len != 0) return s.fail("scalar types cannot have generic arguments", .{});
            try s.out.raw("{s}", .{mapped});
        } else {
            try s.out.raw("{s}", .{segment.name});
        }
        if (segment.args.len > 0) {
            try s.out.raw("<", .{});
            for (segment.args, 0..) |arg, j| {
                if (j != 0) try s.out.raw(", ", .{});
                try writeType(s, arg);
            }
            try s.out.raw(">", .{});
        }
    }
}

/// True when `ty` is a user-defined aggregate (and therefore a constant-buffer
/// payload for a resource declaration).
pub fn isUserStruct(s: *Session, ty: *const ast.Type) bool {
    const path = astx.typePath(ty) orelse return false;
    if (path.segments.len == 0) return false;
    const last = astx.pathLast(path.*);
    return s.program.findStruct(last) != null;
}

/// True for `[T; R, C]` matrix types (R, C are not validated here; the type
/// emitter reports shape errors).
pub fn isMatrixType(ty: *const ast.Type) bool {
    return switch (ty.*) {
        .array => |array| array.columns != null,
        else => false,
    };
}

pub fn isResourceType(s: *Session, ty: *const ast.Type) bool {
    _ = s;
    const path = astx.typePath(ty) orelse return false;
    if (path.segments.len == 0) return false;
    return astx.isResourceTypeName(astx.pathLast(path.*));
}
