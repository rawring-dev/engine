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
//! `Task` handle and a body function runs with the task pointer plus the
//! system's parameters.  Query and resource parameters are opaque i64 handles
//! in the body; forwarding them as call arguments is supported, while any use
//! that would need the synthetic query/record layout is rejected with
//! `OpaqueHandleAccess`.
//!
//! This is the compiler's real output path: `pipeline.zig` runs the parser,
//! semantic analyzer, this lowering pass, and the bytecode fixed-point
//! optimizer.  The runtime later consumes the bytecode.

const std = @import("std");
const ast = @import("ast.zig");
const bytecode = @import("bytecode.zig");
const semantic = @import("semantic/analyzer.zig");
const types = @import("semantic/types.zig");

pub const Error = error{
    OutOfMemory,
    UnsupportedFeature,
    DuplicateFunction,
    NoFunctions,
    TooManyLocals,
    UnknownLocal,
    InvalidBytecode,
    /// A query/resource system parameter is an opaque handle at the async ABI
    /// boundary.  Handles may only be forwarded as call arguments; projecting
    /// fields, iterating, borrowing, or computing on one has no defined
    /// lowering yet, so it is rejected instead of treating the handle as a
    /// pointer to the synthetic query/record layout.
    OpaqueHandleAccess,
};

pub const Config = struct {
    /// Verification/translation reserves this many operand-stack slots.
    stack_slots: u16 = 256,
};

const FunctionInfo = struct {
    decl: *const ast.FunctionDecl,
    constructor_index: u16,
    body_index: ?u16 = null,
    /// Parameter positions that carry opaque query/resource handles.
    opaque_params: []const usize = &.{},
};

const TriggerInfo = struct {
    decl: *const ast.TriggerDecl,
    id: u16,
    constructor_index: u16,
    body_index: u16,
    systems: [][]const u8,
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
                .name_override = pending.name,
            };
            const compiled = try builder.finish();
            self.allocator.free(self.functions.items[offset].name);
            self.allocator.free(self.functions.items[offset].code);
            self.functions.items[offset] = compiled;
        }
    }
};

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
    for (module.items) |item| {
        switch (item.kind) {
            .struct_decl => |decl| try structs.put(allocator, decl.name, &item.kind.struct_decl),
            .table_decl => |decl| try tables.put(allocator, decl.name, &item.kind.table_decl),
            .enum_decl => |decl| try enums.put(allocator, decl.name, &item.kind.enum_decl),
            else => {},
        }
    }
    var infos = std.ArrayList(FunctionInfo).empty;
    defer infos.deinit(allocator);
    var triggers = std.ArrayList(TriggerInfo).empty;
    defer {
        for (triggers.items) |info| allocator.free(info.systems);
        triggers.deinit(allocator);
    }
    var synthetic = std.ArrayList(*ast.FunctionDecl).empty;
    var synthetic_types = std.ArrayList(*ast.Type).empty;
    defer {
        for (synthetic.items) |decl| allocator.destroy(decl);
        synthetic.deinit(allocator);
        for (synthetic_types.items) |ty| allocator.destroy(ty);
        synthetic_types.deinit(allocator);
    }
    var name_map = std.StringHashMapUnmanaged(u16).empty;
    defer name_map.deinit(allocator);
    var next_index: u16 = 0;
    for (module.items) |item| {
        switch (item.kind) {
            .function => |decl| {
                if (name_map.contains(decl.name)) return error.DuplicateFunction;
                const slots: u16 = if (decl.is_async) 2 else 1;
                if (next_index + slots < next_index) return error.TooManyLocals;
                const constructor_index = next_index;
                const body_index = if (decl.is_async) next_index + 1 else null;
                next_index += slots;
                try name_map.put(allocator, decl.name, constructor_index);
                try infos.append(allocator, .{
                    .decl = &item.kind.function,
                    .constructor_index = constructor_index,
                    .body_index = body_index,
                });
            },
            .binding => |binding| {
                if (binding.value.* != .function or !binding.value.function.is_async) continue;
                if (name_map.contains(binding.name)) return error.DuplicateFunction;
                const function = binding.value.function;
                const decl = try allocator.create(ast.FunctionDecl);
                decl.* = .{
                    .name = binding.name,
                    .is_async = true,
                    .generics = &.{},
                    .params = function.params,
                    .result = function.result,
                    .where_clause = null,
                    .body = function.body,
                };
                try synthetic.append(allocator, decl);
                if (next_index + 2 < next_index) return error.TooManyLocals;
                const constructor_index = next_index;
                const body_index = next_index + 1;
                next_index += 2;
                try name_map.put(allocator, binding.name, constructor_index);
                try infos.append(allocator, .{
                    .decl = decl,
                    .constructor_index = constructor_index,
                    .body_index = body_index,
                });
            },
            else => {},
        }
    }
    var trigger_system_names = std.StringHashMapUnmanaged(std.ArrayList([]const u8)).empty;
    defer {
        var it = trigger_system_names.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(allocator);
        trigger_system_names.deinit(allocator);
    }
    // Every `sys` declaration lowers to the same async constructor/body pair
    // as a source async function, whether or not a trigger invokes it.  A
    // system's query/resource parameters are opaque i64 handles at this ABI
    // boundary: the body receives them as handles, and only forwarding them as
    // call arguments is lowered (see `Builder.lowerCallArg`).  Anything that
    // needs the synthetic query/record layout is rejected with
    // `OpaqueHandleAccess` instead of being miscompiled.
    //
    // Trigger-attached systems stay restricted to zero parameters because the
    // generated trigger body does not bind trigger fields into system
    // parameters.
    var synthetic_params = std.ArrayList([]ast.Param).empty;
    defer {
        for (synthetic_params.items) |params| allocator.free(params);
        synthetic_params.deinit(allocator);
    }
    var opaque_param_lists = std.ArrayList([]const usize).empty;
    defer {
        for (opaque_param_lists.items) |indices| allocator.free(indices);
        opaque_param_lists.deinit(allocator);
    }
    for (module.items) |item| {
        if (item.kind != .sys) continue;
        const decl = item.kind.sys;
        var trigger_name: ?[]const u8 = null;
        for (item.attributes) |attribute| {
            if (attribute.path.segments.len == 0 or attribute.args.len == 0) continue;
            const attr_name = attribute.path.segments[attribute.path.segments.len - 1].name;
            if (!std.mem.eql(u8, attr_name, "trigger")) continue;
            const arg = attribute.args[0];
            if (arg.* != .path or arg.path.segments.len == 0) continue;
            trigger_name = arg.path.segments[arg.path.segments.len - 1].name;
            break;
        }
        if (name_map.contains(decl.name)) return error.DuplicateFunction;
        if (trigger_name != null and decl.params.len != 0) return error.UnsupportedFeature;
        const unit_ty = try allocator.create(ast.Type);
        unit_ty.* = .{ .tuple = &.{} };
        try synthetic_types.append(allocator, unit_ty);
        const params = try allocator.alloc(ast.Param, decl.params.len);
        try synthetic_params.append(allocator, params);
        var opaque_indices = std.ArrayList(usize).empty;
        for (decl.params, 0..) |param, i| switch (param) {
            .normal => |normal| params[i] = normal,
            .resource => |resource| {
                params[i] = resource;
                try opaque_indices.append(allocator, i);
            },
            .query => |query| {
                params[i] = .{ .name = query.name, .ty = unit_ty };
                try opaque_indices.append(allocator, i);
            },
        };
        const opaque_slice = try opaque_indices.toOwnedSlice(allocator);
        try opaque_param_lists.append(allocator, opaque_slice);
        const synthetic_decl = try allocator.create(ast.FunctionDecl);
        synthetic_decl.* = .{
            .name = decl.name,
            .is_async = true,
            .generics = decl.generics,
            .params = params,
            .result = unit_ty,
            .where_clause = decl.where_clause,
            .body = .{ .block = decl.body },
        };
        try synthetic.append(allocator, synthetic_decl);
        const constructor_index = next_index;
        const body_index = next_index + 1;
        next_index += 2;
        try name_map.put(allocator, decl.name, constructor_index);
        try infos.append(allocator, .{
            .decl = synthetic_decl,
            .constructor_index = constructor_index,
            .body_index = body_index,
            .opaque_params = opaque_slice,
        });
        if (trigger_name) |trigger| {
            const gop = try trigger_system_names.getOrPut(allocator, trigger);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, decl.name);
        }
    }

    if (infos.items.len == 0 and triggers.items.len == 0) return error.NoFunctions;
    for (module.items) |item| {
        switch (item.kind) {
            .trigger_decl => |decl| {
                if (name_map.contains(decl.name)) return error.DuplicateFunction;
                if (next_index + 2 < next_index) return error.TooManyLocals;
                const constructor_index = next_index;
                const body_index = next_index + 1;
                next_index += 2;
                try name_map.put(allocator, decl.name, constructor_index);
                const systems = if (trigger_system_names.get(decl.name)) |list|
                    try allocator.dupe([]const u8, list.items)
                else
                    try allocator.alloc([]const u8, 0);
                try triggers.append(allocator, .{
                    .decl = &item.kind.trigger_decl,
                    .id = @intCast(triggers.items.len),
                    .constructor_index = constructor_index,
                    .body_index = body_index,
                    .systems = systems,
                });
            },
            else => {},
        }
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
                .mode = .async_constructor,
                .body_index = body_index,
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
                .mode = .async_body,
                .opaque_param_indices = info.opaque_params,
            };
            functions[body_index] = try body.finish();
            initialized += 1;
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
            .name = try allocator.dupe(u8, info.decl.name),
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
        errdefer body_code.deinit(allocator);
        var next_local: u16 = argc + 1;
        for (info.systems) |system_name| {
            const system_index = name_map.get(system_name) orelse return error.UnsupportedFeature;
            try body_code.append(allocator, .{ .call = .{ .function = system_index, .argc = 0 } });
            try body_code.append(allocator, .task_spawn);
            try body_code.append(allocator, .{ .store_local = next_local });
            try handle_slots.append(allocator, next_local);
            next_local += 1;
        }
        for (handle_slots.items) |slot| {
            try body_code.append(allocator, .{ .load_local = slot });
            try body_code.append(allocator, .task_await);
            try body_code.append(allocator, .pop);
        }
        try body_code.append(allocator, .{ .push_i64 = 0 });
        try body_code.append(allocator, .ret);
        functions[info.body_index] = .{
            .name = try std.fmt.allocPrint(allocator, "{s}__body", .{info.decl.name}),
            .params = argc + 1,
            .locals = next_local,
            .max_stack = config.stack_slots,
            .code = try body_code.toOwnedSlice(allocator),
        };
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

const BuilderMode = enum { normal, async_constructor, async_body };

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
    /// Parameter positions carrying opaque query/resource handles (systems
    /// only).  Handles may be forwarded as call arguments and nothing else.
    opaque_param_indices: []const usize = &.{},
    /// Local slots resolved from `opaque_param_indices` while allocating the
    /// function's parameters.
    opaque_locals: std.ArrayList(u16) = .empty,
    code: std.ArrayList(bytecode.Op) = .empty,
    scopes: std.ArrayList(std.StringHashMapUnmanaged(u16)) = .empty,
    next_local: u16 = 0,
    loops: std.ArrayList(LoopCtx) = .empty,

    fn finish(self: *Builder) Error!bytecode.Function {
        defer self.code.deinit(self.allocator);
        defer self.opaque_locals.deinit(self.allocator);
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

        if (self.mode == .async_body) {
            _ = try self.allocLocal("<task>");
        }
        for (self.function.params, 0..) |param, index| {
            const slot = try self.allocLocal(param.name);
            if (self.isOpaqueParam(index)) try self.opaque_locals.append(self.allocator, slot);
        }

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
            .normal, .async_body => switch (self.function.body) {
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

        const name = if (self.name_override) |override|
            try self.allocator.dupe(u8, override)
        else if (self.mode == .async_body)
            try std.fmt.allocPrint(self.allocator, "{s}__body", .{self.function.name})
        else
            try self.allocator.dupe(u8, self.function.name);
        return .{
            .name = name,
            .params = @intCast(self.function.params.len + @as(usize, if (self.mode == .async_body) 1 else 0)),
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

    fn isOpaqueParam(self: *const Builder, index: usize) bool {
        for (self.opaque_param_indices) |candidate| {
            if (candidate == index) return true;
        }
        return false;
    }

    fn isOpaqueSlot(self: *const Builder, slot: u16) bool {
        for (self.opaque_locals.items) |candidate| {
            if (candidate == slot) return true;
        }
        return false;
    }

    /// Lower a call argument.  A bare reference to an opaque query/resource
    /// handle is forwarded by value; everything else goes through the ordinary
    /// expression lowering (which rejects other handle uses).
    fn lowerCallArg(self: *Builder, arg: *ast.Expr) Error!void {
        if (arg.* == .path and arg.path.segments.len == 1) {
            if (self.local(arg.path.segments[0].name)) |slot| {
                if (self.isOpaqueSlot(slot)) {
                    try self.emit(.{ .load_local = slot });
                    return;
                }
            }
        }
        try self.lowerExpr(arg);
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

    fn emitCall(self: *Builder, name: []const u8, argc: usize) Error!void {
        const function = self.name_map.get(name) orelse return error.UnsupportedFeature;
        try self.emit(.{ .call = .{ .function = function, .argc = @intCast(argc) } });
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

    fn structFields(self: *Builder, name: []const u8) ?[]ast.Field {
        if (self.structs.get(name)) |decl| return decl.fields;
        if (self.tables.get(name)) |decl| return decl.fields;
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
                if (self.isOpaqueSlot(slot)) return error.OpaqueHandleAccess;
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
                    const slot = self.local(path.segments[0].name) orelse return error.UnsupportedFeature;
                    if (self.isOpaqueSlot(slot)) return error.OpaqueHandleAccess;
                    try self.emit(.{ .load_local = slot });
                    return;
                }
                const enum_name = path.segments[0].name;
                const def = self.enums.get(enum_name) orelse return error.UnsupportedFeature;
                const variant_name = path.segments[path.segments.len - 1].name;
                const tag = enumTag(def, variant_name) orelse return error.UnsupportedFeature;
                const temp = try self.allocLocal("<enum>");
                try self.push(1);
                try self.emit(.alloc);
                try self.emit(.{ .store_local = temp });
                try self.emit(.{ .load_local = temp });
                try self.push(@intCast(tag));
                try self.emit(.store_mem);
                try self.emit(.{ .load_local = temp });
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
            .cast => |cast| try self.lowerExpr(cast.expr),
            .call => |call| try self.lowerCall(call),
            .try_expr => |inner| {
                try self.lowerExpr(inner);
                const slot = try self.allocLocal("<try>");
                try self.emit(.{ .store_local = slot });
                try self.emit(.{ .load_local = slot });
                try self.push(std.math.minInt(i64));
                try self.emit(.eq);
                const ok_jump = try self.emitJump(true);
                try self.push(std.math.minInt(i64));
                try self.emit(.ret);
                try self.patch(ok_jump);
                try self.emit(.{ .load_local = slot });
            },
            .range, .float, .error_literal, .function => {
                return error.UnsupportedFeature;
            },
        }
    }

    fn lowerPrefix(self: *Builder, prefix_expr: ast.Prefix) Error!void {
        switch (prefix_expr.op) {
            .await_ => {
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

    fn lowerBinary(self: *Builder, binary: ast.Binary) Error!void {
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
                try self.push(8);
                try self.emit(.mul);
                try self.emit(if (binary.op == .sub) .sub else .add);
                return;
            }
            if (r.* == .raw_pointer and self.isScalarType(l)) {
                try self.lowerExpr(binary.lhs);
                try self.lowerExpr(binary.rhs);
                try self.push(8);
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
                if (self.enums.get(named.name)) |def| {
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

    /// Lower builtin container methods (`len`, `slice`, `char_at`) on string,
    /// vector, and map values.  Returns false for any other call.
    fn lowerBuiltinMethodCall(self: *Builder, call: ast.Call) Error!bool {
        if (call.callee.* != .field) return false;
        const field = call.callee.field;
        const name = field.name;
        const is_len = std.mem.eql(u8, name, "len");
        const is_slice = std.mem.eql(u8, name, "slice");
        const is_char_at = std.mem.eql(u8, name, "char_at");
        if (!is_len and !is_slice and !is_char_at) return false;
        const target_ty = self.exprType(field.target) orelse return false;
        const resolved = self.unwrapReferences(target_ty);
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

    fn lowerCall(self: *Builder, call: ast.Call) Error!void {
        if (call.callee.* == .field) {
            if (try self.lowerBuiltinMethodCall(call)) return;
        }
        if (call.callee.* != .path) return error.UnsupportedFeature;
        const path = call.callee.path;
        if (path.segments.len == 0) return error.UnsupportedFeature;
        const name = path.segments[path.segments.len - 1].name;
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
        if (std.mem.eql(u8, name, "print")) {
            for (call.args) |arg| {
                try self.lowerExpr(arg);
                try self.pop();
            }
            try self.push(0);
            return;
        }
        for (call.args) |arg| try self.lowerCallArg(arg);
        try self.emitCall(name, call.args.len);
    }
};
