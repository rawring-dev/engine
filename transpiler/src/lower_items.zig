//! Module-item lowering: e7 declarations -> Slang declarations.

const std = @import("std");
const compiler = @import("compiler");
const ast = compiler.ast;
const astx = @import("astx.zig");
const lower_body = @import("lower_body.zig");
const model = @import("model.zig");
const types = @import("types.zig");
const session_mod = @import("session.zig");

const Lower = lower_body.Lower;
const Scope = lower_body.Scope;
const Session = session_mod.Session;
const Error = session_mod.Error;

pub const Region = enum { module_file, inline_module };

const ExtraBound = struct {
    name: []const u8,
    bound: *const ast.Type,
};

const ExtraBounds = struct {
    items: []ExtraBound = &.{},
};

/// Emit all items of a module (or of an inline `mod` body) in dependency-safe
/// categories.  Slang allows forward references between types and functions,
/// but keeping declarations grouped keeps the output readable.
pub fn emitItems(s: *Session, module: *const ast.Module, items: []*ast.Item, region: Region) Error!void {
    var type_items = std.ArrayList(*const ast.Item).empty;
    var value_items = std.ArrayList(*const ast.Item).empty;
    var impl_items = std.ArrayList(*const ast.Item).empty;
    var function_items = std.ArrayList(*const ast.Item).empty;
    defer {
        type_items.deinit(s.scratch());
        value_items.deinit(s.scratch());
        impl_items.deinit(s.scratch());
        function_items.deinit(s.scratch());
    }

    for (items) |item| {
        switch (item.kind) {
            .enum_decl, .struct_decl, .trait_decl => try type_items.append(s.scratch(), item),
            .uninitialized, .binding => try value_items.append(s.scratch(), item),
            .impl => try impl_items.append(s.scratch(), item),
            .function => try function_items.append(s.scratch(), item),
            .use => {
                if (region == .inline_module) {
                    s.setSpan(module, item);
                    return s.fail("`use` declarations must be at module scope in e7s", .{});
                }
                // Imports are emitted by the project layer before items.
            },
            .mod => |mod_decl| {
                if (mod_decl.items == null) {
                    // External modules are loaded and emitted as separate
                    // Slang modules by the project layer.
                    if (region == .inline_module) {
                        s.setSpan(module, item);
                        return s.fail("external `mod` declarations must be at module scope in e7s", .{});
                    }
                } else {
                    try emitInlineModule(s, module, item);
                }
            },
            else => {
                s.setSpan(module, item);
                return s.fail("this item kind is not supported in e7s", .{});
            },
        }
    }

    for (type_items.items) |item| try emitItem(s, module, item, region);
    for (value_items.items) |item| try emitItem(s, module, item, region);
    for (impl_items.items) |item| try emitItem(s, module, item, region);
    for (function_items.items) |item| try emitItem(s, module, item, region);
}

fn emitItem(s: *Session, module: *const ast.Module, item: *const ast.Item, region: Region) Error!void {
    s.setSpan(module, item);
    switch (item.kind) {
        .struct_decl => try emitStruct(s, module, item),
        .enum_decl => try emitEnum(s, module, item),
        .trait_decl => try emitTrait(s, module, item),
        .impl => try emitImpl(s, module, item),
        .function => try emitFunction(s, module, item),
        .binding => try emitConstant(s, module, item),
        .uninitialized => try emitResource(s, module, item, region),
        else => return s.fail("this item kind is not supported in e7s", .{}),
    }
}

fn emitInlineModule(s: *Session, module: *const ast.Module, item: *const ast.Item) Error!void {
    s.setSpan(module, item);
    const mod_decl = item.kind.mod;
    try checkAttributes(s, item.attributes, &.{});
    try s.out.line("namespace {s} {{", .{mod_decl.name});
    s.out.indent();
    try emitItems(s, module, mod_decl.items.?, .inline_module);
    s.out.trimBlank();
    s.out.dedent();
    try s.out.line("}}", .{});
    try s.out.blank();
}

fn checkAttributes(s: *Session, attributes: []ast.Attribute, allowed: []const []const u8) Error!void {
    for (attributes) |attribute| {
        const name = astx.pathLast(attribute.path);
        var ok = false;
        for (allowed) |candidate| {
            if (std.mem.eql(u8, name, candidate)) {
                ok = true;
                break;
            }
        }
        if (!ok) return s.fail("attribute `@{s}` is not supported here in e7s", .{name});
    }
}

fn writeVisibility(s: *Session, public: bool) Error!void {
    if (public) try s.out.raw("public ", .{});
}

pub fn emitStruct(s: *Session, module: *const ast.Module, item: *const ast.Item) Error!void {
    const decl = item.kind.struct_decl;
    // `@resource` is an e7 documentation tag (world resource vs component);
    // in e7s it is erased from the Slang output.
    try checkAttributes(s, item.attributes, &.{"resource"});
    const is_public = astx.isPublic(item.visibility);

    try writeVisibility(s, is_public);
    try s.out.raw("struct {s}", .{decl.name});
    const extras = try writeGenerics(s, decl.generics, decl.where_clause, true);
    try writeWhereExtras(s, extras);
    try s.out.line(" {{", .{});

    s.out.indent();
    for (decl.fields) |field| try emitField(s, field, is_public);
    s.out.dedent();
    try s.out.line("}};", .{});
    try s.out.blank();
    _ = module;
}

fn emitField(s: *Session, field: ast.Field, struct_public: bool) Error!void {
    var location: ?i64 = null;
    var semantic: ?[]const u8 = null;
    var flat = false;

    for (field.attributes) |attribute| {
        const name = astx.pathLast(attribute.path);
        if (std.mem.eql(u8, name, "location")) {
            if (attribute.args.len != 1) return s.fail("@location expects one integer argument", .{});
            location = astx.intValue(attribute.args[0]) orelse
                return s.fail("@location argument must be an integer literal", .{});
        } else if (std.mem.eql(u8, name, "builtin")) {
            const builtin = astx.attrBuiltinName(attribute) orelse
                return s.fail("@builtin expects one name argument", .{});
            semantic = astx.builtinSemantic(builtin) orelse
                return s.fail("unknown builtin name `{s}`", .{builtin});
        } else if (std.mem.eql(u8, name, "flat")) {
            if (attribute.args.len != 0) return s.fail("@flat takes no arguments", .{});
            flat = true;
        } else {
            return s.fail("attribute `@{s}` is not supported on struct fields in e7s", .{name});
        }
    }

    if (semantic != null and location != null) {
        return s.fail("a field cannot have both @builtin and @location", .{});
    }

    if (struct_public) try s.out.raw("public ", .{});
    _ = field.visibility;
    if (flat) try s.out.raw("nointerpolation ", .{});
    if (location) |index| try s.out.raw("[[vk::location({d})]] ", .{index});
    try types.writeType(s, field.ty);
    try s.out.raw(" {s}", .{field.name});
    if (semantic) |name| try s.out.raw(" : {s}", .{name});
    try s.out.line(";", .{});
}

pub fn emitEnum(s: *Session, module: *const ast.Module, item: *const ast.Item) Error!void {
    const decl = item.kind.enum_decl;
    try checkAttributes(s, item.attributes, &.{});
    if (decl.generics.len != 0) return s.fail("generic enums are not supported in e7s", .{});
    if (decl.where_clause != null) return s.fail("`where` clauses on enums are not supported in e7s", .{});
    if (decl.variants.len == 0) return s.fail("empty enums are not supported in e7s", .{});

    try writeVisibility(s, astx.isPublic(item.visibility));
    try s.out.line("enum class {s} {{", .{decl.name});
    s.out.indent();
    for (decl.variants) |variant| {
        switch (variant.payload) {
            .unit => {},
            else => {
                s.setSpan(module, item);
                return s.fail("enum variants with payloads are not supported in e7s", .{});
            },
        }
        try s.out.line("{s},", .{variant.name});
    }
    s.out.dedent();
    try s.out.line("}};", .{});
    try s.out.blank();
}

pub fn emitTrait(s: *Session, module: *const ast.Module, item: *const ast.Item) Error!void {
    _ = module;
    const decl = item.kind.trait_decl;
    try checkAttributes(s, item.attributes, &.{});
    try writeVisibility(s, astx.isPublic(item.visibility));
    try s.out.raw("interface {s}", .{decl.name});
    _ = try writeGenerics(s, decl.generics, null, false);
    if (decl.bounds.len > 0) {
        try s.out.raw(" : ", .{});
        for (decl.bounds, 0..) |bound, i| {
            if (i != 0) try s.out.raw(", ", .{});
            try types.writeType(s, bound);
        }
    }
    try s.out.line(" {{", .{});

    s.out.indent();
    for (decl.methods) |method| try emitTraitMethod(s, method);
    s.out.dedent();
    try s.out.line("}};", .{});
    try s.out.blank();
}

fn emitTraitMethod(s: *Session, method: ast.TraitMethod) Error!void {
    if (method.is_async) return s.fail("`async` trait methods are not supported in e7s", .{});
    if (method.generics.len != 0) return s.fail("generic trait methods are not supported in e7s", .{});
    if (method.where_clause != null) return s.fail("`where` clauses on trait methods are not supported in e7s", .{});
    try checkAttributes(s, method.attributes, &.{});
    const receiver = method.receiver orelse
        return s.fail("trait method `{s}` needs a self receiver in e7s", .{method.name});

    if (receiver.mutable) try s.out.raw("[mutating] ", .{});
    try types.writeReturnType(s, method.result);
    try s.out.raw(" {s}(", .{method.name});
    for (method.params, 0..) |param, i| {
        if (i != 0) try s.out.raw(", ", .{});
        try types.writeParamType(s, param.ty);
        if (param.name) |name| {
            try s.out.raw(" {s}", .{name});
        } else {
            try s.out.raw(" arg{d}", .{i});
        }
    }
    try s.out.line(");", .{});
}

pub fn emitImpl(s: *Session, module: *const ast.Module, item: *const ast.Item) Error!void {
    const decl = item.kind.impl;
    try checkAttributes(s, item.attributes, &.{});
    const target_path = astx.typePath(decl.target) orelse
        return s.fail("`impl` target must be a named type in e7s", .{});

    const impl_public = astx.isPublic(item.visibility);
    try writeVisibility(s, impl_public);
    try s.out.raw("extension", .{});
    const extras = try writeGenerics(s, decl.generics, decl.where_clause, true);
    try s.out.raw(" ", .{});
    try types.writeType(s, decl.target);
    if (decl.trait_ty) |trait_ty| {
        const trait_path = astx.typePath(trait_ty) orelse
            return s.fail("trait in `impl` must be a named trait", .{});
        _ = trait_path;
        try s.out.raw(" : ", .{});
        try types.writeType(s, trait_ty);
    }
    try writeWhereExtras(s, extras);
    try s.out.line(" {{", .{});

    s.out.indent();
    for (decl.methods) |method| try emitImplMethod(s, module, method, target_path.*, impl_public);
    s.out.dedent();
    try s.out.line("}}", .{});
    try s.out.blank();
}

fn emitImplMethod(
    s: *Session,
    module: *const ast.Module,
    method: ast.Method,
    target: ast.Path,
    public: bool,
) Error!void {
    const function = method.function;
    var params = function.params;
    var receiver_mutable = false;
    var has_receiver = false;

    if (params.len > 0 and std.mem.eql(u8, params[0].name, "this")) {
        switch (params[0].ty.*) {
            .reference => |reference| {
                receiver_mutable = reference.mutable;
                const receiver_path = astx.typePath(reference.child) orelse
                    return s.fail("`this` receiver type must be a named type", .{});
                if (!std.mem.eql(u8, astx.pathLast(receiver_path.*), astx.pathLast(target))) {
                    return s.fail("`this` receiver type does not match the impl target", .{});
                }
                has_receiver = true;
                params = params[1..];
            },
            else => return s.fail("`this` receiver must be declared as `&Type` or `&mut Type`", .{}),
        }
    }

    try checkAttributes(s, method.attributes, &.{"inline"});

    if (function.is_async) return s.fail("`async` methods are not supported in e7s", .{});
    if (astx.hasAttribute(method.attributes, "inline")) try s.out.raw("[ForceInline] ", .{});
    if (has_receiver and receiver_mutable) try s.out.raw("[mutating] ", .{});
    if (public) try s.out.raw("public ", .{});
    if (!has_receiver) try s.out.raw("static ", .{});

    try types.writeReturnType(s, function.result);
    try s.out.raw(" {s}", .{function.name});
    const extras = try writeGenerics(s, function.generics, function.where_clause, true);
    try s.out.raw("(", .{});
    for (params, 0..) |param, i| {
        if (i != 0) try s.out.raw(", ", .{});
        try types.writeParamType(s, param.ty);
        try s.out.raw(" {s}", .{param.name});
    }
    try s.out.raw(")", .{});
    try writeWhereExtras(s, extras);
    try s.out.line(" {{", .{});

    s.out.indent();
    var lower = Lower.init(s, module);
    const scope = try s.scratch().create(Scope);
    scope.* = .{ .parent = null };
    for (params) |param| try scope.vars.put(s.scratch(), param.name, param.ty);
    if (has_receiver) {
        try scope.vars.put(s.scratch(), "this", function.params[0].ty);
    }
    lower.scope = scope;
    try seedGlobals(s, module, scope, &lower);
    try lower.lowerFunctionBody(function.body, function.result);
    s.out.dedent();
    try s.out.line("}}", .{});
}

/// Make module-scope resources and constants visible to expression inference
/// inside function bodies (e.g. `scene.colour` or `lights[i].position`).
fn seedGlobals(s: *Session, module: *const ast.Module, scope: *Scope, lower: *Lower) Error!void {
    for (module.items) |module_item| {
        switch (module_item.kind) {
            .uninitialized => |decl| {
                if (hasResourceAttributes(module_item.attributes)) {
                    try scope.vars.put(s.scratch(), decl.name, decl.ty);
                }
            },
            .binding => |binding| {
                const ty = binding.ty orelse lower.inferType(binding.value) orelse continue;
                try scope.vars.put(s.scratch(), binding.name, ty);
            },
            else => {},
        }
    }
}

fn validateVertexOutput(s: *Session, result: *const ast.Type) Error!void {
    const info = switch (result.*) {
        .path => |path| s.program.findStructByPath(path) orelse
            return s.fail("vertex entry points must return a struct declared in the program", .{}),
        else => return s.fail("vertex entry points must return a struct with a @builtin(position) field", .{}),
    };
    for (info.decl.fields) |field| {
        if (astx.attributeNamed(field.attributes, "builtin")) |attribute| {
            if (astx.attrBuiltinName(attribute)) |name| {
                if (std.mem.eql(u8, name, "position")) return;
            }
        }
    }
    return s.fail("vertex output struct `{s}` needs a field marked @builtin(position)", .{info.decl.name});
}

pub fn emitFunction(s: *Session, module: *const ast.Module, item: *const ast.Item) Error!void {
    const function = item.kind.function;
    if (function.is_async) return s.fail("`async` functions are not supported in e7s", .{});
    if (item.attributes.len > 0) try checkAttributes(s, item.attributes, &.{ "vertex", "fragment", "compute", "inline" });

    const stage = astx.stageAttribute(item.attributes);
    if (astx.countStageAttributes(item.attributes) > 1) {
        return s.fail("a function can have only one stage attribute in e7s", .{});
    }

    if (stage) |stage_info| {
        if (function.params.len > 1) {
            return s.fail("shader entry points take at most one parameter struct in e7s", .{});
        }
        try s.out.line("[shader(\"{s}\")]", .{stage_info.stage.slangName()});
        switch (stage_info.stage) {
            .compute => {
                if (!types.isVoidResult(s, function.result)) {
                    return s.fail("compute entry points must return `nil`", .{});
                }
                if (stage_info.attribute.args.len != 3) {
                    return s.fail("@compute expects three integer arguments: workgroup x, y, z", .{});
                }
                var xyz: [3]i64 = undefined;
                for (0..3) |i| {
                    xyz[i] = astx.intValue(stage_info.attribute.args[i]) orelse
                        return s.fail("@compute workgroup size arguments must be integer literals", .{});
                    if (xyz[i] <= 0) return s.fail("@compute workgroup size must be positive", .{});
                }
                try s.out.line("[numthreads({d}, {d}, {d})]", .{ xyz[0], xyz[1], xyz[2] });
            },
            .vertex => try validateVertexOutput(s, function.result),
            .fragment => {},
        }
    } else if (astx.hasAttribute(item.attributes, "inline")) {
        try s.out.line("[ForceInline]", .{});
    }

    try writeVisibility(s, astx.isPublic(item.visibility));
    try types.writeReturnType(s, function.result);
    try s.out.raw(" {s}", .{function.name});
    const extras = try writeGenerics(s, function.generics, function.where_clause, true);
    try s.out.raw("(", .{});
    for (function.params, 0..) |param, i| {
        if (i != 0) try s.out.raw(", ", .{});
        try types.writeParamType(s, param.ty);
        try s.out.raw(" {s}", .{param.name});
    }
    try s.out.raw(")", .{});
    try writeWhereExtras(s, extras);

    if (stage) |stage_info| {
        if (stage_info.stage == .fragment and !types.isVoidResult(s, function.result)) {
            const is_struct = if (astx.typePath(function.result)) |path|
                s.program.findStructByPath(path.*) != null
            else
                false;
            if (!is_struct) try s.out.raw(" : SV_Target", .{});
        }
    }
    try s.out.line(" {{", .{});

    s.out.indent();
    var lower = Lower.init(s, module);
    const scope = try s.scratch().create(Scope);
    scope.* = .{ .parent = null };
    for (function.params) |param| try scope.vars.put(s.scratch(), param.name, param.ty);
    lower.scope = scope;
    try seedGlobals(s, module, scope, &lower);
    try lower.lowerFunctionBody(function.body, function.result);
    s.out.dedent();
    try s.out.line("}}", .{});
    try s.out.blank();
}

// ---------------------------------------------------------------------------
// Resources and module-scope constants
// ---------------------------------------------------------------------------

fn hasResourceAttributes(attributes: []ast.Attribute) bool {
    return astx.hasAttribute(attributes, "binding") or
        astx.hasAttribute(attributes, "push_constant") or
        astx.hasAttribute(attributes, "uniform") or
        astx.hasAttribute(attributes, "resource");
}

pub fn emitResource(s: *Session, module: *const ast.Module, item: *const ast.Item, region: Region) Error!void {
    _ = module;
    if (region == .inline_module) {
        return s.fail("shader resources must be declared at module scope in e7s", .{});
    }
    const decl = item.kind.uninitialized;
    if (!hasResourceAttributes(item.attributes)) {
        return s.fail(
            "top-level `{s}: T` is only supported as a shader resource in e7s; add @binding or @push_constant",
            .{decl.name},
        );
    }
    try checkAttributes(s, item.attributes, &.{ "binding", "push_constant", "uniform", "resource" });

    const push_constant = astx.attributeNamed(item.attributes, "push_constant");
    const uniform = astx.attributeNamed(item.attributes, "uniform");
    const binding = astx.attributeNamed(item.attributes, "binding");

    if (push_constant != null and binding != null) {
        return s.fail("a resource cannot have both @binding and @push_constant", .{});
    }
    if (push_constant != null and uniform != null) {
        return s.fail("a resource cannot have both @uniform and @push_constant", .{});
    }
    if (push_constant == null and binding == null) {
        return s.fail("resource `{s}` needs @binding(binding, set) or @push_constant", .{decl.name});
    }

    var binding_index: ?i64 = null;
    var set_index: ?i64 = null;
    if (binding) |attribute| {
        if (attribute.args.len != 2) {
            return s.fail("@binding expects two integer arguments: binding index and descriptor set", .{});
        }
        binding_index = astx.intValue(attribute.args[0]) orelse
            return s.fail("@binding arguments must be integer literals", .{});
        set_index = astx.intValue(attribute.args[1]) orelse
            return s.fail("@binding arguments must be integer literals", .{});
        if (binding_index.? < 0 or set_index.? < 0) {
            return s.fail("@binding arguments must be non-negative", .{});
        }
        const key: u64 = (@as(u64, @intCast(set_index.?)) << 32) | @as(u32, @intCast(binding_index.?));
        if (s.used_bindings.contains(key)) {
            return s.fail(
                "duplicate resource binding: binding {d}, set {d}",
                .{ binding_index.?, set_index.? },
            );
        }
        try s.used_bindings.put(s.allocator, key, {});
    }

    const is_explicit_resource = types.isResourceType(s, decl.ty);
    const is_user_struct = types.isUserStruct(s, decl.ty);
    const wrap_constant = push_constant != null or uniform != null or
        (!is_explicit_resource and is_user_struct);

    if (!is_explicit_resource and !is_user_struct and !wrap_constant) {
        return s.fail(
            "resource `{s}` must name a user struct or a Slang resource type (Texture2D<f32>, SamplerState, StructuredBuffer<T>, ...)",
            .{decl.name},
        );
    }
    if (uniform != null and is_explicit_resource) {
        return s.fail("@uniform cannot be applied to explicit Slang resource type `{s}`", .{decl.name});
    }

    if (push_constant) |attribute| {
        if (attribute.args.len != 0) return s.fail("@push_constant takes no arguments", .{});
        try s.out.raw("[[vk::push_constant]] ", .{});
    } else if (binding_index) |index| {
        try s.out.raw("[[vk::binding({d}, {d})]] ", .{ index, set_index.? });
    }

    try writeVisibility(s, astx.isPublic(item.visibility));

    if (wrap_constant and !is_explicit_resource) {
        try s.out.raw("ConstantBuffer<", .{});
        try types.writeType(s, decl.ty);
        try s.out.raw(">", .{});
    } else {
        try types.writeType(s, decl.ty);
    }
    try s.out.line(" {s};", .{decl.name});
    try s.out.blank();
}

pub fn emitConstant(s: *Session, module: *const ast.Module, item: *const ast.Item) Error!void {
    const binding = item.kind.binding;
    if (hasResourceAttributes(item.attributes)) {
        return s.fail("a top-level value binding cannot carry resource attributes in e7s", .{});
    }
    try checkAttributes(s, item.attributes, &.{});

    var lower = Lower.init(s, module);
    var inferred: ?*const ast.Type = null;
    if (binding.ty == null) {
        inferred = lower.inferType(binding.value) orelse {
            return s.fail("module-scope constant `{s}` needs a type annotation in e7s", .{binding.name});
        };
    }
    const ty = binding.ty orelse inferred.?;

    try writeVisibility(s, astx.isPublic(item.visibility));
    try s.out.raw("static const ", .{});
    try types.writeType(s, ty);
    try s.out.raw(" {s} = ", .{binding.name});
    try lower.lowerExpr(binding.value, ty);
    try s.out.line(";", .{});
    try s.out.blank();
}

// ---------------------------------------------------------------------------
// Generics
// ---------------------------------------------------------------------------

fn genericIndex(generics: []ast.GenericParam, name: []const u8) ?usize {
    for (generics, 0..) |generic, i| {
        if (std.mem.eql(u8, generic.name, name)) return i;
    }
    return null;
}

/// Emit the angle-bracketed generic parameter list, putting one bound per
/// parameter there and returning any additional bounds that must be emitted in
/// a trailing `where` clause.  Slang structs/extensions cannot take a `where`
/// clause, so `allow_extra=false` rejects extra bounds for those.
fn writeGenerics(
    s: *Session,
    generics: []ast.GenericParam,
    where_clause: ?ast.WhereClause,
    allow_extra: bool,
) Error!ExtraBounds {
    if (generics.len == 0) {
        if (where_clause) |clause| {
            if (clause.predicates.len != 0) {
                return s.fail("`where` clause requires generic parameters", .{});
            }
        }
        return .{};
    }

    var extra = std.ArrayList(ExtraBound).empty;
    errdefer extra.deinit(s.scratch());

    // Collect where-clause bounds keyed by the constrained generic parameter.
    var where_bounds = try s.scratch().alloc(std.ArrayList(*const ast.Type), generics.len);
    for (where_bounds) |*list| list.* = .empty;
    defer {
        for (where_bounds) |*list| list.deinit(s.scratch());
        s.scratch().free(where_bounds);
    }

    if (where_clause) |clause| {
        for (clause.predicates) |predicate| {
            const path = astx.typePath(predicate.ty) orelse
                return s.fail("`where` predicates must constrain a generic parameter in e7s", .{});
            if (path.segments.len != 1) {
                return s.fail("`where` predicates must name a bare generic parameter in e7s", .{});
            }
            const index = genericIndex(generics, path.segments[0].name) orelse
                return s.fail("`where` clause constrains unknown generic parameter `{s}`", .{path.segments[0].name});
            for (predicate.bounds) |bound| try where_bounds[index].append(s.scratch(), bound);
        }
    }

    try s.out.raw("<", .{});
    for (generics, 0..) |generic, i| {
        if (i != 0) try s.out.raw(", ", .{});
        try s.out.raw("{s}", .{generic.name});

        var bounds = std.ArrayList(*const ast.Type).empty;
        defer bounds.deinit(s.scratch());
        for (generic.bounds) |bound| try bounds.append(s.scratch(), bound);
        for (where_bounds[i].items) |bound| try bounds.append(s.scratch(), bound);

        if (bounds.items.len > 0) {
            try s.out.raw(" : ", .{});
            try types.writeType(s, bounds.items[0]);
            if (bounds.items.len > 1) {
                if (!allow_extra) {
                    return s.fail(
                        "generic parameter `{s}` has multiple bounds; Slang only allows one bound per parameter here (use a function with a `where` clause)",
                        .{generic.name},
                    );
                }
                for (bounds.items[1..]) |bound| {
                    try extra.append(s.scratch(), .{ .name = generic.name, .bound = bound });
                }
            }
        }
    }
    try s.out.raw(">", .{});
    return .{ .items = try extra.toOwnedSlice(s.scratch()) };
}

fn writeWhereExtras(s: *Session, extras: ExtraBounds) Error!void {
    // Slang accepts repeated `where` clauses but not comma-separated
    // predicates; each extra bound gets its own clause.
    for (extras.items) |extra| {
        try s.out.raw(" where {s} : ", .{extra.name});
        try types.writeType(s, extra.bound);
    }
}
