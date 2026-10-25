//! Checked-AST to engine bytecode lowering.
//!
//! The backend intentionally targets a small, explicit subset: integer/bool
//! functions, locals, calls, arithmetic/comparison, `if`/`match`, `while`,
//! `loop`, `for` over integer ranges, assignment, and `ret`.  Everything is
//! represented as 64-bit integers in the bytecode; booleans are 0/1.  Aggregate
//! values and borrows are rejected by `UnsupportedFeature` for now rather than
//! silently miscompiled.
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
};

pub const Config = struct {
    /// Verification/translation reserves this many operand-stack slots.
    stack_slots: u16 = 256,
};

const FunctionInfo = struct {
    decl: *const ast.FunctionDecl,
    constructor_index: u16,
    body_index: ?u16 = null,
};

const TriggerInfo = struct {
    decl: *const ast.TriggerDecl,
    id: u16,
    constructor_index: u16,
    body_index: u16,
    systems: [][]const u8,
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
        const trigger = trigger_name orelse continue;
        if (name_map.contains(decl.name)) return error.DuplicateFunction;
        if (decl.params.len != 0) return error.UnsupportedFeature;
        const params = try allocator.alloc(ast.Param, decl.params.len);
        for (decl.params, 0..) |param, i| switch (param) {
            .normal => |normal| params[i] = normal,
            .query, .resource => return error.UnsupportedFeature,
        };
        const unit_ty = try allocator.create(ast.Type);
        unit_ty.* = .{ .tuple = &.{} };
        try synthetic_types.append(allocator, unit_ty);
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
        });
        const gop = try trigger_system_names.getOrPut(allocator, trigger);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, decl.name);
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

    const functions = try allocator.alloc(bytecode.Function, next_index);
    var initialized: usize = 0;
    errdefer {
        for (functions[0..initialized]) |function| {
            allocator.free(function.name);
            allocator.free(function.code);
        }
        allocator.free(functions);
    }

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
                .mode = .async_body,
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

    var result = bytecode.Module{
        .allocator = allocator,
        .functions = functions,
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
    mode: BuilderMode = .normal,
    body_index: u16 = 0,
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

        if (self.mode == .async_body) {
            _ = try self.allocLocal("<task>");
        }
        for (self.function.params) |param| {
            _ = try self.allocLocal(param.name);
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

        const name = if (self.mode == .async_body)
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

    fn isStringType(self: *Builder, ty: *types.Type) bool {
        return self.resolvedType(ty).* == .string;
    }

    fn isScalarType(self: *Builder, ty: *types.Type) bool {
        return switch (self.resolvedType(ty).*) {
            .int, .float, .bool, .variable, .unknown => true,
            else => false,
        };
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
        const resolved = self.resolvedType(target_ty);
        try self.lowerExpr(index_expr.target);
        try self.lowerExpr(index_expr.index);
        switch (resolved.*) {
            .array => |array| try self.emit(if (array.columns != null) .vec_row else .vec_get),
            .map => |m| try self.emit(if (self.isStringType(m.key)) .map_get_str else .map_get),
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
                    const resolved = self.resolvedType(base_ty);
                    try self.lowerExpr(target.index.target);
                    try self.lowerExpr(target.index.index);
                    try self.lowerExpr(assign.value);
                    switch (resolved.*) {
                        .array => try self.emit(.vec_set),
                        .map => |m| try self.emit(if (self.isStringType(m.key)) .map_set_str else .map_set),
                        else => return error.UnsupportedFeature,
                    }
                } else {
                    if (assign.op != .assign) return error.UnsupportedFeature;
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
        if (loop.pattern.* != .binding and loop.pattern.* != .wildcard) return error.UnsupportedFeature;
        const slot = if (loop.pattern.* == .binding)
            try self.allocLocal(loop.pattern.binding)
        else
            try self.allocLocal("<for>");
        const hidden = try self.allocLocal("<for_end>");

        if (loop.iterable.* != .range) return error.UnsupportedFeature;
        const range = loop.iterable.range;
        if (range.end == null) return error.UnsupportedFeature;
        if (range.start) |start| try self.lowerExpr(start) else try self.push(0);
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

    fn lowerExpr(self: *Builder, expr: *ast.Expr) Error!void {
        switch (expr.*) {
            .int => |value| try self.push(value),
            .boolean => |value| try self.push(if (value) 1 else 0),
            .nil => try self.push(0),
            .path => |path| {
                if (path.segments.len == 1) {
                    const slot = self.local(path.segments[0].name) orelse return error.UnsupportedFeature;
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
                    .negative, .not => {
                        try self.lowerExpr(unary.operand);
                        try self.emit(if (unary.op == .negative) .neg else .not);
                    },
                    .borrow_shared, .borrow_mut => {
                        if (!try self.lowerAddress(unary.operand)) return error.UnsupportedFeature;
                    },
                    .deref => {
                        try self.lowerExpr(unary.operand);
                        try self.emit(.load_mem);
                    },
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

    fn lowerCall(self: *Builder, call: ast.Call) Error!void {
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
        for (call.args) |arg| try self.lowerExpr(arg);
        try self.emitCall(name, call.args.len);
    }
};
