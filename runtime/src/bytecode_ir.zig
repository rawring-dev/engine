//! Bytecode -> textual LLVM IR translation for the ORC JIT.
//!
//! The engine bytecode is a stack machine.  Rather than reconstruct SSA values
//! with phi nodes, each function materialises its operand stack as an `alloca`
//! array plus a stack-pointer `alloca`; every push/pop becomes load/store/GEP.
//! LLVM's own `mem2reg`/`instcombine` passes (driven by the iterative pipeline)
//! then recover SSA form.  This keeps the translator small and makes the
//! compiler/runtime boundary the verified bytecode rather than IR text.

const std = @import("std");
const compiler = @import("compiler");
const bytecode = compiler.bytecode;

pub const Error = error{
    OutOfMemory,
    InvalidBytecode,
};

/// The same escaping is used by generated references and live symbol lookup.
pub fn symbolNameAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const copy = try allocator.alloc(u8, name.len);
    for (name, 0..) |byte, i| copy[i] = switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '$', '-' => byte,
        else => '_',
    };
    return copy;
}

pub fn translate(allocator: std.mem.Allocator, module: *const bytecode.Module) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try bytecode.verify(allocator, module);
    var translator = Translator{
        .allocator = allocator,
        .arena = arena.allocator(),
        .module = module,
    };
    try translator.out.appendSlice(allocator, "declare i64 @e7_code_resolve(i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_task_create(ptr, i64, ptr)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_task_spawn(i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_task_await(i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_task_detach(i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_task_cancel(i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_trigger_enter(i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_trigger_leave(i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_alloc_i64(i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_str_concat(i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_str_slice(i64, i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_str_char_at(i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_str_eq(i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_vec_new(i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_vec_len(i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_vec_get(i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare void @e7_vec_set(i64, i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_vec_row(i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_vec_get2(i64, i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare void @e7_vec_set2(i64, i64, i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare void @e7_vec_set_row(i64, i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_vec_binary(i64, i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_vec_scalar(i64, i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_map_new()\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_map_len(i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_map_key_at(i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_map_value_at(i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_map_get(i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare void @e7_map_set(i64, i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare i64 @e7_map_get_str(i64, i64)\n");
    try translator.out.appendSlice(allocator, "declare void @e7_map_set_str(i64, i64, i64)\n");
    // ECS runtime intrinsics (see runtime/src/ecs.zig and compiler bytecode
    // `RuntimeFunction`).  Declarations mirror the real C ABI: i64 handles and
    // values, i32 command/registration statuses, void reset.
    for (std.enums.values(bytecode.RuntimeFunction)) |function| {
        var defined = false;
        for (module.functions) |user_function| {
            if (std.mem.eql(u8, user_function.name, function.symbol())) {
                defined = true;
                break;
            }
        }
        if (defined) continue;
        try translator.out.appendSlice(allocator, "declare ");
        try translator.out.appendSlice(allocator, switch (function.returnKind()) {
            .i64_ => "i64",
            .i32_ => "i32",
            .void_ => "void",
        });
        try translator.out.appendSlice(allocator, " @");
        try translator.out.appendSlice(allocator, function.symbol());
        try translator.out.appendSlice(allocator, "(");
        for (0..function.arity()) |argument| {
            if (argument > 0) try translator.out.appendSlice(allocator, ", ");
            try translator.out.appendSlice(allocator, "i64");
        }
        try translator.out.appendSlice(allocator, ")\n");
    }
    try translator.out.append(allocator, '\n');
    try translator.emitDispatchHelpers();
    for (module.functions) |function| try translator.emitFunction(function);
    if (translator.uses_fixpoint_attr) {
        try translator.out.appendSlice(allocator, "attributes #0 = { \"instcombine-no-verify-fixpoint\" }\n");
    }
    return translator.out.toOwnedSlice(allocator);
}

/// Collection length/iteration lowering produces IR that trips LLVM 23's
/// InstCombine fixed-point verifier.  Those functions carry
/// `"instcombine-no-verify-fixpoint"`; the driver's own fixed-point loop still
/// limits repeated optimization.
fn functionNeedsFixpointAttr(function: bytecode.Function) bool {
    for (function.code, 0..) |op, index| switch (op) {
        // Container/map lowering expands into branchy call chains that can trip
        // LLVM 23's InstCombine fixed-point verifier.
        // Aggregate constructors also trigger the verifier after stack-slot
        // promotion (e.g. a nine-field UITextField default initializer).
        .alloc,
        .vec_new,
        .vec_len,
        .vec_get,
        .vec_set,
        .vec_row,
        .vec_get2,
        .vec_set2,
        .vec_set_row,
        .vec_binary,
        .vec_scalar,
        .map_new,
        .map_get,
        .map_set,
        .map_get_str,
        .map_set_str,
        .map_len,
        .map_key_at,
        .map_value_at,
        .str_len,
        => return true,
        // Backward branches lower to loop-shaped stack-machine IR that trips
        // LLVM 23's InstCombine fixed-point verifier even when the loop body is
        // pure integer code (e.g. a simple accumulator).  Mark every function
        // with a loop for the opt-out attribute.
        .jump => |target| if (target <= index) return true,
        .jump_if_false => |target| if (target <= index) return true,
        // Indirect calls lower to a switch over the known function table.
        .call_indirect => return true,
        .runtime_call => |call| switch (call.function) {
            // `e7_vec_push`/`e7_str_*` helpers expand into large branchy IR.
            .vec_push => return true,
            // Query-driven loops lower to branchy stack-machine IR that can trip
            // LLVM 23's InstCombine fixed-point verifier; opt out (the driver's
            // own fixed-point loop still runs).
            .ecs_query_next => return true,
            // Float helpers expand into large constant-argument call chains;
            // LLVM 23's InstCombine fixed-point verifier rejects the result.
            .float_add,
            .float_sub,
            .float_mul,
            .float_div,
            .float_neg,
            .float_eq,
            .float_ne,
            .float_lt,
            .float_le,
            .float_gt,
            .float_ge,
            .float_sin,
            .float_cos,
            .float_sqrt,
            .float_abs,
            .float_clamp,
            .float_from_i64,
            .float_to_i64,
            .float_to_milli,
            .float_from_milli,
            => return true,
            else => {},
        },
        else => {},
    };
    return false;
}

const Translator = struct {
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    module: *const bytecode.Module,
    out: std.ArrayList(u8) = .empty,
    temp: usize = 0,
    max_stack: u16 = 0,
    /// Set when a function contains collection iteration/length lowering.
    /// LLVM 23's InstCombine fixed-point verifier aborts on the stack-machine
    /// IR those loops produce, so such functions opt out of the verification;
    /// the iterative pipeline above still drives the IR to a fixed point.
    uses_fixpoint_attr: bool = false,

    fn line(self: *Translator, comptime format: []const u8, args: anytype) Error!void {
        const text = try std.fmt.allocPrint(self.arena, format, args);
        try self.out.appendSlice(self.allocator, text);
        try self.out.append(self.allocator, '\n');
    }

    fn fresh(self: *Translator) []const u8 {
        const name = std.fmt.allocPrint(self.arena, "%t{d}", .{self.temp}) catch unreachable;
        self.temp += 1;
        return name;
    }

    fn label(self: *Translator, index: usize) []const u8 {
        return std.fmt.allocPrint(self.arena, "bb{d}", .{index}) catch unreachable;
    }

    /// Emit one dispatch helper per argument count used by `call_indirect`:
    /// Function values carry native addresses, resolved through the current
    /// live generation at invocation. Null/default values still return zero.
    fn emitDispatchHelpers(self: *Translator) Error!void {
        var arities = std.AutoHashMapUnmanaged(u16, void).empty;
        defer arities.deinit(self.allocator);
        for (self.module.functions) |function| {
            for (function.code) |op| switch (op) {
                .call_indirect => |argc| try arities.put(self.allocator, argc, {}),
                else => {},
            };
        }
        if (arities.count() == 0) return;
        var sorted = std.ArrayList(u16).empty;
        defer sorted.deinit(self.allocator);
        var it = arities.iterator();
        while (it.next()) |entry| try sorted.append(self.allocator, entry.key_ptr.*);
        std.mem.sort(u16, sorted.items, {}, std.sort.asc(u16));
        for (sorted.items) |argc| try self.emitDispatchHelper(argc);
    }

    fn emitDispatchHelper(self: *Translator, argc: u16) Error!void {
        var signature = std.ArrayList(u8).empty;
        defer signature.deinit(self.arena);
        try signature.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "define i64 @e7_hof_dispatch_{d}(i64 %handle", .{argc}));
        for (0..argc) |i| try signature.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, ", i64 %arg{d}", .{i}));
        try signature.appendSlice(self.arena, ") {");
        try self.line("{s}", .{signature.items});
        try self.line("{s}", .{"entry:"});
        try self.line("{s}", .{"  %resolved = call i64 @e7_code_resolve(i64 %handle)"});
        try self.line("{s}", .{"  %valid = icmp ne i64 %resolved, 0"});
        try self.line("{s}", .{"  br i1 %valid, label %invoke, label %bad"});
        try self.line("{s}", .{"invoke:"});
        try self.line("{s}", .{"  %fn = inttoptr i64 %resolved to ptr"});
        var call = std.ArrayList(u8).empty;
        defer call.deinit(self.arena);
        try call.appendSlice(self.arena, "  %result = call i64 %fn(");
        for (0..argc) |i| {
            if (i > 0) try call.appendSlice(self.arena, ", ");
            try call.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "i64 %arg{d}", .{i}));
        }
        try call.appendSlice(self.arena, ")");
        try self.line("{s}", .{call.items});
        try self.line("{s}", .{"  ret i64 %result"});
        try self.line("{s}", .{"bad:"});
        try self.line("{s}", .{"  ret i64 0"});
        try self.line("{s}", .{"}"});
        try self.out.append(self.allocator, '\n');
    }

    fn symbolName(self: *Translator, name: []const u8) []const u8 {
        return symbolNameAlloc(self.arena, name) catch unreachable;
    }

    fn emitFunction(self: *Translator, function: bytecode.Function) Error!void {
        self.temp = 0;
        self.max_stack = function.max_stack;
        var signature = std.ArrayList(u8).empty;
        defer signature.deinit(self.arena);
        const prefix = try std.fmt.allocPrint(self.arena, "define i64 @{s}(", .{self.symbolName(function.name)});
        try signature.appendSlice(self.arena, prefix);
        for (0..function.params) |i| {
            if (i > 0) try signature.appendSlice(self.arena, ", ");
            const part = try std.fmt.allocPrint(self.arena, "i64 %arg{d}", .{i});
            try signature.appendSlice(self.arena, part);
        }
        try signature.appendSlice(self.arena, ")");
        if (functionNeedsFixpointAttr(function)) {
            try signature.appendSlice(self.arena, " #0");
            self.uses_fixpoint_attr = true;
        }
        try signature.appendSlice(self.arena, " {");
        try self.line("{s}", .{signature.items});
        try self.line("entry:", .{});
        for (0..function.locals) |i| try self.line("  %l{d} = alloca i64", .{i});
        for (0..function.params) |i| {
            try self.line("  store i64 %arg{d}, ptr %l{d}", .{ i, i });
        }
        try self.line("  %stack = alloca [{d} x i64]", .{function.max_stack});
        try self.line("  %sp = alloca i64", .{});
        try self.line("  store i64 0, ptr %sp", .{});
        try self.line("  br label %bb0", .{});

        for (function.code, 0..) |op, index| {
            try self.line("{s}:", .{self.label(index)});
            try self.emitOp(op, index, function);
        }
        try self.line("end: ret i64 0", .{});
        try self.line("}}", .{});
        try self.out.append(self.allocator, '\n');
    }

    fn emitOp(self: *Translator, op: bytecode.Op, index: usize, function: bytecode.Function) Error!void {
        switch (op) {
            .nop => {},
            .push_i64 => |value| try self.push(value),
            .load_local => |slot| {
                const value = self.fresh();
                try self.line("  {s} = load i64, ptr %l{d}", .{ value, slot });
                try self.pushValue(value);
            },
            .store_local => |slot| {
                const value = try self.popValue();
                try self.line("  store i64 {s}, ptr %l{d}", .{ value, slot });
            },
            .pop => _ = try self.popValue(),
            .add, .sub, .mul, .div, .rem, .eq, .ne, .lt, .le, .gt, .ge => {
                const rhs = try self.popValue();
                const lhs = try self.popValue();
                const result = self.fresh();
                const instruction: []const u8 = switch (op) {
                    .add => "add",
                    .sub => "sub",
                    .mul => "mul",
                    .div => "sdiv",
                    .rem => "srem",
                    .eq => "icmp eq",
                    .ne => "icmp ne",
                    .lt => "icmp slt",
                    .le => "icmp sle",
                    .gt => "icmp sgt",
                    .ge => "icmp sge",
                    else => unreachable,
                };
                if (op == .eq or op == .ne or op == .lt or op == .le or op == .gt or op == .ge) {
                    const cmp = self.fresh();
                    try self.line("  {s} = {s} i64 {s}, {s}", .{ cmp, instruction, lhs, rhs });
                    try self.line("  {s} = zext i1 {s} to i64", .{ result, cmp });
                } else {
                    try self.line("  {s} = {s} i64 {s}, {s}", .{ result, instruction, lhs, rhs });
                }
                try self.pushValue(result);
            },
            .neg => {
                const value = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = sub i64 0, {s}", .{ result, value });
                try self.pushValue(result);
            },
            .not => {
                const value = try self.popValue();
                const cmp = self.fresh();
                const result = self.fresh();
                try self.line("  {s} = icmp eq i64 {s}, 0", .{ cmp, value });
                try self.line("  {s} = zext i1 {s} to i64", .{ result, cmp });
                try self.pushValue(result);
            },
            .jump => |target| try self.line("  br label %{s}", .{self.label(target)}),
            .jump_if_false => |target| {
                const value = try self.popValue();
                const cmp = self.fresh();
                const next = index + 1;
                try self.line("  {s} = icmp ne i64 {s}, 0", .{ cmp, value });
                if (next < function.code.len) {
                    try self.line("  br i1 {s}, label %{s}, label %{s}", .{
                        cmp, self.label(next), self.label(target),
                    });
                } else {
                    try self.line("  br i1 {s}, label %end, label %{s}", .{ cmp, self.label(target) });
                }
            },
            .call => |call| {
                const callee = self.module.functions[call.function];
                if (call.argc != callee.params) return error.InvalidBytecode;
                const args = self.arena.alloc([]const u8, call.argc) catch return error.OutOfMemory;
                var i: usize = call.argc;
                while (i > 0) {
                    i -= 1;
                    args[i] = try self.popValue();
                }
                var text = std.ArrayList(u8).empty;
                defer text.deinit(self.arena);
                try text.appendSlice(self.arena, "  ");
                const result = self.fresh();
                try text.appendSlice(self.arena, result);
                try text.appendSlice(self.arena, " = call i64 @");
                try text.appendSlice(self.arena, self.symbolName(callee.name));
                try text.appendSlice(self.arena, "(");
                for (args, 0..) |arg, arg_index| {
                    if (arg_index > 0) try text.appendSlice(self.arena, ", ");
                    try text.appendSlice(self.arena, "i64 ");
                    try text.appendSlice(self.arena, arg);
                }
                try text.appendSlice(self.arena, ")");
                try self.out.appendSlice(self.allocator, text.items);
                try self.out.append(self.allocator, '\n');
                try self.pushValue(result);
            },
            .function_ref => |callee| {
                if (callee >= self.module.functions.len) return error.InvalidBytecode;
                const address = self.fresh();
                try self.line("  {s} = ptrtoint ptr @{s} to i64", .{ address, self.symbolName(self.module.functions[callee].name) });
                try self.pushValue(address);
            },
            .call_indirect => |argc| {
                if (argc > 64) return error.InvalidBytecode;
                const args = self.arena.alloc([]const u8, argc) catch return error.OutOfMemory;
                var i: usize = argc;
                while (i > 0) {
                    i -= 1;
                    args[i] = try self.popValue();
                }
                const callee = try self.popValue();
                const result = self.fresh();
                var text = std.ArrayList(u8).empty;
                defer text.deinit(self.arena);
                try text.appendSlice(self.arena, "  ");
                try text.appendSlice(self.arena, result);
                try text.appendSlice(self.arena, " = call i64 @e7_hof_dispatch_");
                const count = std.fmt.allocPrint(self.arena, "{d}", .{argc}) catch return error.OutOfMemory;
                try text.appendSlice(self.arena, count);
                try text.appendSlice(self.arena, "(i64 ");
                try text.appendSlice(self.arena, callee);
                for (args) |arg| {
                    try text.appendSlice(self.arena, ", i64 ");
                    try text.appendSlice(self.arena, arg);
                }
                try text.appendSlice(self.arena, ")");
                try self.out.appendSlice(self.allocator, text.items);
                try self.out.append(self.allocator, '\n');
                try self.pushValue(result);
            },
            .runtime_call => |call| {
                if (call.argc != call.function.arity()) return error.InvalidBytecode;
                const args = self.arena.alloc([]const u8, call.argc) catch return error.OutOfMemory;
                var arg_index: usize = call.argc;
                while (arg_index > 0) {
                    arg_index -= 1;
                    args[arg_index] = try self.popValue();
                }
                var text = std.ArrayList(u8).empty;
                defer text.deinit(self.arena);
                try text.appendSlice(self.arena, "  ");
                const call_result = self.fresh();
                switch (call.function.returnKind()) {
                    .i64_ => {
                        try text.appendSlice(self.arena, call_result);
                        try text.appendSlice(self.arena, " = ");
                    },
                    .i32_ => {
                        try text.appendSlice(self.arena, call_result);
                        try text.appendSlice(self.arena, " = ");
                    },
                    .void_ => {},
                }
                try text.appendSlice(self.arena, "call ");
                try text.appendSlice(self.arena, switch (call.function.returnKind()) {
                    .i64_ => "i64",
                    .i32_ => "i32",
                    .void_ => "void",
                });
                try text.appendSlice(self.arena, " @");
                try text.appendSlice(self.arena, call.function.symbol());
                try text.appendSlice(self.arena, "(");
                for (args, 0..) |arg, arg_number| {
                    if (arg_number > 0) try text.appendSlice(self.arena, ", ");
                    try text.appendSlice(self.arena, "i64 ");
                    try text.appendSlice(self.arena, arg);
                }
                try text.appendSlice(self.arena, ")");
                try self.out.appendSlice(self.allocator, text.items);
                try self.out.append(self.allocator, '\n');
                const result = self.fresh();
                switch (call.function.returnKind()) {
                    .i64_ => try self.pushValue(call_result),
                    .i32_ => {
                        try self.line("  {s} = zext i32 {s} to i64", .{ result, call_result });
                        try self.pushValue(result);
                    },
                    .void_ => {
                        try self.line("  {s} = add i64 0, 0", .{result});
                        try self.pushValue(result);
                    },
                }
            },
            .create_task => |create| {
                const callee = self.module.functions[create.function];
                if (create.argc + 1 != callee.params) return error.InvalidBytecode;
                const args = self.arena.alloc([]const u8, create.argc) catch return error.OutOfMemory;
                var arg_index: usize = create.argc;
                while (arg_index > 0) {
                    arg_index -= 1;
                    args[arg_index] = try self.popValue();
                }
                const array = self.fresh();
                try self.line("  {s} = alloca [{d} x i64]", .{ array, @max(@as(u16, 1), create.argc) });
                for (args, 0..) |arg, i| {
                    const slot = self.fresh();
                    try self.line("  {s} = getelementptr [{d} x i64], ptr {s}, i64 0, i64 {d}", .{
                        slot, @max(@as(u16, 1), create.argc), array, i,
                    });
                    try self.line("  store i64 {s}, ptr {s}", .{ arg, slot });
                }
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_task_create(ptr @{s}, i64 {d}, ptr {s})", .{
                    result, self.symbolName(callee.name), create.argc, array,
                });
                try self.pushValue(result);
            },
            .task_await => {
                const task = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_task_await(i64 {s})", .{ result, task });
                try self.pushValue(result);
            },
            .task_spawn => {
                const task = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_task_spawn(i64 {s})", .{ result, task });
                try self.pushValue(result);
            },
            .task_detach => {
                const task = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_task_detach(i64 {s})", .{ result, task });
                try self.line("  {s} = add i64 0, 0", .{self.fresh()});
                // detach produces unit; keep a value on the operand stack.
                const unit = self.fresh();
                try self.line("  {s} = add i64 0, 0", .{unit});
                try self.pushValue(unit);
            },
            .task_cancel => {
                const task = try self.popValue();
                try self.line("  call i64 @e7_task_cancel(i64 {s})", .{task});
                const unit = self.fresh();
                try self.line("  {s} = add i64 0, 0", .{unit});
                try self.pushValue(unit);
            },
            .trigger_enter => |id| {
                const role = self.fresh();
                try self.line("  {s} = call i64 @e7_trigger_enter(i64 {d})", .{ role, id });
                try self.pushValue(role);
            },
            .trigger_leave => |id| {
                _ = self.fresh();
                try self.line("  call i64 @e7_trigger_leave(i64 {d})", .{id});
            },
            .alloc => {
                const size = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_alloc_i64(i64 {s})", .{ result, size });
                try self.pushValue(result);
            },
            .load_mem => {
                const ptr = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_load_i64(i64 {s})", .{ result, ptr });
                try self.pushValue(result);
            },
            .store_mem => {
                const value = try self.popValue();
                const ptr = try self.popValue();
                try self.line("  call void @e7_store_i64(i64 {s}, i64 {s})", .{ ptr, value });
            },
            .load_u8 => {
                const ptr = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_load_u8(i64 {s})", .{ result, ptr });
                try self.pushValue(result);
            },
            .store_u8 => {
                const value = try self.popValue();
                const ptr = try self.popValue();
                try self.line("  call void @e7_store_u8(i64 {s}, i64 {s})", .{ ptr, value });
            },
            .local_addr => |slot| {
                const result = self.fresh();
                try self.line("  {s} = ptrtoint ptr %l{d} to i64", .{ result, slot });
                try self.pushValue(result);
            },
            .string_lit => |bytes| {
                const array = self.fresh();
                try self.line("  {s} = alloca [{d} x i8]", .{ array, @max(@as(usize, 1), bytes.len) });
                for (bytes, 0..) |byte, i| {
                    const slot = self.fresh();
                    try self.line("  {s} = getelementptr [{d} x i8], ptr {s}, i64 0, i64 {d}", .{ slot, @max(@as(usize, 1), bytes.len), array, i });
                    try self.line("  store i8 {d}, ptr {s}", .{ byte, slot });
                }
                const data = self.fresh();
                try self.line("  {s} = ptrtoint ptr {s} to i64", .{ data, array });
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_str_new(i64 {s}, i64 {d})", .{ result, data, bytes.len });
                try self.pushValue(result);
            },
            .vec_new => {
                const columns = try self.popValue();
                const rows = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_vec_new(i64 {s}, i64 {s})", .{ result, rows, columns });
                try self.pushValue(result);
            },
            .vec_len => {
                const vec = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_vec_len(i64 {s})", .{ result, vec });
                try self.pushValue(result);
            },
            .vec_get => {
                const idx = try self.popValue();
                const vec = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_vec_get(i64 {s}, i64 {s})", .{ result, vec, idx });
                try self.pushValue(result);
            },
            .vec_set => {
                const value = try self.popValue();
                const idx = try self.popValue();
                const vec = try self.popValue();
                try self.line("  call void @e7_vec_set(i64 {s}, i64 {s}, i64 {s})", .{ vec, idx, value });
            },
            .vec_row => {
                const idx = try self.popValue();
                const vec = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_vec_row(i64 {s}, i64 {s})", .{ result, vec, idx });
                try self.pushValue(result);
            },
            .vec_get2 => {
                const column = try self.popValue();
                const row = try self.popValue();
                const matrix = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_vec_get2(i64 {s}, i64 {s}, i64 {s})", .{
                    result, matrix, row, column,
                });
                try self.pushValue(result);
            },
            .vec_set2 => {
                const value = try self.popValue();
                const column = try self.popValue();
                const row = try self.popValue();
                const matrix = try self.popValue();
                try self.line("  call void @e7_vec_set2(i64 {s}, i64 {s}, i64 {s}, i64 {s})", .{
                    matrix, row, column, value,
                });
            },
            .vec_set_row => {
                const row_vector = try self.popValue();
                const row = try self.popValue();
                const matrix = try self.popValue();
                try self.line("  call void @e7_vec_set_row(i64 {s}, i64 {s}, i64 {s})", .{
                    matrix, row, row_vector,
                });
            },
            .vec_binary => |code| {
                const b = try self.popValue();
                const a = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_vec_binary(i64 {d}, i64 {s}, i64 {s})", .{ result, code, a, b });
                try self.pushValue(result);
            },
            .vec_scalar => |code| {
                const scalar = try self.popValue();
                const vec = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_vec_scalar(i64 {d}, i64 {s}, i64 {s})", .{ result, code, vec, scalar });
                try self.pushValue(result);
            },
            .map_new => {
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_map_new()", .{result});
                try self.pushValue(result);
            },
            .map_get => {
                const key = try self.popValue();
                const map = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_map_get(i64 {s}, i64 {s})", .{ result, map, key });
                try self.pushValue(result);
            },
            .map_set => {
                const value = try self.popValue();
                const key = try self.popValue();
                const map = try self.popValue();
                try self.line("  call void @e7_map_set(i64 {s}, i64 {s}, i64 {s})", .{ map, key, value });
            },
            .map_get_str => {
                const key = try self.popValue();
                const map = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_map_get_str(i64 {s}, i64 {s})", .{ result, map, key });
                try self.pushValue(result);
            },
            .map_set_str => {
                const value = try self.popValue();
                const key = try self.popValue();
                const map = try self.popValue();
                try self.line("  call void @e7_map_set_str(i64 {s}, i64 {s}, i64 {s})", .{ map, key, value });
            },
            .str_concat => {
                const b = try self.popValue();
                const a = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_str_concat(i64 {s}, i64 {s})", .{ result, a, b });
                try self.pushValue(result);
            },
            .str_eq => {
                const b = try self.popValue();
                const a = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_str_eq(i64 {s}, i64 {s})", .{ result, a, b });
                try self.pushValue(result);
            },
            .str_len => {
                const str = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_str_len(i64 {s})", .{ result, str });
                try self.pushValue(result);
            },
            .str_slice => {
                const end = try self.popValue();
                const start = try self.popValue();
                const str = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_str_slice(i64 {s}, i64 {s}, i64 {s})", .{ result, str, start, end });
                try self.pushValue(result);
            },
            .str_char_at => {
                const char_index = try self.popValue();
                const str = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_str_char_at(i64 {s}, i64 {s})", .{ result, str, char_index });
                try self.pushValue(result);
            },
            .map_len => {
                const map = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_map_len(i64 {s})", .{ result, map });
                try self.pushValue(result);
            },
            .map_key_at => {
                const entry_index = try self.popValue();
                const map = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_map_key_at(i64 {s}, i64 {s})", .{ result, map, entry_index });
                try self.pushValue(result);
            },
            .map_value_at => {
                const entry_index = try self.popValue();
                const map = try self.popValue();
                const result = self.fresh();
                try self.line("  {s} = call i64 @e7_map_value_at(i64 {s}, i64 {s})", .{ result, map, entry_index });
                try self.pushValue(result);
            },
            .ret => {
                const value = try self.popValue();
                try self.line("  ret i64 {s}", .{value});
            },
        }
        switch (op) {
            .jump, .jump_if_false, .ret => {},
            else => {
                if (index + 1 < function.code.len) {
                    try self.line("  br label %{s}", .{self.label(index + 1)});
                } else {
                    try self.line("  br label %end", .{});
                }
            },
        }
    }

    fn push(self: *Translator, value: i64) Error!void {
        const text = try std.fmt.allocPrint(self.arena, "{d}", .{value});
        try self.pushValue(text);
    }

    fn pushValue(self: *Translator, value: []const u8) Error!void {
        const sp = self.fresh();
        const slot = self.fresh();
        const sp_next = self.fresh();
        try self.line("  {s} = load i64, ptr %sp", .{sp});
        try self.line("  {s} = getelementptr [{d} x i64], ptr %stack, i64 0, i64 {s}", .{ slot, self.max_stack, sp });
        try self.line("  store i64 {s}, ptr {s}", .{ value, slot });
        try self.line("  {s} = add i64 {s}, 1", .{ sp_next, sp });
        try self.line("  store i64 {s}, ptr %sp", .{sp_next});
    }

    fn popValue(self: *Translator) Error![]const u8 {
        const sp = self.fresh();
        const sp_prev = self.fresh();
        const slot = self.fresh();
        const value = self.fresh();
        try self.line("  {s} = load i64, ptr %sp", .{sp});
        try self.line("  {s} = sub i64 {s}, 1", .{ sp_prev, sp });
        try self.line("  store i64 {s}, ptr %sp", .{sp_prev});
        try self.line("  {s} = getelementptr [{d} x i64], ptr %stack, i64 0, i64 {s}", .{ slot, self.max_stack, sp_prev });
        try self.line("  {s} = load i64, ptr {s}", .{ value, slot });
        return value;
    }
};
