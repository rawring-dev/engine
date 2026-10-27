//! Small AST helpers shared by the e7s lowering passes.

const std = @import("std");
const compiler = @import("compiler");
const ast = compiler.ast;

pub fn attributeNamed(attributes: []ast.Attribute, name: []const u8) ?ast.Attribute {
    for (attributes) |attribute| {
        if (std.mem.eql(u8, pathLast(attribute.path), name)) return attribute;
    }
    return null;
}

pub fn hasAttribute(attributes: []ast.Attribute, name: []const u8) bool {
    return attributeNamed(attributes, name) != null;
}

pub fn pathLast(path: ast.Path) []const u8 {
    if (path.segments.len == 0) return "";
    return path.segments[path.segments.len - 1].name;
}

pub fn pathJoinAlloc(allocator: std.mem.Allocator, path: ast.Path) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (path.segments, 0..) |segment, i| {
        if (i != 0) try out.appendSlice(allocator, "::");
        try out.appendSlice(allocator, segment.name);
    }
    return out.toOwnedSlice(allocator);
}

pub fn attributeIntArg(attribute: ast.Attribute, index: usize) ?i64 {
    if (index >= attribute.args.len) return null;
    return intValue(attribute.args[index]);
}

pub fn intValue(expression: *const ast.Expr) ?i64 {
    return switch (expression.*) {
        .int => |value| value,
        .unary => |unary| if (unary.op == .negative)
            if (intValue(unary.operand)) |value| -value else null
        else
            null,
        else => null,
    };
}

pub fn floatValue(expression: *const ast.Expr) ?f64 {
    return switch (expression.*) {
        .float => |value| value,
        .int => |value| @floatFromInt(value),
        .unary => |unary| if (unary.op == .negative)
            if (floatValue(unary.operand)) |value| -value else null
        else
            null,
        else => null,
    };
}

pub fn isPublic(visibility: ?ast.Visibility) bool {
    return visibility != null;
}

pub fn spanOf(module: *const ast.Module, pointer: *const anyopaque) ast.Span {
    return module.spans.get(@intFromPtr(pointer)) orelse ast.Span{};
}

pub fn typePath(ty: *const ast.Type) ?*const ast.Path {
    return switch (ty.*) {
        .path => |*path| path,
        else => null,
    };
}

pub fn typeName(ty: *const ast.Type) ?[]const u8 {
    const path = typePath(ty) orelse return null;
    return pathLast(path.*);
}

pub fn isNilType(ty: *const ast.Type) bool {
    return ty.* == .nil_type;
}

pub fn scalarSlangName(name: []const u8) ?[]const u8 {
    const map = .{
        .{ "bool", "bool" },
        .{ "i8", "int8_t" },
        .{ "i16", "int16_t" },
        .{ "i32", "int" },
        .{ "i64", "int64_t" },
        .{ "u8", "uint8_t" },
        .{ "u16", "uint16_t" },
        .{ "u32", "uint" },
        .{ "u64", "uint64_t" },
        .{ "f16", "half" },
        .{ "f32", "float" },
        .{ "f64", "double" },
        .{ "isize", "int64_t" },
        .{ "usize", "uint64_t" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

pub fn scalarSlangNameOf(ty: *const ast.Type) ?[]const u8 {
    const path = typePath(ty) orelse return null;
    if (path.segments.len != 1) return null;
    return scalarSlangName(path.segments[0].name);
}

/// Names that are Slang resource/buffer types and therefore pass through as
/// declared instead of being wrapped in a constant buffer.
///
/// The `Sampler1D`/`Sampler2D`/... family is Slang's legacy *combined*
/// texture-sampler type: it lowers to a single `OpTypeSampledImage` variable,
/// i.e. one Vulkan `VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER` descriptor,
/// and its `.Sample(coords)` overload takes no separate sampler argument.
/// That is distinct from `SamplerState`, which is a standalone sampler
/// descriptor.  Slang supplies the default element type (`float4`) when no
/// type argument is written.
pub fn isResourceTypeName(name: []const u8) bool {
    const names = [_][]const u8{
        "Sampler1D",
        "Sampler1DArray",
        "Sampler2D",
        "Sampler2DArray",
        "Sampler3D",
        "SamplerCube",
        "SamplerCubeArray",
        "Texture1D",
        "Texture1DArray",
        "Texture2D",
        "Texture2DArray",
        "Texture2DMS",
        "Texture2DMSArray",
        "Texture3D",
        "TextureCube",
        "TextureCubeArray",
        "RWTexture1D",
        "RWTexture1DArray",
        "RWTexture2D",
        "RWTexture2DArray",
        "RWTexture3D",
        "Buffer",
        "RWBuffer",
        "StructuredBuffer",
        "RWStructuredBuffer",
        "ByteAddressBuffer",
        "RWByteAddressBuffer",
        "SamplerState",
        "SamplerComparisonState",
        "ConstantBuffer",
        "ParameterBlock",
        "RaytracingAccelerationStructure",
        "AppendStructuredBuffer",
        "ConsumeStructuredBuffer",
    };
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

pub fn isQualifierSegment(name: []const u8) bool {
    return std.mem.eql(u8, name, "crate") or
        std.mem.eql(u8, name, "self") or
        std.mem.eql(u8, name, "super");
}

pub const Stage = enum {
    vertex,
    fragment,
    compute,

    pub fn slangName(self: Stage) []const u8 {
        return switch (self) {
            .vertex => "vertex",
            .fragment => "fragment",
            .compute => "compute",
        };
    }
};

pub fn stageAttribute(attributes: []ast.Attribute) ?struct { stage: Stage, attribute: ast.Attribute, index: usize } {
    for (attributes, 0..) |attribute, i| {
        const name = pathLast(attribute.path);
        if (std.mem.eql(u8, name, "vertex")) return .{ .stage = .vertex, .attribute = attribute, .index = i };
        if (std.mem.eql(u8, name, "fragment")) return .{ .stage = .fragment, .attribute = attribute, .index = i };
        if (std.mem.eql(u8, name, "compute")) return .{ .stage = .compute, .attribute = attribute, .index = i };
    }
    return null;
}

pub fn countStageAttributes(attributes: []ast.Attribute) usize {
    var count: usize = 0;
    for (attributes) |attribute| {
        const name = pathLast(attribute.path);
        if (std.mem.eql(u8, name, "vertex") or
            std.mem.eql(u8, name, "fragment") or
            std.mem.eql(u8, name, "compute")) count += 1;
    }
    return count;
}

pub fn blockTailExpression(block: *const ast.Block) ?*ast.Expr {
    if (block.entries.len == 0) return null;
    const last = block.entries[block.entries.len - 1];
    return switch (last) {
        .stmt => |statement| switch (statement.*) {
            .expr => |expression| expression,
            else => null,
        },
        else => null,
    };
}

pub fn elseBlockOf(if_expr: ast.IfExpr) ?*ast.Block {
    return if_expr.else_body;
}

pub fn attrBuiltinName(attribute: ast.Attribute) ?[]const u8 {
    if (attribute.args.len != 1) return null;
    return switch (attribute.args[0].*) {
        .path => |path| pathLast(path),
        else => null,
    };
}

pub fn builtinSemantic(name: []const u8) ?[]const u8 {
    const map = .{
        .{ "position", "SV_Position" },
        .{ "vertex_index", "SV_VertexID" },
        .{ "instance_index", "SV_InstanceID" },
        .{ "primitive_id", "SV_PrimitiveID" },
        .{ "front_facing", "SV_IsFrontFace" },
        .{ "sample_index", "SV_SampleIndex" },
        .{ "depth", "SV_Depth" },
        .{ "frag_coord", "SV_Position" },
        .{ "dispatch_thread_id", "SV_DispatchThreadID" },
        .{ "group_thread_id", "SV_GroupThreadID" },
        .{ "group_id", "SV_GroupID" },
        .{ "group_index", "SV_GroupIndex" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}
