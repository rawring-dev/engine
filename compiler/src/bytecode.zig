//! Engine intermediate bytecode.
//!
//! The compiler lowers the checked AST to this compact stack machine and the
//! runtime translates it to LLVM IR for the ORC JIT.  The format is deliberately
//! small and explicitly versioned so the compiler/runtime boundary is stable:
//!
//!   magic "E7BC", u16 version, u16 entry, u32 function count,
//!   functions { name, params, locals, max_stack, code }
//!
//! Values are 64-bit integers; booleans are 0 or 1.  The bytecode is verified
//! before serialization and again after decoding.

const std = @import("std");

pub const magic = "E7BC";
pub const version: u16 = 1;
pub const max_stack_limit: u16 = 1024;

pub const Error = error{
    OutOfMemory,
    InvalidBytecode,
};

pub const Call = struct {
    function: u16,
    argc: u16,
};

/// Runtime C-ABI entry points that bytecode can call directly.
///
/// The compiler targets a stable subset of the runtime intrinsics; keeping the
/// symbol spelled as an enum (rather than a string payload) makes the encoding
/// compact and lets the translator emit exact LLVM declarations.  Every entry
/// is declared with an `i64` result in generated IR: the pointer/handle
/// functions genuinely return `i64`, while the `i32`-returning registration and
/// command helpers only use the low result bits, which the backend ignores.
pub const RuntimeFunction = enum(u8) {
    ecs_reset,
    ecs_register_resource,
    ecs_register_component,
    ecs_resource,
    ecs_has_resource,
    ecs_entity_count,
    ecs_component_get,
    ecs_commands,
    ecs_commands_insert_resource,
    ecs_commands_row_begin,
    ecs_commands_row_add,
    ecs_commands_row_finish,
    ecs_commands_add_plugin,
    ecs_commands_flush,
    ecs_plugin_active,
    ecs_query_begin,
    ecs_query_next,
    ecs_query_component,
    // Engine/window/scene intrinsics (host-provided, see runtime/src/engine.zig).
    engine_window_create,
    engine_window_pump,
    engine_window_should_close,
    engine_window_destroy,
    engine_time_now_ms,
    engine_read_shader,
    engine_scene_create,
    engine_scene_destroy,
    engine_scene_resize,
    engine_scene_set_camera,
    engine_scene_set_cube_angle,
    engine_scene_set_light,
    engine_scene_begin_frame,
    engine_scene_draw_mesh,
    engine_scene_draw_box,
    engine_scene_end_frame,
    engine_should_close,
    engine_key_down,
    engine_mouse_dx,
    engine_mouse_dy,
    // Float helpers (f64 bit patterns in i64 slots; see runtime/src/float.zig).
    float_add,
    float_sub,
    float_mul,
    float_div,
    float_neg,
    float_eq,
    float_ne,
    float_lt,
    float_le,
    float_gt,
    float_ge,
    float_sin,
    float_cos,
    float_sqrt,
    float_abs,
    float_clamp,
    float_from_i64,
    float_to_i64,
    float_to_milli,
    float_from_milli,
    // JSON builtins (schema string + value/text); see runtime/src/json.zig.
    json_encode,
    json_decode,
    // Image loading and generic text/parsing helpers.
    image_load,
    image_width,
    image_height,
    image_pixels,
    image_free,
    str_lines,
    str_fields,
    str_split,
    parse_i64,
    parse_f32,
    vec_push,

    pub fn symbol(self: RuntimeFunction) []const u8 {
        return switch (self) {
            .ecs_reset => "e7_ecs_reset",
            .ecs_register_resource => "e7_ecs_register_resource",
            .ecs_register_component => "e7_ecs_register_component",
            .ecs_resource => "e7_ecs_resource",
            .ecs_has_resource => "e7_ecs_has_resource",
            .ecs_entity_count => "e7_ecs_entity_count",
            .ecs_component_get => "e7_ecs_component_get",
            .ecs_commands => "e7_ecs_commands",
            .ecs_commands_insert_resource => "e7_ecs_commands_insert_resource",
            .ecs_commands_row_begin => "e7_ecs_commands_row_begin",
            .ecs_commands_row_add => "e7_ecs_commands_row_add",
            .ecs_commands_row_finish => "e7_ecs_commands_row_finish",
            .ecs_commands_add_plugin => "e7_ecs_commands_add_plugin",
            .ecs_commands_flush => "e7_ecs_commands_flush",
            .ecs_plugin_active => "e7_ecs_plugin_active",
            .ecs_query_begin => "e7_ecs_query_begin",
            .ecs_query_next => "e7_ecs_query_next",
            .ecs_query_component => "e7_ecs_query_component",
            .engine_window_create => "e7_engine_window_create",
            .engine_window_pump => "e7_engine_window_pump",
            .engine_window_should_close => "e7_engine_window_should_close",
            .engine_window_destroy => "e7_engine_window_destroy",
            .engine_time_now_ms => "e7_engine_time_now_ms",
            .engine_read_shader => "e7_engine_read_shader",
            .engine_scene_create => "e7_engine_scene_create",
            .engine_scene_destroy => "e7_engine_scene_destroy",
            .engine_scene_resize => "e7_engine_scene_resize",
            .engine_scene_set_camera => "e7_engine_scene_set_camera",
            .engine_scene_set_cube_angle => "e7_engine_scene_set_cube_angle",
            .engine_scene_set_light => "e7_engine_scene_set_light",
            .engine_scene_begin_frame => "e7_engine_scene_begin_frame",
            .engine_scene_draw_mesh => "e7_engine_scene_draw_mesh",
            .engine_scene_draw_box => "e7_engine_scene_draw_box",
            .engine_scene_end_frame => "e7_engine_scene_end_frame",
            .engine_should_close => "e7_engine_should_close",
            .engine_key_down => "e7_engine_key_down",
            .engine_mouse_dx => "e7_engine_mouse_dx",
            .engine_mouse_dy => "e7_engine_mouse_dy",
            .float_add => "e7_f32_add",
            .float_sub => "e7_f32_sub",
            .float_mul => "e7_f32_mul",
            .float_div => "e7_f32_div",
            .float_neg => "e7_f32_neg",
            .float_eq => "e7_f32_eq",
            .float_ne => "e7_f32_ne",
            .float_lt => "e7_f32_lt",
            .float_le => "e7_f32_le",
            .float_gt => "e7_f32_gt",
            .float_ge => "e7_f32_ge",
            .float_sin => "e7_f32_sin",
            .float_cos => "e7_f32_cos",
            .float_sqrt => "e7_f32_sqrt",
            .float_abs => "e7_f32_abs",
            .float_clamp => "e7_f32_clamp",
            .float_from_i64 => "e7_f32_from_i64",
            .float_to_i64 => "e7_f32_to_i64",
            .float_to_milli => "e7_f32_to_milli",
            .float_from_milli => "e7_f32_from_milli",
            .json_encode => "e7_json_encode",
            .json_decode => "e7_json_decode",
            .image_load => "e7_image_load",
            .image_width => "e7_image_width",
            .image_height => "e7_image_height",
            .image_pixels => "e7_image_pixels",
            .image_free => "e7_image_free",
            .str_lines => "e7_str_lines",
            .str_fields => "e7_str_fields",
            .str_split => "e7_str_split",
            .parse_i64 => "e7_parse_i64",
            .parse_f32 => "e7_parse_f32",
            .vec_push => "e7_vec_push",
        };
    }

    /// Look up a runtime entry by its C symbol name (the same name e7 source
    /// uses for compiler-known intrinsics).
    pub fn fromSymbol(name: []const u8) ?RuntimeFunction {
        for (std.enums.values(RuntimeFunction)) |function| {
            if (std.mem.eql(u8, function.symbol(), name)) return function;
        }
        return null;
    }

    /// Number of `i64` arguments the ABI entry takes.
    pub fn arity(self: RuntimeFunction) u16 {
        return switch (self) {
            .ecs_reset, .ecs_entity_count, .ecs_commands => 0,
            .ecs_resource,
            .ecs_has_resource,
            .ecs_component_get,
            .ecs_commands_row_begin,
            .ecs_commands_row_finish,
            .ecs_commands_flush,
            .ecs_plugin_active,
            .ecs_query_next,
            => 1,
            .ecs_query_component => 2,
            .ecs_register_resource,
            .ecs_register_component,
            .ecs_commands_add_plugin,
            => 2,
            .ecs_commands_insert_resource, .ecs_commands_row_add => 3,
            .ecs_query_begin => 4,
            .engine_window_create, .engine_scene_resize => 3,
            .engine_window_pump,
            .engine_window_should_close,
            .engine_window_destroy,
            .engine_read_shader,
            .engine_scene_destroy,
            .engine_key_down,
            => 1,
            .engine_scene_create => 3,
            .engine_time_now_ms, .engine_should_close, .engine_mouse_dx, .engine_mouse_dy => 0,
            .engine_scene_set_camera => 6,
            .engine_scene_set_cube_angle => 2,
            .engine_scene_set_light => 8,
            .engine_scene_draw_box => 8,
            .engine_scene_begin_frame,
            .engine_scene_draw_mesh,
            .engine_scene_end_frame,
            => 1,
            .float_add, .float_sub, .float_mul, .float_div => 2,
            .float_eq, .float_ne, .float_lt, .float_le, .float_gt, .float_ge => 2,
            .float_neg, .float_sin, .float_cos, .float_sqrt, .float_abs => 1,
            .float_clamp => 3,
            .float_from_i64, .float_to_i64, .float_to_milli, .float_from_milli => 1,
            .json_encode, .json_decode => 2,
            .image_load, .image_width, .image_height, .image_pixels, .image_free => 1,
            .str_lines, .str_fields, .parse_i64, .parse_f32 => 1,
            .str_split, .vec_push => 2,
        };
    }

    /// C return type of the ABI entry.  The bytecode stack is uniformly i64;
    /// the IR translator widens `i32` statuses and produces a dummy `0` for
    /// `void`, so callers that ignore the result stay simple.
    pub fn returnKind(self: RuntimeFunction) ReturnKind {
        return switch (self) {
            .ecs_reset => .void_,
            .ecs_register_resource,
            .ecs_register_component,
            .ecs_commands_insert_resource,
            .ecs_commands_row_add,
            .ecs_commands_row_finish,
            .ecs_commands_add_plugin,
            .ecs_commands_flush,
            .image_free,
            => .i32_,
            else => .i64_,
        };
    }
};

pub const ReturnKind = enum { i64_, i32_, void_ };

pub const RuntimeCall = struct {
    function: RuntimeFunction,
    argc: u16,
};

pub const Op = union(enum) {
    nop,
    push_i64: i64,
    load_local: u16,
    store_local: u16,
    pop,
    add,
    sub,
    mul,
    div,
    rem,
    neg,
    not,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    jump: u32,
    jump_if_false: u32,
    call: Call,
    /// Call a runtime C-ABI intrinsic; arguments are popped like `call` and one
    /// `i64` result is pushed (the backend ignores results it does not use).
    runtime_call: RuntimeCall,
    create_task: Call,
    task_await,
    task_spawn,
    task_detach,
    task_cancel,
    trigger_enter: u16,
    trigger_leave: u16,
    alloc,
    load_mem,
    store_mem,
    load_u8,
    store_u8,
    local_addr: u16,
    string_lit: []const u8,
    vec_new,
    vec_len,
    vec_get,
    vec_set,
    vec_row,
    vec_get2,
    vec_set2,
    vec_set_row,
    vec_binary: u8,
    vec_scalar: u8,
    map_new,
    map_get,
    map_set,
    map_get_str,
    map_set_str,
    str_concat,
    str_eq,
    str_len,
    str_slice,
    str_char_at,
    map_len,
    map_key_at,
    map_value_at,
    ret,
};

pub const Function = struct {
    name: []const u8,
    params: u16,
    locals: u16,
    max_stack: u16,
    code: []Op,
};

pub const Module = struct {
    allocator: std.mem.Allocator,
    functions: []Function,
    entry: ?u16 = null,

    pub fn deinit(self: *Module) void {
        for (self.functions) |function| {
            self.allocator.free(function.name);
            self.allocator.free(function.code);
        }
        self.allocator.free(self.functions);
        self.* = undefined;
    }

    pub fn functionNamed(self: *const Module, name: []const u8) ?u16 {
        for (self.functions, 0..) |function, i| {
            if (std.mem.eql(u8, function.name, name)) return @intCast(i);
        }
        return null;
    }
};

pub const Stats = struct {
    iterations: usize,
    folds: usize,
    reached_fixed_point: bool,
};

pub const OptimizeConfig = struct {
    max_iterations: usize = 16,
};

/// Fold stack constants and remove redundant push/pop pairs.  Jump targets are
/// never rewritten, so folded instructions become `nop` placeholders rather
/// than shifting branch offsets.
pub fn optimize(
    allocator: std.mem.Allocator,
    module: *Module,
    config: OptimizeConfig,
) Error!Stats {
    var iterations: usize = 0;
    var total_folds: usize = 0;
    var fixed = false;
    while (iterations < config.max_iterations) : (iterations += 1) {
        var folds: usize = 0;
        for (module.functions) |*function| {
            folds += try foldFunction(allocator, function);
        }
        total_folds += folds;
        if (folds == 0) {
            fixed = true;
            iterations += 1;
            break;
        }
    }
    return .{ .iterations = iterations, .folds = total_folds, .reached_fixed_point = fixed };
}

fn foldFunction(allocator: std.mem.Allocator, function: *Function) Error!usize {
    const code = function.code;
    if (code.len == 0) return 0;
    const targets = try allocator.alloc(bool, code.len);
    defer allocator.free(targets);
    @memset(targets, false);
    for (code) |op| switch (op) {
        .jump => |target| if (target < code.len) {
            targets[target] = true;
        },
        .jump_if_false => |target| if (target < code.len) {
            targets[target] = true;
        },
        else => {},
    };

    var folds: usize = 0;
    var i: usize = 0;
    while (i < code.len) {
        if (code[i] == .push_i64) {
            const j = nextNonNop(code, i + 1) orelse {
                i += 1;
                continue;
            };
            if (code[j] == .push_i64) {
                if (nextNonNop(code, j + 1)) |k| {
                    if (!targets[j] and !targets[k]) {
                        if (evalBinary(code[k], code[i].push_i64, code[j].push_i64)) |result| {
                            code[i] = .{ .push_i64 = result };
                            code[j] = .nop;
                            code[k] = .nop;
                            folds += 1;
                            i = k + 1;
                            continue;
                        }
                    }
                }
            }
            if (!targets[j]) {
                switch (code[j]) {
                    .neg => {
                        code[i] = .{ .push_i64 = -%code[i].push_i64 };
                        code[j] = .nop;
                        folds += 1;
                        i = j + 1;
                        continue;
                    },
                    .not => {
                        code[i] = .{ .push_i64 = if (code[i].push_i64 == 0) 1 else 0 };
                        code[j] = .nop;
                        folds += 1;
                        i = j + 1;
                        continue;
                    },
                    .pop => {
                        code[i] = .nop;
                        code[j] = .nop;
                        folds += 1;
                        i = j + 1;
                        continue;
                    },
                    else => {},
                }
            }
        }
        i += 1;
    }

    return folds;
}

fn nextNonNop(code: []const Op, start: usize) ?usize {
    var index = start;
    while (index < code.len) : (index += 1) {
        if (code[index] != .nop) return index;
    }
    return null;
}

fn evalBinary(op: Op, lhs: i64, rhs: i64) ?i64 {
    return switch (op) {
        .add => lhs +% rhs,
        .sub => lhs -% rhs,
        .mul => lhs *% rhs,
        .div => if (rhs == 0 or (lhs == std.math.minInt(i64) and rhs == -1)) null else @divTrunc(lhs, rhs),
        .rem => if (rhs == 0) null else @rem(lhs, rhs),
        .eq => if (lhs == rhs) 1 else 0,
        .ne => if (lhs != rhs) 1 else 0,
        .lt => if (lhs < rhs) 1 else 0,
        .le => if (lhs <= rhs) 1 else 0,
        .gt => if (lhs > rhs) 1 else 0,
        .ge => if (lhs >= rhs) 1 else 0,
        else => null,
    };
}

pub fn verify(allocator: std.mem.Allocator, module: *const Module) Error!void {
    if (module.functions.len == 0) return error.InvalidBytecode;
    if (module.entry) |entry| if (entry >= module.functions.len) return error.InvalidBytecode;
    for (module.functions, 0..) |function, function_index| {
        _ = function_index;
        if (function.name.len == 0) return error.InvalidBytecode;
        if (function.max_stack == 0 or function.max_stack > max_stack_limit) return error.InvalidBytecode;
        if (function.code.len == 0) return error.InvalidBytecode;
        try verifyFunction(allocator, module, function);
    }
}

fn verifyFunction(allocator: std.mem.Allocator, module: *const Module, function: Function) Error!void {
    const heights = try allocator.alloc(?i32, function.code.len);
    defer allocator.free(heights);
    @memset(heights, null);
    var work = std.ArrayList(usize).empty;
    defer work.deinit(allocator);
    try work.append(allocator, 0);

    while (work.pop()) |index| {
        const height = heights[index] orelse 0;
        if (heights[index] == null) heights[index] = height;
        const op = function.code[index];
        var fallthrough: ?usize = null;
        var next_height: i32 = height;
        switch (op) {
            .nop => {},
            .push_i64 => {
                next_height += 1;
                fallthrough = index + 1;
            },
            .load_local => |local| {
                if (local >= function.locals) return error.InvalidBytecode;
                next_height += 1;
                fallthrough = index + 1;
            },
            .store_local => |local| {
                if (local >= function.locals or height < 1) return error.InvalidBytecode;
                next_height -= 1;
                fallthrough = index + 1;
            },
            .pop => {
                if (height < 1) return error.InvalidBytecode;
                next_height -= 1;
                fallthrough = index + 1;
            },
            .add, .sub, .mul, .div, .rem, .eq, .ne, .lt, .le, .gt, .ge => {
                if (height < 2) return error.InvalidBytecode;
                next_height -= 1;
                fallthrough = index + 1;
            },
            .neg, .not => {
                if (height < 1) return error.InvalidBytecode;
                fallthrough = index + 1;
            },
            .jump => |target| {
                try enqueueTarget(allocator, &work, heights, function, target, height);
                continue;
            },
            .jump_if_false => |target| {
                if (height < 1) return error.InvalidBytecode;
                next_height -= 1;
                try enqueueTarget(allocator, &work, heights, function, target, next_height);
                fallthrough = index + 1;
            },
            .call => |call| {
                if (call.function >= module.functions.len) return error.InvalidBytecode;
                if (call.argc != module.functions[call.function].params) return error.InvalidBytecode;
                if (height < call.argc) return error.InvalidBytecode;
                next_height = height - @as(i32, call.argc) + 1;
                fallthrough = index + 1;
            },
            .runtime_call => |call| {
                if (call.argc != call.function.arity()) return error.InvalidBytecode;
                if (height < call.argc) return error.InvalidBytecode;
                next_height = height - @as(i32, call.argc) + 1;
                fallthrough = index + 1;
            },
            .create_task => |call| {
                if (call.function >= module.functions.len) return error.InvalidBytecode;
                if (call.argc + 1 != module.functions[call.function].params) return error.InvalidBytecode;
                if (height < call.argc) return error.InvalidBytecode;
                next_height = height - @as(i32, call.argc) + 1;
                fallthrough = index + 1;
            },
            .task_await, .task_spawn => {
                if (height < 1) return error.InvalidBytecode;
                fallthrough = index + 1;
            },
            .task_detach, .task_cancel => {
                if (height < 1) return error.InvalidBytecode;
                next_height -= 1;
                fallthrough = index + 1;
            },
            .trigger_enter => {
                next_height += 1;
                fallthrough = index + 1;
            },
            .trigger_leave => {
                fallthrough = index + 1;
            },
            .alloc, .load_mem, .vec_len, .str_len, .map_len => {
                if (height < 1) return error.InvalidBytecode;
                fallthrough = index + 1;
            },
            .load_u8 => {
                if (height < 1) return error.InvalidBytecode;
                fallthrough = index + 1;
            },
            .vec_get, .vec_row, .vec_binary, .vec_scalar, .map_get, .map_get_str, .str_concat, .str_eq, .str_char_at, .map_key_at, .map_value_at => {
                if (height < 2) return error.InvalidBytecode;
                next_height -= 1;
                fallthrough = index + 1;
            },
            // `store_mem` pops the address and the value (the IR translator
            // calls `e7_store_i64(ptr, value)` after two pops).
            .store_mem => {
                if (height < 2) return error.InvalidBytecode;
                next_height -= 2;
                fallthrough = index + 1;
            },
            .vec_get2 => {
                if (height < 3) return error.InvalidBytecode;
                next_height -= 2;
                fallthrough = index + 1;
            },
            // Set operations pop container + key/index + value and push nothing.
            .vec_set, .vec_set_row, .map_set, .map_set_str => {
                if (height < 3) return error.InvalidBytecode;
                next_height -= 3;
                fallthrough = index + 1;
            },
            .str_slice => {
                if (height < 3) return error.InvalidBytecode;
                next_height -= 2;
                fallthrough = index + 1;
            },
            .store_u8 => {
                if (height < 2) return error.InvalidBytecode;
                next_height -= 2;
                fallthrough = index + 1;
            },
            .vec_set2 => {
                if (height < 4) return error.InvalidBytecode;
                next_height -= 3;
                fallthrough = index + 1;
            },
            .local_addr => {
                next_height += 1;
                fallthrough = index + 1;
            },
            .string_lit, .map_new => {
                next_height += 1;
                fallthrough = index + 1;
            },
            .vec_new => {
                if (height < 2) return error.InvalidBytecode;
                next_height -= 1;
                fallthrough = index + 1;
            },
            .ret => {
                if (height < 1) return error.InvalidBytecode;
                continue;
            },
        }
        if (next_height > function.max_stack) return error.InvalidBytecode;
        if (fallthrough) |next| {
            if (next >= function.code.len) return error.InvalidBytecode;
            try enqueueTarget(allocator, &work, heights, function, next, next_height);
        }
    }
}

fn enqueueTarget(
    allocator: std.mem.Allocator,
    work: *std.ArrayList(usize),
    heights: []?i32,
    function: Function,
    target: usize,
    height: i32,
) Error!void {
    if (target >= function.code.len) return error.InvalidBytecode;
    if (height < 0 or height > function.max_stack) return error.InvalidBytecode;
    if (heights[target]) |existing| {
        if (existing != height) return error.InvalidBytecode;
        return;
    }
    heights[target] = height;
    try work.append(allocator, target);
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

pub fn encode(allocator: std.mem.Allocator, module: *const Module) Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, magic);
    try writeU16(&out, allocator, version);
    try writeU16(&out, allocator, module.entry orelse std.math.maxInt(u16));
    try writeU32(&out, allocator, @intCast(module.functions.len));
    for (module.functions) |function| {
        try writeU16(&out, allocator, @intCast(function.name.len));
        try out.appendSlice(allocator, function.name);
        try writeU16(&out, allocator, function.params);
        try writeU16(&out, allocator, function.locals);
        try writeU16(&out, allocator, function.max_stack);
        try writeU32(&out, allocator, @intCast(function.code.len));
        for (function.code) |op| try encodeOp(&out, allocator, op);
    }
    return out.toOwnedSlice(allocator);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Module {
    var cursor = Cursor{ .bytes = bytes };
    if (!std.mem.eql(u8, cursor.take(4) orelse return error.InvalidBytecode, magic)) return error.InvalidBytecode;
    if ((cursor.readU16() orelse return error.InvalidBytecode) != version) return error.InvalidBytecode;
    const entry_raw = cursor.readU16() orelse return error.InvalidBytecode;
    const count = cursor.readU32() orelse return error.InvalidBytecode;
    if (count == 0 or count > 1_000_000) return error.InvalidBytecode;
    const functions = try allocator.alloc(Function, count);
    var initialized: usize = 0;
    errdefer {
        for (functions[0..initialized]) |function| {
            allocator.free(function.name);
            allocator.free(function.code);
        }
        allocator.free(functions);
    }
    for (functions) |*function| {
        const name_len = cursor.readU16() orelse return error.InvalidBytecode;
        const name = cursor.take(name_len) orelse return error.InvalidBytecode;
        const params = cursor.readU16() orelse return error.InvalidBytecode;
        const locals = cursor.readU16() orelse return error.InvalidBytecode;
        const max_stack = cursor.readU16() orelse return error.InvalidBytecode;
        const code_len = cursor.readU32() orelse return error.InvalidBytecode;
        if (code_len == 0 or code_len > 10_000_000) return error.InvalidBytecode;
        const code = try allocator.alloc(Op, code_len);
        errdefer allocator.free(code);
        for (code) |*op| op.* = try decodeOp(&cursor);
        function.* = .{
            .name = try allocator.dupe(u8, name),
            .params = params,
            .locals = locals,
            .max_stack = max_stack,
            .code = code,
        };
        initialized += 1;
    }
    if (cursor.offset != bytes.len) return error.InvalidBytecode;
    var module = Module{
        .allocator = allocator,
        .functions = functions,
        .entry = if (entry_raw == std.math.maxInt(u16)) null else entry_raw,
    };
    try verify(allocator, &module);
    return module;
}

const Cursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *Cursor, count: usize) ?[]const u8 {
        if (self.offset + count > self.bytes.len) return null;
        const slice = self.bytes[self.offset .. self.offset + count];
        self.offset += count;
        return slice;
    }
    fn readU16(self: *Cursor) ?u16 {
        const bytes = self.take(2) orelse return null;
        return std.mem.readInt(u16, bytes[0..2], .little);
    }
    fn readU32(self: *Cursor) ?u32 {
        const bytes = self.take(4) orelse return null;
        return std.mem.readInt(u32, bytes[0..4], .little);
    }
    fn readI64(self: *Cursor) ?i64 {
        const bytes = self.take(8) orelse return null;
        return @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
    }
};

fn writeU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) Error!void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}
fn writeU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}
fn writeI64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i64) Error!void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @bitCast(value), .little);
    try out.appendSlice(allocator, &bytes);
}

fn encodeOp(out: *std.ArrayList(u8), allocator: std.mem.Allocator, op: Op) Error!void {
    const tag: u8 = switch (op) {
        .nop => 0,
        .push_i64 => 1,
        .load_local => 2,
        .store_local => 3,
        .pop => 4,
        .add => 5,
        .sub => 6,
        .mul => 7,
        .div => 8,
        .rem => 9,
        .neg => 10,
        .not => 11,
        .eq => 12,
        .ne => 13,
        .lt => 14,
        .le => 15,
        .gt => 16,
        .ge => 17,
        .jump => 18,
        .jump_if_false => 19,
        .call => 20,
        .ret => 21,
        .create_task => 22,
        .task_await => 23,
        .task_spawn => 24,
        .task_detach => 25,
        .task_cancel => 26,
        .trigger_enter => 27,
        .trigger_leave => 28,
        .alloc => 29,
        .load_mem => 30,
        .store_mem => 31,
        .load_u8 => 32,
        .store_u8 => 33,
        .local_addr => 34,
        .string_lit => 35,
        .vec_new => 36,
        .vec_len => 37,
        .vec_get => 38,
        .vec_set => 39,
        .vec_row => 40,
        .vec_binary => 41,
        .vec_scalar => 42,
        .map_new => 43,
        .map_get => 44,
        .map_set => 45,
        .str_concat => 46,
        .str_eq => 47,
        .map_get_str => 48,
        .map_set_str => 49,
        .str_len => 50,
        .str_slice => 51,
        .str_char_at => 52,
        .map_len => 53,
        .map_key_at => 54,
        .map_value_at => 55,
        .vec_get2 => 56,
        .vec_set2 => 57,
        .vec_set_row => 58,
        .runtime_call => 59,
    };
    try out.append(allocator, tag);
    switch (op) {
        .push_i64 => |value| try writeI64(out, allocator, value),
        .load_local, .store_local => |local| try writeU16(out, allocator, local),
        .jump, .jump_if_false => |target| try writeU32(out, allocator, target),
        .trigger_enter, .trigger_leave => |id| try writeU16(out, allocator, id),
        .local_addr => |slot| try writeU16(out, allocator, slot),
        .string_lit => |bytes| {
            try writeU32(out, allocator, @intCast(bytes.len));
            try out.appendSlice(allocator, bytes);
        },
        .vec_binary, .vec_scalar => |code| try out.append(allocator, code),
        .call, .create_task => |call| {
            try writeU16(out, allocator, call.function);
            try writeU16(out, allocator, call.argc);
        },
        .runtime_call => |call| {
            try out.append(allocator, @intFromEnum(call.function));
            try writeU16(out, allocator, call.argc);
        },
        else => {},
    }
}

fn decodeOp(cursor: *Cursor) Error!Op {
    const tag = (cursor.take(1) orelse return error.InvalidBytecode)[0];
    return switch (tag) {
        0 => .nop,
        1 => .{ .push_i64 = cursor.readI64() orelse return error.InvalidBytecode },
        2 => .{ .load_local = cursor.readU16() orelse return error.InvalidBytecode },
        3 => .{ .store_local = cursor.readU16() orelse return error.InvalidBytecode },
        4 => .pop,
        5 => .add,
        6 => .sub,
        7 => .mul,
        8 => .div,
        9 => .rem,
        10 => .neg,
        11 => .not,
        12 => .eq,
        13 => .ne,
        14 => .lt,
        15 => .le,
        16 => .gt,
        17 => .ge,
        18 => .{ .jump = cursor.readU32() orelse return error.InvalidBytecode },
        19 => .{ .jump_if_false = cursor.readU32() orelse return error.InvalidBytecode },
        20 => .{ .call = .{
            .function = cursor.readU16() orelse return error.InvalidBytecode,
            .argc = cursor.readU16() orelse return error.InvalidBytecode,
        } },
        21 => .ret,
        22 => .{ .create_task = .{
            .function = cursor.readU16() orelse return error.InvalidBytecode,
            .argc = cursor.readU16() orelse return error.InvalidBytecode,
        } },
        23 => .task_await,
        24 => .task_spawn,
        25 => .task_detach,
        26 => .task_cancel,
        27 => .{ .trigger_enter = cursor.readU16() orelse return error.InvalidBytecode },
        28 => .{ .trigger_leave = cursor.readU16() orelse return error.InvalidBytecode },
        29 => .alloc,
        30 => .load_mem,
        31 => .store_mem,
        32 => .load_u8,
        33 => .store_u8,
        34 => .{ .local_addr = cursor.readU16() orelse return error.InvalidBytecode },
        35 => blk: {
            const len = cursor.readU32() orelse return error.InvalidBytecode;
            const bytes = cursor.take(len) orelse return error.InvalidBytecode;
            const copy = std.heap.page_allocator.dupe(u8, bytes) catch return error.OutOfMemory;
            break :blk .{ .string_lit = copy };
        },
        36 => .vec_new,
        37 => .vec_len,
        38 => .vec_get,
        39 => .vec_set,
        40 => .vec_row,
        41 => .{ .vec_binary = (cursor.take(1) orelse return error.InvalidBytecode)[0] },
        42 => .{ .vec_scalar = (cursor.take(1) orelse return error.InvalidBytecode)[0] },
        43 => .map_new,
        44 => .map_get,
        45 => .map_set,
        46 => .str_concat,
        47 => .str_eq,
        48 => .map_get_str,
        49 => .map_set_str,
        50 => .str_len,
        51 => .str_slice,
        52 => .str_char_at,
        53 => .map_len,
        54 => .map_key_at,
        55 => .map_value_at,
        56 => .vec_get2,
        57 => .vec_set2,
        58 => .vec_set_row,
        59 => blk: {
            const raw = (cursor.take(1) orelse return error.InvalidBytecode)[0];
            if (raw >= std.enums.values(RuntimeFunction).len) return error.InvalidBytecode;
            const function: RuntimeFunction = @enumFromInt(raw);
            const argc = cursor.readU16() orelse return error.InvalidBytecode;
            if (argc != function.arity()) return error.InvalidBytecode;
            break :blk .{ .runtime_call = .{ .function = function, .argc = argc } };
        },
        else => error.InvalidBytecode,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testModule(allocator: std.mem.Allocator) !Module {
    const code = try allocator.alloc(Op, 9);
    code[0] = .{ .push_i64 = 2 };
    code[1] = .{ .push_i64 = 3 };
    code[2] = .add;
    code[3] = .{ .push_i64 = 4 };
    code[4] = .mul;
    code[5] = .{ .push_i64 = 0 };
    code[6] = .add;
    code[7] = .{ .push_i64 = 1 };
    code[8] = .sub;
    // Keep a return value on the stack and return it.
    const full = try allocator.alloc(Op, 10);
    @memcpy(full[0..9], code);
    full[9] = .ret;
    allocator.free(code);
    const functions = try allocator.alloc(Function, 1);
    functions[0] = .{
        .name = try allocator.dupe(u8, "answer"),
        .params = 0,
        .locals = 0,
        .max_stack = 16,
        .code = full,
    };
    return .{ .allocator = allocator, .functions = functions, .entry = 0 };
}

test "bytecode round-trips and verifies" {
    var module = try testModule(std.testing.allocator);
    defer module.deinit();
    try verify(std.testing.allocator, &module);

    const bytes = try encode(std.testing.allocator, &module);
    defer std.testing.allocator.free(bytes);
    var decoded = try decode(std.testing.allocator, bytes);
    defer decoded.deinit();
    try verify(std.testing.allocator, &decoded);
    try std.testing.expectEqual(@as(usize, 1), decoded.functions.len);
    try std.testing.expectEqual(@as(usize, 10), decoded.functions[0].code.len);
}

test "bytecode optimizer folds constants to a fixed point" {
    var module = try testModule(std.testing.allocator);
    defer module.deinit();
    const stats = try optimize(std.testing.allocator, &module, .{});
    try std.testing.expect(stats.reached_fixed_point);
    try std.testing.expect(stats.folds >= 2);
    try verify(std.testing.allocator, &module);
}

test "bytecode verification rejects bad jumps" {
    var module = try testModule(std.testing.allocator);
    defer module.deinit();
    module.functions[0].code[0] = .{ .jump = 999 };
    try std.testing.expectError(error.InvalidBytecode, verify(std.testing.allocator, &module));
}

test "bytecode round-trips matrix indexing ops" {
    const code = try std.testing.allocator.alloc(Op, 15);
    code[0] = .{ .push_i64 = 1 }; // matrix
    code[1] = .{ .push_i64 = 0 }; // row
    code[2] = .{ .push_i64 = 1 }; // column
    code[3] = .vec_get2;
    code[4] = .{ .push_i64 = 1 };
    code[5] = .{ .push_i64 = 0 };
    code[6] = .{ .push_i64 = 9 };
    code[7] = .vec_set2;
    code[8] = .{ .push_i64 = 1 };
    code[9] = .{ .push_i64 = 0 };
    code[10] = .{ .push_i64 = 1 }; // row vector
    code[11] = .vec_set_row;
    code[12] = .{ .push_i64 = 0 };
    code[13] = .add;
    code[14] = .ret;
    const functions = try std.testing.allocator.alloc(Function, 1);
    functions[0] = .{
        .name = try std.testing.allocator.dupe(u8, "matrix"),
        .params = 0,
        .locals = 0,
        .max_stack = 16,
        .code = code,
    };
    var module = Module{
        .allocator = std.testing.allocator,
        .functions = functions,
        .entry = 0,
    };
    defer module.deinit();
    try verify(std.testing.allocator, &module);
    const bytes = try encode(std.testing.allocator, &module);
    defer std.testing.allocator.free(bytes);
    var decoded = try decode(std.testing.allocator, bytes);
    defer decoded.deinit();
    try verify(std.testing.allocator, &decoded);
    try std.testing.expect(decoded.functions[0].code[3] == .vec_get2);
    try std.testing.expect(decoded.functions[0].code[7] == .vec_set2);
    try std.testing.expect(decoded.functions[0].code[11] == .vec_set_row);
}

test "bytecode round-trips runtime calls" {
    const code = try std.testing.allocator.alloc(Op, 8);
    code[0] = .{ .push_i64 = 3 }; // resource id
    code[1] = .{ .push_i64 = 2 }; // slots
    code[2] = .{ .runtime_call = .{ .function = .ecs_register_resource, .argc = 2 } };
    code[3] = .pop;
    code[4] = .{ .push_i64 = 3 };
    code[5] = .{ .runtime_call = .{ .function = .ecs_resource, .argc = 1 } };
    code[6] = .{ .push_i64 = 1 };
    code[7] = .ret;
    const functions = try std.testing.allocator.alloc(Function, 1);
    functions[0] = .{
        .name = try std.testing.allocator.dupe(u8, "ecs"),
        .params = 0,
        .locals = 0,
        .max_stack = 16,
        .code = code,
    };
    var module = Module{
        .allocator = std.testing.allocator,
        .functions = functions,
        .entry = 0,
    };
    defer module.deinit();
    try verify(std.testing.allocator, &module);
    const bytes = try encode(std.testing.allocator, &module);
    defer std.testing.allocator.free(bytes);
    var decoded = try decode(std.testing.allocator, bytes);
    defer decoded.deinit();
    try verify(std.testing.allocator, &decoded);
    try std.testing.expect(decoded.functions[0].code[2].runtime_call.function == .ecs_register_resource);
    try std.testing.expectEqual(@as(u16, 1), decoded.functions[0].code[5].runtime_call.argc);
}
