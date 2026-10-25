//! Semantic analysis: name/type resolution, unification-based type inference,
//! mutability checks, and a conservative lexical borrow checker.
//!
//! The checker is intentionally layered:
//!   * `types.zig` owns the type graph, unification, substitution, formatting.
//!   * this file owns scopes, declarations, places, loans, and AST traversal.
//!
//! Borrow checking is modelled on Rust's place/loan model [rust].
//! Borrows are tracked by place (root binding + field/index projections).
//! Loans created by an expression live to the end of the enclosing statement
//! unless they are promoted into a binding, in which case they live for the
//! binding's scope.  This is a conservative NLL approximation, not a full
//! region-inference implementation.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("types.zig");

pub const Diagnostic = struct {
    message: []const u8,
    span: ast.Span = .{},
};

pub const TriggerInfo = struct {
    name: []const u8,
    systems: [][]const u8,
};

pub const Analysis = struct {
    arena: std.heap.ArenaAllocator,
    store: types.TypeStore,
    diagnostics: []Diagnostic,
    expr_types: std.AutoHashMapUnmanaged(usize, *types.Type),
    triggers: []TriggerInfo,

    pub fn deinit(self: *Analysis) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn ok(self: *const Analysis) bool {
        return self.diagnostics.len == 0;
    }

    pub fn typeOf(self: *const Analysis, expr: *const ast.Expr) ?*types.Type {
        return self.expr_types.get(@intFromPtr(expr));
    }
};

pub fn analyze(allocator: std.mem.Allocator, module: *ast.Module) !Analysis {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var checker = Checker{
        .allocator = arena.allocator(),
        .store = types.TypeStore.init(arena.allocator()),
    };
    try checker.run(module);
    const triggers = try checker.triggerInfos();
    return .{
        .arena = arena,
        .store = checker.store,
        .diagnostics = try checker.diagnostics.toOwnedSlice(checker.allocator),
        .expr_types = checker.expr_types,
        .triggers = triggers,
    };
}

const Error = error{OutOfMemory};

const GenericEnv = std.StringHashMapUnmanaged(*types.Type);

const TypeDefKind = enum { struct_, enum_, table_, trigger_ };

const TypeDef = struct {
    name: []const u8,
    qualified_name: []const u8 = "",
    module_path: []const u8 = "",
    kind: TypeDefKind,
    item: *ast.Item,
    generics: []ast.GenericParam,
    where_clause: ?ast.WhereClause = null,
    fields: []ast.Field = &.{},
    variants: []ast.Variant = &.{},
    systems: std.ArrayList(*Callable) = .empty,
    methods: std.StringHashMapUnmanaged(*Callable) = .empty,
    synthetic_fields: ?std.StringHashMapUnmanaged(*types.Type) = null,
};

const CallableKind = enum { function, method, sys };

const ImportTarget = union(enum) {
    type_def: *TypeDef,
    function: *Callable,
};

const TraitDef = struct {
    name: []const u8,
    qualified_name: []const u8 = "",
    module_path: []const u8 = "",
    generics: []ast.GenericParam = &.{},
    bounds: []*ast.Type = &.{},
};

const TraitImpl = struct {
    target: []const u8,
    trait_name: []const u8,
};

const ImplEntry = struct {
    item: *ast.Item,
    prefix: []const u8,
};

const Callable = struct {
    name: []const u8,
    module_path: []const u8 = "",
    kind: CallableKind,
    is_async: bool = false,
    generics: []ast.GenericParam,
    where_clause: ?ast.WhereClause = null,
    params: []ast.Param,
    result: *ast.Type,
    body: ?ast.FunctionBody,
    sys_params: []ast.SysParam = &.{},
    owner: ?*TypeDef = null,
};

const Binding = struct {
    id: usize,
    name: []const u8,
    ty: *types.Type,
    mutable: bool,
    initialized: bool = true,
    moved: bool = false,
    is_param: bool = false,
    is_external: bool = false,
    scope_depth: usize = 0,
    is_global: bool = false,
    loans: std.ArrayList(*Loan) = .empty,
};

const Scope = struct {
    bindings: std.ArrayList(*Binding) = .empty,
};

const Projection = union(enum) {
    field: []const u8,
    index,
    deref,
};

const Place = struct {
    root: *Binding,
    path: []Projection,
};

const Loan = struct {
    id: usize,
    place: Place,
    mutable: bool,
    owner: ?*Binding = null,
    active: bool = true,
};

const Checker = struct {
    allocator: std.mem.Allocator,
    store: types.TypeStore,
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    expr_types: std.AutoHashMapUnmanaged(usize, *types.Type) = .empty,
    type_defs: std.StringHashMapUnmanaged(*TypeDef) = .empty,
    functions: std.StringHashMapUnmanaged(*Callable) = .empty,
    qualified_types: std.StringHashMapUnmanaged(*TypeDef) = .empty,
    traits: std.StringHashMapUnmanaged(*TraitDef) = .empty,
    qualified_traits: std.StringHashMapUnmanaged(*TraitDef) = .empty,
    trait_impls: std.ArrayList(TraitImpl) = .empty,
    qualified_functions: std.StringHashMapUnmanaged(*Callable) = .empty,
    item_types: std.AutoHashMapUnmanaged(usize, *TypeDef) = .empty,
    item_callables: std.AutoHashMapUnmanaged(usize, *Callable) = .empty,
    imports: std.StringHashMapUnmanaged(ImportTarget) = .empty,
    impl_items: std.ArrayList(ImplEntry) = .empty,
    collected_mods: std.AutoHashMapUnmanaged(usize, void) = .empty,
    scopes: std.ArrayList(Scope) = .empty,
    loans: std.ArrayList(*Loan) = .empty,
    next_binding_id: usize = 0,
    next_loan_id: usize = 0,
    next_query_id: usize = 0,
    generics: ?*GenericEnv = null,
    current_return: ?*types.Type = null,
    loop_depth: usize = 0,
    block_has_return: bool = false,
    spans: *const ast.SpanMap = undefined,
    current_span: ast.Span = .{},
    current_module: []const u8 = "",
    current_async: bool = false,
    current_generics: ?[]ast.GenericParam = null,
    unsafe_depth: usize = 0,

    // ------------------------------------------------------------------
    // Driver
    // ------------------------------------------------------------------

    fn run(self: *Checker, module: *ast.Module) !void {
        self.spans = &module.spans;
        try self.installBuiltinTraits();
        try self.enterScope();
        try self.collectItems(module.items, "");
        try self.collectImpls();
        try self.collectUses(module.items, "");
        self.checkModuleItems(module.items, "") catch |err| switch (err) {
            error.OutOfMemory => return err,
        };
        self.leaveScope();
    }

    fn installBuiltinTraits(self: *Checker) Error!void {
        const names = [_][]const u8{
            "Add",       "Sub",        "Mul",   "Div",   "Neg",
            "PartialEq", "PartialOrd", "Deref", "Index",
        };
        for (names) |name| {
            const def = try self.allocator.create(TraitDef);
            def.* = .{
                .name = name,
                .qualified_name = name,
                .module_path = "",
            };
            try self.traits.put(self.allocator, name, def);
            try self.qualified_traits.put(self.allocator, name, def);
        }
    }

    fn checkModuleItems(self: *Checker, items: []*ast.Item, prefix: []const u8) Error!void {
        for (items) |item| try self.checkItem(item, prefix);
    }

    fn collectItems(self: *Checker, items: []*ast.Item, prefix: []const u8) Error!void {
        for (items) |item| try self.collectItem(item, prefix);
    }

    fn collectItem(self: *Checker, item: *ast.Item, prefix: []const u8) Error!void {
        switch (item.kind) {
            .struct_decl, .enum_decl, .table_decl, .trigger_decl => try self.collectType(item, prefix),
            .trait_decl => try self.collectTrait(item, prefix),
            .function => try self.collectFunction(item, prefix),
            .sys => try self.collectSys(item, prefix),
            .impl => try self.impl_items.append(self.allocator, .{ .item = item, .prefix = prefix }),
            .mod => |m| if (m.items) |items| try self.collectModule(items, try self.childModule(prefix, m.name)),
            .use, .binding, .uninitialized => {},
        }
    }

    fn collectModule(self: *Checker, items: []*ast.Item, prefix: []const u8) !void {
        const key = @intFromPtr(items.ptr);
        if (self.collected_mods.contains(key)) return;
        try self.collected_mods.put(self.allocator, key, {});
        try self.collectItems(items, prefix);
    }

    fn collectType(self: *Checker, item: *ast.Item, prefix: []const u8) !void {
        const name = typeNameOfItem(item) orelse return;
        const qualified = try self.qualifiedName(prefix, name);
        if (self.qualified_types.get(qualified) != null) {
            try self.report("duplicate type `{s}`", .{qualified});
            return;
        }
        const def = try self.allocator.create(TypeDef);
        def.* = .{
            .name = name,
            .qualified_name = qualified,
            .module_path = prefix,
            .kind = switch (item.kind) {
                .struct_decl => .struct_,
                .enum_decl => .enum_,
                .table_decl => .table_,
                .trigger_decl => .trigger_,
                else => unreachable,
            },
            .item = item,
            .generics = genericsOfItem(item),
            .fields = fieldsOfItem(item),
            .variants = variantsOfItem(item),
        };
        try self.qualified_types.put(self.allocator, qualified, def);
        try self.item_types.put(self.allocator, @intFromPtr(item), def);
        if (self.type_defs.get(name) == null) try self.type_defs.put(self.allocator, name, def);
    }

    fn collectFunction(self: *Checker, item: *ast.Item, prefix: []const u8) !void {
        const decl = item.kind.function;
        const qualified = try self.qualifiedName(prefix, decl.name);
        if (self.qualified_functions.get(qualified) != null) {
            try self.report("duplicate function `{s}`", .{qualified});
            return;
        }
        const callable = try self.allocator.create(Callable);
        callable.* = .{
            .name = decl.name,
            .module_path = prefix,
            .kind = .function,
            .is_async = decl.is_async,
            .generics = decl.generics,
            .where_clause = decl.where_clause,
            .params = decl.params,
            .result = decl.result,
            .body = decl.body,
        };
        try self.qualified_functions.put(self.allocator, qualified, callable);
        try self.item_callables.put(self.allocator, @intFromPtr(item), callable);
        if (self.functions.get(decl.name) == null) try self.functions.put(self.allocator, decl.name, callable);
    }

    fn collectSys(self: *Checker, item: *ast.Item, prefix: []const u8) !void {
        const decl = item.kind.sys;
        const qualified = try self.qualifiedName(prefix, decl.name);
        if (self.qualified_functions.get(qualified) != null) {
            try self.report("duplicate item `{s}`", .{qualified});
            return;
        }
        const unit_type = try self.allocator.create(ast.Type);
        unit_type.* = .{ .tuple = &.{} };
        const callable = try self.allocator.create(Callable);
        callable.* = .{
            .name = decl.name,
            .kind = .sys,
            .is_async = true,
            .generics = decl.generics,
            .params = &.{},
            .result = unit_type,
            .body = .{ .block = decl.body },
            .sys_params = decl.params,
        };
        try self.qualified_functions.put(self.allocator, qualified, callable);
        try self.item_callables.put(self.allocator, @intFromPtr(item), callable);
        if (self.functions.get(decl.name) == null) try self.functions.put(self.allocator, decl.name, callable);
        for (item.attributes) |attribute| {
            if (attribute.path.segments.len == 0) continue;
            const attr_name = attribute.path.segments[attribute.path.segments.len - 1].name;
            if (!std.mem.eql(u8, attr_name, "trigger") or attribute.args.len == 0) continue;
            const arg = attribute.args[0];
            if (arg.* != .path or arg.path.segments.len == 0) continue;
            const trigger_name = arg.path.segments[arg.path.segments.len - 1].name;
            const trigger_def = self.lookupTypeDef(trigger_name) orelse continue;
            if (trigger_def.kind != .trigger_) continue;
            try trigger_def.systems.append(self.allocator, callable);
        }
    }

    fn childModule(self: *Checker, prefix: []const u8, name: []const u8) ![]const u8 {
        return self.qualifiedName(prefix, name);
    }

    fn qualifiedName(self: *Checker, prefix: []const u8, name: []const u8) ![]const u8 {
        if (prefix.len == 0) return name;
        return std.fmt.allocPrint(self.allocator, "{s}::{s}", .{ prefix, name });
    }

    fn collectTrait(self: *Checker, item: *ast.Item, prefix: []const u8) Error!void {
        const decl = item.kind.trait_decl;
        const qualified = try self.qualifiedName(prefix, decl.name);
        if (self.qualified_traits.contains(qualified)) {
            try self.report("duplicate trait `{s}`", .{qualified});
            return;
        }
        const def = try self.allocator.create(TraitDef);
        def.* = .{
            .name = decl.name,
            .qualified_name = qualified,
            .module_path = prefix,
            .generics = decl.generics,
            .bounds = decl.bounds,
        };
        try self.qualified_traits.put(self.allocator, qualified, def);
        if (self.traits.get(decl.name) == null) try self.traits.put(self.allocator, decl.name, def);
    }

    fn lookupTrait(self: *Checker, module_prefix: []const u8, name: []const u8) ?*TraitDef {
        var buffer: [512]u8 = undefined;
        const key = if (std.mem.indexOf(u8, name, "::") != null)
            name
        else if (module_prefix.len > 0)
            std.fmt.bufPrint(&buffer, "{s}::{s}", .{ module_prefix, name }) catch name
        else
            name;
        if (self.qualified_traits.get(key)) |def| return def;
        if (self.traits.get(lastPathSegment(name))) |def| return def;
        return null;
    }

    fn checkTraitDef(self: *Checker, def: *TraitDef) Error!void {
        const old_module = self.current_module;
        const old_env = self.generics;
        var env = try self.rigidEnv(def.generics);
        self.current_module = def.module_path;
        self.generics = &env;
        defer {
            self.current_module = old_module;
            self.generics = old_env;
        }
        for (def.generics) |generic| {
            const generic_ty = env.get(generic.name) orelse continue;
            try self.checkBounds(generic_ty, generic.bounds, def.qualified_name);
        }
        for (def.bounds) |bound| {
            if (try self.resolveTraitPath(bound)) |_| {} else {
                try self.report("unknown supertrait `{s}`", .{bound.path.segments[bound.path.segments.len - 1].name});
            }
        }
    }

    fn resolveTraitPath(self: *Checker, ty: *ast.Type) Error!?*TraitDef {
        if (ty.* != .path or ty.path.segments.len == 0) return null;
        const full = self.normalizePath(try self.joinPath("", ty.path));
        if (self.lookupTrait(self.current_module, full)) |def| return def;
        return self.lookupTrait(self.current_module, ty.path.segments[ty.path.segments.len - 1].name);
    }

    fn collectImpls(self: *Checker) !void {
        for (self.impl_items.items) |entry| {
            const item = entry.item;
            const decl = item.kind.impl;
            var env = try self.rigidEnv(decl.generics);
            const old_env = self.generics;
            const old_module = self.current_module;
            self.generics = &env;
            self.current_module = entry.prefix;
            defer {
                self.generics = old_env;
                self.current_module = old_module;
            }
            const target = try self.resolveType(decl.target);
            const def = self.namedDef(target) orelse {
                if (decl.trait_ty != null) try self.report("trait impl target must be a named type", .{});
                continue;
            };
            try self.checkWhereClause(decl.where_clause, &env, def.qualified_name);
            if (decl.trait_ty) |trait_ty| {
                if (try self.resolveTraitPath(trait_ty)) |trait_def| {
                    var duplicate = false;
                    for (self.trait_impls.items) |existing| {
                        if (std.mem.eql(u8, existing.target, def.qualified_name) and
                            std.mem.eql(u8, existing.trait_name, trait_def.qualified_name))
                        {
                            duplicate = true;
                            break;
                        }
                    }
                    if (duplicate) {
                        try self.report("duplicate trait impl `{s}` for `{s}`", .{ trait_def.qualified_name, def.qualified_name });
                    } else {
                        try self.trait_impls.append(self.allocator, .{
                            .target = def.qualified_name,
                            .trait_name = trait_def.qualified_name,
                        });
                    }
                } else {
                    try self.report("unknown trait in impl", .{});
                }
            }

            for (decl.methods) |method| {
                if (def.methods.get(method.function.name) != null) {
                    try self.report("duplicate method `{s}::{s}`", .{ def.name, method.function.name });
                    continue;
                }
                const all_generics = try self.concatGenerics(decl.generics, method.function.generics);
                const callable = try self.allocator.create(Callable);
                callable.* = .{
                    .name = method.function.name,
                    .module_path = entry.prefix,
                    .kind = .method,
                    .generics = all_generics,
                    .params = method.function.params,
                    .result = method.function.result,
                    .body = method.function.body,
                    .owner = def,
                };
                try def.methods.put(self.allocator, method.function.name, callable);
            }
        }
    }

    fn implements(self: *Checker, ty: *types.Type, trait_def: *TraitDef, depth: usize) bool {
        if (depth > 32) return false;
        const resolved = self.store.resolve(ty);
        if (resolved.* != .named) return false;
        for (self.trait_impls.items) |impl| {
            if (!std.mem.eql(u8, impl.target, resolved.named.name)) continue;
            const implemented = self.qualified_traits.get(impl.trait_name) orelse continue;
            if (self.traitSatisfies(implemented, trait_def, depth + 1)) return true;
        }
        return false;
    }

    fn traitSatisfies(self: *Checker, implemented: *TraitDef, required: *TraitDef, depth: usize) bool {
        if (depth > 32) return false;
        if (std.mem.eql(u8, implemented.qualified_name, required.qualified_name)) return true;
        for (implemented.bounds) |bound| {
            const super = self.lookupTrait(implemented.module_path, lastPathSegment(bound.path.segments[bound.path.segments.len - 1].name)) orelse continue;
            if (self.traitSatisfies(super, required, depth + 1)) return true;
        }
        return false;
    }

    fn checkBounds(self: *Checker, ty: *types.Type, bounds: []*ast.Type, context: []const u8) Error!void {
        const resolved = self.store.resolve(ty);
        for (bounds) |bound| {
            const trait_def = try self.resolveTraitPath(bound) orelse {
                try self.report("unknown trait bound `{s}`", .{bound.path.segments[bound.path.segments.len - 1].name});
                continue;
            };
            if (resolved.* == .variable and resolved.variable.kind == .any) continue;
            if (resolved.* == .generic or resolved.* == .unknown) continue;
            if (!self.implements(ty, trait_def, 0)) {
                try self.report("trait bound not satisfied: `{s}` does not implement `{s}` ({s})", .{
                    try self.store.typeName(ty), trait_def.qualified_name, context,
                });
            }
        }
    }

    fn checkWhereClause(self: *Checker, where: ?ast.WhereClause, env: *GenericEnv, context: []const u8) Error!void {
        const clause = where orelse return;
        for (clause.predicates) |predicate| {
            const ty = try self.resolveTypeIn(predicate.ty, env);
            try self.checkBounds(ty, predicate.bounds, context);
        }
    }

    fn checkTypeBounds(self: *Checker, def: *TypeDef, args: []*types.Type) Error!void {
        if (args.len != def.generics.len) return;
        for (def.generics, args) |param, arg| {
            try self.checkBounds(arg, param.bounds, def.qualified_name);
        }
        if (def.where_clause != null) {
            var env = try self.envFor(def.generics, args);
            try self.checkWhereClause(def.where_clause, &env, def.qualified_name);
        }
    }

    fn checkGenericBounds(self: *Checker, callable: *Callable, args: []*types.Type) Error!void {
        if (args.len != callable.generics.len) return;
        for (callable.generics, args) |param, arg| {
            try self.checkBounds(arg, param.bounds, callable.name);
        }
        if (callable.where_clause != null) {
            var env = try self.envFor(callable.generics, args);
            try self.checkWhereClause(callable.where_clause, &env, callable.name);
        }
    }

    fn concatGenerics(self: *Checker, outer: []ast.GenericParam, inner: []ast.GenericParam) ![]ast.GenericParam {
        const out = try self.allocator.alloc(ast.GenericParam, outer.len + inner.len);
        @memcpy(out[0..outer.len], outer);
        @memcpy(out[outer.len..], inner);
        return out;
    }

    fn collectUses(self: *Checker, items: []*ast.Item, prefix: []const u8) Error!void {
        for (items) |item| {
            switch (item.kind) {
                .use => |decl| try self.collectUseTree(decl.tree, prefix),
                .mod => |m| if (m.items) |inner| {
                    try self.collectUses(inner, try self.childModule(prefix, m.name));
                },
                else => {},
            }
        }
    }

    fn collectUseTree(self: *Checker, tree: ast.UseTree, base: []const u8) Error!void {
        switch (tree) {
            .path => |entry| {
                if (entry.path.segments.len == 0) return;
                const full = try self.joinPath(base, entry.path);
                const target_name = entry.path.segments[entry.path.segments.len - 1].name;
                const local_name = entry.alias orelse target_name;
                if (self.lookupQualifiedType(full)) |def| {
                    try self.addImport(local_name, .{ .type_def = def });
                } else if (self.lookupQualifiedFunction(full)) |function| {
                    try self.addImport(local_name, .{ .function = function });
                }
            },
            .group => |group| {
                const full = try self.joinPath(base, group.prefix);
                for (group.trees) |child| try self.collectUseTree(child, full);
            },
            .glob => |prefix_path| {
                const full = try self.joinPath(base, prefix_path);
                try self.importGlob(full);
            },
        }
    }

    fn importGlob(self: *Checker, prefix: []const u8) Error!void {
        var type_it = self.qualified_types.iterator();
        while (type_it.next()) |entry| {
            if (!modulePathMatches(entry.key_ptr.*, prefix)) continue;
            const last = lastPathSegment(entry.key_ptr.*);
            try self.addImport(last, .{ .type_def = entry.value_ptr.* });
        }
        var fn_it = self.qualified_functions.iterator();
        while (fn_it.next()) |entry| {
            if (!modulePathMatches(entry.key_ptr.*, prefix)) continue;
            const last = lastPathSegment(entry.key_ptr.*);
            try self.addImport(last, .{ .function = entry.value_ptr.* });
        }
    }

    fn joinPath(self: *Checker, base: []const u8, path: ast.Path) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        if (base.len > 0) try out.appendSlice(self.allocator, base);
        for (path.segments) |segment| {
            if (out.items.len > 0) try out.appendSlice(self.allocator, "::");
            try out.appendSlice(self.allocator, segment.name);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn normalizePath(self: *Checker, full: []const u8) []const u8 {
        _ = self;
        if (std.mem.startsWith(u8, full, "crate::")) return full["crate::".len..];
        if (std.mem.startsWith(u8, full, "self::")) return full["self::".len..];
        return full;
    }

    fn typePathName(self: *Checker, ty: *ast.Type) Error!?[]const u8 {
        if (ty.* != .path or ty.path.segments.len == 0) return null;
        const full = try self.joinPath("", ty.path);
        return self.normalizePath(full);
    }

    fn addImport(self: *Checker, name: []const u8, target: ImportTarget) Error!void {
        if (self.imports.get(name)) |existing| {
            const same = switch (existing) {
                .type_def => |a| switch (target) {
                    .type_def => |b| a == b,
                    .function => false,
                },
                .function => |a| switch (target) {
                    .function => |b| a == b,
                    .type_def => false,
                },
            };
            if (!same) try self.report("conflicting import `{s}`", .{name});
            return;
        }
        try self.imports.put(self.allocator, name, target);
    }

    fn scopedKey(self: *Checker, name: []const u8, buffer: *[512]u8) ?[]const u8 {
        if (std.mem.indexOf(u8, name, "::") != null) return name;
        if (self.current_module.len == 0) return name;
        return std.fmt.bufPrint(buffer, "{s}::{s}", .{ self.current_module, name }) catch null;
    }

    fn lookupTypeDef(self: *Checker, name: []const u8) ?*TypeDef {
        var buffer: [512]u8 = undefined;
        const key = self.scopedKey(name, &buffer) orelse name;
        if (self.qualified_types.get(key)) |def| return def;
        if (self.type_defs.get(name)) |def| return def;
        if (self.imports.get(name)) |target| switch (target) {
            .type_def => |def| return def,
            .function => {},
        };
        return null;
    }

    fn lookupQualifiedType(self: *Checker, name: []const u8) ?*TypeDef {
        var buffer: [512]u8 = undefined;
        const key = self.scopedKey(name, &buffer) orelse name;
        if (self.qualified_types.get(key)) |def| return def;
        const last = lastPathSegment(key);
        if (self.qualified_types.get(last)) |def| return def;
        if (self.type_defs.get(last)) |def| return def;
        if (self.imports.get(last)) |target| switch (target) {
            .type_def => |def| return def,
            .function => {},
        };
        return null;
    }

    fn lookupFunction(self: *Checker, name: []const u8) ?*Callable {
        var buffer: [512]u8 = undefined;
        const key = self.scopedKey(name, &buffer) orelse name;
        if (self.qualified_functions.get(key)) |function| return function;
        if (self.functions.get(name)) |function| return function;
        if (self.imports.get(name)) |target| switch (target) {
            .function => |function| return function,
            .type_def => {},
        };
        return null;
    }

    fn lookupQualifiedFunction(self: *Checker, name: []const u8) ?*Callable {
        var buffer: [512]u8 = undefined;
        const key = self.scopedKey(name, &buffer) orelse name;
        if (self.qualified_functions.get(key)) |function| return function;
        const last = lastPathSegment(key);
        if (self.qualified_functions.get(last)) |function| return function;
        if (self.functions.get(last)) |function| return function;
        if (self.imports.get(last)) |target| switch (target) {
            .function => |function| return function,
            .type_def => {},
        };
        return null;
    }

    fn checkItem(self: *Checker, item: *ast.Item, prefix: []const u8) Error!void {
        const previous_span = self.current_span;
        const previous_module = self.current_module;
        if (self.spans.get(@intFromPtr(item))) |span| self.current_span = span;
        self.current_module = prefix;
        defer {
            self.current_span = previous_span;
            self.current_module = previous_module;
        }
        switch (item.kind) {
            .struct_decl, .enum_decl, .table_decl, .trigger_decl => {
                if (self.item_types.get(@intFromPtr(item)) == null) try self.collectType(item, prefix);
                try self.checkTypeDef(item);
            },
            .function => {
                if (self.item_callables.get(@intFromPtr(item)) == null) try self.collectFunction(item, prefix);
                if (self.item_callables.get(@intFromPtr(item))) |callable| try self.checkCallable(callable);
            },
            .sys => {
                if (self.item_callables.get(@intFromPtr(item)) == null) try self.collectSys(item, prefix);
                if (self.item_callables.get(@intFromPtr(item))) |callable| try self.checkSys(callable);
            },
            .trait_decl => {
                if (self.lookupTrait(prefix, item.kind.trait_decl.name)) |def| try self.checkTraitDef(def);
            },
            .impl => |decl| for (decl.methods) |method| {
                const target_name = (try self.typePathName(decl.target)) orelse continue;
                const def = self.lookupTypeDef(target_name) orelse continue;
                if (def.methods.get(method.function.name)) |callable| try self.checkCallable(callable);
            },
            .binding => |binding| try self.checkBinding(binding),
            .uninitialized => |decl| try self.checkUninitialized(decl),
            .mod => |m| if (m.items) |items| {
                const child = try self.childModule(prefix, m.name);
                try self.collectModule(items, child);
                try self.checkModuleItems(items, child);
            },
            .use => {},
        }
    }

    // ------------------------------------------------------------------
    // Diagnostics
    // ------------------------------------------------------------------

    fn triggerInfos(self: *Checker) ![]TriggerInfo {
        var infos = std.ArrayList(TriggerInfo).empty;
        var it = self.qualified_types.iterator();
        while (it.next()) |entry| {
            const def = entry.value_ptr.*;
            if (def.kind != .trigger_) continue;
            const systems = try self.allocator.alloc([]const u8, def.systems.items.len);
            for (def.systems.items, 0..) |system, i| systems[i] = system.name;
            try infos.append(self.allocator, .{
                .name = def.qualified_name,
                .systems = systems,
            });
        }
        return infos.toOwnedSlice(self.allocator);
    }

    fn report(self: *Checker, comptime format: []const u8, args: anytype) !void {
        try self.diagnostics.append(self.allocator, .{
            .message = try std.fmt.allocPrint(self.allocator, format, args),
            .span = self.current_span,
        });
    }

    fn reportMismatch(self: *Checker, expected: *types.Type, actual: *types.Type, context: []const u8) !void {
        const e = try self.store.typeName(expected);
        const a = try self.store.typeName(actual);
        try self.report("type mismatch in {s}: expected `{s}`, found `{s}`", .{ context, e, a });
    }

    fn expectAssignable(self: *Checker, expected: *types.Type, actual: *types.Type, context: []const u8) !void {
        self.store.assignable(expected, actual) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try self.reportMismatch(expected, actual, context),
        };
    }

    fn unifyOrReport(self: *Checker, left: *types.Type, right: *types.Type, context: []const u8) !void {
        self.store.unify(left, right) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const l = try self.store.typeName(left);
                const r = try self.store.typeName(right);
                try self.report("type mismatch in {s}: `{s}` vs `{s}`", .{ context, l, r });
            },
        };
    }

    // ------------------------------------------------------------------
    // Scopes and bindings
    // ------------------------------------------------------------------

    fn enterScope(self: *Checker) Error!void {
        try self.scopes.append(self.allocator, .{});
    }

    fn leaveScope(self: *Checker) void {
        var scope = self.scopes.pop().?;
        for (scope.bindings.items) |binding| self.releaseOwned(binding);
        scope.bindings.deinit(self.allocator);
    }

    fn declare(self: *Checker, name: []const u8, ty: *types.Type, mutable: bool) !*Binding {
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        for (scope.bindings.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) {
                try self.report("duplicate binding `{s}`", .{name});
                break;
            }
        }
        const binding = try self.allocator.create(Binding);
        binding.* = .{
            .id = self.next_binding_id,
            .name = name,
            .ty = ty,
            .mutable = mutable,
            .is_global = self.scopes.items.len == 1,
            .scope_depth = self.scopes.items.len,
        };
        self.next_binding_id += 1;
        try scope.bindings.append(self.allocator, binding);
        return binding;
    }

    fn lookup(self: *Checker, name: []const u8) ?*Binding {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            for (self.scopes.items[i].bindings.items) |binding| {
                if (std.mem.eql(u8, binding.name, name)) return binding;
            }
        }
        return null;
    }

    fn checkBinding(self: *Checker, binding: ast.Binding) !void {
        const mark = self.loans.items.len;
        var ty: *types.Type = undefined;
        if (binding.ty) |annotation| {
            ty = try self.resolveType(annotation);
        } else {
            ty = try self.store.freshVar(.any);
        }
        _ = try self.checkMoveExpr(binding.value, ty);
        const declared = try self.declare(binding.name, ty, binding.mutable);
        try self.ownLoansFrom(mark, declared);
    }

    fn checkUninitialized(self: *Checker, decl: ast.UninitializedDecl) !void {
        const ty = try self.resolveType(decl.ty);
        const binding = try self.declare(decl.name, ty, decl.mutable);
        binding.initialized = false;
    }

    // ------------------------------------------------------------------
    // Places and loans
    // ------------------------------------------------------------------

    fn makePlace(self: *Checker, root: *Binding, path: []Projection) !*Place {
        const place = try self.allocator.create(Place);
        place.* = .{ .root = root, .path = path };
        return place;
    }

    fn placeOf(self: *Checker, expr: *ast.Expr) !?*Place {
        switch (expr.*) {
            .path => |path| {
                if (path.segments.len != 1) return null;
                const binding = self.lookup(path.segments[0].name) orelse return null;
                return self.makePlace(binding, &.{});
            },
            .field => |field| {
                const base = try self.placeOf(field.target) orelse return null;
                const path = try self.allocator.alloc(Projection, base.path.len + 1);
                @memcpy(path[0..base.path.len], base.path);
                path[base.path.len] = .{ .field = field.name };
                return self.makePlace(base.root, path);
            },
            .index => |index_expr| {
                const base = try self.placeOf(index_expr.target) orelse return null;
                const base_ty = self.store.resolve(try self.placeType(base));
                const key_ty: ?*types.Type = switch (base_ty.*) {
                    .map => |m| m.key,
                    .named => if (self.implementsTrait(base_ty, "Index")) null else try self.store.make(.{ .int = .usize }),
                    else => try self.store.make(.{ .int = .usize }),
                };
                if (key_ty) |key| _ = try self.checkExpr(index_expr.index, key);
                const path = try self.allocator.alloc(Projection, base.path.len + 1);
                @memcpy(path[0..base.path.len], base.path);
                path[base.path.len] = .index;
                return self.makePlace(base.root, path);
            },
            .unary => |unary| {
                if (unary.op != .deref) return null;
                const base = try self.placeOf(unary.operand) orelse return null;
                const path = try self.allocator.alloc(Projection, base.path.len + 1);
                @memcpy(path[0..base.path.len], base.path);
                path[base.path.len] = .deref;
                return self.makePlace(base.root, path);
            },
            else => return null,
        }
    }

    fn placeType(self: *Checker, place: *Place) !*types.Type {
        var ty = place.root.ty;
        for (place.path) |projection| {
            ty = switch (projection) {
                .field => |name| (try self.fieldType(ty, name)) orelse return try self.store.make(.unknown),
                .index => blk: {
                    const resolved = self.store.resolve(ty);
                    break :blk switch (resolved.*) {
                        .array => |a| if (a.columns != null)
                            try self.makeArrayType(a.element, a.columns, null)
                        else
                            a.element,
                        .map => |m| m.value,
                        .string => resolved,
                        .unknown => resolved,
                        .named => if (self.implementsTrait(resolved, "Index"))
                            (self.customOperatorMethod(resolved, "index", 2) orelse try self.store.make(.unknown))
                        else
                            try self.store.make(.unknown),
                        else => try self.store.make(.unknown),
                    };
                },
                .deref => blk: {
                    const resolved = self.store.resolve(ty);
                    break :blk switch (resolved.*) {
                        .reference => |r| r.child,
                        .box => |child| child,
                        .raw_pointer => |child| child,
                        .unknown => resolved,
                        else => try self.store.make(.unknown),
                    };
                },
            };
        }
        return ty;
    }

    fn placeMutable(self: *Checker, place: *Place) Error!bool {
        if (place.path.len == 0) return place.root.mutable;
        var allowed = place.root.mutable;
        var ty = self.store.resolve(place.root.ty);
        for (place.path) |projection| {
            ty = self.store.resolve(ty);
            switch (projection) {
                .deref => {
                    switch (ty.*) {
                        .reference => |r| {
                            if (!r.mutable) return false;
                            allowed = true;
                            ty = self.store.resolve(r.child);
                        },
                        .raw_pointer => |child| {
                            allowed = true;
                            ty = self.store.resolve(child);
                        },
                        .box => |child| {
                            if (!allowed) return false;
                            ty = self.store.resolve(child);
                        },
                        else => return false,
                    }
                },
                .field => |name| {
                    while (self.store.resolve(ty).* == .reference) {
                        const ref = self.store.resolve(ty).reference;
                        if (!ref.mutable) return false;
                        allowed = true;
                        ty = self.store.resolve(ref.child);
                    }
                    ty = self.store.resolve(ty);
                    if (ty.* == .box) {
                        if (!allowed) return false;
                        ty = self.store.resolve(ty.box);
                    } else if (ty.* == .raw_pointer) {
                        allowed = true;
                        ty = self.store.resolve(ty.raw_pointer);
                    }
                    ty = (try self.fieldType(ty, name)) orelse return false;
                    ty = self.store.resolve(ty);
                },
                .index => {
                    while (self.store.resolve(ty).* == .reference) {
                        const ref = self.store.resolve(ty).reference;
                        if (!ref.mutable) return false;
                        allowed = true;
                        ty = self.store.resolve(ref.child);
                    }
                    ty = self.store.resolve(ty);
                    if (ty.* == .box) {
                        if (!allowed) return false;
                        ty = self.store.resolve(ty.box);
                    } else if (ty.* == .raw_pointer) {
                        allowed = true;
                        ty = self.store.resolve(ty.raw_pointer);
                    }
                    ty = switch (ty.*) {
                        .array => |a| if (a.columns != null)
                            try self.makeArrayType(a.element, a.columns, null)
                        else
                            self.store.resolve(a.element),
                        .map => |m| m.value,
                        .string => ty,
                        else => return false,
                    };
                },
            }
        }
        return allowed;
    }

    fn overlap(a: *const Place, b: *const Place) bool {
        if (a.root != b.root) return false;
        const limit = @min(a.path.len, b.path.len);
        for (0..limit) |i| {
            switch (a.path[i]) {
                .field => |name| switch (b.path[i]) {
                    .field => |other| if (!std.mem.eql(u8, name, other)) return false,
                    .index, .deref => {},
                },
                .index, .deref => {},
            }
        }
        return true;
    }

    fn checkRead(self: *Checker, place: *Place) !void {
        if (!place.root.initialized) {
            try self.report("use of uninitialized value `{s}`", .{place.root.name});
            return;
        }
        if (place.root.moved) {
            try self.report("use of moved value `{s}`", .{place.root.name});
            return;
        }
        for (self.loans.items) |loan| {
            if (!loan.active) continue;
            if (loan.mutable and overlap(&loan.place, place)) {
                try self.report("cannot read `{s}` while it is mutably borrowed", .{place.root.name});
                return;
            }
        }
    }

    fn checkMutation(self: *Checker, place: *Place) !void {
        if (place.root.moved) {
            try self.report("use of moved value `{s}`", .{place.root.name});
            return;
        }
        for (self.loans.items) |loan| {
            if (!loan.active) continue;
            if (overlap(&loan.place, place)) {
                try self.report("cannot mutate `{s}` while it is borrowed", .{place.root.name});
                return;
            }
        }
    }

    fn borrowPlace(self: *Checker, place: *Place, mutable: bool) !void {
        if (!place.root.initialized) {
            try self.report("cannot borrow uninitialized value `{s}`", .{place.root.name});
            return;
        }
        if (place.root.moved) {
            try self.report("cannot borrow moved value `{s}`", .{place.root.name});
            return;
        }
        if (mutable and !try self.placeMutable(place)) {
            try self.report("cannot mutably borrow immutable place `{s}`", .{place.root.name});
            return;
        }
        for (self.loans.items) |loan| {
            if (!loan.active) continue;
            if (overlap(&loan.place, place) and (mutable or loan.mutable)) {
                try self.report("conflicting borrow of `{s}`", .{place.root.name});
                return;
            }
        }
        const loan = try self.allocator.create(Loan);
        loan.* = .{
            .id = self.next_loan_id,
            .place = .{ .root = place.root, .path = place.path },
            .mutable = mutable,
        };
        self.next_loan_id += 1;
        try self.loans.append(self.allocator, loan);
    }

    fn ownLoansFrom(self: *Checker, mark: usize, owner: *Binding) !void {
        if (mark >= self.loans.items.len) return;
        for (self.loans.items[mark..]) |loan| {
            if (loan.owner == null and loan.active) {
                loan.owner = owner;
                try owner.loans.append(self.allocator, loan);
            }
        }
    }

    fn releaseOwned(self: *Checker, owner: *Binding) void {
        for (owner.loans.items) |loan| loan.active = false;
        owner.loans.deinit(self.allocator);
        owner.loans = .empty;
    }

    fn releaseLoansAt(self: *Checker, place: *Place) void {
        for (self.loans.items) |loan| {
            if (!loan.active) continue;
            if (overlap(&loan.place, place)) {
                loan.active = false;
                continue;
            }
            // Reassigning a reference variable also ends the loans it owns.
            if (place.path.len == 0 and loan.owner == place.root) loan.active = false;
        }
    }

    fn isCopyType(self: *Checker, ty: *types.Type) bool {
        const resolved = self.store.resolve(ty);
        return switch (resolved.*) {
            .unit, .bool, .string, .never, .unknown, .int, .float, .reference, .raw_pointer, .function, .error_value => true,
            .variable => |v| v.kind != .any,
            .box => false,
            .optional => |child| self.isCopyType(child),
            .error_union => |err| self.isCopyType(err.error_type) and self.isCopyType(err.value_type),
            .tuple => |items| blk: {
                for (items) |item| if (!self.isCopyType(item)) break :blk false;
                break :blk true;
            },
            .array => |array| self.isCopyType(array.element),
            .map => false,
            .range => true,
            .named, .query, .resource, .generic => false,
        };
    }

    fn checkMoveLoans(self: *Checker, place: *Place) !void {
        for (self.loans.items) |loan| {
            if (loan.active and overlap(&loan.place, place)) {
                try self.report("cannot move `{s}` while it is borrowed", .{place.root.name});
                return;
            }
        }
    }

    fn markMoveValue(self: *Checker, expr: *ast.Expr) Error!void {
        if (expr.* != .path or expr.path.segments.len != 1) return;
        const name = expr.path.segments[0].name;
        const binding = self.lookup(name) orelse return;
        if (binding.moved) return;
        const ty = self.store.resolve(binding.ty);
        if (self.isCopyType(ty)) return;
        const place = try self.makePlace(binding, &.{});
        try self.checkMoveLoans(place);
        binding.moved = true;
    }

    fn markBlockTailMove(self: *Checker, block: *ast.Block) Error!void {
        if (blockTailExpr(block)) |tail| try self.markMoveValue(tail);
    }

    fn checkMoveExpr(self: *Checker, expr: *ast.Expr, expected: ?*types.Type) Error!*types.Type {
        if (expr.* == .path and expr.path.segments.len == 1) {
            const name = expr.path.segments[0].name;
            if (self.lookup(name)) |binding| {
                if (binding.moved) {
                    try self.report("use of moved value `{s}`", .{name});
                    return self.store.make(.unknown);
                }
                const ty = self.store.resolve(binding.ty);
                if (!self.isCopyType(ty)) {
                    const place = try self.makePlace(binding, &.{});
                    try self.checkMoveLoans(place);
                    binding.moved = true;
                    _ = try self.record(expr, ty);
                    if (expected) |wanted| try self.expectAssignable(wanted, ty, "move");
                    return ty;
                }
            }
        }
        return self.checkExpr(expr, expected);
    }

    fn releaseTemporaries(self: *Checker, mark: usize) void {
        if (mark >= self.loans.items.len) return;
        for (self.loans.items[mark..]) |loan| {
            if (loan.active and loan.owner == null) loan.active = false;
        }
    }

    fn releaseUnusedLocals(self: *Checker, depth: usize, remaining: []ast.Entry) void {
        if (depth == 0 or depth > self.scopes.items.len) return;
        for (self.scopes.items[depth - 1].bindings.items) |binding| {
            if (binding.scope_depth != depth) continue;
            if (binding.loans.items.len == 0) continue;
            if (!entriesUseName(remaining, binding.name)) self.releaseOwned(binding);
        }
    }

    // ------------------------------------------------------------------
    // Type definitions and generics
    // ------------------------------------------------------------------

    fn checkTypeDef(self: *Checker, item: *ast.Item) !void {
        const def = self.item_types.get(@intFromPtr(item)) orelse
            self.type_defs.get(typeNameOfItem(item) orelse return) orelse return;
        var env = try self.rigidEnv(def.generics);
        const old_env = self.generics;
        const old_module = self.current_module;
        const old_generics = self.current_generics;
        self.generics = &env;
        self.current_module = def.module_path;
        self.current_generics = def.generics;
        defer {
            self.generics = old_env;
            self.current_module = old_module;
            self.current_generics = old_generics;
        }
        for (def.generics) |generic| {
            const generic_ty = env.get(generic.name) orelse continue;
            try self.checkBounds(generic_ty, generic.bounds, def.qualified_name);
        }
        try self.checkWhereClause(def.where_clause, &env, def.qualified_name);

        var fields_seen = std.StringHashMapUnmanaged(void).empty;
        defer fields_seen.deinit(self.allocator);
        for (def.fields) |field| {
            if (fields_seen.contains(field.name)) {
                try self.report("duplicate field `{s}::{s}`", .{ def.name, field.name });
            } else {
                try fields_seen.put(self.allocator, field.name, {});
            }
            _ = try self.resolveType(field.ty);
        }

        var variants_seen = std.StringHashMapUnmanaged(void).empty;
        defer variants_seen.deinit(self.allocator);
        for (def.variants) |variant| {
            if (variants_seen.contains(variant.name)) {
                try self.report("duplicate variant `{s}::{s}`", .{ def.name, variant.name });
            } else {
                try variants_seen.put(self.allocator, variant.name, {});
            }
            switch (variant.payload) {
                .unit => {},
                .tuple => |payloads| {
                    for (payloads) |payload| _ = try self.resolveType(payload.ty);
                },
                .struct_fields => |fields| {
                    for (fields) |field| _ = try self.resolveType(field.ty);
                },
            }
        }
    }

    fn rigidEnv(self: *Checker, generics: []ast.GenericParam) !GenericEnv {
        var env = GenericEnv.empty;
        for (generics, 0..) |param, i| {
            const ty = try self.store.make(.{ .generic = .{ .index = i, .name = param.name } });
            try env.put(self.allocator, param.name, ty);
        }
        return env;
    }

    fn namedDef(self: *Checker, ty: *types.Type) ?*TypeDef {
        const resolved = self.store.resolve(ty);
        if (resolved.* != .named) return null;
        return self.lookupTypeDef(resolved.named.name);
    }

    fn fieldType(self: *Checker, ty: *types.Type, name: []const u8) !?*types.Type {
        const resolved = self.store.resolve(ty);
        switch (resolved.*) {
            .unknown => return self.store.make(.unknown),
            .reference => |ref| return self.fieldType(ref.child, name),
            .query => |q| return self.fieldType(q.element, name),
            .named => |named| {
                const def = self.lookupTypeDef(named.name) orelse return null;
                if (def.synthetic_fields) |fields| return fields.get(name);
                var env = try self.envFor(def.generics, named.args);
                for (def.fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) {
                        return try self.resolveTypeIn(field.ty, &env);
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    fn envFor(self: *Checker, generics: []ast.GenericParam, args: []*types.Type) !GenericEnv {
        var env = GenericEnv.empty;
        for (generics, 0..) |param, i| {
            const ty = if (i < args.len) args[i] else try self.store.make(.unknown);
            try env.put(self.allocator, param.name, ty);
        }
        return env;
    }

    fn variantOf(self: *Checker, ty: *types.Type, name: []const u8) ?*ast.Variant {
        const def = self.namedDef(ty) orelse return null;
        for (def.variants) |*variant| {
            if (std.mem.eql(u8, variant.name, name)) return variant;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Type resolution
    // ------------------------------------------------------------------

    fn resolveType(self: *Checker, source: *ast.Type) Error!*types.Type {
        return self.resolveTypeIn(source, self.generics);
    }

    fn resolveTypeIn(self: *Checker, source: *ast.Type, env: ?*GenericEnv) Error!*types.Type {
        return switch (source.*) {
            .inferred_error => |child| self.store.make(.{ .error_union = .{
                .error_type = try self.store.make(.unknown),
                .value_type = try self.resolveTypeIn(child, env),
            } }),
            .error_union => |e| self.store.make(.{ .error_union = .{
                .error_type = try self.resolveTypeIn(e.error_type, env),
                .value_type = try self.resolveTypeIn(e.value_type, env),
            } }),
            .optional => |child| self.store.make(.{ .optional = try self.resolveTypeIn(child, env) }),
            .reference => |ref| self.store.make(.{ .reference = .{
                .mutable = ref.mutable,
                .child = try self.resolveTypeIn(ref.child, env),
            } }),
            .box => |child| self.store.make(.{ .box = try self.resolveTypeIn(child, env) }),
            .raw_pointer => |child| self.store.make(.{ .raw_pointer = try self.resolveTypeIn(child, env) }),
            .function => |f| blk: {
                const params = try self.allocator.alloc(*types.Type, f.params.len);
                for (f.params, 0..) |param, i| params[i] = try self.resolveTypeIn(param, env);
                break :blk self.store.make(.{ .function = .{
                    .params = params,
                    .result = try self.resolveTypeIn(f.result, env),
                } });
            },
            .tuple => |items| blk: {
                if (items.len == 0) break :blk self.store.make(.unit);
                const out = try self.allocator.alloc(*types.Type, items.len);
                for (items, 0..) |item, i| out[i] = try self.resolveTypeIn(item, env);
                break :blk self.store.make(.{ .tuple = out });
            },
            .array => |a| blk: {
                const length = if (a.length) |expr| try self.constArrayLength(expr) else null;
                const columns = if (a.columns) |expr| try self.constArrayLength(expr) else null;
                break :blk self.store.make(.{ .array = .{
                    .element = try self.resolveTypeIn(a.element, env),
                    .length = length,
                    .columns = columns,
                } });
            },
            .map => |m| self.store.make(.{ .map = .{
                .key = try self.resolveTypeIn(m.key, env),
                .value = try self.resolveTypeIn(m.value, env),
            } }),
            .path => |path| self.resolveTypePath(path, env),
        };
    }

    fn resolveTypePath(self: *Checker, path: ast.Path, env: ?*GenericEnv) Error!*types.Type {
        if (path.segments.len == 0) return self.store.make(.unknown);
        const segment = path.segments[path.segments.len - 1];
        const name = segment.name;
        if (env) |generics| {
            if (generics.get(name)) |ty| return ty;
        }
        if (path.segments.len == 1) {
            if (types.TypeStore.builtin(name)) |builtin_type| {
                if (segment.args.len != 0) {
                    try self.report("builtin type `{s}` takes no type arguments", .{name});
                }
                return self.store.make(builtin_type);
            }
        }
        if (path.segments.len == 1 and std.mem.eql(u8, name, "Task")) {
            if (segment.args.len != 1) {
                try self.report("`Task` expects exactly one type argument", .{});
                return self.store.make(.unknown);
            }
            return self.makeTask(try self.resolveTypeIn(segment.args[0], env));
        }
        if (path.segments.len == 1 and std.mem.eql(u8, name, "Cancelled")) {
            if (segment.args.len != 0) {
                try self.report("`Cancelled` takes no type arguments", .{});
            }
            return self.cancelledType();
        }
        const full = self.normalizePath(try self.joinPath("", path));
        const def = self.lookupQualifiedType(full) orelse self.lookupTypeDef(name) orelse {
            try self.report("unknown type `{s}`", .{full});
            return self.store.make(.unknown);
        };
        const args = try self.allocator.alloc(*types.Type, segment.args.len);
        for (segment.args, 0..) |arg, i| args[i] = try self.resolveTypeIn(arg, env);
        if (args.len != def.generics.len) {
            try self.report("type `{s}` expects {d} type argument(s), found {d}", .{
                def.qualified_name, def.generics.len, args.len,
            });
        }
        try self.checkTypeBounds(def, args);
        return self.store.make(.{ .named = .{ .name = def.qualified_name, .args = args } });
    }

    fn cancelledType(self: *Checker) !*types.Type {
        return self.store.make(.{ .named = .{ .name = "Cancelled", .args = &.{} } });
    }

    fn isCancelledType(self: *Checker, ty: *types.Type) bool {
        const resolved = self.store.resolve(ty);
        return resolved.* == .named and std.mem.eql(u8, resolved.named.name, "Cancelled");
    }

    fn makeTask(self: *Checker, inner: *types.Type) !*types.Type {
        const args = try self.allocator.alloc(*types.Type, 1);
        args[0] = inner;
        return self.store.make(.{ .named = .{ .name = "Task", .args = args } });
    }

    fn taskInner(self: *Checker, ty: *types.Type) ?*types.Type {
        const resolved = self.store.resolve(ty);
        if (resolved.* != .named or !std.mem.eql(u8, resolved.named.name, "Task") or resolved.named.args.len != 1) return null;
        return resolved.named.args[0];
    }

    fn implicitCancelled(self: *Checker, success: *types.Type) !*types.Type {
        const resolved = self.store.resolve(success);
        if (resolved.* == .error_union and self.isCancelledType(resolved.error_union.error_type)) return resolved;
        return self.store.make(.{ .error_union = .{
            .error_type = try self.cancelledType(),
            .value_type = success,
        } });
    }

    fn asyncTaskType(self: *Checker, success: *types.Type) !*types.Type {
        return self.makeTask(try self.implicitCancelled(success));
    }

    fn constArrayLength(self: *Checker, expr: *ast.Expr) !?usize {
        if (expr.* == .int and expr.int >= 0) return @intCast(expr.int);
        try self.report("array length must be a non-negative integer literal", .{});
        return null;
    }

    // ------------------------------------------------------------------
    // Callables
    // ------------------------------------------------------------------

    fn checkFunctionBody(self: *Checker, body: ast.FunctionBody, result: *types.Type, label: []const u8) Error!void {
        switch (body) {
            .expr => |expr| {
                const actual = try self.checkMoveExpr(expr, null);
                try self.expectReturn(result, actual, "function body");
                try self.checkBorrowEscape(expr, result);
            },
            .block => |block| {
                const ty = try self.checkBlockWithTail(block, result);
                try self.markBlockTailMove(block);
                if (self.store.resolve(result).* == .unit) return;
                if (self.store.resolve(ty).* == .unit) {
                    if (!self.block_has_return) {
                        try self.report("function `{s}` may return without a value", .{label});
                    }
                } else {
                    try self.expectReturn(result, ty, "function body");
                }
            },
        }
    }

    fn returnMatches(self: *Checker, expected: *types.Type, actual: *types.Type) bool {
        if (self.store.assignable(expected, actual)) {
            return true;
        } else |_| {}
        if (self.current_async) {
            const implicit = self.implicitCancelled(expected) catch return false;
            if (self.store.assignable(implicit, actual)) return true else |_| {}
        }
        return false;
    }

    fn expectReturn(self: *Checker, expected: *types.Type, actual: *types.Type, context: []const u8) Error!void {
        if (self.returnMatches(expected, actual)) return;
        try self.reportMismatch(expected, actual, context);
    }

    fn containsReference(self: *Checker, ty: *types.Type) bool {
        const resolved = self.store.resolve(ty);
        return switch (resolved.*) {
            .reference, .raw_pointer => true,
            .box, .optional, .range, .resource => |child| self.containsReference(child),
            .error_union => |e| self.containsReference(e.error_type) or self.containsReference(e.value_type),
            .function => |f| blk: {
                for (f.params) |param| if (self.containsReference(param)) break :blk true;
                break :blk self.containsReference(f.result);
            },
            .tuple => |items| blk: {
                for (items) |item| if (self.containsReference(item)) break :blk true;
                break :blk false;
            },
            .array => |a| self.containsReference(a.element),
            .map => |m| self.containsReference(m.key) or self.containsReference(m.value),
            .query => |q| self.containsReference(q.element),
            .named => |n| blk: {
                if (!std.mem.eql(u8, n.name, "Task")) {
                    for (n.args) |arg| if (self.containsReference(arg)) break :blk true;
                    break :blk false;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn checkAsyncSignature(self: *Checker, callable: *Callable) Error!void {
        if (!callable.is_async or callable.kind == .sys) return;
        for (callable.params) |param| {
            const ty = try self.resolveType(param.ty);
            if (self.containsReference(ty)) {
                try self.report("async parameter `{s}` cannot contain references", .{param.name});
            }
        }
        const result = try self.resolveType(callable.result);
        if (self.containsReference(result)) {
            try self.report("async result type cannot contain references", .{});
        }
    }

    fn checkCallable(self: *Checker, callable: *Callable) Error!void {
        var env = try self.rigidEnv(callable.generics);
        const old_env = self.generics;
        const old_return = self.current_return;
        const old_loop = self.loop_depth;
        const old_has_return = self.block_has_return;
        const old_module = self.current_module;
        const old_async = self.current_async;
        const old_generics = self.current_generics;
        self.generics = &env;
        self.current_module = callable.module_path;
        self.current_async = callable.is_async;
        self.current_generics = callable.generics;
        for (callable.generics) |generic| {
            const generic_ty = env.get(generic.name) orelse continue;
            try self.checkBounds(generic_ty, generic.bounds, callable.name);
        }
        try self.checkWhereClause(callable.where_clause, &env, callable.name);
        try self.checkAsyncSignature(callable);
        self.current_return = try self.resolveType(callable.result);
        self.loop_depth = 0;
        self.block_has_return = false;
        defer {
            self.generics = old_env;
            self.current_module = old_module;
            self.current_async = old_async;
            self.current_generics = old_generics;
            self.current_return = old_return;
            self.loop_depth = old_loop;
            self.block_has_return = old_has_return;
        }

        const loan_mark = self.loans.items.len;
        defer self.releaseTemporaries(loan_mark);
        try self.enterScope();
        defer self.leaveScope();
        for (callable.params) |param| {
            const binding = try self.declare(param.name, try self.resolveType(param.ty), false);
            binding.is_param = true;
        }
        try self.checkFunctionBody(callable.body.?, self.current_return.?, callable.name);
    }

    fn resolveTypeArgs(self: *Checker, args: []*ast.Type) ![]*types.Type {
        const out = try self.allocator.alloc(*types.Type, args.len);
        for (args, 0..) |arg, i| out[i] = try self.resolveType(arg);
        return out;
    }

    const Instantiation = struct {
        ty: *types.Type,
        args: []*types.Type,
    };

    fn callableType(self: *Checker, callable: *Callable, explicit_args: ?[]*types.Type) Error!*types.Type {
        return (try self.instantiateCallable(callable, explicit_args)).ty;
    }

    fn instantiateCallable(self: *Checker, callable: *Callable, explicit_args: ?[]*types.Type) Error!Instantiation {
        const old_module = self.current_module;
        self.current_module = callable.module_path;
        defer self.current_module = old_module;
        if (explicit_args) |args| {
            if (args.len != callable.generics.len) {
                try self.report("function `{s}` expects {d} type argument(s), found {d}", .{
                    callable.name, callable.generics.len, args.len,
                });
            }
        }
        var env = GenericEnv.empty;
        const args = try self.allocator.alloc(*types.Type, callable.generics.len);
        for (callable.generics, 0..) |param, i| {
            const ty = if (explicit_args != null and i < explicit_args.?.len)
                explicit_args.?[i]
            else
                try self.store.freshVar(.any);
            args[i] = ty;
            try env.put(self.allocator, param.name, ty);
        }
        const params = try self.allocator.alloc(*types.Type, callable.params.len);
        for (callable.params, 0..) |param, i| {
            params[i] = try self.resolveTypeIn(param.ty, &env);
        }
        if (explicit_args) |provided| try self.checkGenericBounds(callable, provided);
        const success = try self.resolveTypeIn(callable.result, &env);
        const result_ty = if (callable.is_async) try self.asyncTaskType(success) else success;
        return .{
            .ty = try self.store.make(.{ .function = .{
                .params = params,
                .result = result_ty,
            } }),
            .args = args,
        };
    }

    fn checkSys(self: *Checker, callable: *Callable) Error!void {
        var env = try self.rigidEnv(callable.generics);
        const old_env = self.generics;
        const old_return = self.current_return;
        const old_loop = self.loop_depth;
        const old_has_return = self.block_has_return;
        const old_module = self.current_module;
        const old_async = self.current_async;
        const old_generics = self.current_generics;
        self.generics = &env;
        self.current_module = callable.module_path;
        self.current_async = callable.is_async;
        self.current_generics = callable.generics;
        self.current_return = try self.store.make(.unit);
        self.loop_depth = 0;
        self.block_has_return = false;
        defer {
            self.generics = old_env;
            self.current_module = old_module;
            self.current_async = old_async;
            self.current_generics = old_generics;
            self.current_return = old_return;
            self.loop_depth = old_loop;
            self.block_has_return = old_has_return;
        }

        const loan_mark = self.loans.items.len;
        defer self.releaseTemporaries(loan_mark);
        try self.enterScope();
        defer self.leaveScope();
        for (callable.sys_params) |param| {
            switch (param) {
                .normal => |p| {
                    const binding = try self.declare(p.name, try self.resolveType(p.ty), false);
                    binding.is_param = true;
                },
                .resource => |p| {
                    const binding = try self.declare(p.name, try self.resolveType(p.ty), false);
                    binding.is_param = true;
                    binding.is_external = true;
                },
                .query => |q| {
                    const row = try self.checkQuery(q);
                    const binding = try self.declare(q.name, try self.store.make(.{ .query = .{ .element = row } }), false);
                    binding.is_external = true;
                },
            }
        }
        const body = callable.body.?.block;
        _ = try self.checkBlock(body);
    }

    fn checkQuery(self: *Checker, query: ast.QueryParam) !*types.Type {
        const source_ty = try self.resolveType(query.from);
        var fields_map = std.StringHashMapUnmanaged(*types.Type).empty;
        var field_names = std.ArrayList([]const u8).empty;
        var field_types = std.ArrayList(*types.Type).empty;

        for (query.projections) |projection| {
            const name = if (projection.path.segments.len > 0)
                projection.path.segments[projection.path.segments.len - 1].name
            else
                "_";
            const ty = (try self.fieldType(source_ty, name)) orelse
                try self.store.make(.unknown);
            try fields_map.put(self.allocator, name, ty);
            try field_names.append(self.allocator, name);
            try field_types.append(self.allocator, ty);
        }

        if (query.filter) |filter_expr| {
            try self.enterScope();
            defer self.leaveScope();
            for (field_names.items, field_types.items) |name, ty| {
                _ = try self.declare(name, ty, false);
            }
            _ = try self.checkExpr(filter_expr, try self.store.make(.bool));
        }

        const synthetic_name = try std.fmt.allocPrint(self.allocator, "__query_{d}", .{self.next_query_id});
        self.next_query_id += 1;
        const def = try self.allocator.create(TypeDef);
        def.* = .{
            .name = synthetic_name,
            .kind = .struct_,
            .item = undefined,
            .generics = &.{},
            .synthetic_fields = fields_map,
        };
        try self.type_defs.put(self.allocator, synthetic_name, def);
        return self.store.make(.{ .named = .{ .name = synthetic_name, .args = &.{} } });
    }

    // ------------------------------------------------------------------
    // Blocks and statements
    // ------------------------------------------------------------------

    fn checkBlock(self: *Checker, block: *ast.Block) Error!*types.Type {
        return self.checkBlockWithTail(block, null);
    }

    fn checkBlockWithTail(self: *Checker, block: *ast.Block, tail_expected: ?*types.Type) Error!*types.Type {
        try self.enterScope();
        defer self.leaveScope();
        var result = try self.store.make(.unit);
        const depth = self.scopes.items.len;
        for (block.entries, 0..) |entry, index| {
            switch (entry) {
                .item => |item| try self.checkItem(item, self.current_module),
                .stmt => |stmt| {
                    if (try self.checkStmt(stmt)) |ty| {
                        result = ty;
                    } else {
                        result = try self.store.make(.unit);
                    }
                },
            }
            if (index + 1 < block.entries.len) {
                self.releaseUnusedLocals(depth, block.entries[index + 1 ..]);
            }
        }
        if (tail_expected) |expected| {
            if (blockTailExpr(block)) |tail| try self.checkBorrowEscape(tail, expected);
        }
        return result;
    }

    fn checkStmt(self: *Checker, stmt: *ast.Stmt) Error!?*types.Type {
        const previous_span = self.current_span;
        if (self.spans.get(@intFromPtr(stmt))) |span| self.current_span = span;
        defer self.current_span = previous_span;
        const mark = self.loans.items.len;
        defer self.releaseTemporaries(mark);
        switch (stmt.*) {
            .binding => |binding| {
                try self.checkBinding(binding);
                return null;
            },
            .ret => |value| {
                try self.checkRet(value);
                return null;
            },
            .break_stmt, .cont => {
                if (self.loop_depth == 0) {
                    try self.report("`break`/`cont` outside a loop", .{});
                }
                return null;
            },
            .while_stmt => |loop| {
                _ = try self.checkExpr(loop.condition, try self.store.make(.bool));
                self.loop_depth += 1;
                _ = try self.checkBlock(loop.body);
                self.loop_depth -= 1;
                return null;
            },
            .for_stmt => |loop| {
                const iterable = try self.checkMoveExpr(loop.iterable, null);
                const element = try self.iterableElement(iterable);
                try self.enterScope();
                try self.checkPattern(loop.pattern, element);
                self.loop_depth += 1;
                _ = try self.checkBlock(loop.body);
                self.loop_depth -= 1;
                self.leaveScope();
                return null;
            },
            .loop_stmt => |loop| {
                self.loop_depth += 1;
                _ = try self.checkBlock(loop.body);
                self.loop_depth -= 1;
                return null;
            },
            .expr => |expr| return try self.checkExpr(expr, null),
            .assign => |assign| {
                try self.checkAssign(assign);
                return null;
            },
            .unsafe_block => |block| {
                self.unsafe_depth += 1;
                defer self.unsafe_depth -= 1;
                _ = try self.checkBlock(block);
                return null;
            },
            .uninitialized => |decl| {
                try self.checkUninitialized(decl);
                return null;
            },
        }
    }

    fn checkBorrowEscape(self: *Checker, expr: *ast.Expr, expected: *types.Type) !void {
        if (self.store.resolve(expected).* != .reference) return;
        switch (expr.*) {
            .unary => |unary| {
                if (unary.op != .borrow_shared and unary.op != .borrow_mut) return;
                if (try self.placeOf(unary.operand)) |place| {
                    if (!place.root.is_param and !place.root.is_global) {
                        try self.report("cannot return a borrow of local `{s}`", .{place.root.name});
                    }
                }
            },
            .path => |path| {
                if (path.segments.len != 1) return;
                const binding = self.lookup(path.segments[0].name) orelse return;
                for (binding.loans.items) |loan| {
                    if (loan.active and !loan.place.root.is_param and !loan.place.root.is_global) {
                        try self.report("cannot return reference `{s}` borrowing local `{s}`", .{
                            binding.name, loan.place.root.name,
                        });
                        return;
                    }
                }
            },
            else => {},
        }
    }

    fn checkRet(self: *Checker, value: ?*ast.Expr) !void {
        self.block_has_return = true;
        const expected = self.current_return orelse {
            try self.report("`ret` outside a function", .{});
            return;
        };
        if (value) |expr| {
            const actual = try self.checkMoveExpr(expr, null);
            try self.expectReturn(expected, actual, "return");
            try self.checkBorrowEscape(expr, expected);
        } else {
            try self.expectAssignable(expected, try self.store.make(.unit), "return");
        }
    }

    fn iterableElement(self: *Checker, ty: *types.Type) !*types.Type {
        const resolved = self.store.resolve(ty);
        return switch (resolved.*) {
            .range => |child| child,
            .array => |array| array.element,
            .query => |q| q.element,
            .string => resolved,
            .unknown => self.store.make(.unknown),
            else => blk: {
                const name = try self.store.typeName(resolved);
                try self.report("cannot iterate over `{s}`", .{name});
                break :blk self.store.make(.unknown);
            },
        };
    }

    fn checkAssign(self: *Checker, assign: ast.AssignStmt) !void {
        const place = (try self.placeOf(assign.target)) orelse {
            try self.report("assignment target is not a place", .{});
            return;
        };
        if (!place.root.initialized and (place.path.len != 0 or assign.op != .assign)) {
            try self.report("use of uninitialized value `{s}`", .{place.root.name});
            return;
        }
        if (place.root.moved and (place.path.len != 0 or assign.op != .assign)) {
            try self.report("use of moved value `{s}`", .{place.root.name});
            return;
        }
        if (!try self.placeMutable(place)) {
            try self.report("cannot assign to immutable place `{s}`", .{place.root.name});
        }
        if (place.path.len == 0 and assign.op == .assign) place.root.moved = false;
        try self.checkMutation(place);
        const target_ty = try self.placeType(place);
        try self.recordPlaceTypes(assign.target, target_ty);
        const mark = self.loans.items.len;
        _ = try self.checkMoveExpr(assign.value, target_ty);
        self.releaseLoansAt(place);
        try self.ownLoansFrom(mark, place.root);
        if (place.path.len == 0) {
            place.root.moved = false;
            place.root.initialized = true;
        }
    }

    fn recordPlaceTypes(self: *Checker, expr: *ast.Expr, whole_ty: *types.Type) Error!void {
        _ = try self.record(expr, whole_ty);
        switch (expr.*) {
            .path => |path| {
                if (path.segments.len == 1) {
                    if (self.lookup(path.segments[0].name)) |binding| {
                        _ = try self.record(expr, binding.ty);
                    }
                }
            },
            .field => |field| {
                if (try self.placeOf(field.target)) |base| {
                    const base_ty = try self.placeType(base);
                    try self.recordPlaceTypes(field.target, base_ty);
                }
            },
            .index => |index_expr| {
                if (try self.placeOf(index_expr.target)) |base| {
                    const base_ty = try self.placeType(base);
                    try self.recordPlaceTypes(index_expr.target, base_ty);
                }
                _ = try self.checkExpr(index_expr.index, null);
            },
            .unary => |unary| {
                if (unary.op == .deref) {
                    _ = try self.checkExpr(unary.operand, null);
                }
            },
            else => {},
        }
    }

    // ------------------------------------------------------------------
    // Patterns
    // ------------------------------------------------------------------

    fn checkPattern(self: *Checker, pattern: *ast.Pattern, expected: *types.Type) Error!void {
        return self.checkPatternImpl(pattern, expected, true);
    }

    fn checkPatternImpl(
        self: *Checker,
        pattern: *ast.Pattern,
        expected: *types.Type,
        bind: bool,
    ) Error!void {
        switch (pattern.*) {
            .wildcard => {},
            .literal => |literal| {
                const ty = try self.literalType(literal);
                try self.expectAssignable(expected, ty, "pattern");
            },
            .binding => |name| {
                // A bare identifier that names a unit variant of the expected
                // enum is a variant pattern, not a fresh binding.
                if (self.namedDef(expected)) |def| {
                    if (def.kind == .enum_) {
                        if (self.variantOf(expected, name)) |variant| {
                            if (variant.payload != .unit) {
                                try self.report("variant `{s}` requires a payload pattern", .{name});
                            }
                            const segments = try self.allocator.alloc(ast.PathSegment, 1);
                            segments[0] = .{ .name = name, .args = &.{} };
                            pattern.* = .{ .path = .{ .segments = segments } };
                            return;
                        }
                    }
                }
                if (bind) _ = try self.declare(name, expected, false);
            },
            .path => |path| {
                const variant_name = if (path.segments.len > 0)
                    path.segments[path.segments.len - 1].name
                else
                    "";
                if (self.variantOf(expected, variant_name)) |variant| {
                    if (variant.payload != .unit) {
                        try self.report("variant `{s}` requires a payload pattern", .{variant_name});
                    }
                } else {
                    try self.report("unknown unit variant `{s}`", .{variant_name});
                }
            },
            .tuple => |items| {
                const resolved = self.store.resolve(expected);
                if (resolved.* == .tuple) {
                    if (items.len != resolved.tuple.len) {
                        try self.report("tuple pattern has {d} elements, expected {d}", .{
                            items.len, resolved.tuple.len,
                        });
                    }
                    for (items, 0..) |item, i| {
                        const element = if (i < resolved.tuple.len)
                            resolved.tuple[i]
                        else
                            try self.store.make(.unknown);
                        try self.checkPatternImpl(item, element, bind);
                    }
                } else if (resolved.* != .unknown) {
                    try self.report("tuple pattern requires a tuple type", .{});
                }
            },
            .tuple_struct => |tuple| try self.checkTupleStructPatternImpl(tuple, expected, bind),
            .struct_pattern => |struct_pattern| try self.checkStructPatternImpl(struct_pattern, expected, bind),
            .or_pattern => |items| {
                if (items.len == 0) return;
                try self.checkPatternImpl(items[0], expected, bind);
                for (items[1..]) |item| try self.checkPatternImpl(item, expected, false);
            },
        }
    }

    fn checkTupleStructPatternImpl(
        self: *Checker,
        tuple: ast.TupleStructPattern,
        expected: *types.Type,
        bind: bool,
    ) Error!void {
        const name = if (tuple.path.segments.len > 0)
            tuple.path.segments[tuple.path.segments.len - 1].name
        else
            "";
        const variant = self.variantOf(expected, name) orelse {
            try self.report("unknown variant `{s}` in pattern", .{name});
            return;
        };
        switch (variant.payload) {
            .tuple => |payloads| {
                if (payloads.len != tuple.items.len) {
                    try self.report("variant `{s}` expects {d} fields, found {d}", .{
                        name, payloads.len, tuple.items.len,
                    });
                }
                const def = self.namedDef(expected);
                var env = if (def) |d| try self.envFor(d.generics, self.store.resolve(expected).named.args) else GenericEnv.empty;
                for (tuple.items, 0..) |item, i| {
                    const ty = if (i < payloads.len)
                        try self.resolveTypeIn(payloads[i].ty, &env)
                    else
                        try self.store.make(.unknown);
                    try self.checkPatternImpl(item, ty, bind);
                }
            },
            else => try self.report("variant `{s}` is not a tuple variant", .{name}),
        }
    }

    fn checkStructPatternImpl(
        self: *Checker,
        pattern: ast.StructPattern,
        expected: *types.Type,
        bind: bool,
    ) Error!void {
        const variant_name = if (pattern.path.segments.len > 0)
            pattern.path.segments[pattern.path.segments.len - 1].name
        else
            "";
        if (self.variantOf(expected, variant_name)) |variant| {
            switch (variant.payload) {
                .struct_fields => |fields| {
                    const def = self.namedDef(expected);
                    var env = if (def) |d| try self.envFor(d.generics, self.store.resolve(expected).named.args) else GenericEnv.empty;
                    for (pattern.fields) |field_pattern| {
                        var found = false;
                        for (fields) |field| {
                            if (!std.mem.eql(u8, field.name, field_pattern.name)) continue;
                            found = true;
                            const ty = try self.resolveTypeIn(field.ty, &env);
                            if (field_pattern.pattern) |sub| {
                                try self.checkPatternImpl(sub, ty, bind);
                            } else if (bind) {
                                _ = try self.declare(field_pattern.name, ty, false);
                            }
                            break;
                        }
                        if (!found) try self.report("unknown field `{s}` in variant pattern", .{field_pattern.name});
                    }
                    return;
                },
                else => {
                    try self.report("variant `{s}` is not a struct variant", .{variant_name});
                    return;
                },
            }
        }
        for (pattern.fields) |field| {
            const ty = (try self.fieldType(expected, field.name)) orelse {
                try self.report("unknown field `{s}` in pattern", .{field.name});
                continue;
            };
            if (field.pattern) |sub| {
                try self.checkPatternImpl(sub, ty, bind);
            } else if (bind) {
                _ = try self.declare(field.name, ty, false);
            }
        }
    }

    // ------------------------------------------------------------------
    // Expressions
    // ------------------------------------------------------------------

    fn checkExpr(self: *Checker, expr: *ast.Expr, expected: ?*types.Type) Error!*types.Type {
        const ty = switch (expr.*) {
            .int => try self.store.integerVar(),
            .float => try self.store.floatVar(),
            .string => try self.store.make(.string),
            .boolean => try self.store.make(.bool),
            .nil => try self.store.make(.{ .optional = try self.store.freshVar(.any) }),
            .error_literal => |path| try self.errorValueType(path),
            .path => |path| try self.checkPath(path),
            .function => |function| try self.checkFunctionExpr(function),
            .struct_literal => |literal| try self.checkStructLiteral(literal),
            .map_literal => |literal| try self.checkMapLiteral(literal),
            .list => |items| try self.checkList(items, expected),
            .block => |block| blk: {
                const ty = try self.checkBlock(block);
                try self.markBlockTailMove(block);
                break :blk ty;
            },
            .if_expr => |if_expr| try self.checkIf(if_expr, expected),
            .match_expr => |match_expr| try self.checkMatch(match_expr, expected),
            .unary => |unary| try self.checkUnary(unary, expected),
            .prefix => |prefix_expr| try self.checkPrefix(prefix_expr),
            .binary => |binary| try self.checkBinary(binary),
            .range => |range| try self.checkRange(range),
            .cast => |cast| blk: {
                _ = try self.checkExpr(cast.expr, null);
                break :blk try self.resolveType(cast.ty);
            },
            .call => |call| try self.checkCall(call),
            .field => |field| try self.checkField(field),
            .index => |index| try self.checkIndex(index),
            .try_expr => |inner| blk: {
                const inner_ty = self.store.resolve(try self.checkExpr(inner, null));
                break :blk switch (inner_ty.*) {
                    .error_union => |e| e.value_type,
                    .optional => |child| child,
                    .unknown => inner_ty,
                    else => blk2: {
                        const name = try self.store.typeName(inner_ty);
                        try self.report("`?` requires an error union or optional, found `{s}`", .{name});
                        break :blk2 try self.store.make(.unknown);
                    },
                };
            },
        };

        const recorded = try self.record(expr, ty);
        if (expected) |wanted| try self.expectAssignable(wanted, recorded, "expression");
        return recorded;
    }

    fn record(self: *Checker, expr: *ast.Expr, ty: *types.Type) !*types.Type {
        try self.expr_types.put(self.allocator, @intFromPtr(expr), ty);
        return ty;
    }

    fn checkPath(self: *Checker, path: ast.Path) !*types.Type {
        if (path.segments.len == 1) {
            const segment = path.segments[0];
            if (self.lookup(segment.name)) |binding| {
                if (try self.placeOfPath(segment.name)) |place| try self.checkRead(place);
                return binding.ty;
            }
            if (self.lookupTypeDef(segment.name)) |def| {
                if (def.kind == .trigger_) {
                    return self.triggerCallableType(def, segment);
                }
            }
            if (self.lookupFunction(segment.name)) |callable| {
                const explicit = if (segment.args.len > 0) try self.resolveTypeArgs(segment.args) else null;
                return self.callableType(callable, explicit);
            }
        }

        if (path.segments.len >= 2) {
            const last = path.segments[path.segments.len - 1];
            const type_segment = path.segments[path.segments.len - 2];
            const type_path = ast.Path{ .segments = path.segments[0 .. path.segments.len - 1] };
            const type_full = self.normalizePath(try self.joinPath("", type_path));
            if (self.lookupQualifiedType(type_full)) |def| {
                if (def.methods.get(last.name)) |method| {
                    const explicit = if (type_segment.args.len > 0)
                        try self.resolveTypeArgs(type_segment.args)
                    else
                        null;
                    return self.callableType(method, explicit);
                }
                if (def.kind == .enum_) {
                    for (def.variants) |variant| {
                        if (!std.mem.eql(u8, variant.name, last.name)) continue;
                        const enum_args = try self.resolveTypeArgs(type_segment.args);
                        if (enum_args.len != def.generics.len) {
                            try self.report("type `{s}` expects {d} type argument(s), found {d}", .{
                                def.qualified_name, def.generics.len, enum_args.len,
                            });
                        }
                        const enum_ty = try self.store.make(.{ .named = .{
                            .name = def.qualified_name,
                            .args = enum_args,
                        } });
                        return switch (variant.payload) {
                            .unit => enum_ty,
                            .tuple => |payloads| blk: {
                                var env = try self.envFor(def.generics, enum_args);
                                const params = try self.allocator.alloc(*types.Type, payloads.len);
                                for (payloads, 0..) |payload, i| {
                                    params[i] = try self.resolveTypeIn(payload.ty, &env);
                                }
                                break :blk self.store.make(.{ .function = .{
                                    .params = params,
                                    .result = enum_ty,
                                } });
                            },
                            .struct_fields => try self.store.make(.unknown),
                        };
                    }
                }
            }

            const full = self.normalizePath(try self.joinPath("", path));
            if (self.lookupQualifiedFunction(full)) |callable| {
                const explicit = if (last.args.len > 0) try self.resolveTypeArgs(last.args) else null;
                return self.callableType(callable, explicit);
            }
        }

        const name = if (path.segments.len > 0) path.segments[path.segments.len - 1].name else "?";
        const full = self.normalizePath(try self.joinPath("", path));
        try self.report("unknown name `{s}`", .{full});
        _ = name;
        return self.store.make(.unknown);
    }

    fn triggerCallableType(self: *Checker, def: *TypeDef, segment: ast.PathSegment) Error!*types.Type {
        const explicit = if (segment.args.len > 0) try self.resolveTypeArgs(segment.args) else null;
        if (explicit) |args| {
            if (args.len != def.generics.len) {
                try self.report("trigger `{s}` expects {d} type argument(s), found {d}", .{
                    def.qualified_name, def.generics.len, args.len,
                });
            }
        }
        const args = try self.allocator.alloc(*types.Type, def.generics.len);
        var env = GenericEnv.empty;
        for (def.generics, 0..) |generic, i| {
            const arg = if (explicit != null and i < explicit.?.len)
                explicit.?[i]
            else
                try self.store.freshVar(.any);
            args[i] = arg;
            try env.put(self.allocator, generic.name, arg);
        }
        const params = try self.allocator.alloc(*types.Type, def.fields.len);
        for (def.fields, 0..) |field, i| params[i] = try self.resolveTypeIn(field.ty, &env);
        const result = try self.asyncTaskType(try self.store.make(.unit));
        return self.store.make(.{ .function = .{ .params = params, .result = result } });
    }

    fn placeOfPath(self: *Checker, name: []const u8) !?*Place {
        const binding = self.lookup(name) orelse return null;
        return self.makePlace(binding, &.{});
    }

    fn checkFunctionExpr(self: *Checker, function: ast.FunctionExpr) Error!*types.Type {
        const loan_mark = self.loans.items.len;
        defer self.releaseTemporaries(loan_mark);
        try self.enterScope();
        defer self.leaveScope();
        const old_return = self.current_return;
        const old_loop = self.loop_depth;
        const old_has_return = self.block_has_return;
        const old_async = self.current_async;
        const old_generics = self.current_generics;
        const success = try self.resolveType(function.result);
        self.current_return = success;
        self.current_async = function.is_async;
        self.current_generics = null;
        self.loop_depth = 0;
        self.block_has_return = false;
        defer {
            self.current_return = old_return;
            self.current_async = old_async;
            self.current_generics = old_generics;
            self.loop_depth = old_loop;
            self.block_has_return = old_has_return;
        }
        var params = try self.allocator.alloc(*types.Type, function.params.len);
        for (function.params, 0..) |param, i| {
            params[i] = try self.resolveType(param.ty);
            const binding = try self.declare(param.name, params[i], false);
            binding.is_param = true;
        }
        if (function.is_async) {
            for (params) |param| {
                if (self.containsReference(param)) {
                    try self.report("async function expression parameter cannot contain references", .{});
                    break;
                }
            }
            if (self.containsReference(self.current_return.?)) {
                try self.report("async function expression result cannot contain references", .{});
            }
        }
        try self.checkFunctionBody(function.body, self.current_return.?, "function expression");
        const result_ty = if (function.is_async) try self.asyncTaskType(self.current_return.?) else self.current_return.?;
        return self.store.make(.{ .function = .{
            .params = params,
            .result = result_ty,
        } });
    }

    fn checkStructLiteral(self: *Checker, literal: ast.StructLiteral) !*types.Type {
        const last_index = literal.path.segments.len - 1;
        const name = literal.path.segments[last_index].name;
        const full = self.normalizePath(try self.joinPath("", literal.path));
        const def = self.lookupQualifiedType(full) orelse {
            if (literal.path.segments.len >= 2) {
                const owner_path = ast.Path{ .segments = literal.path.segments[0..last_index] };
                const owner_full = self.normalizePath(try self.joinPath("", owner_path));
                if (self.lookupQualifiedType(owner_full)) |owner| {
                    if (owner.kind == .enum_) {
                        const type_segment = literal.path.segments[last_index - 1];
                        const enum_args = try self.resolveTypeArgs(type_segment.args);
                        const owner_ty = try self.store.make(.{ .named = .{
                            .name = owner.qualified_name,
                            .args = enum_args,
                        } });
                        if (self.variantOf(owner_ty, name)) |variant| {
                            switch (variant.payload) {
                                .struct_fields => |fields| return self.checkEnumStructLiteral(owner, name, fields, literal, enum_args),
                                else => try self.report("variant `{s}` is not a struct variant", .{name}),
                            }
                        }
                    }
                }
            }
            try self.report("unknown struct `{s}`", .{full});
            return self.store.make(.unknown);
        };
        const args = try self.resolveTypeArgs(literal.path.segments[last_index].args);
        if (args.len != def.generics.len) {
            try self.report("type `{s}` expects {d} type argument(s), found {d}", .{
                def.qualified_name, def.generics.len, args.len,
            });
        }
        try self.checkTypeBounds(def, args);
        var seen = std.StringHashMapUnmanaged(void).empty;
        defer seen.deinit(self.allocator);
        for (literal.fields) |field| {
            if (seen.contains(field.name)) {
                try self.report("duplicate field `{s}` in struct literal", .{field.name});
                continue;
            }
            try seen.put(self.allocator, field.name, {});
            const field_ty = (try self.fieldType(try self.store.make(.{ .named = .{
                .name = def.qualified_name,
                .args = args,
            } }), field.name)) orelse {
                try self.report("unknown field `{s}` in `{s}`", .{ field.name, full });
                continue;
            };
            _ = try self.checkMoveExpr(field.value, field_ty);
        }
        for (def.fields) |field| {
            if (!seen.contains(field.name)) {
                try self.report("missing field `{s}` in `{s}` literal", .{ field.name, full });
            }
        }
        return self.store.make(.{ .named = .{ .name = def.qualified_name, .args = args } });
    }

    fn checkEnumStructLiteral(
        self: *Checker,
        def: *TypeDef,
        variant_name: []const u8,
        fields: []ast.Field,
        literal: ast.StructLiteral,
        args: []*types.Type,
    ) Error!*types.Type {
        if (args.len != def.generics.len) {
            try self.report("type `{s}` expects {d} type argument(s), found {d}", .{
                def.qualified_name, def.generics.len, args.len,
            });
        }
        var env = try self.envFor(def.generics, args);
        var seen = std.StringHashMapUnmanaged(void).empty;
        defer seen.deinit(self.allocator);
        for (literal.fields) |field_init| {
            if (seen.contains(field_init.name)) {
                try self.report("duplicate field `{s}` in variant literal", .{field_init.name});
                continue;
            }
            try seen.put(self.allocator, field_init.name, {});
            var found = false;
            for (fields) |field| {
                if (!std.mem.eql(u8, field.name, field_init.name)) continue;
                found = true;
                _ = try self.checkMoveExpr(field_init.value, try self.resolveTypeIn(field.ty, &env));
                break;
            }
            if (!found) try self.report("unknown field `{s}` in variant `{s}`", .{ field_init.name, variant_name });
        }
        for (fields) |field| {
            if (!seen.contains(field.name)) {
                try self.report("missing field `{s}` in variant `{s}`", .{ field.name, variant_name });
            }
        }
        return self.store.make(.{ .named = .{ .name = def.qualified_name, .args = args } });
    }

    fn checkMapLiteral(self: *Checker, literal: ast.MapLiteral) !*types.Type {
        const key_ty = try self.resolveType(literal.key_ty);
        const value_ty = try self.resolveType(literal.value_ty);
        for (literal.entries) |entry| {
            _ = try self.checkExpr(entry.key, key_ty);
            _ = try self.checkExpr(entry.value, value_ty);
        }
        return self.store.make(.{ .map = .{ .key = key_ty, .value = value_ty } });
    }

    fn checkList(self: *Checker, items: []*ast.Expr, expected: ?*types.Type) !*types.Type {
        var expected_array: ?types.Array = null;
        if (expected) |wanted| {
            const resolved = self.store.resolve(wanted);
            if (resolved.* == .array) expected_array = resolved.array;
        }

        var matrix = items.len > 0;
        for (items) |item| if (item.* != .list) {
            matrix = false;
            break;
        };
        if (matrix) {
            var element = try self.store.freshVar(.any);
            var columns: ?usize = null;
            var row_count: ?usize = items.len;
            if (expected_array) |array| {
                element = array.element;
                columns = array.columns;
                if (array.length != null and array.length.? != items.len) {
                    try self.report("matrix row count mismatch: expected {d}, found {d}", .{
                        array.length.?, items.len,
                    });
                }
            }
            for (items) |item| {
                const row_ty = try self.checkList(item.list, null);
                const resolved = self.store.resolve(row_ty);
                if (resolved.* != .array) {
                    try self.report("matrix rows must be vectors", .{});
                    continue;
                }
                if (columns == null) {
                    columns = resolved.array.length;
                } else if (resolved.array.length != null and columns.? != resolved.array.length.?) {
                    try self.report("matrix has inconsistent row lengths", .{});
                }
                try self.unifyOrReport(element, resolved.array.element, "matrix element");
            }
            row_count = items.len;
            return self.store.make(.{ .array = .{
                .element = element,
                .length = row_count,
                .columns = columns,
            } });
        }

        var element = try self.store.freshVar(.any);
        if (expected_array) |array| element = array.element;
        for (items) |item| {
            _ = try self.checkMoveExpr(item, element);
        }
        return self.store.make(.{ .array = .{
            .element = element,
            .length = items.len,
            .columns = null,
        } });
    }

    fn joinType(self: *Checker, slot: *?*types.Type, ty: *types.Type, context: []const u8) !void {
        if (slot.*) |previous| {
            try self.unifyOrReport(previous, ty, context);
        } else {
            slot.* = ty;
        }
    }

    fn checkIf(self: *Checker, if_expr: ast.IfExpr, expected: ?*types.Type) !*types.Type {
        var branch_ty: ?*types.Type = null;
        for (if_expr.branches) |branch| {
            _ = try self.checkExpr(branch.condition, try self.store.make(.bool));
            const branch_body_ty = try self.checkBlock(branch.body);
            try self.markBlockTailMove(branch.body);
            try self.joinType(&branch_ty, branch_body_ty, "if branches");
        }
        if (if_expr.else_body) |else_body| {
            const else_ty = try self.checkBlock(else_body);
            try self.markBlockTailMove(else_body);
            try self.joinType(&branch_ty, else_ty, "if branches");
        } else {
            branch_ty = try self.store.make(.unit);
        }
        if (expected) |wanted| if (branch_ty) |actual| try self.expectAssignable(wanted, actual, "if expression");
        return branch_ty orelse self.store.make(.unit);
    }

    fn checkMatch(self: *Checker, match_expr: ast.MatchExpr, expected: ?*types.Type) !*types.Type {
        const scrutinee = try self.checkMoveExpr(match_expr.scrutinee, null);
        var body_ty: ?*types.Type = null;
        for (match_expr.arms) |arm| {
            try self.enterScope();
            defer self.leaveScope();
            try self.checkPattern(arm.pattern, scrutinee);
            if (arm.guard) |guard| {
                _ = try self.checkExpr(guard, try self.store.make(.bool));
            }
            const arm_ty = try self.checkBlock(arm.body);
            try self.markBlockTailMove(arm.body);
            try self.joinType(&body_ty, arm_ty, "match arms");
        }
        const result = body_ty orelse try self.store.make(.unit);
        try self.checkExhaustive(scrutinee, match_expr.arms);
        if (expected) |wanted| try self.expectAssignable(wanted, result, "match expression");
        return result;
    }

    fn checkExhaustive(self: *Checker, scrutinee: *types.Type, arms: []ast.MatchArm) !void {
        const matched = self.store.resolve(scrutinee);
        var catch_all_seen = false;
        var variant_seen = std.StringHashMapUnmanaged(void).empty;
        var saw_true = false;
        var saw_false = false;
        var saw_nil = false;
        var saw_non_nil = false;

        for (arms) |arm| {
            const guarded = arm.guard != null;
            if (!guarded) {
                if (catch_all_seen) {
                    try self.report("unreachable match arm after catch-all pattern", .{});
                }
                if (patternIsCatchAll(arm.pattern)) {
                    catch_all_seen = true;
                } else if (matched.* == .bool) {
                    collectBoolLiterals(arm.pattern, &saw_true, &saw_false);
                } else if (self.namedDef(matched)) |def| {
                    if (def.kind == .enum_) {
                        collectVariantNames(arm.pattern, &variant_seen, self.allocator) catch return error.OutOfMemory;
                    } else if (self.structPatternCoversAll(arm.pattern, def)) {
                        catch_all_seen = true;
                    }
                } else if (matched.* == .optional) {
                    if (patternHasNil(arm.pattern)) saw_nil = true;
                    if (!patternOnlyNil(arm.pattern)) saw_non_nil = true;
                }
            }
        }

        if (catch_all_seen) {
            // Still detect duplicate literal/variant arms before the catch-all.
            try self.reportDuplicateCoverage(matched, arms);
            return;
        }

        switch (matched.*) {
            .bool => {
                if (!saw_true or !saw_false) {
                    try self.report("non-exhaustive match: `bool` needs both `true` and `false` arms or `_`", .{});
                }
            },
            .optional => {
                if (!saw_nil or !saw_non_nil) {
                    try self.report("non-exhaustive match: optional needs a `nil` arm and a non-`nil` arm or `_`", .{});
                }
            },
            .named => |named| {
                const def = self.type_defs.get(named.name) orelse return;
                if (def.kind == .enum_) {
                    for (def.variants) |variant| {
                        if (!variant_seen.contains(variant.name)) {
                            try self.report("non-exhaustive match: missing variant `{s}`", .{variant.name});
                            return;
                        }
                    }
                } else {
                    try self.report("non-exhaustive match: add a `_` arm", .{});
                }
            },
            .unknown, .never => {},
            else => try self.report("non-exhaustive match: add a `_` arm", .{}),
        }
        try self.reportDuplicateCoverage(matched, arms);
    }

    fn structPatternCoversAll(self: *Checker, pattern: *ast.Pattern, def: *TypeDef) bool {
        _ = self;
        if (pattern.* != .struct_pattern) return false;
        const fields = pattern.struct_pattern.fields;
        if (fields.len != def.fields.len) return false;
        for (def.fields) |field| {
            var found = false;
            for (fields) |candidate| {
                if (std.mem.eql(u8, candidate.name, field.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    fn collectBoolDuplicateCheck(
        self: *Checker,
        pattern: *ast.Pattern,
        seen: *std.StringHashMapUnmanaged(void),
    ) Error!void {
        switch (pattern.*) {
            .literal => |literal| switch (literal) {
                .boolean => |value| {
                    const key = if (value) "true" else "false";
                    if (seen.contains(key)) {
                        try self.report("unreachable match arm: duplicate `{s}`", .{key});
                    } else {
                        try seen.put(self.allocator, key, {});
                    }
                },
                else => {},
            },
            .or_pattern => |items| for (items) |item| try self.collectBoolDuplicateCheck(item, seen),
            else => {},
        }
    }

    fn reportDuplicateCoverage(self: *Checker, matched: *types.Type, arms: []ast.MatchArm) Error!void {
        var seen_bool = std.StringHashMapUnmanaged(void).empty;
        var seen_variants = std.StringHashMapUnmanaged(void).empty;
        for (arms) |arm| {
            if (arm.guard != null) continue;
            if (matched.* == .bool) {
                try self.collectBoolDuplicateCheck(arm.pattern, &seen_bool);
            } else if (self.namedDef(matched)) |def| {
                if (def.kind != .enum_) continue;
                if (patternIsCatchAll(arm.pattern)) continue;
                var local = std.StringHashMapUnmanaged(void).empty;
                collectVariantNames(arm.pattern, &local, self.allocator) catch return error.OutOfMemory;
                var it = local.iterator();
                while (it.next()) |entry| {
                    if (seen_variants.contains(entry.key_ptr.*)) {
                        try self.report("unreachable match arm: duplicate variant `{s}`", .{entry.key_ptr.*});
                    } else {
                        try seen_variants.put(self.allocator, entry.key_ptr.*, {});
                    }
                }
            }
        }
    }

    fn checkAwaitBarrier(self: *Checker) Error!void {
        for (self.loans.items) |loan| {
            if (!loan.active) continue;
            const root = loan.place.root;
            if (root.is_external or root.is_global) {
                try self.report("external borrow of `{s}` cannot cross `await`", .{root.name});
            }
        }
    }

    fn checkPrefix(self: *Checker, prefix_expr: ast.Prefix) !*types.Type {
        const operand_ty = self.store.resolve(try self.checkMoveExpr(prefix_expr.operand, null));
        switch (prefix_expr.op) {
            .await_, .spawn, .detach => {
                if (!self.current_async) {
                    try self.report("`{s}` is only allowed in async context", .{@tagName(prefix_expr.op)});
                }
                const inner = self.taskInner(operand_ty) orelse {
                    const name = try self.store.typeName(operand_ty);
                    try self.report("`{s}` requires a Task, found `{s}`", .{ @tagName(prefix_expr.op), name });
                    return self.store.make(.unknown);
                };
                if (prefix_expr.op == .await_) try self.checkAwaitBarrier();
                return switch (prefix_expr.op) {
                    .await_ => inner,
                    .spawn => operand_ty,
                    .detach => self.store.make(.unit),
                    else => unreachable,
                };
            },
            .cancel => {
                if (!self.current_async) {
                    try self.report("`cancel` is only allowed in async context", .{});
                }
                if (operand_ty.* != .reference or !operand_ty.reference.mutable or
                    self.taskInner(operand_ty.reference.child) == null)
                {
                    try self.report("`cancel` requires `&mut Task<T>`", .{});
                }
                return self.store.make(.unit);
            },
        }
    }

    fn checkUnary(self: *Checker, unary: ast.Unary, expected: ?*types.Type) !*types.Type {
        _ = expected;
        switch (unary.op) {
            .not => {
                _ = try self.checkExpr(unary.operand, try self.store.make(.bool));
                return self.store.make(.bool);
            },
            .negative => {
                const ty = try self.checkExpr(unary.operand, null);
                if (self.implementsTrait(ty, "Neg")) {
                    if (self.customOperatorMethod(ty, "neg", 1)) |result| return result;
                    if (self.store.resolve(ty).* == .generic) return ty;
                }
                try self.requireNumeric(ty, "unary `-`");
                return ty;
            },
            .borrow_shared, .borrow_mut => {
                const mutable = unary.op == .borrow_mut;
                if (try self.placeOf(unary.operand)) |place| {
                    try self.borrowPlace(place, mutable);
                    return self.store.make(.{ .reference = .{
                        .mutable = mutable,
                        .child = try self.placeType(place),
                    } });
                }
                if (mutable) {
                    try self.report("mutable borrow requires a place expression", .{});
                    return self.store.make(.unknown);
                }
                const ty = try self.checkExpr(unary.operand, null);
                return self.store.make(.{ .reference = .{ .mutable = false, .child = ty } });
            },
            .deref => {
                const ty = self.store.resolve(try self.checkExpr(unary.operand, null));
                return switch (ty.*) {
                    .reference => |r| r.child,
                    .box => |child| child,
                    .raw_pointer => |child| blk: {
                        if (self.unsafe_depth == 0) {
                            try self.report("raw pointer dereference requires an `unsafe` block", .{});
                        }
                        break :blk child;
                    },
                    .unknown => ty,
                    .generic => blk: {
                        if (self.implementsTrait(ty, "Deref")) break :blk self.store.make(.unknown);
                        const name = try self.store.typeName(ty);
                        try self.report("cannot dereference `{s}`", .{name});
                        break :blk self.store.make(.unknown);
                    },
                    .named => blk: {
                        if (self.implementsTrait(ty, "Deref")) {
                            if (self.customOperatorMethod(ty, "deref", 1)) |result| break :blk result;
                        }
                        const name = try self.store.typeName(ty);
                        try self.report("cannot dereference `{s}`", .{name});
                        break :blk self.store.make(.unknown);
                    },
                    else => blk: {
                        const name = try self.store.typeName(ty);
                        try self.report("cannot dereference `{s}`", .{name});
                        break :blk self.store.make(.unknown);
                    },
                };
            },
        }
    }

    fn checkBinary(self: *Checker, binary: ast.Binary) !*types.Type {
        const left = try self.checkExpr(binary.lhs, null);
        const right = try self.checkExpr(binary.rhs, null);
        switch (binary.op) {
            .or_, .xor_, .and_ => {
                try self.expectAssignable(try self.store.make(.bool), left, "boolean operator");
                try self.expectAssignable(try self.store.make(.bool), right, "boolean operator");
                return self.store.make(.bool);
            },
            .eq, .ne => {
                if (self.implementsTrait(left, "PartialEq")) {
                    return self.store.make(.bool);
                }
                try self.unifyOrReport(left, right, "comparison");
                return self.store.make(.bool);
            },
            .lt, .le, .gt, .ge => {
                if (self.implementsTrait(left, "PartialOrd")) {
                    return self.store.make(.bool);
                }
                const l = self.store.resolve(left);
                if (l.* != .string and l.* != .int and l.* != .float and l.* != .variable) {
                    const name = try self.store.typeName(l);
                    try self.report("comparison requires a numeric, string, or PartialOrd type, found `{s}`", .{name});
                    return self.store.make(.bool);
                }
                try self.unifyOrReport(left, right, "comparison");
                return self.store.make(.bool);
            },
            .add => {
                const l = self.store.resolve(left);
                const r = self.store.resolve(right);
                if (l.* == .string and r.* == .string) return self.store.make(.string);
                if (l.* == .raw_pointer and self.isNumericLike(r)) {
                    if (self.unsafe_depth == 0) try self.report("raw pointer arithmetic requires an `unsafe` block", .{});
                    return left;
                }
                if (r.* == .raw_pointer and self.isNumericLike(l)) {
                    if (self.unsafe_depth == 0) try self.report("raw pointer arithmetic requires an `unsafe` block", .{});
                    return right;
                }
                if (try self.arrayBinary(.add, left, right)) |result| return result;
                if (try self.customBinary(.add, left, right)) |result| return result;
                try self.unifyOrReport(left, right, "addition");
                try self.requireNumeric(left, "addition");
                return left;
            },
            .sub, .mul, .div => {
                const l = self.store.resolve(left);
                if (binary.op == .sub and l.* == .raw_pointer and self.isNumericLike(self.store.resolve(right))) {
                    if (self.unsafe_depth == 0) try self.report("raw pointer arithmetic requires an `unsafe` block", .{});
                    return left;
                }
                if (try self.arrayBinary(binary.op, left, right)) |result| return result;
                if (try self.customBinary(binary.op, left, right)) |result| return result;
                try self.unifyOrReport(left, right, "arithmetic");
                try self.requireNumeric(left, "arithmetic");
                return left;
            },
            .mod => {
                try self.unifyOrReport(left, right, "arithmetic");
                try self.requireNumeric(left, "arithmetic");
                return left;
            },
        }
    }

    fn makeArrayType(self: *Checker, element: *types.Type, length: ?usize, columns: ?usize) !*types.Type {
        return self.store.make(.{ .array = .{
            .element = element,
            .length = length,
            .columns = columns,
        } });
    }

    fn arrayBinary(self: *Checker, op: ast.BinaryOp, left: *types.Type, right: *types.Type) !?*types.Type {
        const l = self.store.resolve(left);
        const r = self.store.resolve(right);
        if (l.* == .array and r.* == .array) {
            try self.requireNumeric(l.array.element, "vector/matrix arithmetic");
            try self.requireNumeric(r.array.element, "vector/matrix arithmetic");
            try self.unifyOrReport(l.array.element, r.array.element, "vector/matrix element");
            switch (op) {
                .add, .sub, .div => {
                    try self.checkSameShape(l.array, r.array, "vector/matrix arithmetic");
                    return self.makeArrayType(l.array.element, l.array.length, l.array.columns);
                },
                .mul => return self.multiplyArrays(l.array, r.array),
                else => return null,
            }
        }
        if (l.* == .array and self.isNumericLike(r)) {
            try self.requireNumeric(l.array.element, "vector/matrix scalar arithmetic");
            return self.makeArrayType(l.array.element, l.array.length, l.array.columns);
        }
        if (r.* == .array and self.isNumericLike(l)) {
            try self.requireNumeric(r.array.element, "vector/matrix scalar arithmetic");
            return self.makeArrayType(r.array.element, r.array.length, r.array.columns);
        }
        return null;
    }

    fn multiplyArrays(self: *Checker, a: types.Array, b: types.Array) !*types.Type {
        const a_matrix = a.columns != null;
        const b_matrix = b.columns != null;
        if (a_matrix and b_matrix) {
            try self.requireShapeMatch(a.columns.?, b.length, "matrix multiplication");
            return self.makeArrayType(a.element, a.length, b.columns);
        }
        if (a_matrix and !b_matrix) {
            try self.requireShapeMatch(a.columns.?, b.length, "matrix-vector multiplication");
            return self.makeArrayType(a.element, a.length, null);
        }
        if (!a_matrix and b_matrix) {
            try self.requireShapeMatch(a.length, b.length, "vector-matrix multiplication");
            return self.makeArrayType(a.element, b.columns, null);
        }
        if (a.length != null and b.length != null) {
            try self.requireShapeMatch(a.length.?, b.length, "dot product");
        }
        return a.element;
    }

    fn checkSameShape(self: *Checker, a: types.Array, b: types.Array, context: []const u8) !void {
        if (a.length != null and b.length != null and a.length.? != b.length.?) {
            try self.report("{s} shape mismatch: {d} vs {d}", .{ context, a.length.?, b.length.? });
        }
        if (a.columns != null and b.columns != null and a.columns.? != b.columns.?) {
            try self.report("{s} column mismatch: {d} vs {d}", .{ context, a.columns.?, b.columns.? });
        }
    }

    fn requireShapeMatch(self: *Checker, left: ?usize, right: ?usize, context: []const u8) !void {
        if (left != null and right != null and left.? != right.?) {
            try self.report("{s} dimension mismatch: {d} vs {d}", .{ context, left.?, right.? });
        }
    }

    fn isNumericLike(self: *Checker, ty: *types.Type) bool {
        const resolved = self.store.resolve(ty);
        return switch (resolved.*) {
            .int, .float, .variable, .unknown => true,
            else => false,
        };
    }

    fn implementsTrait(self: *Checker, ty: *types.Type, name: []const u8) bool {
        const trait_def = self.traits.get(name) orelse return false;
        const resolved = self.store.resolve(ty);
        if (resolved.* == .generic) {
            if (self.current_generics) |generics| {
                for (generics) |param| {
                    if (!std.mem.eql(u8, param.name, resolved.generic.name)) continue;
                    for (param.bounds) |bound| {
                        if (bound.* != .path or bound.path.segments.len == 0) continue;
                        if (std.mem.eql(u8, bound.path.segments[bound.path.segments.len - 1].name, name)) return true;
                    }
                }
            }
            return false;
        }
        return self.implements(ty, trait_def, 0);
    }

    fn customBinary(self: *Checker, op: ast.BinaryOp, left: *types.Type, right: *types.Type) !?*types.Type {
        const trait_name = switch (op) {
            .add => "Add",
            .sub => "Sub",
            .mul => "Mul",
            .div => "Div",
            else => return null,
        };
        const def = self.namedDef(left) orelse {
            if (self.implementsTrait(left, trait_name)) return left;
            return null;
        };
        if (!self.implementsTrait(left, trait_name)) return null;
        const method_name = switch (op) {
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            .div => "div",
            else => unreachable,
        };
        const method = def.methods.get(method_name) orelse return left;
        const callable = try self.callableType(method, null);
        const resolved = self.store.resolve(callable);
        if (resolved.* != .function or resolved.function.params.len != 2) return left;
        try self.expectAssignable(resolved.function.params[0], left, "operator left operand");
        try self.expectAssignable(resolved.function.params[1], right, "operator right operand");
        return resolved.function.result;
    }

    fn customOperatorMethod(self: *Checker, ty: *types.Type, method_name: []const u8, param_count: usize) ?*types.Type {
        const def = self.namedDef(ty) orelse return null;
        const method = def.methods.get(method_name) orelse return null;
        const callable = self.callableType(method, null) catch return null;
        const resolved = self.store.resolve(callable);
        if (resolved.* != .function or resolved.function.params.len != param_count) return null;
        return resolved.function.result;
    }

    fn requireNumeric(self: *Checker, ty: *types.Type, context: []const u8) !void {
        const resolved = self.store.resolve(ty);
        switch (resolved.*) {
            .int, .float, .variable, .unknown => {},
            else => {
                const name = try self.store.typeName(resolved);
                try self.report("{s} requires a numeric type, found `{s}`", .{ context, name });
            },
        }
    }

    fn checkRange(self: *Checker, range: ast.Range) !*types.Type {
        var element: *types.Type = try self.store.freshVar(.any);
        if (range.start) |start| {
            element = try self.checkExpr(start, null);
        }
        if (range.end) |end| {
            const end_ty = try self.checkExpr(end, element);
            try self.unifyOrReport(element, end_ty, "range");
        }
        try self.requireNumeric(element, "range");
        return self.store.make(.{ .range = element });
    }

    fn checkCall(self: *Checker, call: ast.Call) !*types.Type {
        if (call.callee.* == .path and call.callee.path.segments.len == 1) {
            const name = call.callee.path.segments[0].name;
            if (std.mem.eql(u8, name, "print") and self.lookup(name) == null and self.functions.get(name) == null) {
                for (call.args) |arg| _ = try self.checkExpr(arg, null);
                return self.store.make(.unit);
            }
        }
        var bound_callable: ?*Callable = null;
        var bound_args: ?[]*types.Type = null;
        var callee: *types.Type = undefined;
        if (call.callee.* == .path and call.callee.path.segments.len == 1 and
            self.lookup(call.callee.path.segments[0].name) == null)
        {
            const segment = call.callee.path.segments[0];
            if (self.lookupFunction(segment.name)) |callable| {
                const explicit = if (segment.args.len > 0) try self.resolveTypeArgs(segment.args) else null;
                const inst = try self.instantiateCallable(callable, explicit);
                callee = inst.ty;
                _ = try self.record(call.callee, callee);
                if (explicit == null) {
                    bound_callable = callable;
                    bound_args = inst.args;
                }
            } else {
                callee = self.store.resolve(try self.checkExpr(call.callee, null));
            }
        } else {
            callee = self.store.resolve(try self.checkExpr(call.callee, null));
        }
        switch (callee.*) {
            .function => |function| {
                if (function.params.len != call.args.len) {
                    try self.report("call expects {d} argument(s), found {d}", .{
                        function.params.len, call.args.len,
                    });
                }
                for (call.args, 0..) |arg, i| {
                    const expected = if (i < function.params.len) function.params[i] else try self.store.make(.unknown);
                    _ = try self.checkMoveExpr(arg, expected);
                }
                if (bound_callable) |callable| {
                    try self.checkGenericBounds(callable, bound_args.?);
                }
                return function.result;
            },
            .unknown => {
                for (call.args) |arg| _ = try self.checkExpr(arg, null);
                return callee;
            },
            else => {
                const name = try self.store.typeName(callee);
                try self.report("cannot call value of type `{s}`", .{name});
                for (call.args) |arg| _ = try self.checkExpr(arg, null);
                return self.store.make(.unknown);
            },
        }
    }

    fn checkField(self: *Checker, field: ast.FieldAccess) !*types.Type {
        var temp = ast.Expr{ .field = field };
        if (try self.placeOf(&temp)) |place| try self.checkRead(place);
        const target_ty = try self.checkExpr(field.target, null);
        if (try self.fieldType(target_ty, field.name)) |ty| return ty;
        try self.report("unknown field `{s}`", .{field.name});
        return self.store.make(.unknown);
    }

    fn checkIndex(self: *Checker, index_expr: ast.Index) !*types.Type {
        var temp = ast.Expr{ .index = index_expr };
        var index_checked = false;
        if (try self.placeOf(&temp)) |place| {
            try self.checkRead(place);
            index_checked = true;
        }
        const target_ty = self.store.resolve(try self.checkExpr(index_expr.target, null));
        if (!index_checked) {
            const key_ty: ?*types.Type = switch (target_ty.*) {
                .map => |m| m.key,
                .named => if (self.implementsTrait(target_ty, "Index")) null else try self.store.make(.{ .int = .usize }),
                else => try self.store.make(.{ .int = .usize }),
            };
            if (key_ty) |key| _ = try self.checkExpr(index_expr.index, key);
        }
        return switch (target_ty.*) {
            .array => |array| if (array.columns != null)
                try self.makeArrayType(array.element, array.columns, null)
            else
                array.element,
            .map => |m| m.value,
            .string => target_ty,
            .unknown => target_ty,
            .named => blk: {
                if (self.implementsTrait(target_ty, "Index")) {
                    if (self.customOperatorMethod(target_ty, "index", 2)) |result| break :blk result;
                }
                const name = try self.store.typeName(target_ty);
                try self.report("cannot index value of type `{s}`", .{name});
                break :blk self.store.make(.unknown);
            },
            else => blk: {
                const name = try self.store.typeName(target_ty);
                try self.report("cannot index value of type `{s}`", .{name});
                break :blk self.store.make(.unknown);
            },
        };
    }

    fn errorValueType(self: *Checker, path: ast.Path) !*types.Type {
        var name = std.ArrayList(u8).empty;
        for (path.segments, 0..) |segment, i| {
            if (i != 0) try name.appendSlice(self.allocator, "::");
            try name.appendSlice(self.allocator, segment.name);
        }
        return self.store.make(.{ .error_value = try name.toOwnedSlice(self.allocator) });
    }

    fn literalType(self: *Checker, literal: ast.Literal) !*types.Type {
        return switch (literal) {
            .int => self.store.integerVar(),
            .float => self.store.floatVar(),
            .string => self.store.make(.string),
            .boolean => self.store.make(.bool),
            .nil => self.store.make(.{ .optional = try self.store.freshVar(.any) }),
        };
    }
};

fn blockTailExpr(block: *ast.Block) ?*ast.Expr {
    if (block.entries.len == 0) return null;
    return switch (block.entries[block.entries.len - 1]) {
        .stmt => |stmt| if (stmt.* == .expr) stmt.expr else null,
        .item => null,
    };
}

fn modulePathMatches(qualified: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return std.mem.indexOf(u8, qualified, "::") == null;
    return std.mem.startsWith(u8, qualified, prefix) and
        qualified.len > prefix.len and qualified[prefix.len] == ':';
}

fn lastPathSegment(path: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, path, "::")) |index| return path[index + 2 ..];
    return path;
}

// ---------------------------------------------------------------------------
// NLL-style last-use scan
// ---------------------------------------------------------------------------

fn entriesUseName(entries: []ast.Entry, name: []const u8) bool {
    for (entries) |entry| {
        const used = switch (entry) {
            .item => false,
            .stmt => |stmt| stmtUsesName(stmt, name),
        };
        if (used) return true;
    }
    return false;
}

fn stmtUsesName(stmt: *ast.Stmt, name: []const u8) bool {
    return switch (stmt.*) {
        .binding => |binding| exprUsesName(binding.value, name),
        .ret => |value| if (value) |expr| exprUsesName(expr, name) else false,
        .break_stmt, .cont => false,
        .while_stmt => |loop| exprUsesName(loop.condition, name) or blockUsesName(loop.body, name),
        .for_stmt => |loop| exprUsesName(loop.iterable, name) or blockUsesName(loop.body, name),
        .loop_stmt => |loop| blockUsesName(loop.body, name),
        .expr => |expr| exprUsesName(expr, name),
        .assign => |assign| placeUsesName(assign.target, name) or exprUsesName(assign.value, name),
        .unsafe_block => |block| blockUsesName(block, name),
        .uninitialized => false,
    };
}

fn placeUsesName(expr: *ast.Expr, name: []const u8) bool {
    return exprUsesName(expr, name);
}

fn blockUsesName(block: *ast.Block, name: []const u8) bool {
    return entriesUseName(block.entries, name);
}

fn functionBodyUsesName(body: ast.FunctionBody, name: []const u8) bool {
    return switch (body) {
        .expr => |expr| exprUsesName(expr, name),
        .block => |block| blockUsesName(block, name),
    };
}

fn exprUsesName(expr: *ast.Expr, name: []const u8) bool {
    return switch (expr.*) {
        .path => |path| path.segments.len > 0 and std.mem.eql(u8, path.segments[0].name, name),
        .int, .float, .string, .boolean, .nil, .error_literal => false,
        .function => |function| functionBodyUsesName(function.body, name),
        .struct_literal => |literal| blk: {
            for (literal.fields) |field| if (exprUsesName(field.value, name)) break :blk true;
            break :blk false;
        },
        .map_literal => |literal| blk: {
            for (literal.entries) |entry| {
                if (exprUsesName(entry.key, name) or exprUsesName(entry.value, name)) break :blk true;
            }
            break :blk false;
        },
        .list => |items| blk: {
            for (items) |item| if (exprUsesName(item, name)) break :blk true;
            break :blk false;
        },
        .block => |block| blockUsesName(block, name),
        .if_expr => |if_expr| blk: {
            for (if_expr.branches) |branch| {
                if (exprUsesName(branch.condition, name) or blockUsesName(branch.body, name)) break :blk true;
            }
            if (if_expr.else_body) |body| if (blockUsesName(body, name)) break :blk true;
            break :blk false;
        },
        .match_expr => |match_expr| blk: {
            if (exprUsesName(match_expr.scrutinee, name)) break :blk true;
            for (match_expr.arms) |arm| {
                if (arm.guard) |guard| if (exprUsesName(guard, name)) break :blk true;
                if (blockUsesName(arm.body, name)) break :blk true;
            }
            break :blk false;
        },
        .unary => |unary| exprUsesName(unary.operand, name),
        .prefix => |prefix_expr| exprUsesName(prefix_expr.operand, name),
        .binary => |binary| exprUsesName(binary.lhs, name) or exprUsesName(binary.rhs, name),
        .range => |range| blk: {
            if (range.start) |start| if (exprUsesName(start, name)) break :blk true;
            if (range.end) |end| if (exprUsesName(end, name)) break :blk true;
            break :blk false;
        },
        .cast => |cast| exprUsesName(cast.expr, name),
        .call => |call| blk: {
            if (exprUsesName(call.callee, name)) break :blk true;
            for (call.args) |arg| if (exprUsesName(arg, name)) break :blk true;
            break :blk false;
        },
        .field => |field| exprUsesName(field.target, name),
        .index => |index| exprUsesName(index.target, name) or exprUsesName(index.index, name),
        .try_expr => |inner| exprUsesName(inner, name),
    };
}

// ---------------------------------------------------------------------------
// Exhaustiveness helpers
// ---------------------------------------------------------------------------

fn patternIsCatchAll(pattern: *ast.Pattern) bool {
    return switch (pattern.*) {
        .wildcard, .binding => true,
        .or_pattern => |items| blk: {
            for (items) |item| if (patternIsCatchAll(item)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn collectBoolDuplicateCheck(
    pattern: *ast.Pattern,
    seen: *std.StringHashMapUnmanaged(void),
    allocator: std.mem.Allocator,
) !void {
    switch (pattern.*) {
        .literal => |literal| switch (literal) {
            .boolean => |value| {
                const key = if (value) "true" else "false";
                if (seen.contains(key)) return error.OutOfMemory;
                try seen.put(allocator, key, {});
            },
            else => {},
        },
        .or_pattern => |items| for (items) |item| try collectBoolDuplicateCheck(item, seen, allocator),
        else => {},
    }
}

fn patternHasNil(pattern: *ast.Pattern) bool {
    return switch (pattern.*) {
        .literal => |literal| literal == .nil,
        .or_pattern => |items| blk: {
            for (items) |item| if (patternHasNil(item)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn patternOnlyNil(pattern: *ast.Pattern) bool {
    return switch (pattern.*) {
        .literal => |literal| literal == .nil,
        .or_pattern => |items| blk: {
            for (items) |item| if (!patternOnlyNil(item)) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

fn collectBoolLiterals(pattern: *ast.Pattern, saw_true: *bool, saw_false: *bool) void {
    switch (pattern.*) {
        .literal => |literal| switch (literal) {
            .boolean => |value| {
                if (value) saw_true.* = true else saw_false.* = true;
            },
            else => {},
        },
        .or_pattern => |items| for (items) |item| collectBoolLiterals(item, saw_true, saw_false),
        else => {},
    }
}

fn collectVariantNames(
    pattern: *ast.Pattern,
    seen: *std.StringHashMapUnmanaged(void),
    allocator: std.mem.Allocator,
) !void {
    switch (pattern.*) {
        .path => |path| if (path.segments.len > 0) {
            try seen.put(allocator, path.segments[path.segments.len - 1].name, {});
        },
        .tuple_struct => |tuple| if (tuple.path.segments.len > 0) {
            try seen.put(allocator, tuple.path.segments[tuple.path.segments.len - 1].name, {});
        },
        .struct_pattern => |struct_pattern| if (struct_pattern.path.segments.len > 0) {
            try seen.put(allocator, struct_pattern.path.segments[struct_pattern.path.segments.len - 1].name, {});
        },
        .or_pattern => |items| for (items) |item| try collectVariantNames(item, seen, allocator),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Helpers over the item union
// ---------------------------------------------------------------------------

fn typeNameOfItem(item: *ast.Item) ?[]const u8 {
    return switch (item.kind) {
        .struct_decl => |d| d.name,
        .enum_decl => |d| d.name,
        .table_decl => |d| d.name,
        .trigger_decl => |d| d.name,
        else => null,
    };
}

fn typeNameOfType(ty: *ast.Type) ?[]const u8 {
    if (ty.* != .path or ty.path.segments.len == 0) return null;
    return ty.path.segments[ty.path.segments.len - 1].name;
}

fn genericsOfItem(item: *ast.Item) []ast.GenericParam {
    return switch (item.kind) {
        .struct_decl => |d| d.generics,
        .enum_decl => |d| d.generics,
        .table_decl => |d| d.generics,
        .trigger_decl => |d| d.generics,
        else => &.{},
    };
}

fn fieldsOfItem(item: *ast.Item) []ast.Field {
    return switch (item.kind) {
        .struct_decl => |d| d.fields,
        .table_decl => |d| d.fields,
        .trigger_decl => |d| d.fields,
        else => &.{},
    };
}

fn variantsOfItem(item: *ast.Item) []ast.Variant {
    return switch (item.kind) {
        .enum_decl => |d| d.variants,
        else => &.{},
    };
}
