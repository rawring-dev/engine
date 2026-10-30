//! Checked-AST to engine bytecode lowering.
//!
//! The backend intentionally targets a small, explicit subset: integer/bool
//! functions, locals, calls, arithmetic/comparison, `if`/`match`, `while`,
//! `loop`, `for` over integer ranges, assignment, and `ret`.  Everything is
//! represented as 64-bit integers in the bytecode; booleans are 0/1.  Aggregate
//! values and borrows are rejected by `UnsupportedFeature` for now rather than
//! silently miscompiled.
//!
//! `sys` declarations lower like async functions: a constructor returns a
//! `Task` handle and the body runs with the task pointer plus placeholder
//! parameters.  The body prologue materializes world handles instead: resource
//! parameters call `e7_ecs_resource` (guarded by `e7_ecs_has_resource` so
//! legacy source-level calls still forward caller values), query parameters
//! call `e7_ecs_query_begin`, and `Commands` parameters call `e7_ecs_commands`.
//! Trigger bodies spawn a zero-argument constructor for each system and gate
//! `@plugin` systems on `e7_ecs_plugin_active`.  Query row projection and
//! iteration still need entity-loop lowering, so they stay rejected with
//! `UnsupportedFeature`.
//!
//! Floats are stored as their f64 bit pattern in the uniform i64 slot
//! representation.  Float literals lower directly; float arithmetic,
//! comparisons, unary negation, and int<->float `as` casts lower to the
//! `e7_f32_*` runtime helpers (see `runtime/src/float.zig`).
//!
//! This is the compiler's real output path: `pipeline.zig` runs the parser,
//! semantic analyzer, this lowering pass, and the bytecode fixed-point
//! optimizer.  The runtime later consumes the bytecode.

const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const semantic = @import("semantic/analyzer.zig");
const types = @import("semantic/types.zig");
const intrinsics = @import("intrinsics.zig");
const native_methods = @import("native_methods.zig");

pub const Error = error{
    OutOfMemory,
    UnsupportedFeature,
    DuplicateFunction,
    NoFunctions,
    TooManyLocals,
    UnknownLocal,
    InvalidBytecode,
};

pub const Config = struct {
    /// Verification/translation reserves this many operand-stack slots.
    stack_slots: u16 = 256,
};

const FunctionInfo = struct {
    decl: *const ast.FunctionDecl,
    constructor_index: u16,
    body_index: ?u16 = null,
    /// Qualified source name (`main`, `ui::helper`); bytecode symbols use it.
    qualified_name: []const u8 = "",
    /// Non-null for `sys` declarations: the body prologue materializes world
    /// handles (resources, queries, Commands) instead of receiving them.
    sys_decl: ?*const ast.SysDecl = null,
    /// Module prefix used to resolve ECS names from this system's parameters.
    module_prefix: []const u8 = "",
    /// Zero-argument constructor for a system, used by trigger bodies and
    /// plugin initialization (source calls may still pass explicit args).
    trigger_ctor_index: ?u16 = null,
};

const TriggerSystemInfo = struct {
    /// Zero-argument system constructor used for trigger spawns.
    constructor_index: u16,
    gate: ?i64 = null,
};

const TriggerInfo = struct {
    decl: *const ast.TriggerDecl,
    id: u16,
    constructor_index: u16,
    body_index: u16,
    systems: []TriggerSystemInfo,
    /// Qualified trigger name; bytecode constructor/body symbols derive from it.
    name: []const u8,
};

/// Build a bytecode (and LLVM-safe) symbol for an impl method.  Qualified type
/// names use `::`, which LLVM IR identifiers cannot contain unquoted, so every
/// character outside the unquoted-identifier set becomes `_`.
fn mangleMethodSymbol(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    method_name: []const u8,
) Error![]const u8 {
    const raw = try std.fmt.allocPrint(allocator, "impl.{s}.{s}", .{ type_name, method_name });
    for (raw) |*char| {
        switch (char.*) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '$', '-' => {},
            else => char.* = '_',
        }
    }
    return raw;
}

/// Bytecode functions for custom operator/Index implementation methods.
///
/// Methods are only compiled when lowering actually resolves an operator to
/// them, so an impl block is not compiled (and cannot fail to compile) unless
/// its method is used.  A method can reference further methods, so compilation
/// drains the pending queue to a fixed point.
const MethodTable = struct {
    allocator: std.mem.Allocator,
    config: Config,
    name_map: *const std.StringHashMapUnmanaged(u16),
    analysis: *const semantic.Analysis,
    structs: *const std.StringHashMapUnmanaged(*const ast.StructDecl),
    tables: *const std.StringHashMapUnmanaged(*const ast.TableDecl),
    enums: *const std.StringHashMapUnmanaged(*const ast.EnumDecl),
    /// First bytecode index occupied by impl-method functions.
    base_index: u16,
    /// Bytecode indices of plain functions that may be used as values.
    value_functions: ?*const std.AutoHashMapUnmanaged(u16, void) = null,
    by_decl: std.AutoHashMapUnmanaged(usize, u16) = .empty,
    pending: std.ArrayList(PendingMethod) = .empty,
    functions: std.ArrayList(bytecode.Function) = .empty,
    /// Cleared once the functions are copied into the module function table.
    owned: bool = true,

    const PendingMethod = struct {
        decl: *const ast.FunctionDecl,
        index: u16,
        name: []const u8,
    };

    fn deinit(self: *MethodTable) void {
        if (self.owned) {
            for (self.functions.items) |function| {
                self.allocator.free(function.name);
                self.allocator.free(function.code);
            }
        }
        self.functions.deinit(self.allocator);
        for (self.pending.items) |pending| self.allocator.free(pending.name);
        self.pending.deinit(self.allocator);
        self.by_decl.deinit(self.allocator);
    }

    fn ensure(self: *MethodTable, method: semantic.ImplMethod) Error!u16 {
        const key = @intFromPtr(method.decl);
        if (self.by_decl.get(key)) |index| return index;
        const offset = std.math.cast(u16, self.functions.items.len) orelse return error.TooManyLocals;
        const index = std.math.add(u16, self.base_index, offset) catch return error.TooManyLocals;
        const name = try mangleMethodSymbol(self.allocator, method.type_name, method.method_name);
        errdefer self.allocator.free(name);
        try self.by_decl.put(self.allocator, key, index);
        errdefer _ = self.by_decl.remove(key);
        // Placeholder owning no allocations; replaced by `finish`.
        try self.functions.append(self.allocator, .{
            .name = "",
            .params = 0,
            .locals = 0,
            .max_stack = self.config.stack_slots,
            .code = &.{},
        });
        try self.pending.append(self.allocator, .{ .decl = method.decl, .index = index, .name = name });
        return index;
    }

    fn finish(self: *MethodTable) Error!void {
        var next: usize = 0;
        while (next < self.pending.items.len) : (next += 1) {
            const pending = self.pending.items[next];
            const offset = pending.index - self.base_index;
            var builder = Builder{
                .allocator = self.allocator,
                .config = self.config,
                .name_map = self.name_map,
                .function = pending.decl,
                .analysis = self.analysis,
                .structs = self.structs,
                .tables = self.tables,
                .enums = self.enums,
                .methods = self,
                .value_functions = self.value_functions,
                .name_override = pending.name,
            };
            const compiled = try builder.finish();
            self.allocator.free(self.functions.items[offset].name);
            self.allocator.free(self.functions.items[offset].code);
            self.functions.items[offset] = compiled;
        }
    }
};

/// Append `prefix::name` into a caller-provided buffer.  ECS lookups use this
/// instead of heap strings so lowering allocates only persistent artifacts.
fn qualifiedNameBuf(buffer: *[512]u8, prefix: []const u8, name: []const u8) []const u8 {
    if (prefix.len == 0) return name;
    return std.fmt.bufPrint(buffer, "{s}::{s}", .{ prefix, name }) catch name;
}

fn joinPathBuf(buffer: *[512]u8, path: ast.Path) []const u8 {
    var length: usize = 0;
    for (path.segments, 0..) |segment, index| {
        if (index > 0) {
            if (length + 2 > buffer.len) return path.segments[path.segments.len - 1].name;
            buffer[length] = ':';
            buffer[length + 1] = ':';
            length += 2;
        }
        if (length + segment.name.len > buffer.len) return path.segments[path.segments.len - 1].name;
        @memcpy(buffer[length .. length + segment.name.len], segment.name);
        length += segment.name.len;
    }
    return buffer[0..length];
}

fn lastSegment(name: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, name, "::")) |index| return name[index + 2 ..];
    return name;
}

/// Final path segment of a type in symbol position: `res &mut Gpu` -> `Gpu`,
/// `&mut Commands` -> `Commands`.  Returns null for non-path types.
fn typeLastName(ty: *const ast.Type) ?[]const u8 {
    var current = ty;
    while (true) {
        switch (current.*) {
            .reference => |reference| current = reference.child,
            .box => |child| current = child,
            .optional => |child| current = child,
            .path => |path| {
                if (path.segments.len == 0) return null;
                return path.segments[path.segments.len - 1].name;
            },
            else => return null,
        }
    }
}

fn qualifiedNameAlloc(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    name: []const u8,
) Error![]const u8 {
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}::{s}", .{ prefix, name });
}

/// Recursive item collection shared by the function/sys/trigger registries.
const LowerState = struct {
    allocator: std.mem.Allocator,
    config: Config,
    analysis: *const semantic.Analysis,
    structs: *std.StringHashMapUnmanaged(*const ast.StructDecl),
    tables: *std.StringHashMapUnmanaged(*const ast.TableDecl),
    enums: *std.StringHashMapUnmanaged(*const ast.EnumDecl),
    infos: *std.ArrayList(FunctionInfo),
    triggers: *std.ArrayList(TriggerInfo),
    synthetic: *std.ArrayList(*ast.FunctionDecl),
    synthetic_types: *std.ArrayList(*ast.Type),
    synthetic_params: *std.ArrayList([]ast.Param),
    name_map: *std.StringHashMapUnmanaged(u16),
    trigger_systems: *std.StringHashMapUnmanaged(std.ArrayList(TriggerSystemInfo)),
    owned_names: *std.ArrayList([]const u8),
    next_index: u16 = 0,

    fn qualified(self: *LowerState, prefix: []const u8, name: []const u8) Error![]const u8 {
        const owned = try qualifiedNameAlloc(self.allocator, prefix, name);
        errdefer self.allocator.free(owned);
        try self.owned_names.append(self.allocator, owned);
        return owned;
    }

    fn childPrefix(self: *LowerState, prefix: []const u8, name: []const u8) Error![]const u8 {
        return self.qualified(prefix, name);
    }

    fn registerAlias(self: *LowerState, name: []const u8, index: u16) Error!void {
        if (self.name_map.contains(name)) return;
        try self.name_map.put(self.allocator, name, index);
    }

    fn registerFunction(self: *LowerState, decl: *const ast.FunctionDecl, qualified_name: []const u8, async_slots: bool) Error!void {
        if (self.name_map.contains(qualified_name)) return error.DuplicateFunction;
        const slots: u16 = if (async_slots) 2 else 1;
        if (self.next_index + slots < self.next_index) return error.TooManyLocals;
        const constructor_index = self.next_index;
        self.next_index += slots;
        try self.name_map.put(self.allocator, qualified_name, constructor_index);
        try self.registerAlias(decl.name, constructor_index);
        try self.infos.append(self.allocator, .{
            .decl = decl,
            .constructor_index = constructor_index,
            .body_index = if (async_slots) constructor_index + 1 else null,
            .qualified_name = qualified_name,
        });
    }

    fn collectItems(self: *LowerState, items: []*ast.Item, prefix: []const u8) Error!void {
        for (items) |item| {
            switch (item.kind) {
                .struct_decl => try self.structs.put(self.allocator, item.kind.struct_decl.name, &item.kind.struct_decl),
                .table_decl => try self.tables.put(self.allocator, item.kind.table_decl.name, &item.kind.table_decl),
                .enum_decl => try self.enums.put(self.allocator, item.kind.enum_decl.name, &item.kind.enum_decl),
                .function => |decl| {
                    const qualified_name = try self.qualified(prefix, decl.name);
                    try self.registerFunction(&item.kind.function, qualified_name, decl.is_async);
                },
                .binding => |binding| {
                    if (binding.value.* != .function or !binding.value.function.is_async) continue;
                    const qualified_name = try self.qualified(prefix, binding.name);
                    if (self.name_map.contains(qualified_name)) return error.DuplicateFunction;
                    const function = binding.value.function;
                    const decl = try self.allocator.create(ast.FunctionDecl);
                    decl.* = .{
                        .name = binding.name,
                        .is_async = true,
                        .generics = &.{},
                        .params = function.params,
                        .result = function.result,
                        .where_clause = null,
                        .body = function.body,
                    };
                    try self.synthetic.append(self.allocator, decl);
                    if (self.next_index + 2 < self.next_index) return error.TooManyLocals;
                    const constructor_index = self.next_index;
                    self.next_index += 2;
                    try self.name_map.put(self.allocator, qualified_name, constructor_index);
                    try self.registerAlias(binding.name, constructor_index);
                    try self.infos.append(self.allocator, .{
                        .decl = decl,
                        .constructor_index = constructor_index,
                        .body_index = constructor_index + 1,
                        .qualified_name = qualified_name,
                    });
                },
                .sys => try self.collectSys(item, prefix),
                .mod => |m| if (m.items) |inner| {
                    try self.collectItems(inner, try self.childPrefix(prefix, m.name));
                },
                .plugin_decl => |plugin| {
                    try self.collectItems(plugin.items, try self.childPrefix(prefix, plugin.name));
                },
                else => {},
            }
        }
    }

    const SysTrigger = struct {
        constructor_index: u16,
        body_index: u16,
        params: u16,
        gate: ?i64,
    };

    fn collectSys(self: *LowerState, item: *ast.Item, prefix: []const u8) Error!void {
        const decl = &item.kind.sys;
        const qualified_name = try self.qualified(prefix, decl.name);
        if (self.name_map.contains(qualified_name)) return error.DuplicateFunction;
        const unit_ty = try self.allocator.create(ast.Type);
        unit_ty.* = .{ .tuple = &.{} };
        try self.synthetic_types.append(self.allocator, unit_ty);
        // Placeholder ABI parameters keep the async body arity stable
        // (task + declared params); the constructor passes zeroes and the body
        // prologue binds the real world handles.
        const params = try self.allocator.alloc(ast.Param, decl.params.len);
        try self.synthetic_params.append(self.allocator, params);
        for (params) |*placeholder| {
            placeholder.* = .{ .name = "<sys_param>", .ty = unit_ty };
        }
        const synthetic_decl = try self.allocator.create(ast.FunctionDecl);
        synthetic_decl.* = .{
            .name = decl.name,
            .is_async = true,
            .generics = decl.generics,
            .params = params,
            .result = unit_ty,
            .where_clause = decl.where_clause,
            .body = .{ .block = decl.body },
        };
        try self.synthetic.append(self.allocator, synthetic_decl);
        if (self.next_index + 3 < self.next_index) return error.TooManyLocals;
        const constructor_index = self.next_index;
        self.next_index += 3;
        try self.name_map.put(self.allocator, qualified_name, constructor_index);
        try self.registerAlias(decl.name, constructor_index);
        try self.infos.append(self.allocator, .{
            .decl = synthetic_decl,
            .constructor_index = constructor_index,
            .body_index = constructor_index + 1,
            .qualified_name = qualified_name,
            .sys_decl = decl,
            .module_prefix = prefix,
            .trigger_ctor_index = constructor_index + 2,
        });

        const trigger_key = itemTriggerKey(item);
        const gate = self.analysis.systemGate(qualified_name);
        if (trigger_key) |key| {
            const gop = try self.trigger_systems.getOrPut(self.allocator, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.allocator, .{
                .constructor_index = constructor_index + 2,
                .gate = gate,
            });
        }
    }

    fn collectTriggers(self: *LowerState, items: []*ast.Item, prefix: []const u8) Error!void {
        for (items) |item| {
            switch (item.kind) {
                .trigger_decl => {
                    const decl = &item.kind.trigger_decl;
                    const qualified_name = try self.qualified(prefix, decl.name);
                    if (self.name_map.contains(qualified_name)) return error.DuplicateFunction;
                    if (self.next_index + 2 < self.next_index) return error.TooManyLocals;
                    const constructor_index = self.next_index;
                    self.next_index += 2;
                    try self.name_map.put(self.allocator, qualified_name, constructor_index);
                    try self.registerAlias(decl.name, constructor_index);
                    const systems = if (self.trigger_systems.get(decl.name)) |list|
                        try self.allocator.dupe(TriggerSystemInfo, list.items)
                    else
                        try self.allocator.alloc(TriggerSystemInfo, 0);
                    try self.triggers.append(self.allocator, .{
                        .decl = decl,
                        .id = @intCast(self.triggers.items.len),
                        .constructor_index = constructor_index,
                        .body_index = constructor_index + 1,
                        .systems = systems,
                        .name = qualified_name,
                    });
                },
                .mod => |m| if (m.items) |inner| {
                    try self.collectTriggers(inner, try self.childPrefix(prefix, m.name));
                },
                .plugin_decl => |plugin| {
                    try self.collectTriggers(plugin.items, try self.childPrefix(prefix, plugin.name));
                },
                else => {},
            }
        }
    }
};

/// Last path segment of `@trigger(...)`, used to match systems to triggers.
fn itemTriggerKey(item: *const ast.Item) ?[]const u8 {
    for (item.attributes) |attribute| {
        if (attribute.path.segments.len == 0 or attribute.args.len == 0) continue;
        const attr_name = attribute.path.segments[attribute.path.segments.len - 1].name;
        if (!std.mem.eql(u8, attr_name, "trigger")) continue;
        const arg = attribute.args[0];
        if (arg.* != .path or arg.path.segments.len == 0) return null;
        return arg.path.segments[arg.path.segments.len - 1].name;
    }
    return null;
}

/// `__e7_ecs_setup`: reset the world and register every ungated resource and
/// component.  Plugin-gated resources are registered by `add_plugin` lowering
/// just before their plugin init runs.
fn buildEcsSetup(allocator: std.mem.Allocator, analysis: *const semantic.Analysis) Error!bytecode.Function {
    var code = std.ArrayList(bytecode.Op).empty;
    errdefer code.deinit(allocator);
    try code.append(allocator, .{ .runtime_call = .{ .function = .ecs_reset, .argc = 0 } });
    try code.append(allocator, .pop);
    for (analysis.resources) |info| {
        if (info.plugin_id != null) continue;
        try code.append(allocator, .{ .push_i64 = info.id });
        try code.append(allocator, .{ .push_i64 = @intCast(info.slots) });
        try code.append(allocator, .{ .runtime_call = .{ .function = .ecs_register_resource, .argc = 2 } });
        try code.append(allocator, .pop);
    }
    for (analysis.components) |info| {
        try code.append(allocator, .{ .push_i64 = info.id });
        try code.append(allocator, .{ .push_i64 = @intCast(info.slots) });
        try code.append(allocator, .{ .runtime_call = .{ .function = .ecs_register_component, .argc = 2 } });
        try code.append(allocator, .pop);
    }
    try code.append(allocator, .{ .push_i64 = 0 });
    try code.append(allocator, .ret);
    return .{
        .name = try allocator.dupe(u8, "__e7_ecs_setup"),
        .params = 0,
        .locals = 0,
        .max_stack = 16,
        .code = try code.toOwnedSlice(allocator),
    };
}

pub fn lower(
    allocator: std.mem.Allocator,
    module: *ast.Module,
    analysis: *const semantic.Analysis,
    config: Config,
) Error!bytecode.Module {
    var structs = std.StringHashMapUnmanaged(*const ast.StructDecl).empty;
    var tables = std.StringHashMapUnmanaged(*const ast.TableDecl).empty;
    var enums = std.StringHashMapUnmanaged(*const ast.EnumDecl).empty;
    defer structs.deinit(allocator);
    defer tables.deinit(allocator);
    defer enums.deinit(allocator);

    var infos = std.ArrayList(FunctionInfo).empty;
    defer infos.deinit(allocator);
    var triggers = std.ArrayList(TriggerInfo).empty;
    defer {
        for (triggers.items) |info| allocator.free(info.systems);
        triggers.deinit(allocator);
    }
    var synthetic = std.ArrayList(*ast.FunctionDecl).empty;
    var synthetic_types = std.ArrayList(*ast.Type).empty;
    var synthetic_params = std.ArrayList([]ast.Param).empty;
    defer {
        for (synthetic.items) |decl| allocator.destroy(decl);
        synthetic.deinit(allocator);
        for (synthetic_types.items) |ty| allocator.destroy(ty);
        synthetic_types.deinit(allocator);
        for (synthetic_params.items) |params| allocator.free(params);
        synthetic_params.deinit(allocator);
    }
    var name_map = std.StringHashMapUnmanaged(u16).empty;
    defer name_map.deinit(allocator);
    var trigger_systems = std.StringHashMapUnmanaged(std.ArrayList(TriggerSystemInfo)).empty;
    defer {
        var it = trigger_systems.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(allocator);
        trigger_systems.deinit(allocator);
    }
    var owned_names = std.ArrayList([]const u8).empty;
    defer {
        for (owned_names.items) |name| allocator.free(name);
        owned_names.deinit(allocator);
    }

    var state = LowerState{
        .allocator = allocator,
        .config = config,
        .analysis = analysis,
        .structs = &structs,
        .tables = &tables,
        .enums = &enums,
        .infos = &infos,
        .triggers = &triggers,
        .synthetic = &synthetic,
        .synthetic_types = &synthetic_types,
        .synthetic_params = &synthetic_params,
        .name_map = &name_map,
        .trigger_systems = &trigger_systems,
        .owned_names = &owned_names,
    };
    try state.collectItems(module.items, "");
    try state.collectTriggers(module.items, "");

    if (infos.items.len == 0 and triggers.items.len == 0) return error.NoFunctions;

    var sys_wrappers = std.AutoHashMapUnmanaged(u16, u16).empty;
    defer sys_wrappers.deinit(allocator);
    for (infos.items) |info| {
        const wrapper = info.trigger_ctor_index orelse continue;
        try sys_wrappers.put(allocator, info.constructor_index, wrapper);
    }

    // Plain, non-async functions may be referenced as first-class values.  The
    // value is the stable bytecode function index; indirect calls dispatch on it.
    var value_functions = std.AutoHashMapUnmanaged(u16, void).empty;
    defer value_functions.deinit(allocator);
    for (infos.items) |info| {
        if (info.body_index != null or info.sys_decl != null) continue;
        try value_functions.put(allocator, info.constructor_index, {});
    }

    // Plugin id -> init constructor index, used by `commands.add_plugin`.
    var plugin_inits = std.AutoHashMapUnmanaged(i64, u16).empty;
    defer plugin_inits.deinit(allocator);
    for (analysis.plugins) |plugin| {
        const init_name = plugin.init orelse continue;
        if (name_map.get(init_name)) |index| {
            const wrapper = sys_wrappers.get(index) orelse index;
            try plugin_inits.put(allocator, plugin.id, wrapper);
        }
    }

    const has_ecs = analysis.resources.len > 0 or analysis.components.len > 0;
    var next_index = state.next_index;
    var setup_index: ?u16 = null;
    if (has_ecs) {
        if (next_index == std.math.maxInt(u16)) return error.TooManyLocals;
        setup_index = next_index;
        next_index += 1;
        try name_map.put(allocator, "__e7_ecs_setup", setup_index.?);
    }

    var methods = MethodTable{
        .allocator = allocator,
        .config = config,
        .name_map = &name_map,
        .analysis = analysis,
        .structs = &structs,
        .tables = &tables,
        .enums = &enums,
        .base_index = next_index,
        .value_functions = &value_functions,
    };
    defer methods.deinit();

    const functions = try allocator.alloc(bytecode.Function, next_index);
    var initialized: usize = 0;
    var transferred = false;
    errdefer if (!transferred) {
        for (functions[0..initialized]) |function| {
            allocator.free(function.name);
            allocator.free(function.code);
        }
        allocator.free(functions);
    };

    for (infos.items) |info| {
        const is_main = std.mem.eql(u8, info.qualified_name, "main");
        if (info.body_index) |body_index| {
            var constructor = Builder{
                .allocator = allocator,
                .config = config,
                .name_map = &name_map,
                .function = info.decl,
                .analysis = analysis,
                .structs = &structs,
                .tables = &tables,
                .enums = &enums,
                .methods = &methods,
                .name_override = info.qualified_name,
                .mode = .async_constructor,
                .body_index = body_index,
                .sys_wrappers = &sys_wrappers,
                .value_functions = &value_functions,
            };
            functions[info.constructor_index] = try constructor.finish();
            initialized += 1;

            var body = Builder{
                .allocator = allocator,
                .config = config,
                .name_map = &name_map,
                .function = info.decl,
                .analysis = analysis,
                .structs = &structs,
                .tables = &tables,
                .enums = &enums,
                .methods = &methods,
                .name_override = info.qualified_name,
                .mode = if (info.sys_decl != null) .sys_body else .async_body,
                .sys_decl = info.sys_decl,
                .module_prefix = info.module_prefix,
                .plugin_inits = &plugin_inits,
                .sys_wrappers = &sys_wrappers,
                .value_functions = &value_functions,
                .emit_ecs_setup = is_main and has_ecs,
            };
            functions[body_index] = try body.finish();
            initialized += 1;
            if (info.sys_decl) |sys_decl| {
                // Zero-argument constructor used by triggers and plugin init:
                // the body receives placeholder zeroes and its prologue reads
                // world handles from the ECS.
                const wrapper_index = info.trigger_ctor_index.?;
                var wrapper_code = std.ArrayList(bytecode.Op).empty;
                errdefer wrapper_code.deinit(allocator);
                for (0..sys_decl.params.len) |_| {
                    try wrapper_code.append(allocator, .{ .push_i64 = 0 });
                }
                try wrapper_code.append(allocator, .{ .create_task = .{
                    .function = body_index,
                    .argc = @intCast(sys_decl.params.len),
                } });
                try wrapper_code.append(allocator, .ret);
                functions[wrapper_index] = .{
                    .name = try std.fmt.allocPrint(allocator, "{s}__trigger", .{info.qualified_name}),
                    .params = 0,
                    .locals = 0,
                    .max_stack = config.stack_slots,
                    .code = try wrapper_code.toOwnedSlice(allocator),
                };
                initialized += 1;
            }
        } else {
            var builder = Builder{
                .allocator = allocator,
                .config = config,
                .name_map = &name_map,
                .function = info.decl,
                .analysis = analysis,
                .structs = &structs,
                .tables = &tables,
                .enums = &enums,
                .methods = &methods,
                .name_override = info.qualified_name,
                .plugin_inits = &plugin_inits,
                .sys_wrappers = &sys_wrappers,
                .value_functions = &value_functions,
                .emit_ecs_setup = is_main and has_ecs,
            };
            functions[info.constructor_index] = try builder.finish();
            initialized += 1;
        }
    }

    for (triggers.items) |info| {
        const argc: u16 = @intCast(info.decl.fields.len);
        var ctor_code = try allocator.alloc(bytecode.Op, info.decl.fields.len + 2);
        for (0..info.decl.fields.len) |i| ctor_code[i] = .{ .load_local = @intCast(i) };
        ctor_code[info.decl.fields.len] = .{ .create_task = .{
            .function = info.body_index,
            .argc = argc,
        } };
        ctor_code[info.decl.fields.len + 1] = .ret;
        functions[info.constructor_index] = .{
            .name = try allocator.dupe(u8, info.name),
            .params = argc,
            .locals = argc,
            .max_stack = config.stack_slots,
            .code = ctor_code,
        };
        initialized += 1;

        var body_code = std.ArrayList(bytecode.Op).empty;
        errdefer body_code.deinit(allocator);
        var handle_slots = std.ArrayList(u16).empty;
        defer handle_slots.deinit(allocator);
        var gate_jumps = std.ArrayList(usize).empty;
        defer gate_jumps.deinit(allocator);
        var next_local: u16 = argc + 1;
        for (info.systems) |system| {
            if (system.gate) |plugin_id| {
                try body_code.append(allocator, .{ .push_i64 = plugin_id });
                try body_code.append(allocator, .{ .runtime_call = .{
                    .function = .ecs_plugin_active,
                    .argc = 1,
                } });
                try gate_jumps.append(allocator, body_code.items.len);
                try body_code.append(allocator, .{ .jump_if_false = 0 });
            }
            // Systems fetch their world parameters themselves; the constructor
            // takes no arguments (the source-level call form is `await Sys()`).
            try body_code.append(allocator, .{ .call = .{
                .function = system.constructor_index,
                .argc = 0,
            } });
            try body_code.append(allocator, .task_spawn);
            try body_code.append(allocator, .{ .store_local = next_local });
            try handle_slots.append(allocator, next_local);
            next_local += 1;
            const after_spawn: u32 = @intCast(body_code.items.len);
            for (gate_jumps.items) |jump| body_code.items[jump] = .{ .jump_if_false = after_spawn };
            gate_jumps.clearRetainingCapacity();
        }
        for (handle_slots.items) |slot| {
            try body_code.append(allocator, .{ .load_local = slot });
            try body_code.append(allocator, .task_await);
            try body_code.append(allocator, .pop);
        }
        // Phase boundary: queued Commands from the systems (and from the
        // caller before `await Trigger(...)`) are applied when the trigger ends.
        try body_code.append(allocator, .{ .runtime_call = .{ .function = .ecs_commands, .argc = 0 } });
        try body_code.append(allocator, .{ .runtime_call = .{ .function = .ecs_commands_flush, .argc = 1 } });
        try body_code.append(allocator, .pop);
        try body_code.append(allocator, .{ .push_i64 = 0 });
        try body_code.append(allocator, .ret);
        functions[info.body_index] = .{
            .name = try std.fmt.allocPrint(allocator, "{s}__body", .{info.name}),
            .params = argc + 1,
            .locals = next_local,
            .max_stack = config.stack_slots,
            .code = try body_code.toOwnedSlice(allocator),
        };
        initialized += 1;
    }

    if (setup_index) |index| {
        functions[index] = try buildEcsSetup(allocator, analysis);
        initialized += 1;
    }

    // Compile any impl methods that lowering resolved custom operators to.
    try methods.finish();

    const method_functions = methods.functions.items;
    const combined = try allocator.alloc(bytecode.Function, next_index + method_functions.len);
    @memcpy(combined[0..next_index], functions);
    @memcpy(combined[next_index..], method_functions);
    allocator.free(functions);
    transferred = true;
    // Ownership of the method functions moved into `combined`.
    methods.functions.deinit(allocator);
    methods.functions = .empty;
    methods.owned = false;

    var result = bytecode.Module{
        .allocator = allocator,
        .functions = combined,
        .entry = name_map.get("main"),
    };
    errdefer result.deinit();
    try bytecode.verify(allocator, &result);
    return result;
}

const LoopCtx = struct {
    breaks: std.ArrayList(usize),
    continues: std.ArrayList(usize),
};

const BuilderMode = enum { normal, async_constructor, async_body, sys_body };

const Builder = struct {
    allocator: std.mem.Allocator,
    config: Config,
    name_map: *const std.StringHashMapUnmanaged(u16),
    function: *const ast.FunctionDecl,
    analysis: *const semantic.Analysis,
    structs: *const std.StringHashMapUnmanaged(*const ast.StructDecl),
    tables: *const std.StringHashMapUnmanaged(*const ast.TableDecl),
    enums: *const std.StringHashMapUnmanaged(*const ast.EnumDecl),
    /// Non-null for implementation-method functions (custom operators/Index).
    methods: ?*MethodTable = null,
    /// Bytecode symbol to use instead of the AST function name.
    name_override: ?[]const u8 = null,
    mode: BuilderMode = .normal,
    body_index: u16 = 0,
    /// Module prefix for resolving ECS names (`ui` for `ui` module items).
    module_prefix: []const u8 = "",
    /// Declared system whose body is being lowered; non-null in sys_body mode.
    sys_decl: ?*const ast.SysDecl = null,
    /// Bytecode indices of plain functions usable as first-class values.
    value_functions: ?*const std.AutoHashMapUnmanaged(u16, void) = null,
    /// Plugin id -> init constructor index for `commands.add_plugin`.
    plugin_inits: ?*const std.AutoHashMapUnmanaged(i64, u16) = null,
    /// System constructor index -> zero-argument trigger constructor.
    sys_wrappers: ?*const std.AutoHashMapUnmanaged(u16, u16) = null,
    /// Emit the synthetic ECS setup call before `main`'s body.
    emit_ecs_setup: bool = false,
    code: std.ArrayList(bytecode.Op) = .empty,
    scopes: std.ArrayList(std.StringHashMapUnmanaged(u16)) = .empty,
    next_local: u16 = 0,
    loops: std.ArrayList(LoopCtx) = .empty,

    fn finish(self: *Builder) Error!bytecode.Function {
        defer self.code.deinit(self.allocator);
        defer {
            for (self.loops.items) |*loop| {
                loop.breaks.deinit(self.allocator);
                loop.continues.deinit(self.allocator);
            }
            self.loops.deinit(self.allocator);
        }
        try self.enterScope();
        defer {
            while (self.scopes.items.len > 0) self.leaveScope();
            self.scopes.deinit(self.allocator);
        }

        const has_task = self.mode == .async_body or self.mode == .sys_body;
        if (has_task) {
            _ = try self.allocLocal("<task>");
        }
        const param_slots = try self.allocator.alloc(u16, self.function.params.len);
        defer self.allocator.free(param_slots);
        for (self.function.params, 0..) |param, index| {
            param_slots[index] = try self.allocLocal(param.name);
        }

        if (self.emit_ecs_setup) {
            try self.emitCall("__e7_ecs_setup", 0);
            try self.pop();
        }
        if (self.mode == .sys_body) try self.emitSysPrologue();

        switch (self.mode) {
            .async_constructor => {
                for (self.function.params, 0..) |_, i| {
                    try self.emit(.{ .load_local = @intCast(i) });
                }
                try self.emit(.{ .create_task = .{
                    .function = self.body_index,
                    .argc = @intCast(self.function.params.len),
                } });
                try self.emit(.ret);
            },
            .normal, .async_body, .sys_body => switch (self.function.body) {
                .expr => |expr| {
                    try self.lowerExpr(expr);
                    try self.emit(.ret);
                },
                .block => |block| {
                    try self.lowerBlockValue(block);
                    try self.emit(.ret);
                },
            },
        }

        const base_name = self.name_override orelse self.function.name;
        const name = if (self.mode == .async_body or self.mode == .sys_body)
            try std.fmt.allocPrint(self.allocator, "{s}__body", .{base_name})
        else
            try self.allocator.dupe(u8, base_name);
        return .{
            .name = name,
            .params = @intCast(self.function.params.len + @as(usize, if (has_task) 1 else 0)),
            .locals = self.next_local,
            .max_stack = self.config.stack_slots,
            .code = try self.code.toOwnedSlice(self.allocator),
        };
    }

    fn enterScope(self: *Builder) Error!void {
        try self.scopes.append(self.allocator, .empty);
    }

    fn leaveScope(self: *Builder) void {
        var scope = self.scopes.pop().?;
        scope.deinit(self.allocator);
    }

    fn allocLocal(self: *Builder, name: []const u8) Error!u16 {
        if (self.next_local == std.math.maxInt(u16)) return error.TooManyLocals;
        const slot = self.next_local;
        self.next_local += 1;
        try self.scopes.items[self.scopes.items.len - 1].put(self.allocator, name, slot);
        return slot;
    }

    fn local(self: *Builder, name: []const u8) ?u16 {
        var index = self.scopes.items.len;
        while (index > 0) {
            index -= 1;
            if (self.scopes.items[index].get(name)) |slot| return slot;
        }
        return null;
    }

    fn lowerCallArg(self: *Builder, arg: *ast.Expr) Error!void {
        try self.lowerExpr(arg);
    }

    fn runtimeCall(self: *Builder, function: bytecode.RuntimeFunction, argc: u16) Error!void {
        try self.emit(.{ .runtime_call = .{ .function = function, .argc = argc } });
    }

    // ------------------------------------------------------------------
    // ECS metadata resolution
    // ------------------------------------------------------------------

    fn findResourceInfo(self: *const Builder, name: []const u8) ?semantic.ResourceInfo {
        var buffer: [512]u8 = undefined;
        const qualified = qualifiedNameBuf(&buffer, self.module_prefix, name);
        if (self.analysis.resource(qualified)) |info| return info;
        if (self.analysis.resource(name)) |info| return info;
        for (self.analysis.resources) |info| {
            if (std.mem.eql(u8, lastSegment(info.name), name)) return info;
        }
        return null;
    }

    fn findComponentInfo(self: *const Builder, name: []const u8) ?semantic.ComponentInfo {
        var buffer: [512]u8 = undefined;
        const qualified = qualifiedNameBuf(&buffer, self.module_prefix, name);
        if (self.analysis.component(qualified)) |info| return info;
        if (self.analysis.component(name)) |info| return info;
        for (self.analysis.components) |info| {
            if (std.mem.eql(u8, lastSegment(info.name), name)) return info;
        }
        return null;
    }

    fn resourceInfoForExpr(self: *Builder, expr: *ast.Expr) ?semantic.ResourceInfo {
        const ty = self.exprType(expr) orelse return null;
        const named = self.namedBase(ty) orelse return null;
        if (self.analysis.resource(named.name)) |info| return info;
        return self.findResourceInfo(lastSegment(named.name));
    }

    fn componentInfoForExpr(self: *Builder, expr: *ast.Expr) ?semantic.ComponentInfo {
        const ty = self.exprType(expr) orelse return null;
        const named = self.namedBase(ty) orelse return null;
        if (self.analysis.component(named.name)) |info| return info;
        return self.findComponentInfo(lastSegment(named.name));
    }

    fn pluginInfoForExpr(self: *const Builder, expr: *ast.Expr) ?semantic.PluginInfo {
        if (expr.* != .path or expr.path.segments.len == 0) return null;
        var buffer: [512]u8 = undefined;
        const full = joinPathBuf(&buffer, expr.path);
        if (self.analysis.plugin(full)) |info| return info;
        var qualified_buffer: [512]u8 = undefined;
        const qualified = qualifiedNameBuf(&qualified_buffer, self.module_prefix, full);
        return self.analysis.plugin(qualified);
    }

    // ------------------------------------------------------------------
    // System prologue: materialize world handles from declared parameters
    // ------------------------------------------------------------------

    fn emitSysPrologue(self: *Builder) Error!void {
        const decl = self.sys_decl orelse return;
        for (decl.params, 0..) |param, index| {
            const param_name = switch (param) {
                .normal => |p| p.name,
                .resource => |p| p.name,
                .query => |q| q.name,
            };
            // Async bodies reserve slot 0 for the task; declared parameters
            // occupy slots 1..N and are already bound by ABI copies.
            const slot: u16 = @intCast(index + 1);
            try self.scopes.items[self.scopes.items.len - 1].put(self.allocator, param_name, slot);
            switch (param) {
                .resource => |resource_param| {
                    const type_name = typeLastName(resource_param.ty) orelse return error.UnsupportedFeature;
                    try self.emitResourceHandle(type_name, slot);
                },
                .query => |query| try self.emitQueryPrologue(query, slot),
                .normal => |normal_param| {
                    const type_name = typeLastName(normal_param.ty) orelse continue;
                    if (std.mem.eql(u8, type_name, "Commands")) {
                        try self.runtimeCall(.ecs_commands, 0);
                        try self.emit(.{ .store_local = slot });
                        continue;
                    }
                    // Known resources are world-backed; with no registration
                    // (legacy source-level systems) the caller's value is kept.
                    try self.emitResourceHandle(type_name, slot);
                },
            }
        }
    }

    /// Overwrite `slot` with the registered resource pointer when the world has
    /// it; otherwise keep the caller-provided value (or the placeholder zero
    /// supplied by a trigger constructor).
    fn emitResourceHandle(self: *Builder, type_name: []const u8, slot: u16) Error!void {
        const info = self.findResourceInfo(type_name) orelse return;
        try self.push(info.id);
        try self.runtimeCall(.ecs_has_resource, 1);
        const skip = self.code.items.len;
        try self.emit(.{ .jump_if_false = 0 });
        try self.push(info.id);
        try self.runtimeCall(.ecs_resource, 1);
        try self.emit(.{ .store_local = slot });
        const target: u32 = @intCast(self.code.items.len);
        self.code.items[skip] = .{ .jump_if_false = target };
    }

    fn emitQueryPrologue(self: *Builder, query: ast.QueryParam, slot: u16) Error!void {
        const count = query.projections.len;
        const ids = try self.allocator.alloc(i64, count);
        defer self.allocator.free(ids);
        const muts = try self.allocator.alloc(i64, count);
        defer self.allocator.free(muts);
        for (query.projections, 0..) |projection, index| {
            const name = if (projection.path.segments.len > 0)
                projection.path.segments[projection.path.segments.len - 1].name
            else
                "";
            ids[index] = if (self.findComponentInfo(name)) |info| info.id else -1;
            muts[index] = if (projection.mutable) 1 else 0;
        }
        var has_id: i64 = -1;
        if (query.has) |has_ty| {
            if (typeLastName(has_ty)) |name| {
                if (self.findComponentInfo(name)) |info| has_id = info.id;
            }
        }
        try self.push(@intCast(count));
        if (count == 0) {
            try self.push(0);
            try self.push(0);
        } else {
            const ids_slot = try self.emitI64Array(ids);
            const muts_slot = try self.emitI64Array(muts);
            try self.emit(.{ .load_local = ids_slot });
            try self.emit(.{ .load_local = muts_slot });
        }
        try self.push(has_id);
        try self.runtimeCall(.ecs_query_begin, 4);
        try self.emit(.{ .store_local = slot });
    }

    /// Materialize `values` as a heap array of 8-byte slots; returns the local
    /// holding its base address (a raw i64 passed to the ECS ABI).
    fn emitI64Array(self: *Builder, values: []const i64) Error!u16 {
        const slot = try self.allocLocal("<ecs_args>");
        try self.push(@intCast(values.len));
        try self.emit(.alloc);
        try self.emit(.{ .store_local = slot });
        for (values, 0..) |value, index| {
            try self.emit(.{ .load_local = slot });
            // 8-byte slots: byte offset is `index * 8`.
            try self.push(@intCast(index * 8));
            try self.emit(.add);
            try self.push(value);
            try self.emit(.store_mem);
        }
        return slot;
    }

    /// Lower `await query &mut T`: `Commands` yields the shared command
    /// buffer; a resource type yields the resource pointer.  Component/table
    /// queries need entity iteration and are rejected for now.
    fn lowerQueryLease(self: *Builder, query: ast.QueryExpr) Error!void {
        const name = typeLastName(query.ty) orelse return error.UnsupportedFeature;
        if (std.mem.eql(u8, name, "Commands")) {
            try self.runtimeCall(.ecs_commands, 0);
            return;
        }
        if (self.findResourceInfo(name)) |info| {
            try self.push(info.id);
            try self.runtimeCall(.ecs_resource, 1);
            return;
        }
        return error.UnsupportedFeature;
    }

    // ------------------------------------------------------------------
    // Commands methods
    // ------------------------------------------------------------------

    fn lowerCommandsMethodCall(self: *Builder, call: ast.Call) Error!bool {
        if (call.callee.* != .field) return false;
        const field = call.callee.field;
        const target_ty = self.exprType(field.target) orelse return false;
        const named = self.namedBase(target_ty) orelse return false;
        if (!std.mem.eql(u8, lastSegment(named.name), "Commands")) return false;
        const name = field.name;

        if (std.mem.eql(u8, name, "insert_resource")) {
            if (call.args.len != 1) return error.UnsupportedFeature;
            const info = self.resourceInfoForExpr(call.args[0]) orelse return error.UnsupportedFeature;
            try self.lowerExpr(field.target);
            try self.push(info.id);
            try self.lowerExpr(call.args[0]);
            try self.runtimeCall(.ecs_commands_insert_resource, 3);
            try self.pop();
            try self.push(0);
            return true;
        }

        if (std.mem.eql(u8, name, "add_row")) {
            if (call.args.len != 2 or call.args[1].* != .row_literal) return error.UnsupportedFeature;
            if (call.args[1].row_literal.len == 0) return error.UnsupportedFeature;
            try self.lowerExpr(field.target);
            try self.runtimeCall(.ecs_commands_row_begin, 1);
            const row_slot = try self.allocLocal("<row>");
            try self.emit(.{ .store_local = row_slot });
            for (call.args[1].row_literal) |item| {
                const info = self.componentInfoForExpr(item) orelse return error.UnsupportedFeature;
                try self.emit(.{ .load_local = row_slot });
                try self.push(info.id);
                if (info.slots == 0 and item.* == .path) {
                    // Marker component with no payload slots.
                    try self.push(0);
                } else {
                    try self.lowerExpr(item);
                }
                try self.runtimeCall(.ecs_commands_row_add, 3);
                try self.pop();
            }
            try self.emit(.{ .load_local = row_slot });
            try self.runtimeCall(.ecs_commands_row_finish, 1);
            try self.pop();
            try self.push(0);
            return true;
        }

        if (std.mem.eql(u8, name, "remove_component")) {
            if (call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedFeature;
            const type_name = typeLastName(call.type_args[0]) orelse return error.UnsupportedFeature;
            const info = self.findComponentInfo(type_name) orelse return error.UnsupportedFeature;
            try self.lowerExpr(field.target);
            try self.lowerExpr(call.args[0]);
            try self.push(info.id);
            try self.runtimeCall(.ecs_commands_remove_component, 3);
            try self.pop();
            try self.push(0);
            return true;
        }

        if (std.mem.eql(u8, name, "add_component")) {
            if (call.type_args.len != 1 or call.args.len != 2) return error.UnsupportedFeature;
            const type_name = typeLastName(call.type_args[0]) orelse return error.UnsupportedFeature;
            const info = self.findComponentInfo(type_name) orelse return error.UnsupportedFeature;
            try self.lowerExpr(field.target);
            try self.lowerExpr(call.args[0]);
            try self.push(info.id);
            try self.lowerExpr(call.args[1]);
            try self.runtimeCall(.ecs_commands_add_component, 4);
            try self.pop();
            try self.push(0);
            return true;
        }

        if (std.mem.eql(u8, name, "despawn")) {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedFeature;
            try self.lowerExpr(field.target);
            try self.lowerExpr(call.args[0]);
            try self.runtimeCall(.ecs_commands_despawn, 2);
            try self.pop();
            try self.push(0);
            return true;
        }

        if (std.mem.eql(u8, name, "add_plugin")) {
            if (call.args.len != 1) return error.UnsupportedFeature;
            const plugin = self.pluginInfoForExpr(call.args[0]) orelse return error.UnsupportedFeature;
            try self.lowerExpr(field.target);
            const cmd_slot = try self.allocLocal("<commands>");
            try self.emit(.{ .store_local = cmd_slot });
            // Gated resources must exist before the plugin init queues inserts.
            for (self.analysis.resources) |resource| {
                const gate = resource.plugin_id orelse continue;
                if (gate != plugin.id) continue;
                try self.push(resource.id);
                try self.push(@intCast(resource.slots));
                try self.runtimeCall(.ecs_register_resource, 2);
                try self.pop();
            }
            try self.emit(.{ .load_local = cmd_slot });
            try self.push(plugin.id);
            try self.runtimeCall(.ecs_commands_add_plugin, 2);
            try self.pop();
            // Activation is only observed after a flush; flush before init.
            try self.emit(.{ .load_local = cmd_slot });
            try self.runtimeCall(.ecs_commands_flush, 1);
            try self.pop();
            if (self.plugin_inits) |inits| {
                if (inits.get(plugin.id)) |init_index| {
                    try self.emit(.{ .call = .{ .function = init_index, .argc = 0 } });
                    try self.emit(.task_await);
                    try self.pop();
                }
            }
            // Apply Commands queued by plugin init (resource insertion, rows).
            try self.emit(.{ .load_local = cmd_slot });
            try self.runtimeCall(.ecs_commands_flush, 1);
            try self.pop();
            try self.push(0);
            return true;
        }

        return false;
    }

    fn emit(self: *Builder, op: bytecode.Op) Error!void {
        try self.code.append(self.allocator, op);
    }

    fn push(self: *Builder, value: i64) Error!void {
        try self.emit(.{ .push_i64 = value });
    }

    fn pop(self: *Builder) Error!void {
        try self.emit(.pop);
    }

    fn emitJump(self: *Builder, if_false: bool) Error!usize {
        const index = self.code.items.len;
        try self.emit(if (if_false) .{ .jump_if_false = 0 } else .{ .jump = 0 });
        return index;
    }

    fn patch(self: *Builder, index: usize) Error!void {
        const target: u32 = @intCast(self.code.items.len);
        switch (self.code.items[index]) {
            .jump => self.code.items[index] = .{ .jump = target },
            .jump_if_false => self.code.items[index] = .{ .jump_if_false = target },
            else => return error.UnsupportedFeature,
        }
    }

    /// Emit a call.  Zero-argument calls into a system use its zero-argument
    /// trigger constructor so world parameters are supplied by the ECS.
    fn callFunction(self: *Builder, function: u16, argc: usize) Error!void {
        var target = function;
        if (argc == 0) {
            if (self.sys_wrappers) |wrappers| {
                if (wrappers.get(function)) |wrapper| target = wrapper;
            }
        }
        try self.emit(.{ .call = .{ .function = target, .argc = @intCast(argc) } });
    }

    fn emitCall(self: *Builder, name: []const u8, argc: usize) Error!void {
        const function = self.name_map.get(name) orelse return error.UnsupportedFeature;
        try self.callFunction(function, argc);
    }

    /// Emit a call to a custom operator/Index implementation method.
    fn methodCall(self: *Builder, method: semantic.ImplMethod, argc: u16) Error!void {
        const methods = self.methods orelse return error.UnsupportedFeature;
        const function = try methods.ensure(method);
        try self.emit(.{ .call = .{ .function = function, .argc = argc } });
    }

    fn isStringType(self: *Builder, ty: *types.Type) bool {
        return self.resolvedType(ty).* == .string;
    }

    fn isScalarType(self: *Builder, ty: *types.Type) bool {
        return switch (self.resolvedType(ty).*) {
            .int, .float, .bool, .variable, .unknown => true,
            else => false,
        };
    }

    fn hasAggregateDecl(self: *Builder, name: []const u8) bool {
        if (self.structs.contains(name) or self.tables.contains(name) or self.enums.contains(name)) {
            return true;
        }
        // Qualified names may carry an enclosing module path; the declaration
        // tables are keyed by the unqualified type name.
        if (std.mem.lastIndexOf(u8, name, "::")) |index| {
            const last = name[index + 2 ..];
            return self.structs.contains(last) or self.tables.contains(last) or self.enums.contains(last);
        }
        return false;
    }

    /// True when values of `ty` are heap-allocated aggregate objects (structs,
    /// enums, tables, vectors, matrices, maps, strings) rather than i64 scalars.
    /// A local of such a type stores the object pointer, not the object itself.
    fn isAggregateType(self: *Builder, ty: *types.Type) bool {
        return switch (self.resolvedType(ty).*) {
            .string, .array, .map => true,
            .named => |named| self.hasAggregateDecl(named.name),
            else => false,
        };
    }

    /// Resolve through any number of reference layers so field/index/builtin
    /// lowering runs against the referenced aggregate.
    fn unwrapReferences(self: *Builder, ty: *types.Type) *types.Type {
        var resolved = self.resolvedType(ty);
        while (resolved.* == .reference) resolved = self.resolvedType(resolved.reference.child);
        return resolved;
    }

    fn exprType(self: *Builder, expr: *ast.Expr) ?*types.Type {
        return self.analysis.typeOf(expr);
    }

    fn resolvedType(self: *Builder, ty: *types.Type) *types.Type {
        return self.analysis.store.resolve(ty);
    }

    fn namedBase(self: *Builder, ty: *types.Type) ?types.Named {
        var resolved = self.resolvedType(ty);
        while (true) {
            switch (resolved.*) {
                .reference => |r| resolved = self.resolvedType(r.child),
                .box => |child| resolved = self.resolvedType(child),
                else => break,
            }
        }
        if (resolved.* == .named) return resolved.named;
        return null;
    }

    fn lastPathSegment(name: []const u8) []const u8 {
        var index = name.len;
        while (index > 0) : (index -= 1) {
            if (name[index - 1] == ':') return name[index..];
        }
        return name;
    }

    fn structFields(self: *Builder, name: []const u8) ?[]ast.Field {
        if (self.structs.get(name)) |decl| return decl.fields;
        if (self.tables.get(name)) |decl| return decl.fields;
        const short = lastPathSegment(name);
        if (!std.mem.eql(u8, short, name)) {
            if (self.structs.get(short)) |decl| return decl.fields;
            if (self.tables.get(short)) |decl| return decl.fields;
        }
        return null;
    }

    fn fieldOffset(self: *Builder, name: []const u8, field: []const u8, out: *usize) bool {
        const fields = self.structFields(name) orelse return false;
        for (fields, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate.name, field)) {
                out.* = i * 8;
                return true;
            }
        }
        return false;
    }

    fn lowerStructLiteral(self: *Builder, literal: ast.StructLiteral) Error!void {
        const name = literal.path.segments[literal.path.segments.len - 1].name;
        if (literal.path.segments.len >= 2) {
            if (self.enums.get(literal.path.segments[0].name)) |def| {
                const tag = enumTag(def, name) orelse return error.UnsupportedFeature;
                const variant = def.variants[tag];
                if (variant.payload != .struct_fields) return error.UnsupportedFeature;
                const fields = variant.payload.struct_fields;
                const temp = try self.allocLocal("<enum>");
                try self.push(@intCast(fields.len + 1));
                try self.emit(.alloc);
                try self.emit(.{ .store_local = temp });
                try self.emit(.{ .load_local = temp });
                try self.push(@intCast(tag));
                try self.emit(.store_mem);
                for (literal.fields) |field_init| {
                    var index: ?usize = null;
                    for (fields, 0..) |field, i| {
                        if (std.mem.eql(u8, field.name, field_init.name)) index = i;
                    }
                    const i = index orelse return error.UnsupportedFeature;
                    try self.emit(.{ .load_local = temp });
                    try self.push(@intCast(8 + i * 8));
                    try self.emit(.add);
                    try self.lowerExpr(field_init.value);
                    try self.emit(.store_mem);
                }
                try self.emit(.{ .load_local = temp });
                return;
            }
        }
        const fields = self.structFields(name) orelse return error.UnsupportedFeature;
        const temp = try self.allocLocal("<struct>");
        try self.push(@intCast(fields.len));
        try self.emit(.alloc);
        try self.emit(.{ .store_local = temp });
        for (literal.fields) |field_init| {
            var offset: usize = 0;
            if (!self.fieldOffset(name, field_init.name, &offset)) return error.UnsupportedFeature;
            try self.emit(.{ .load_local = temp });
            try self.push(@intCast(offset));
            try self.emit(.add);
            try self.lowerExpr(field_init.value);
            try self.emit(.store_mem);
        }
        try self.emit(.{ .load_local = temp });
    }

    fn lowerField(self: *Builder, field: ast.FieldAccess) Error!void {
        const target_ty = self.exprType(field.target) orelse return error.UnsupportedFeature;
        const named = self.namedBase(target_ty) orelse return error.UnsupportedFeature;
        var offset: usize = 0;
        if (!self.fieldOffset(named.name, field.name, &offset)) return error.UnsupportedFeature;
        try self.lowerExpr(field.target);
        try self.push(@intCast(offset));
        try self.emit(.add);
        try self.emit(.load_mem);
    }

    fn lowerMapLiteral(self: *Builder, literal: ast.MapLiteral, expr: *ast.Expr) Error!void {
        var string_keys = false;
        if (self.exprType(expr)) |ty| {
            if (self.resolvedType(ty).* == .map) {
                string_keys = self.isStringType(self.resolvedType(ty).map.key);
            }
        }
        const temp = try self.allocLocal("<map>");
        try self.emit(.map_new);
        try self.emit(.{ .store_local = temp });
        for (literal.entries) |entry| {
            try self.emit(.{ .load_local = temp });
            try self.lowerExpr(entry.key);
            try self.lowerExpr(entry.value);
            try self.emit(if (string_keys) .map_set_str else .map_set);
        }
        try self.emit(.{ .load_local = temp });
    }

    fn lowerList(self: *Builder, items: []*ast.Expr) Error!void {
        var matrix = items.len > 0;
        var columns: usize = 0;
        if (items.len > 0) {
            const first = items[0];
            if (first.* != .list) matrix = false;
            if (first.* == .list) columns = first.list.len;
            for (items) |item| {
                if (item.* != .list or item.list.len != columns) {
                    matrix = false;
                    break;
                }
            }
        }
        const rows = items.len;
        const temp = try self.allocLocal("<vec>");
        try self.push(@intCast(rows));
        try self.push(@intCast(if (matrix) columns else 0));
        try self.emit(.vec_new);
        try self.emit(.{ .store_local = temp });
        if (matrix) {
            for (items, 0..) |row_expr, row| {
                for (row_expr.list, 0..) |item, column| {
                    try self.emit(.{ .load_local = temp });
                    try self.push(@intCast(row * columns + column));
                    try self.lowerExpr(item);
                    try self.emit(.vec_set);
                }
            }
        } else {
            for (items, 0..) |item, index| {
                try self.emit(.{ .load_local = temp });
                try self.push(@intCast(index));
                try self.lowerExpr(item);
                try self.emit(.vec_set);
            }
        }
        try self.emit(.{ .load_local = temp });
    }

    fn lowerIndex(self: *Builder, index_expr: ast.Index) Error!void {
        const target_ty = self.exprType(index_expr.target) orelse return error.UnsupportedFeature;
        const resolved = self.unwrapReferences(target_ty);
        try self.lowerExpr(index_expr.target);
        for (index_expr.indices) |index| try self.lowerExpr(index);
        switch (resolved.*) {
            .array => |array| {
                if (array.columns != null) {
                    switch (index_expr.indices.len) {
                        1 => try self.emit(.vec_row),
                        2 => try self.emit(.vec_get2),
                        else => return error.UnsupportedFeature,
                    }
                } else {
                    if (index_expr.indices.len != 1) return error.UnsupportedFeature;
                    try self.emit(.vec_get);
                }
            },
            .map => |m| {
                if (index_expr.indices.len != 1) return error.UnsupportedFeature;
                try self.emit(if (self.isStringType(m.key)) .map_get_str else .map_get);
            },
            .raw_pointer => |pointee| {
                if (index_expr.indices.len != 1) return error.UnsupportedFeature;
                try self.push(self.rawPointeeSize(resolved));
                try self.emit(.mul);
                try self.emit(.add);
                try self.emitRawLoad(pointee);
            },
            .named => {
                if (index_expr.indices.len != 1) return error.UnsupportedFeature;
                const method = self.analysis.operatorMethod(resolved, "Index", "index") orelse
                    return error.UnsupportedFeature;
                try self.methodCall(method, 2);
            },
            else => return error.UnsupportedFeature,
        }
    }

    fn lowerAddress(self: *Builder, expr: *ast.Expr) Error!bool {
        switch (expr.*) {
            .path => |path| {
                if (path.segments.len != 1) return false;
                const slot = self.local(path.segments[0].name) orelse return false;
                try self.emit(.{ .local_addr = slot });
                return true;
            },
            .field => |field| {
                const target_ty = self.exprType(field.target) orelse return false;
                const named = self.namedBase(target_ty) orelse return false;
                var offset: usize = 0;
                if (!self.fieldOffset(named.name, field.name, &offset)) return false;
                try self.lowerExpr(field.target);
                try self.push(@intCast(offset));
                try self.emit(.add);
                return true;
            },
            .unary => |unary| {
                if (unary.op != .deref) return false;
                try self.lowerExpr(unary.operand);
                return true;
            },
            else => return false,
        }
    }

    /// Lower `&`/`&mut`.  A reference to a scalar is a pointer to that scalar's
    /// 8-byte storage slot; a reference to an aggregate aliases the aggregate
    /// object pointer, because the local already stores that pointer and the
    /// object is addressed through it everywhere.  This mirrors `lowerDeref`.
    fn lowerReference(self: *Builder, expr: *ast.Expr) Error!void {
        if (self.exprType(expr)) |ty| {
            if (self.isAggregateType(ty)) {
                if (!isPlaceSyntax(expr)) {
                    // Aggregate rvalue: alias the freshly produced object.
                    try self.lowerExpr(expr);
                    return;
                }
                // Only places that directly alias the aggregate object are
                // supported; vector/matrix element places are copies and raw
                // pointer derefs are slot addresses.
                if (!self.isAliasableAggregatePlace(expr)) return error.UnsupportedFeature;
                try self.lowerExpr(expr);
                return;
            }
        }
        if (try self.lowerAddress(expr)) return;
        // Place expressions we cannot address (vector/matrix elements) must not
        // silently fall back to a copy: a mutable borrow of one would mutate
        // the copy instead of the container.
        if (isPlaceSyntax(expr)) return error.UnsupportedFeature;
        // A non-place scalar rvalue has no slot of its own, so materialize one;
        // `&` always yields a pointer to an 8-byte slot.
        const slot = try self.allocLocal("<ref>");
        try self.lowerExpr(expr);
        try self.emit(.{ .store_local = slot });
        try self.emit(.{ .local_addr = slot });
    }

    fn isPlaceSyntax(expr: *const ast.Expr) bool {
        return switch (expr.*) {
            .path, .field, .index => true,
            .unary => |unary| unary.op == .deref,
            else => false,
        };
    }

    /// True for aggregate places whose value is the object pointer itself:
    /// locals/parameters, struct fields, and dereferences of references.
    fn isAliasableAggregatePlace(self: *Builder, expr: *const ast.Expr) bool {
        return switch (expr.*) {
            .path, .field => true,
            .unary => |unary| blk: {
                if (unary.op != .deref) break :blk false;
                const operand_ty = self.exprType(unary.operand) orelse break :blk false;
                break :blk self.resolvedType(operand_ty).* == .reference;
            },
            else => false,
        };
    }

    /// Lower `*expr`.  A reference to an aggregate aliases the object pointer,
    /// so dereferencing it is the identity; references to scalars, boxes, and
    /// raw pointers store a real pointer that must be loaded.  Custom `Deref`
    /// keeps applying to named values.
    fn lowerDeref(self: *Builder, unary: ast.Unary) Error!void {
        if (self.exprType(unary.operand)) |operand_ty| {
            switch (self.resolvedType(operand_ty).*) {
                .reference => |reference| {
                    if (self.isAggregateType(reference.child)) {
                        try self.lowerExpr(unary.operand);
                        return;
                    }
                },
                .named => {
                    if (self.analysis.operatorMethod(operand_ty, "Deref", "deref")) |method| {
                        try self.lowerExpr(unary.operand);
                        try self.methodCall(method, 1);
                        return;
                    }
                },
                .raw_pointer => |pointee| {
                    try self.lowerExpr(unary.operand);
                    return self.emitRawLoad(pointee);
                },
                else => {},
            }
        }
        try self.lowerExpr(unary.operand);
        try self.emit(.load_mem);
    }

    /// True for `*r` where `r` references an aggregate value.
    fn isAggregateDerefTarget(self: *Builder, target: *ast.Expr) bool {
        if (target.* != .unary or target.unary.op != .deref) return false;
        const operand_ty = self.exprType(target.unary.operand) orelse return false;
        const resolved = self.resolvedType(operand_ty);
        return resolved.* == .reference and self.isAggregateType(resolved.reference.child);
    }

    fn lowerBlockStatements(self: *Builder, block: *ast.Block) Error!void {
        try self.enterScope();
        defer self.leaveScope();
        for (block.entries) |entry| switch (entry) {
            .item => return error.UnsupportedFeature,
            .stmt => |stmt| try self.lowerStmt(stmt),
        };
    }

    fn lowerBlockValue(self: *Builder, block: *ast.Block) Error!void {
        try self.enterScope();
        defer self.leaveScope();
        if (block.entries.len == 0) return self.push(0);
        for (block.entries[0 .. block.entries.len - 1]) |entry| switch (entry) {
            .item => return error.UnsupportedFeature,
            .stmt => |stmt| try self.lowerStmt(stmt),
        };
        switch (block.entries[block.entries.len - 1]) {
            .item => return error.UnsupportedFeature,
            .stmt => |stmt| switch (stmt.*) {
                .expr => |expr| try self.lowerExpr(expr),
                else => {
                    try self.lowerStmt(stmt);
                    try self.push(0);
                },
            },
        }
    }

    fn lowerStmt(self: *Builder, stmt: *ast.Stmt) Error!void {
        switch (stmt.*) {
            .binding => |binding| {
                try self.lowerExpr(binding.value);
                const slot = try self.allocLocal(binding.name);
                try self.emit(.{ .store_local = slot });
            },
            .ret => |value| {
                if (value) |expr| {
                    try self.lowerExpr(expr);
                } else {
                    try self.push(0);
                }
                try self.emit(.ret);
            },
            .expr => |expr| {
                try self.lowerExpr(expr);
                try self.pop();
            },
            .assign => |assign| {
                const target = assign.target;
                if (target.* == .path and target.path.segments.len == 1) {
                    const slot = self.local(target.path.segments[0].name) orelse return error.UnknownLocal;
                    if (assign.op == .assign) {
                        try self.lowerExpr(assign.value);
                    } else {
                        try self.emit(.{ .load_local = slot });
                        try self.lowerExpr(assign.value);
                        try self.emit(switch (assign.op) {
                            .add => .add,
                            .sub => .sub,
                            .mul => .mul,
                            .div => .div,
                            .mod => .rem,
                            .assign => unreachable,
                        });
                    }
                    try self.emit(.{ .store_local = slot });
                } else if (target.* == .index) {
                    if (assign.op != .assign) return error.UnsupportedFeature;
                    const base_ty = self.exprType(target.index.target) orelse return error.UnsupportedFeature;
                    const resolved = self.unwrapReferences(base_ty);
                    const resolved_value = self.resolvedType(resolved);
                    if (resolved_value.* == .raw_pointer) {
                        // `p[i] = value`: store at `p + i * pointee stride` using
                        // the pointee's ABI width.
                        if (target.index.indices.len != 1) return error.UnsupportedFeature;
                        try self.lowerExpr(target.index.target);
                        try self.lowerExpr(target.index.indices[0]);
                        try self.push(self.rawPointeeSize(resolved));
                        try self.emit(.mul);
                        try self.emit(.add);
                        try self.lowerExpr(assign.value);
                        try self.emitRawStore(resolved_value.raw_pointer);
                        return;
                    }
                    try self.lowerExpr(target.index.target);
                    for (target.index.indices) |index| try self.lowerExpr(index);
                    try self.lowerExpr(assign.value);
                    switch (resolved.*) {
                        .array => |array| {
                            if (array.columns != null) {
                                switch (target.index.indices.len) {
                                    1 => try self.emit(.vec_set_row),
                                    2 => try self.emit(.vec_set2),
                                    else => return error.UnsupportedFeature,
                                }
                            } else {
                                if (target.index.indices.len != 1) return error.UnsupportedFeature;
                                try self.emit(.vec_set);
                            }
                        },
                        .map => |m| {
                            if (target.index.indices.len != 1) return error.UnsupportedFeature;
                            try self.emit(if (self.isStringType(m.key)) .map_set_str else .map_set);
                        },
                        else => return error.UnsupportedFeature,
                    }
                } else {
                    if (assign.op != .assign) return error.UnsupportedFeature;
                    // `*p = value` through a raw pointer stores with the
                    // pointee's ABI width (narrow C scalars) or the 8-byte slot.
                    if (target.* == .unary and target.unary.op == .deref) {
                        if (self.exprType(target.unary.operand)) |operand_ty| {
                            const resolved = self.resolvedType(operand_ty);
                            if (resolved.* == .raw_pointer) {
                                try self.lowerExpr(target.unary.operand);
                                try self.lowerExpr(assign.value);
                                try self.emitRawStore(resolved.raw_pointer);
                                return;
                            }
                        }
                    }
                    // Whole-value assignment through a reference to an
                    // aggregate cannot be represented: the reference aliases
                    // the object pointer, not the referent's storage slot.
                    // Field/index assignments through the reference still work.
                    if (self.isAggregateDerefTarget(target)) return error.UnsupportedFeature;
                    if (!try self.lowerAddress(target)) return error.UnsupportedFeature;
                    try self.lowerExpr(assign.value);
                    try self.emit(.store_mem);
                }
            },
            .while_stmt => |loop| {
                const start = self.code.items.len;
                try self.lowerExpr(loop.condition);
                const end_jump = try self.emitJump(true);
                try self.loops.append(self.allocator, .{ .breaks = .empty, .continues = .empty });
                const loop_index = self.loops.items.len - 1;
                defer _ = self.loops.pop();
                try self.lowerBlockStatements(loop.body);
                try self.emit(.{ .jump = @intCast(start) });
                try self.patchLoop(&self.loops.items[loop_index], start, self.code.items.len);
                try self.patch(end_jump);
            },
            .loop_stmt => |loop| {
                const start = self.code.items.len;
                try self.loops.append(self.allocator, .{ .breaks = .empty, .continues = .empty });
                const loop_index = self.loops.items.len - 1;
                defer _ = self.loops.pop();
                try self.lowerBlockStatements(loop.body);
                try self.emit(.{ .jump = @intCast(start) });
                try self.patchLoop(&self.loops.items[loop_index], start, self.code.items.len);
            },
            .break_stmt => {
                if (self.loops.items.len == 0) return error.UnsupportedFeature;
                const index = try self.emitJump(false);
                try self.loops.items[self.loops.items.len - 1].breaks.append(self.allocator, index);
            },
            .cont => {
                if (self.loops.items.len == 0) return error.UnsupportedFeature;
                const index = try self.emitJump(false);
                try self.loops.items[self.loops.items.len - 1].continues.append(self.allocator, index);
            },
            .for_stmt => |loop| try self.lowerFor(loop),
            .unsafe_block => |block| try self.lowerBlockStatements(block),
            .uninitialized => |decl| {
                _ = try self.allocLocal(decl.name);
            },
            // `disown commands` releases the caller's claim and flushes the
            // deferred command buffer so world mutations become visible.
            .disown => |expr| {
                if (expr.* == .unary and (expr.unary.op == .borrow_shared or expr.unary.op == .borrow_mut)) {
                    try self.lowerExpr(expr.unary.operand);
                } else {
                    try self.lowerExpr(expr);
                }
                try self.runtimeCall(.ecs_commands_flush, 1);
                try self.pop();
            },
        }
    }

    fn patchLoop(self: *Builder, context: *LoopCtx, continue_target: usize, break_target: usize) Error!void {
        for (context.breaks.items) |index| {
            self.code.items[index] = .{ .jump = @intCast(break_target) };
        }
        for (context.continues.items) |index| {
            self.code.items[index] = .{ .jump = @intCast(continue_target) };
        }
        context.breaks.deinit(self.allocator);
        context.continues.deinit(self.allocator);
    }

    fn lowerFor(self: *Builder, loop: ast.ForStmt) Error!void {
        try self.enterScope();
        defer self.leaveScope();
        if (loop.iterable.* == .range) return self.lowerForRange(loop);

        const iterable_ty = self.exprType(loop.iterable) orelse return error.UnsupportedFeature;
        const resolved = self.resolvedType(iterable_ty);
        switch (resolved.*) {
            .query => try self.lowerForQuery(loop),
            .array => |array| {
                // Iteration walks the flat element list; matrices do not have a
                // meaningful single-index layout for that, so reject them
                // rather than silently iterating only their rows.
                if (array.columns != null) return error.UnsupportedFeature;
                try self.lowerForCollection(loop, .vector);
            },
            .string => try self.lowerForCollection(loop, .string),
            .map => try self.lowerForCollection(loop, .map),
            else => return error.UnsupportedFeature,
        }
    }

    /// Iterate an ECS query handle: `e7_ecs_query_next` drives the loop and
    /// `e7_ecs_query_component(query, index)` binds each projected component
    /// pointer into a local.  Aggregate component pointers are exactly the
    /// reference representation used elsewhere, so field/index assignment
    /// through a `&mut` projection reuses the ordinary reference lowering.
    fn lowerForQuery(self: *Builder, loop: ast.ForStmt) Error!void {
        const pattern = loop.pattern;
        const pair = pattern.* == .tuple;
        if (!pair and pattern.* != .binding and pattern.* != .wildcard) return error.UnsupportedFeature;
        const projection_count: usize = if (pair) pattern.tuple.len else 1;

        try self.enterScope();
        defer self.leaveScope();

        var binding_slots = try self.allocator.alloc(?u16, projection_count);
        defer self.allocator.free(binding_slots);
        if (pair) {
            for (pattern.tuple, 0..) |item, index| {
                binding_slots[index] = try self.forPatternSlot(item);
            }
        } else {
            binding_slots[0] = try self.forPatternSlot(pattern);
        }

        const handle_slot = try self.allocLocal("<query>");
        const row_slot = try self.allocLocal("<query_row>");
        try self.lowerExpr(loop.iterable);
        try self.emit(.{ .store_local = handle_slot });

        const start = self.code.items.len;
        try self.loops.append(self.allocator, .{ .breaks = .empty, .continues = .empty });
        const loop_index = self.loops.items.len - 1;
        defer _ = self.loops.pop();

        try self.emit(.{ .load_local = handle_slot });
        try self.runtimeCall(.ecs_query_next, 1);
        try self.emit(.{ .store_local = row_slot });
        // `query_next` returns entity_id + 1, or 0 when exhausted.
        // `jump_if_false` branches to its target when the value is zero.
        try self.emit(.{ .load_local = row_slot });
        const end_jump = try self.emitJump(true);

        for (binding_slots, 0..) |slot, index| {
            const target = slot orelse continue;
            try self.emit(.{ .load_local = handle_slot });
            try self.push(@intCast(index));
            try self.runtimeCall(.ecs_query_component, 2);
            try self.emit(.{ .store_local = target });
        }

        try self.lowerBlockStatements(loop.body);
        try self.emit(.{ .jump = @intCast(start) });

        const break_target = self.code.items.len;
        try self.patchLoop(&self.loops.items[loop_index], start, break_target);
        try self.patch(end_jump);
        // Query handles are snapshots; the runtime releases the handle when
        // `query_next` reaches the end, so no explicit release is emitted.
    }

    fn lowerForRange(self: *Builder, loop: ast.ForStmt) Error!void {
        if (loop.pattern.* != .binding and loop.pattern.* != .wildcard) return error.UnsupportedFeature;
        const slot = if (loop.pattern.* == .binding)
            try self.allocLocal(loop.pattern.binding)
        else
            try self.allocLocal("<for>");
        const hidden = try self.allocLocal("<for_end>");

        const range = loop.iterable.range;
        if (range.end == null) return error.UnsupportedFeature;
        if (range.start) |start_expr| try self.lowerExpr(start_expr) else try self.push(0);
        try self.emit(.{ .store_local = slot });
        try self.lowerExpr(range.end.?);
        try self.emit(.{ .store_local = hidden });

        const start = self.code.items.len;
        try self.loops.append(self.allocator, .{ .breaks = .empty, .continues = .empty });
        const loop_index = self.loops.items.len - 1;
        defer _ = self.loops.pop();

        try self.emit(.{ .load_local = slot });
        try self.emit(.{ .load_local = hidden });
        try self.emit(if (range.inclusive) .le else .lt);
        const end_jump = try self.emitJump(true);

        try self.lowerBlockStatements(loop.body);

        const increment_target = self.code.items.len;
        try self.emit(.{ .load_local = slot });
        try self.push(1);
        try self.emit(.add);
        try self.emit(.{ .store_local = slot });
        try self.emit(.{ .jump = @intCast(start) });

        const break_target = self.code.items.len;
        try self.patchLoop(&self.loops.items[loop_index], increment_target, break_target);
        try self.patch(end_jump);
    }

    const CollectionKind = enum { vector, string, map };

    /// Allocate a binding slot for one `for` pattern element, or null for `_`.
    fn forPatternSlot(self: *Builder, pattern: *ast.Pattern) Error!?u16 {
        return switch (pattern.*) {
            .binding => |name| try self.allocLocal(name),
            .wildcard => null,
            else => error.UnsupportedFeature,
        };
    }

    fn emitContainerLen(self: *Builder, kind: CollectionKind) Error!void {
        try self.emit(switch (kind) {
            .vector => .vec_len,
            .string => .str_len,
            .map => .map_len,
        });
    }

    /// Iterate vectors, strings, and maps.  A tuple pattern binds
    /// `(index, value)` for vectors/strings and `(key, value)` for maps; a bare
    /// binding binds the element, the character, or the map key.
    fn lowerForCollection(self: *Builder, loop: ast.ForStmt, kind: CollectionKind) Error!void {
        const pattern = loop.pattern;
        const pair = pattern.* == .tuple;
        if (pair and pattern.tuple.len != 2) return error.UnsupportedFeature;
        if (!pair and pattern.* != .binding and pattern.* != .wildcard) return error.UnsupportedFeature;

        var first_slot: ?u16 = null;
        var second_slot: ?u16 = null;
        if (pair) {
            first_slot = try self.forPatternSlot(pattern.tuple[0]);
            second_slot = try self.forPatternSlot(pattern.tuple[1]);
        } else if (pattern.* == .binding) {
            first_slot = try self.forPatternSlot(pattern);
        }

        const iterable_slot = try self.allocLocal("<for_iter>");
        const length_slot = try self.allocLocal("<for_len>");
        const index_slot = try self.allocLocal("<for_index>");

        try self.lowerExpr(loop.iterable);
        try self.emit(.{ .store_local = iterable_slot });
        try self.emit(.{ .load_local = iterable_slot });
        try self.emitContainerLen(kind);
        try self.emit(.{ .store_local = length_slot });
        try self.push(0);
        try self.emit(.{ .store_local = index_slot });

        const start = self.code.items.len;
        try self.loops.append(self.allocator, .{ .breaks = .empty, .continues = .empty });
        const loop_index = self.loops.items.len - 1;
        defer _ = self.loops.pop();

        try self.emit(.{ .load_local = index_slot });
        try self.emit(.{ .load_local = length_slot });
        try self.emit(.lt);
        const end_jump = try self.emitJump(true);

        if (pair) {
            switch (kind) {
                .map => {
                    if (first_slot) |slot| {
                        try self.emit(.{ .load_local = iterable_slot });
                        try self.emit(.{ .load_local = index_slot });
                        try self.emit(.map_key_at);
                        try self.emit(.{ .store_local = slot });
                    }
                    if (second_slot) |slot| {
                        try self.emit(.{ .load_local = iterable_slot });
                        try self.emit(.{ .load_local = index_slot });
                        try self.emit(.map_value_at);
                        try self.emit(.{ .store_local = slot });
                    }
                },
                .vector => {
                    if (first_slot) |slot| {
                        try self.emit(.{ .load_local = index_slot });
                        try self.emit(.{ .store_local = slot });
                    }
                    if (second_slot) |slot| {
                        try self.emit(.{ .load_local = iterable_slot });
                        try self.emit(.{ .load_local = index_slot });
                        try self.emit(.vec_get);
                        try self.emit(.{ .store_local = slot });
                    }
                },
                .string => {
                    if (first_slot) |slot| {
                        try self.emit(.{ .load_local = index_slot });
                        try self.emit(.{ .store_local = slot });
                    }
                    if (second_slot) |slot| {
                        try self.emit(.{ .load_local = iterable_slot });
                        try self.emit(.{ .load_local = index_slot });
                        try self.emit(.str_char_at);
                        try self.emit(.{ .store_local = slot });
                    }
                },
            }
        } else if (first_slot) |slot| {
            try self.emit(.{ .load_local = iterable_slot });
            try self.emit(.{ .load_local = index_slot });
            try self.emit(switch (kind) {
                .vector => .vec_get,
                .string => .str_char_at,
                .map => .map_key_at,
            });
            try self.emit(.{ .store_local = slot });
        }

        try self.lowerBlockStatements(loop.body);

        const increment_target = self.code.items.len;
        try self.emit(.{ .load_local = index_slot });
        try self.push(1);
        try self.emit(.add);
        try self.emit(.{ .store_local = index_slot });
        try self.emit(.{ .jump = @intCast(start) });

        const break_target = self.code.items.len;
        try self.patchLoop(&self.loops.items[loop_index], increment_target, break_target);
        try self.patch(end_jump);
    }

    fn lowerExpr(self: *Builder, expr: *ast.Expr) Error!void {
        switch (expr.*) {
            .int => |value| try self.push(value),
            .boolean => |value| try self.push(if (value) 1 else 0),
            .nil => try self.push(0),
            .path => |path| {
                if (path.segments.len == 1) {
                    if (self.local(path.segments[0].name)) |slot| {
                        try self.emit(.{ .load_local = slot });
                        return;
                    }
                }
                if (path.segments.len >= 2) {
                    if (self.enums.get(path.segments[0].name)) |def| {
                        // Value form of a tuple enum variant: tag-only aggregate
                        // (payload construction goes through the call form).
                        const variant_name = path.segments[path.segments.len - 1].name;
                        const tag = enumTag(def, variant_name) orelse return error.UnsupportedFeature;
                        // Value form is the tag-only aggregate (one slot);
                        // payload construction uses the call form.
                        const temp = try self.allocLocal("<enum>");
                        try self.push(1);
                        try self.emit(.alloc);
                        try self.emit(.{ .store_local = temp });
                        try self.emit(.{ .load_local = temp });
                        try self.push(@intCast(tag));
                        try self.emit(.store_mem);
                        try self.emit(.{ .load_local = temp });
                        return;
                    }
                }
                // First-class function value: a bare top-level/module function
                // name pushes its stable bytecode index.
                if (self.isFunctionValueExpr(expr)) {
                    try self.lowerFunctionRef(path);
                    return;
                }
                if (path.segments.len >= 2) return error.UnsupportedFeature;
                // Unit-struct constructor shorthand: `mesh := CubeMesh`.
                // A zero-field struct/table value is an empty aggregate.
                if (self.exprType(expr)) |ty| {
                    if (self.namedBase(ty)) |named| {
                        if (self.structFields(named.name)) |fields| {
                            if (fields.len == 0) {
                                try self.push(0);
                                try self.emit(.alloc);
                                return;
                            }
                        }
                    }
                }
                return error.UnsupportedFeature;
            },
            .string => |text| try self.emit(.{ .string_lit = text }),
            .struct_literal => |literal| try self.lowerStructLiteral(literal),
            .map_literal => |literal| try self.lowerMapLiteral(literal, expr),
            .list => |items| try self.lowerList(items),
            .field => |field| try self.lowerField(field),
            .index => |index_expr| try self.lowerIndex(index_expr),
            .block => |block| try self.lowerBlockValue(block),
            .if_expr => |if_expr| try self.lowerIf(if_expr),
            .match_expr => |match_expr| try self.lowerMatch(match_expr),
            .prefix => |prefix_expr| try self.lowerPrefix(prefix_expr),
            .unary => |unary| {
                switch (unary.op) {
                    .negative => {
                        if (self.exprType(unary.operand)) |operand_ty| {
                            if (self.numericClass(operand_ty) == .float) {
                                try self.lowerExpr(unary.operand);
                                try self.runtimeCall(.float_neg, 1);
                                return;
                            }
                            if (self.analysis.operatorMethod(operand_ty, "Neg", "neg")) |method| {
                                try self.lowerExpr(unary.operand);
                                try self.methodCall(method, 1);
                                return;
                            }
                        }
                        try self.lowerExpr(unary.operand);
                        try self.emit(.neg);
                    },
                    .not => {
                        try self.lowerExpr(unary.operand);
                        try self.emit(.not);
                    },
                    .borrow_shared, .borrow_mut => try self.lowerReference(unary.operand),
                    .deref => try self.lowerDeref(unary),
                }
            },
            .binary => |binary| try self.lowerBinary(binary),
            .cast => |cast| try self.lowerCast(cast, expr),
            .call => |call| try self.lowerCall(call, expr),
            .try_expr => |inner| {
                try self.lowerExpr(inner);
                const slot = try self.allocLocal("<try>");
                try self.emit(.{ .store_local = slot });
                const inner_ty = self.resolvedType(self.exprType(inner) orelse return error.UnsupportedFeature);
                const is_optional = inner_ty.* == .optional;
                const failure: i64 = if (is_optional) 0 else std.math.minInt(i64);
                try self.emit(.{ .load_local = slot });
                try self.push(failure);
                try self.emit(.eq);
                const ok_jump = try self.emitJump(true);
                try self.push(failure);
                try self.emit(.ret);
                try self.patch(ok_jump);
                try self.emit(.{ .load_local = slot });
                if (is_optional) switch (self.resolvedType(inner_ty.optional).*) {
                    .bool, .int, .float => try self.emit(.load_mem),
                    else => {},
                };
            },
            // Floats are stored as their f64 bit pattern in the uniform i64
            // slot representation; arithmetic/comparisons use the e7_f32_*
            // runtime helpers.
            .float => |value| try self.push(@bitCast(value)),
            .range, .error_literal, .function => {
                return error.UnsupportedFeature;
            },
            // ECS front-end constructs: execution/lowering is owned by the
            // later Commands/plugin ECS task.
            .query, .row_literal => return error.UnsupportedFeature,
        }
    }

    fn lowerPrefix(self: *Builder, prefix_expr: ast.Prefix) Error!void {
        switch (prefix_expr.op) {
            .await_ => {
                if (prefix_expr.operand.* == .query) {
                    try self.lowerQueryLease(prefix_expr.operand.query);
                    return;
                }
                try self.lowerExpr(prefix_expr.operand);
                try self.emit(.task_await);
            },
            .spawn => {
                try self.lowerExpr(prefix_expr.operand);
                try self.emit(.task_spawn);
            },
            .detach => {
                try self.lowerExpr(prefix_expr.operand);
                try self.emit(.task_detach);
                try self.push(0);
            },
            .cancel => {
                if (prefix_expr.operand.* == .unary) {
                    const unary = prefix_expr.operand.unary;
                    if (unary.op == .borrow_mut and unary.operand.* == .path and unary.operand.path.segments.len == 1) {
                        const slot = self.local(unary.operand.path.segments[0].name) orelse return error.UnknownLocal;
                        try self.emit(.{ .load_local = slot });
                    } else {
                        return error.UnsupportedFeature;
                    }
                } else {
                    try self.lowerExpr(prefix_expr.operand);
                }
                try self.emit(.task_cancel);
                try self.push(0);
            },
        }
    }

    const NumericClass = enum { integer, float, other };

    /// Unresolved numeric literals are type variables carrying an integer or
    /// float kind; classify them without forcing a concrete type.
    fn numericClass(self: *Builder, ty: *types.Type) NumericClass {
        var current = self.resolvedType(ty);
        while (current.* == .variable) {
            const variable = current.variable;
            if (variable.binding) |binding| {
                current = self.resolvedType(binding);
                continue;
            }
            return switch (variable.kind) {
                .float => .float,
                .integer => .integer,
                .any => .other,
            };
        }
        return switch (current.*) {
            .float => .float,
            .int, .bool => .integer,
            else => .other,
        };
    }

    fn isIntegerLike(self: *Builder, ty: *types.Type) bool {
        return self.numericClass(ty) == .integer;
    }

    /// Float binary operators lower to the `e7_f32_*` runtime helpers.  Both
    /// operands are f64 bit patterns in i64 slots; comparisons return 0/1.
    fn lowerFloatBinary(self: *Builder, binary: ast.Binary) Error!void {
        try self.lowerExpr(binary.lhs);
        try self.lowerExpr(binary.rhs);
        const runtime_function: bytecode.RuntimeFunction = switch (binary.op) {
            .add => .float_add,
            .sub => .float_sub,
            .mul => .float_mul,
            .div => .float_div,
            .eq => .float_eq,
            .ne => .float_ne,
            .lt => .float_lt,
            .le => .float_le,
            .gt => .float_gt,
            .ge => .float_ge,
            .mod, .xor_, .and_, .or_ => return error.UnsupportedFeature,
        };
        try self.runtimeCall(runtime_function, 2);
    }

    /// `as` casts: float<->float is a bit-copy, int<->float converts through the
    /// runtime helpers, and other casts preserve the previous bit-copy behavior.
    fn lowerCast(self: *Builder, cast: ast.Cast, expr: *ast.Expr) Error!void {
        const target_ty = self.exprType(expr) orelse return error.UnsupportedFeature;
        const source_ty = self.exprType(cast.expr) orelse return error.UnsupportedFeature;
        const target_class = self.numericClass(target_ty);
        const source_class = self.numericClass(source_ty);
        try self.lowerExpr(cast.expr);
        if (source_class == .float and target_class == .float) return;
        if (source_class == .float and target_class == .integer) {
            try self.runtimeCall(.float_to_i64, 1);
            return;
        }
        if (source_class == .integer and target_class == .float) {
            try self.runtimeCall(.float_from_i64, 1);
            return;
        }
        // Integer<->integer and other casts keep their existing bit-copy
        // semantics.
    }

    fn lowerBinary(self: *Builder, binary: ast.Binary) Error!void {
        if (binary.op != .and_ and binary.op != .or_) {
            const left_ty = self.exprType(binary.lhs) orelse return error.UnsupportedFeature;
            const right_ty = self.exprType(binary.rhs) orelse return error.UnsupportedFeature;
            if (self.numericClass(left_ty) == .float or self.numericClass(right_ty) == .float) {
                try self.lowerFloatBinary(binary);
                return;
            }
        }
        switch (binary.op) {
            .and_ => {
                try self.lowerExpr(binary.lhs);
                const false_jump = try self.emitJump(true);
                try self.lowerExpr(binary.rhs);
                const end_jump = try self.emitJump(false);
                try self.patch(false_jump);
                try self.push(0);
                try self.patch(end_jump);
                return;
            },
            .or_ => {
                try self.lowerExpr(binary.lhs);
                const eval_rhs = try self.emitJump(true);
                try self.push(1);
                const end_jump = try self.emitJump(false);
                try self.patch(eval_rhs);
                try self.lowerExpr(binary.rhs);
                try self.patch(end_jump);
                return;
            },
            else => {},
        }

        if (try self.lowerCustomBinary(binary)) return;

        const left_ty = self.exprType(binary.lhs);
        const right_ty = self.exprType(binary.rhs);
        if (left_ty != null and right_ty != null) {
            const l = self.resolvedType(left_ty.?);
            const r = self.resolvedType(right_ty.?);
            if (l.* == .string and r.* == .string) {
                try self.lowerExpr(binary.lhs);
                try self.lowerExpr(binary.rhs);
                switch (binary.op) {
                    .add => try self.emit(.str_concat),
                    .eq, .ne => {
                        try self.emit(.str_eq);
                        if (binary.op == .ne) try self.emit(.not);
                    },
                    else => return error.UnsupportedFeature,
                }
                return;
            }
            if (l.* == .raw_pointer and self.isScalarType(r)) {
                try self.lowerExpr(binary.lhs);
                try self.lowerExpr(binary.rhs);
                try self.push(self.rawPointeeSize(l));
                try self.emit(.mul);
                try self.emit(if (binary.op == .sub) .sub else .add);
                return;
            }
            if (r.* == .raw_pointer and self.isScalarType(l)) {
                try self.lowerExpr(binary.lhs);
                try self.lowerExpr(binary.rhs);
                try self.push(self.rawPointeeSize(r));
                try self.emit(.mul);
                try self.emit(.add);
                return;
            }
            const op_code: ?u8 = switch (binary.op) {
                .add => 0,
                .sub => 1,
                .mul => 2,
                .div => 3,
                else => null,
            };
            if (l.* == .array and r.* == .array) {
                try self.lowerExpr(binary.lhs);
                try self.lowerExpr(binary.rhs);
                try self.emit(.{ .vec_binary = op_code orelse return error.UnsupportedFeature });
                return;
            }
            if (l.* == .array and self.isScalarType(r)) {
                try self.lowerExpr(binary.lhs);
                try self.lowerExpr(binary.rhs);
                try self.emit(.{ .vec_scalar = op_code orelse return error.UnsupportedFeature });
                return;
            }
            if (r.* == .array and self.isScalarType(l)) {
                try self.lowerExpr(binary.lhs);
                try self.lowerExpr(binary.rhs);
                try self.emit(.{ .vec_scalar = (op_code orelse return error.UnsupportedFeature) | 0x80 });
                return;
            }
        }

        try self.lowerExpr(binary.lhs);
        try self.lowerExpr(binary.rhs);
        try self.emit(switch (binary.op) {
            .xor_ => .ne,
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .mod => .rem,
            .and_, .or_ => unreachable,
        });
    }

    /// Lower a binary operator that a named type implements through a custom
    /// operator trait.  Returns false when the operands are not custom
    /// operators, leaving built-in lowering untouched.
    fn lowerCustomBinary(self: *Builder, binary: ast.Binary) Error!bool {
        const left_ty = self.exprType(binary.lhs) orelse return false;
        switch (binary.op) {
            .add, .sub, .mul, .div => {
                const trait_name: []const u8 = switch (binary.op) {
                    .add => "Add",
                    .sub => "Sub",
                    .mul => "Mul",
                    .div => "Div",
                    else => unreachable,
                };
                const method_name: []const u8 = switch (binary.op) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "mul",
                    .div => "div",
                    else => unreachable,
                };
                if (self.analysis.operatorMethod(left_ty, trait_name, method_name)) |method| {
                    try self.lowerExpr(binary.lhs);
                    try self.lowerExpr(binary.rhs);
                    try self.methodCall(method, 2);
                    return true;
                }
                // The analyzer accepted a custom impl but no usable method
                // exists; refuse to silently fall back to scalar arithmetic.
                if (self.analysis.implementsTrait(left_ty, trait_name)) return error.UnsupportedFeature;
                return false;
            },
            .eq, .ne => {
                const method = self.analysis.operatorMethod(left_ty, "PartialEq", "eq") orelse {
                    if (self.analysis.implementsTrait(left_ty, "PartialEq")) return error.UnsupportedFeature;
                    return false;
                };
                try self.lowerExpr(binary.lhs);
                try self.lowerExpr(binary.rhs);
                try self.methodCall(method, 2);
                if (binary.op == .ne) try self.emit(.not);
                return true;
            },
            .lt, .le, .gt, .ge => {
                if (!self.analysis.implementsTrait(left_ty, "PartialOrd")) return false;
                return self.lowerCustomComparison(binary, left_ty);
            },
            else => return false,
        }
    }

    const ComparisonPlan = struct {
        method: []const u8,
        swap: bool = false,
        negate: bool = false,
    };

    fn lowerCustomComparison(self: *Builder, binary: ast.Binary, left_ty: *types.Type) Error!bool {
        const plans: []const ComparisonPlan = switch (binary.op) {
            .lt => &[_]ComparisonPlan{.{ .method = "lt" }},
            .le => &[_]ComparisonPlan{
                .{ .method = "le" },
                .{ .method = "lt", .swap = true, .negate = true },
            },
            .gt => &[_]ComparisonPlan{
                .{ .method = "gt" },
                .{ .method = "lt", .swap = true },
            },
            .ge => &[_]ComparisonPlan{
                .{ .method = "ge" },
                .{ .method = "le", .swap = true },
                .{ .method = "lt", .negate = true },
            },
            else => return false,
        };
        for (plans) |plan| {
            const method = self.analysis.operatorMethod(left_ty, "PartialOrd", plan.method) orelse continue;
            if (plan.swap) {
                // Evaluate operands left-to-right, then pass them reversed to
                // the method (e.g. `a > b` -> `lt(b, a)`).
                const lhs_slot = try self.allocLocal("<cmp_lhs>");
                try self.lowerExpr(binary.lhs);
                try self.emit(.{ .store_local = lhs_slot });
                const rhs_slot = try self.allocLocal("<cmp_rhs>");
                try self.lowerExpr(binary.rhs);
                try self.emit(.{ .store_local = rhs_slot });
                try self.emit(.{ .load_local = rhs_slot });
                try self.emit(.{ .load_local = lhs_slot });
            } else {
                try self.lowerExpr(binary.lhs);
                try self.lowerExpr(binary.rhs);
            }
            try self.methodCall(method, 2);
            if (plan.negate) try self.emit(.not);
            return true;
        }
        // PartialOrd is implemented but exposes none of the comparison methods
        // lowering can use (e.g. only `eq`): report instead of comparing pointers.
        return error.UnsupportedFeature;
    }

    fn lowerIf(self: *Builder, if_expr: ast.IfExpr) Error!void {
        var end_jumps = std.ArrayList(usize).empty;
        defer end_jumps.deinit(self.allocator);
        for (if_expr.branches) |branch| {
            try self.lowerExpr(branch.condition);
            const next_jump = try self.emitJump(true);
            try self.lowerBlockValue(branch.body);
            try end_jumps.append(self.allocator, try self.emitJump(false));
            try self.patch(next_jump);
        }
        if (if_expr.else_body) |body| {
            try self.lowerBlockValue(body);
        } else {
            try self.push(0);
        }
        for (end_jumps.items) |index| try self.patch(index);
    }

    /// Look up an enum declaration by type name.  Project modules may carry a
    /// qualified name (`scene::document::ShapeKind`); the declaration tables are
    /// keyed by the unqualified identifier.
    fn enumDeclFor(self: *Builder, name: []const u8) ?*const ast.EnumDecl {
        if (self.enums.get(name)) |def| return def;
        if (std.mem.lastIndexOf(u8, name, "::")) |index| {
            if (self.enums.get(name[index + 2 ..])) |def| return def;
        }
        return null;
    }

    fn enumTag(def: *const ast.EnumDecl, name: []const u8) ?usize {
        for (def.variants, 0..) |variant, i| {
            if (std.mem.eql(u8, variant.name, name)) return i;
        }
        return null;
    }

    fn lowerEnumMatch(self: *Builder, match_expr: ast.MatchExpr, def: *const ast.EnumDecl, temp: u16) Error!void {
        var end_jumps = std.ArrayList(usize).empty;
        defer end_jumps.deinit(self.allocator);
        var has_default = false;
        for (match_expr.arms) |arm| {
            if (arm.guard != null) return error.UnsupportedFeature;
            try self.enterScope();
            defer self.leaveScope();
            var next_jump: ?usize = null;
            switch (arm.pattern.*) {
                .wildcard => has_default = true,
                .binding => |name| {
                    const slot = try self.allocLocal(name);
                    try self.emit(.{ .load_local = temp });
                    try self.emit(.{ .store_local = slot });
                    has_default = true;
                },
                .path => |path| {
                    const variant_name = path.segments[path.segments.len - 1].name;
                    const tag = enumTag(def, variant_name) orelse return error.UnsupportedFeature;
                    try self.emit(.{ .load_local = temp });
                    try self.emit(.load_mem);
                    try self.push(@intCast(tag));
                    try self.emit(.eq);
                    next_jump = try self.emitJump(true);
                },
                .tuple_struct => |tuple| {
                    const variant_name = tuple.path.segments[tuple.path.segments.len - 1].name;
                    const tag = enumTag(def, variant_name) orelse return error.UnsupportedFeature;
                    const variant = def.variants[tag];
                    if (variant.payload != .tuple) return error.UnsupportedFeature;
                    try self.emit(.{ .load_local = temp });
                    try self.emit(.load_mem);
                    try self.push(@intCast(tag));
                    try self.emit(.eq);
                    next_jump = try self.emitJump(true);
                    for (tuple.items, 0..) |element, i| {
                        if (element.* == .wildcard) continue;
                        if (element.* != .binding) return error.UnsupportedFeature;
                        const slot = try self.allocLocal(element.binding);
                        try self.emit(.{ .load_local = temp });
                        try self.push(@intCast(8 + i * 8));
                        try self.emit(.add);
                        try self.emit(.load_mem);
                        try self.emit(.{ .store_local = slot });
                    }
                },
                .struct_pattern => |pattern| {
                    const variant_name = pattern.path.segments[pattern.path.segments.len - 1].name;
                    const tag = enumTag(def, variant_name) orelse return error.UnsupportedFeature;
                    const variant = def.variants[tag];
                    if (variant.payload != .struct_fields) return error.UnsupportedFeature;
                    try self.emit(.{ .load_local = temp });
                    try self.emit(.load_mem);
                    try self.push(@intCast(tag));
                    try self.emit(.eq);
                    next_jump = try self.emitJump(true);
                    for (pattern.fields) |field_pattern| {
                        var index: ?usize = null;
                        for (variant.payload.struct_fields, 0..) |field, i| {
                            if (std.mem.eql(u8, field.name, field_pattern.name)) index = i;
                        }
                        const i = index orelse return error.UnsupportedFeature;
                        const sub = field_pattern.pattern orelse {
                            const slot = try self.allocLocal(field_pattern.name);
                            try self.emit(.{ .load_local = temp });
                            try self.push(@intCast(8 + i * 8));
                            try self.emit(.add);
                            try self.emit(.load_mem);
                            try self.emit(.{ .store_local = slot });
                            continue;
                        };
                        if (sub.* != .binding) return error.UnsupportedFeature;
                        const slot = try self.allocLocal(sub.binding);
                        try self.emit(.{ .load_local = temp });
                        try self.push(@intCast(8 + i * 8));
                        try self.emit(.add);
                        try self.emit(.load_mem);
                        try self.emit(.{ .store_local = slot });
                    }
                },
                else => return error.UnsupportedFeature,
            }
            try self.lowerBlockValue(arm.body);
            try end_jumps.append(self.allocator, try self.emitJump(false));
            if (next_jump) |index| try self.patch(index);
            if (has_default) break;
        }
        if (!has_default) try self.push(0);
        for (end_jumps.items) |index| try self.patch(index);
    }

    fn lowerMatch(self: *Builder, match_expr: ast.MatchExpr) Error!void {
        const scrutinee_ty = self.exprType(match_expr.scrutinee);
        if (scrutinee_ty) |ty| {
            if (self.namedBase(ty)) |named| {
                if (self.enumDeclFor(named.name)) |def| {
                    const temp = try self.allocLocal("<match>");
                    try self.lowerExpr(match_expr.scrutinee);
                    try self.emit(.{ .store_local = temp });
                    try self.lowerEnumMatch(match_expr, def, temp);
                    return;
                }
            }
        }
        if (match_expr.arms.len == 0) return error.UnsupportedFeature;
        const temp = try self.allocLocal("<match>");
        try self.lowerExpr(match_expr.scrutinee);
        try self.emit(.{ .store_local = temp });
        var end_jumps = std.ArrayList(usize).empty;
        defer end_jumps.deinit(self.allocator);
        var has_default = false;
        for (match_expr.arms) |arm| {
            if (arm.guard != null) return error.UnsupportedFeature;
            try self.enterScope();
            defer self.leaveScope();
            const pattern = arm.pattern.*;
            var next_jump: ?usize = null;
            switch (pattern) {
                .wildcard => {
                    has_default = true;
                },
                .binding => |name| {
                    const slot = try self.allocLocal(name);
                    try self.emit(.{ .load_local = temp });
                    try self.emit(.{ .store_local = slot });
                    has_default = true;
                },
                .literal => |literal| {
                    const value: i64 = switch (literal) {
                        .int => |v| v,
                        .boolean => |v| if (v) 1 else 0,
                        else => return error.UnsupportedFeature,
                    };
                    try self.emit(.{ .load_local = temp });
                    try self.push(value);
                    try self.emit(.eq);
                    next_jump = try self.emitJump(true);
                },
                else => return error.UnsupportedFeature,
            }
            try self.lowerBlockValue(arm.body);
            try end_jumps.append(self.allocator, try self.emitJump(false));
            if (next_jump) |index| try self.patch(index);
            if (has_default) break;
        }
        if (!has_default) try self.push(0);
        for (end_jumps.items) |index| try self.patch(index);
    }

    /// Compiler-known host intrinsic: lower arguments and emit one
    /// `runtime_call` to its `e7_*` symbol.  User functions/bindings with the
    /// same name take precedence.
    fn lowerIntrinsicCall(self: *Builder, call: ast.Call) Error!bool {
        if (call.callee.* != .path or call.callee.path.segments.len != 1) return false;
        const name = call.callee.path.segments[0].name;
        if (self.local(name) != null or self.name_map.get(name) != null) return false;
        if (intrinsics.lookup(name) == null) return false;
        const runtime_function = bytecode.RuntimeFunction.fromSymbol(name) orelse return false;
        if (call.args.len != runtime_function.arity()) return error.UnsupportedFeature;
        for (call.args) |arg| try self.lowerExpr(arg);
        try self.runtimeCall(runtime_function, @intCast(call.args.len));
        return true;
    }

    /// Compiler-known native method (`f32::sin`, `ptr::load_u32`, ...): lower
    /// the arguments and emit the same `runtime_call` the matching intrinsic
    /// would.  A user-defined qualified function with the same path wins.
    fn lowerNativeMethodCall(self: *Builder, call: ast.Call) Error!bool {
        if (call.callee.* != .path) return false;
        const path = call.callee.path;
        if (path.segments.len != 2) return false;
        const namespace = path.segments[0].name;
        const method_name = path.segments[1].name;
        const method = native_methods.lookup(namespace, method_name) orelse return false;
        var full_buffer: [512]u8 = undefined;
        const full = joinPathBuf(&full_buffer, path);
        if (self.name_map.get(full) != null) return false;
        if (self.structs.get(namespace) != null or
            self.enums.get(namespace) != null or
            self.tables.get(namespace) != null) return false;
        if (call.type_args.len != 0) return error.UnsupportedFeature;
        if (call.args.len != method.params.len) return error.UnsupportedFeature;
        switch (method.lowering) {
            .vector_new => {
                for (call.args) |arg| try self.lowerExpr(arg);
                try self.emit(.vec_new);
            },
            .byte_offset => {
                // `ptr::offset(pointer, bytes)`: unchecked byte arithmetic, no
                // pointee-size scaling (unlike `pointer + count`).
                try self.lowerExpr(call.args[0]);
                try self.lowerExpr(call.args[1]);
                try self.emit(.add);
            },
            .runtime_call => {
                const runtime_function = method.runtime orelse return error.UnsupportedFeature;
                for (call.args) |arg| try self.lowerExpr(arg);
                try self.runtimeCall(runtime_function, @intCast(call.args.len));
            },
        }
        return true;
    }

    /// ABI stride in bytes of a raw pointer's pointee.  The C-interop scalars
    /// `u8`/`u16`/`u32`/`f32` use their storage width; every other pointee
    /// (`i8`/`i16`/`i32`, `u64`/`i64`, pointers, aggregates) keeps the e7
    /// 8-byte slot stride.
    fn rawPointeeSize(self: *Builder, pointer_ty: *types.Type) i64 {
        const resolved = self.resolvedType(pointer_ty);
        if (resolved.* != .raw_pointer) return 8;
        const pointee = self.resolvedType(resolved.raw_pointer);
        return switch (pointee.*) {
            .int => |kind| switch (kind) {
                .u8 => 1,
                .u16 => 2,
                .u32 => 4,
                else => 8,
            },
            .float => |kind| switch (kind) {
                .f32 => 4,
                else => 8,
            },
            else => 8,
        };
    }

    /// Load through the address on top of the stack as `pointee_ty`.  The
    /// unsigned narrow integers and `f32` use the typed ABI helpers (with
    /// `e7_load_f32` widening to the shared f64 representation); every other
    /// pointee uses the 8-byte slot load.
    fn emitRawLoad(self: *Builder, pointee_ty: *types.Type) Error!void {
        const pointee = self.resolvedType(pointee_ty);
        switch (pointee.*) {
            .int => |kind| switch (kind) {
                .u8 => return self.runtimeCall(.load_u8, 1),
                .u16 => return self.runtimeCall(.load_u16, 1),
                .u32 => return self.runtimeCall(.load_u32, 1),
                else => {},
            },
            .float => |kind| switch (kind) {
                .f32 => return self.runtimeCall(.load_f32, 1),
                else => {},
            },
            else => {},
        }
        try self.emit(.load_mem);
    }

    /// Store the value below the address on the stack, truncating to
    /// `pointee_ty` the same way the typed ABI helpers do.
    fn emitRawStore(self: *Builder, pointee_ty: *types.Type) Error!void {
        const pointee = self.resolvedType(pointee_ty);
        switch (pointee.*) {
            .int => |kind| switch (kind) {
                .u8 => return self.runtimeCall(.store_u8, 2),
                .u16 => return self.runtimeCall(.store_u16, 2),
                .u32 => return self.runtimeCall(.store_u32, 2),
                else => {},
            },
            .float => |kind| switch (kind) {
                .f32 => return self.runtimeCall(.store_f32, 2),
                else => {},
            },
            else => {},
        }
        try self.emit(.store_mem);
    }

    /// Lower builtin container methods (`len`, `slice`, `char_at`) on string,    /// Lower builtin container methods (`len`, `slice`, `char_at`) on string,
    /// vector, and map values.  Returns false for any other call.
    /// Receiver-call sugar for inherent `impl Type:` methods.  The receiver is
    /// passed as the first argument; aggregate references already use the
    /// pointer representation, so no extra conversion is needed for `&T`/`&mut T`.
    fn lowerInherentMethodCall(self: *Builder, call: ast.Call) Error!bool {
        if (call.callee.* != .field) return false;
        const field = call.callee.field;
        const receiver_ty = self.exprType(field.target) orelse return false;
        const method = self.analysis.inherentMethod(receiver_ty, field.name) orelse return false;
        const first_param_is_reference = method.decl.params.len > 0 and
            method.decl.params[0].ty.* == .reference;
        if (first_param_is_reference and !self.isAggregateType(receiver_ty) and
            self.resolvedType(receiver_ty).* != .reference)
        {
            // Implicit borrow of a scalar place.
            if (!try self.lowerAddress(field.target)) {
                const slot = try self.allocLocal("<receiver>");
                try self.lowerExpr(field.target);
                try self.emit(.{ .store_local = slot });
                try self.emit(.{ .local_addr = slot });
            }
        } else {
            try self.lowerExpr(field.target);
        }
        for (call.args) |arg| try self.lowerExpr(arg);
        try self.methodCall(method, @intCast(1 + call.args.len));
        return true;
    }

    fn lowerBuiltinMethodCall(self: *Builder, call: ast.Call) Error!bool {
        if (call.callee.* != .field) return false;
        const field = call.callee.field;
        const name = field.name;
        const is_len = std.mem.eql(u8, name, "len");
        const is_slice = std.mem.eql(u8, name, "slice");
        const is_char_at = std.mem.eql(u8, name, "char_at");
        const is_entity = std.mem.eql(u8, name, "entity");
        if (!is_len and !is_slice and !is_char_at and !is_entity) return false;
        const target_ty = self.exprType(field.target) orelse return false;
        const resolved = self.unwrapReferences(target_ty);
        if (is_entity) {
            if (resolved.* != .query or call.args.len != 0) return error.UnsupportedFeature;
            try self.lowerExpr(field.target);
            try self.runtimeCall(.ecs_query_entity, 1);
            return true;
        }
        if (is_len) {
            try self.lowerExpr(field.target);
            try self.emit(switch (resolved.*) {
                .string => .str_len,
                .array => .vec_len,
                .map => .map_len,
                else => return error.UnsupportedFeature,
            });
            return true;
        }
        if (resolved.* != .string) return error.UnsupportedFeature;
        try self.lowerExpr(field.target);
        for (call.args) |arg| try self.lowerExpr(arg);
        try self.emit(if (is_slice) .str_slice else .str_char_at);
        return true;
    }

    fn jsonSchemaForType(self: *Builder, ty: *types.Type) ?[]const u8 {
        const named = self.namedBase(ty) orelse return null;
        return self.analysis.jsonSchema(named.name);
    }

    /// `json_encode(value)` / `json_decode::<T>(text)` and the
    /// `json::encode` / `json::decode::<T>` namespace aliases: the analyzer
    /// generated a schema string for the call expression; codegen embeds it and
    /// emits a runtime call.  The runtime walks the aggregate layout described
    /// by the schema.
    fn lowerJsonCall(self: *Builder, call: ast.Call, expr: *ast.Expr) Error!bool {
        if (call.callee.* != .path) return false;
        const path = call.callee.path;
        if (path.segments.len == 0) return false;
        const last_segment = path.segments[path.segments.len - 1];
        if (path.segments.len == 2 and std.mem.eql(u8, path.segments[0].name, "ecs") and std.mem.eql(u8, last_segment.name, "component_catalog")) {
            const catalog = self.analysis.jsonCallSchema(@intFromPtr(expr)) orelse return error.UnsupportedFeature;
            try self.emit(.{ .string_lit = catalog });
            return true;
        }
        var is_encode = false;
        var is_decode = false;
        var is_schema = false;
        if (path.segments.len == 1) {
            is_encode = std.mem.eql(u8, last_segment.name, "json_encode");
            is_decode = std.mem.eql(u8, last_segment.name, "json_decode");
            if (!is_encode and !is_decode) return false;
            // User functions/bindings shadow the builtin.
            if (self.name_map.get(last_segment.name) != null) return false;
        } else if (path.segments.len == 2) {
            if (!std.mem.eql(u8, path.segments[0].name, "json")) return false;
            is_encode = std.mem.eql(u8, last_segment.name, "encode");
            is_decode = std.mem.eql(u8, last_segment.name, "decode");
            is_schema = std.mem.eql(u8, last_segment.name, "schema");
            if (!is_encode and !is_decode and !is_schema) return false;
        } else {
            return false;
        }
        if (is_schema) {
            const schema = self.analysis.jsonCallSchema(@intFromPtr(expr)) orelse return error.UnsupportedFeature;
            try self.emit(.{ .string_lit = schema });
            return true;
        }
        if (call.args.len != 1) return error.UnsupportedFeature;
        const schema = self.analysis.jsonCallSchema(@intFromPtr(expr)) orelse blk: {
            // Fallback for bytecode produced before per-call schemas existed:
            // the type must be a derived struct/enum with a cached schema.
            const target = if (is_encode) call.args[0] else expr;
            const target_ty = self.exprType(target) orelse return error.UnsupportedFeature;
            break :blk self.jsonSchemaForType(target_ty) orelse return error.UnsupportedFeature;
        };
        try self.emit(.{ .string_lit = schema });
        try self.lowerExpr(call.args[0]);
        if (is_encode) {
            // JSON schemas erase reference layers. Aggregate borrows already
            // alias their object handle; scalar and optional borrows point to
            // a storage slot, which must be loaded before walking the schema.
            var argument_ty = self.resolvedType(self.exprType(call.args[0]) orelse return error.UnsupportedFeature);
            while (argument_ty.* == .reference) {
                const child = argument_ty.reference.child;
                if (!self.isAggregateType(child)) try self.emit(.load_mem);
                argument_ty = self.resolvedType(child);
            }
        }
        try self.runtimeCall(if (is_encode) .json_encode else .json_decode, 2);
        return true;
    }

    /// True when `expr` has a function type (a first-class function value).
    fn isFunctionValueExpr(self: *Builder, expr: *ast.Expr) bool {
        const ty = self.exprType(expr) orelse return false;
        return self.resolvedType(ty).* == .function;
    }

    /// Resolve a path to a compiled top-level/module function index using the
    /// same precedence as direct calls (qualified path first, then the
    /// module-scoped and imported aliases).
    fn resolveFunctionIndex(self: *Builder, path: ast.Path) ?u16 {
        if (path.segments.len >= 2) {
            var buffer: [512]u8 = undefined;
            const full = joinPathBuf(&buffer, path);
            if (self.name_map.get(full)) |index| return index;
            // Module-relative reference (`obj::load_obj` inside an
            // `assets::AssetsPlugin` item) resolves against the owning module.
            // Match the longest module prefix shared with the current item.
            var best: ?u16 = null;
            var best_shared: usize = 0;
            var it = self.name_map.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (key.len <= full.len + 2) continue;
                if (!std.mem.endsWith(u8, key, full)) continue;
                if (!std.mem.eql(u8, key[key.len - full.len - 2 .. key.len - full.len], "::")) continue;
                var shared: usize = 0;
                while (shared < self.module_prefix.len and shared < key.len and
                    self.module_prefix[shared] == key[shared]) : (shared += 1)
                {}
                if (best == null or shared > best_shared) {
                    best = entry.value_ptr.*;
                    best_shared = shared;
                }
            }
            if (best) |index| return index;
            // Imported alias: semantics resolve qualified paths through their
            // last segment as well.
            return self.name_map.get(path.segments[path.segments.len - 1].name);
        }
        if (path.segments.len != 1) return null;
        const name = path.segments[0].name;
        var qualified_buffer: [512]u8 = undefined;
        const qualified = qualifiedNameBuf(&qualified_buffer, self.module_prefix, name);
        if (self.name_map.get(qualified)) |index| return index;
        return self.name_map.get(name);
    }

    /// Lower a bare function name in value position: push its bytecode index.
    /// Lower a bare function name in value position: push its bytecode index.
    fn lowerFunctionRef(self: *Builder, path: ast.Path) Error!void {
        const index = self.resolveFunctionIndex(path) orelse return error.UnsupportedFeature;
        const allowed = self.value_functions orelse return error.UnsupportedFeature;
        if (!allowed.contains(index)) return error.UnsupportedFeature;
        try self.emit(.{ .function_ref = index });
    }

    /// Lower an indirect call: callee value first, then arguments, then the
    /// `call_indirect` op carrying the argument count.
    fn lowerIndirectCall(self: *Builder, call: ast.Call) Error!void {
        try self.lowerExpr(call.callee);
        for (call.args) |arg| try self.lowerCallArg(arg);
        try self.emit(.{ .call_indirect = @intCast(call.args.len) });
    }

    fn lowerCall(self: *Builder, call: ast.Call, expr: *ast.Expr) Error!void {
        if (try self.lowerJsonCall(call, expr)) return;
        if (try self.lowerCommandsMethodCall(call)) return;
        if (try self.lowerIntrinsicCall(call)) return;
        if (try self.lowerNativeMethodCall(call)) return;
        if (call.callee.* == .field) {
            if (try self.lowerBuiltinMethodCall(call)) return;
            if (try self.lowerInherentMethodCall(call)) return;
        }
        if (call.callee.* == .path) {
            const path = call.callee.path;
            if (path.segments.len == 0) return error.UnsupportedFeature;
            const name = path.segments[path.segments.len - 1].name;
            // A local/parameter shadows a top-level function of the same name
            // (the analyzer resolves values the same way): call through the slot.
            if (path.segments.len == 1 and self.local(name) != null) {
                if (self.isFunctionValueExpr(call.callee)) return self.lowerIndirectCall(call);
                return error.UnsupportedFeature;
            }
            if (path.segments.len >= 2) {
                if (self.enums.get(path.segments[0].name)) |def| {
                    const tag = enumTag(def, name) orelse return error.UnsupportedFeature;
                    const variant = def.variants[tag];
                    if (variant.payload != .tuple) return error.UnsupportedFeature;
                    const payloads = variant.payload.tuple;
                    const temp = try self.allocLocal("<enum>");
                    try self.push(@intCast(payloads.len + 1));
                    try self.emit(.alloc);
                    try self.emit(.{ .store_local = temp });
                    try self.emit(.{ .load_local = temp });
                    try self.push(@intCast(tag));
                    try self.emit(.store_mem);
                    for (call.args, 0..) |arg, i| {
                        try self.emit(.{ .load_local = temp });
                        try self.push(@intCast(8 + i * 8));
                        try self.emit(.add);
                        try self.lowerExpr(arg);
                        try self.emit(.store_mem);
                    }
                    try self.emit(.{ .load_local = temp });
                    return;
                }
            }
            const direct = self.resolveFunctionIndex(path);
            if (direct == null and std.mem.eql(u8, name, "print")) {
                for (call.args) |arg| {
                    try self.lowerExpr(arg);
                    try self.pop();
                }
                try self.push(0);
                return;
            }
            if (direct) |function| {
                for (call.args) |arg| try self.lowerCallArg(arg);
                try self.callFunction(function, call.args.len);
                return;
            }
            // Function value reached through a path the direct map does not
            // cover (for example an imported alias): call indirectly.
            if (self.isFunctionValueExpr(call.callee)) return self.lowerIndirectCall(call);
            for (call.args) |arg| try self.lowerCallArg(arg);
            try self.emitCall(name, call.args.len);
            return;
        }
        // Function-typed field, index, or call-expression callee.
        if (self.isFunctionValueExpr(call.callee)) return self.lowerIndirectCall(call);
        return error.UnsupportedFeature;
    }
};
