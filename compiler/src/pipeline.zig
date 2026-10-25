//! End-to-end compiler pipeline:
//! source -> lex/parse -> semantic analysis -> bytecode lowering -> fixed-point
//! bytecode optimization.
//!
//! The resulting `CompileResult.bytecode` is the artifact handed to the
//! runtime.  The runtime owns the bytecode -> LLVM IR translation and JIT.

const std = @import("std");
const parser = @import("parser.zig");
const semantic = @import("semantic.zig");
const codegen = @import("codegen.zig");
const bytecode = @import("bytecode.zig");
const ast = @import("ast.zig");

pub const Options = struct {
    codegen: codegen.Config = .{},
    optimize: bytecode.OptimizeConfig = .{},
};

pub const Error = error{
    LexFailed,
    ParseFailed,
    SemanticFailed,
} || codegen.Error || bytecode.Error;

pub const CompileResult = struct {
    parsed: parser.Ast,
    analysis: semantic.Analysis,
    bytecode: bytecode.Module,
    optimization: bytecode.Stats,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompileResult) void {
        self.bytecode.deinit();
        self.analysis.deinit();
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn functionNamed(self: *const CompileResult, name: []const u8) ?*const bytecode.Function {
        const index = self.bytecode.functionNamed(name) orelse return null;
        return &self.bytecode.functions[index];
    }
};

pub fn compile(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
) Error!CompileResult {
    const parsed_result = try parser.parse(allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => return error.ParseFailed,
    };
    errdefer parsed.deinit();

    var analysis = try semantic.analyze(allocator, parsed.module);
    errdefer analysis.deinit();
    if (!analysis.ok()) return error.SemanticFailed;

    var module = try codegen.lower(allocator, parsed.module, &analysis, options.codegen);
    errdefer module.deinit();

    const stats = try bytecode.optimize(allocator, &module, options.optimize);
    try bytecode.verify(allocator, &module);

    return .{
        .parsed = parsed,
        .analysis = analysis,
        .bytecode = module,
        .optimization = stats,
        .allocator = allocator,
    };
}

fn hasLocalAddr(function: *const bytecode.Function) bool {
    for (function.code) |op| switch (op) {
        .local_addr => return true,
        else => {},
    };
    return false;
}

test "compiles a source function to optimized bytecode" {
    var result = try compile(
        std.testing.allocator,
        \\add <- (a: i32, b: i32) -> i32 = a + b
        \\main <- () -> i32 = add(2, 3)
    ,
        .{},
    );
    defer result.deinit();

    try std.testing.expect(result.analysis.ok());
    try std.testing.expectEqual(@as(usize, 2), result.bytecode.functions.len);
    const main = result.functionNamed("main").?;
    try std.testing.expect(main.code.len > 0);
    try std.testing.expect(result.optimization.reached_fixed_point);
}

test "compiles control flow to bytecode" {
    var result = try compile(
        std.testing.allocator,
        \\fact <- (n: i32) -> i32:
        \\    m := n
        \\    r := 1
        \\    while m > 0:
        \\        r = r * m
        \\        m = m - 1
        \\    r
    ,
        .{},
    );
    defer result.deinit();
    try bytecode.verify(std.testing.allocator, &result.bytecode);
}

test "compiles map and vector iteration and container builtins" {
    var result = try compile(
        std.testing.allocator,
        \\sum_map <- () -> i32:
        \\    m := map[i32, i32] { 1: 10, 2: 20 }
        \\    total := 0
        \\    for (key, value) in m:
        \\        total = total + key + value
        \\    for key in m:
        \\        total = total + key
        \\    total
        \\sum_vec <- () -> i32:
        \\    xs := [1, 2, 3]
        \\    total := 0
        \\    for x in xs:
        \\        total = total + x
        \\    for (i, x) in xs:
        \\        total = total + i + x
        \\    total
        \\break_map <- () -> i32:
        \\    m := map[i32, i32] { 1: 10, 2: 20, 3: 30 }
        \\    total := 0
        \\    for (key, value) in m:
        \\        if key == 2:
        \\            break
        \\        total = total + key
        \\    for _ in m:
        \\        total = total + 1
        \\    total
        \\container_ops <- () -> i32:
        \\    text := "hello"
        \\    text.len() + text.slice(1, 3).len() + text.char_at(0).len()
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    const map_body = result.functionNamed("sum_map").?;
    var saw_map_len = false;
    var saw_map_key = false;
    var saw_map_value = false;
    for (map_body.code) |op| switch (op) {
        .map_len => saw_map_len = true,
        .map_key_at => saw_map_key = true,
        .map_value_at => saw_map_value = true,
        else => {},
    };
    try std.testing.expect(saw_map_len and saw_map_key and saw_map_value);

    const vec_body = result.functionNamed("sum_vec").?;
    var saw_vec_len = false;
    var saw_vec_get = false;
    for (vec_body.code) |op| switch (op) {
        .vec_len => saw_vec_len = true,
        .vec_get => saw_vec_get = true,
        else => {},
    };
    try std.testing.expect(saw_vec_len and saw_vec_get);

    const ops_body = result.functionNamed("container_ops").?;
    var saw_str_len = false;
    var saw_str_slice = false;
    var saw_str_char_at = false;
    for (ops_body.code) |op| switch (op) {
        .str_len => saw_str_len = true,
        .str_slice => saw_str_slice = true,
        .str_char_at => saw_str_char_at = true,
        else => {},
    };
    try std.testing.expect(saw_str_len and saw_str_slice and saw_str_char_at);
}

test "compiles matrix two-dimensional indexing and row assignment" {
    var result = try compile(
        std.testing.allocator,
        \\elem <- (m: [i32; 2, 3]) -> i32 = m[0, 1]
        \\write_elem <- () -> i32:
        \\    m := [[1, 2, 3], [4, 5, 6]]
        \\    m[1, 0] = 42
        \\    m[1, 0]
        \\write_row <- () -> i32:
        \\    m := [[1, 2, 3], [4, 5, 6]]
        \\    m[0] = [7, 8, 9]
        \\    m[0, 2]
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    const read_body = result.functionNamed("elem").?;
    var saw_get2 = false;
    for (read_body.code) |op| switch (op) {
        .vec_get2 => saw_get2 = true,
        else => {},
    };
    try std.testing.expect(saw_get2);

    const write_body = result.functionNamed("write_elem").?;
    var saw_set2 = false;
    for (write_body.code) |op| switch (op) {
        .vec_set2 => saw_set2 = true,
        else => {},
    };
    try std.testing.expect(saw_set2);

    const row_body = result.functionNamed("write_row").?;
    var saw_set_row = false;
    for (row_body.code) |op| switch (op) {
        .vec_set_row => saw_set_row = true,
        else => {},
    };
    try std.testing.expect(saw_set_row);
}

test "compiles aggregate references as object aliases" {
    var result = try compile(
        std.testing.allocator,
        \\Point <- struct
        \\    x: i32
        \\    y: i32
        \\sum_ref <- (p: &Point) -> i32 = p.x + p.y
        \\bump <- (p: &mut Point) -> i32:
        \\    p.x = p.x + 1
        \\    p.x
        \\via_ref <- () -> i32:
        \\    p := Point { x: 2, y: 3 }
        \\    sum_ref(&p)
        \\mutate <- () -> i32:
        \\    p := Point { x: 2, y: 3 }
        \\    bump(&mut p)
        \\    p.x
        \\local_ref <- () -> i32:
        \\    p := Point { x: 2, y: 3 }
        \\    r := &p
        \\    r.x + (*r).y
        \\whole_value <- () -> i32:
        \\    p := Point { x: 2, y: 3 }
        \\    r := &p
        \\    q := *r
        \\    q.y
        \\scalar_ref <- () -> i32:
        \\    x := 5
        \\    r := &x
        \\    *r
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    // Aggregate references alias the object pointer, so taking one never forms
    // the address of a local slot.
    for ([_][]const u8{ "sum_ref", "bump", "via_ref", "mutate", "local_ref", "whole_value" }) |name| {
        try std.testing.expect(!hasLocalAddr(result.functionNamed(name).?));
    }
    // Scalar references still point at the local i64 slot.
    const scalar = result.functionNamed("scalar_ref").?;
    try std.testing.expect(hasLocalAddr(scalar));
}

test "compiles container references through aggregate aliases" {
    var result = try compile(
        std.testing.allocator,
        \\vector_ref <- () -> i32:
        \\    xs := [1, 2, 3]
        \\    r := &mut xs
        \\    r[1] = 9
        \\    r.len() * 10 + r[1]
        \\map_ref <- () -> i32:
        \\    m := map[i32, i32] { 1: 10 }
        \\    r := &mut m
        \\    r[2] = 22
        \\    r[1] + r[2]
        \\string_ref <- () -> i32:
        \\    s := "hello"
        \\    r := &s
        \\    r.len() + r.char_at(1).len()
        \\matrix_ref <- (m: &[i32; 2, 3]) -> i32 = m[0, 1]
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    for ([_][]const u8{ "vector_ref", "map_ref", "string_ref", "matrix_ref" }) |name| {
        try std.testing.expect(!hasLocalAddr(result.functionNamed(name).?));
    }

    const vector = result.functionNamed("vector_ref").?;
    var saw_vec_set = false;
    var saw_vec_len = false;
    for (vector.code) |op| switch (op) {
        .vec_set => saw_vec_set = true,
        .vec_len => saw_vec_len = true,
        else => {},
    };
    try std.testing.expect(saw_vec_set and saw_vec_len);

    const map_function = result.functionNamed("map_ref").?;
    var saw_map_set = false;
    for (map_function.code) |op| switch (op) {
        .map_set => saw_map_set = true,
        else => {},
    };
    try std.testing.expect(saw_map_set);

    const string = result.functionNamed("string_ref").?;
    var saw_str_len = false;
    var saw_str_char_at = false;
    for (string.code) |op| switch (op) {
        .str_len => saw_str_len = true,
        .str_char_at => saw_str_char_at = true,
        else => {},
    };
    try std.testing.expect(saw_str_len and saw_str_char_at);

    const matrix = result.functionNamed("matrix_ref").?;
    var saw_get2 = false;
    for (matrix.code) |op| switch (op) {
        .vec_get2 => saw_get2 = true,
        else => {},
    };
    try std.testing.expect(saw_get2);
}

test "rejects semantically invalid source before lowering" {
    try std.testing.expectError(error.SemanticFailed, compile(
        std.testing.allocator,
        \\f <- () -> i32:
        \\    x := 1
        \\    x = "bad"
        \\    0
    ,
        .{},
    ));
}

test "compiles async functions to task bytecode" {
    var result = try compile(
        std.testing.allocator,
        \\double <- async (x: i32) -> i32 = x * 2
        \\pair <- async () -> i32:
        \\    value := (await double(21))?
        \\    value
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 4), result.bytecode.functions.len);
    try std.testing.expect(result.functionNamed("double") != null);
    try std.testing.expect(result.functionNamed("double__body") != null);
    try std.testing.expect(result.functionNamed("pair") != null);
    try std.testing.expect(result.functionNamed("pair__body") != null);
    try bytecode.verify(std.testing.allocator, &result.bytecode);
}

test "compiles inline async function expressions" {
    var result = try compile(
        std.testing.allocator,
        \\double := async (x: i32) -> i32 = x * 2
        \\run <- async () -> i32:
        \\    value := (await double(21))?
        \\    value
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.functionNamed("double") != null);
    try std.testing.expect(result.functionNamed("double__body") != null);
}

test "lowers custom operator and Index impl methods to calls" {
    var result = try compile(
        std.testing.allocator,
        \\Point <- struct
        \\    x: i32
        \\    y: i32
        \\impl Add for Point:
        \\    add <- (a: Point, b: Point) -> Point = Point { x: a.x + b.x, y: a.y + b.y }
        \\impl Index for Point:
        \\    index <- (p: Point, i: i32) -> i32 = p.x + i
        \\sum <- () -> Point = Point { x: 1, y: 2 } + Point { x: 3, y: 4 }
        \\get <- () -> i32:
        \\    p := Point { x: 5, y: 6 }
        \\    p[1]
    ,
        .{},
    );
    defer result.deinit();
    // Two source functions plus lazily-compiled `add` and `index` methods.
    try std.testing.expectEqual(@as(usize, 4), result.bytecode.functions.len);
    try std.testing.expect(result.functionNamed("impl.Point.add") != null);
    try std.testing.expect(result.functionNamed("impl.Point.index") != null);
    try std.testing.expect(result.functionNamed("sum") != null);
    try std.testing.expect(result.functionNamed("get") != null);
    try bytecode.verify(std.testing.allocator, &result.bytecode);
}

test "does not compile unused impl methods" {
    var result = try compile(
        std.testing.allocator,
        \\Point <- struct
        \\    x: i32
        \\    y: i32
        \\impl Add for Point:
        \\    add <- (a: Point, b: Point) -> Point = Point { x: a.x + b.x, y: a.y + b.y }
        \\value <- () -> i32 = 7
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.bytecode.functions.len);
    try std.testing.expect(result.functionNamed("impl.Point.add") == null);
}

fn countCallOps(function: *const bytecode.Function) usize {
    var count: usize = 0;
    for (function.code) |op| switch (op) {
        .call => count += 1,
        else => {},
    };
    return count;
}

test "compiles normal sys declarations as async functions with parameters" {
    var result = try compile(
        std.testing.allocator,
        \\double <- async (x: i32) -> i32 = x * 2
        \\Apply <- sys(x: i32):
        \\    await double(x)
        \\run <- async () -> i32:
        \\    task := Apply(21)
        \\    await task
        \\    7
    ,
        .{},
    );
    defer result.deinit();

    // double, Apply, run each lower to a constructor/body pair.
    try std.testing.expectEqual(@as(usize, 6), result.bytecode.functions.len);
    try std.testing.expect(result.functionNamed("Apply") != null);
    try std.testing.expect(result.functionNamed("Apply__body") != null);

    // The constructor forwards its parameter into the task body.
    const apply_ctor = result.functionNamed("Apply").?;
    try std.testing.expectEqual(@as(u16, 1), apply_ctor.params);
    var create_task_argc: ?u16 = null;
    for (apply_ctor.code) |op| switch (op) {
        .create_task => |call| create_task_argc = call.argc,
        else => {},
    };
    try std.testing.expectEqual(@as(u16, 1), create_task_argc.?);

    // The body receives the task pointer plus the system's own parameter.
    const apply_body = result.functionNamed("Apply__body").?;
    try std.testing.expectEqual(@as(u16, 2), apply_body.params);
    // `await double(x)` lowers to one constructor call plus `task_await`.
    try std.testing.expectEqual(@as(usize, 1), countCallOps(apply_body));
    var awaits_double = false;
    for (apply_body.code) |op| switch (op) {
        .task_await => awaits_double = true,
        else => {},
    };
    try std.testing.expect(awaits_double);
    try bytecode.verify(std.testing.allocator, &result.bytecode);
}

test "forwards query and resource handles between system declarations" {
    var result = try compile(
        std.testing.allocator,
        \\S <- struct
        \\    a: i32
        \\Consume <- sys(q: select &a from S):
        \\    ret
        \\Touch <- sys(target: res &mut S):
        \\    ret
        \\Apply <- sys(q: select &a from S, target: res &mut S):
        \\    Consume(q)
        \\    Touch(target)
    ,
        .{},
    );
    defer result.deinit();

    // Three systems, each a constructor/body pair.
    try std.testing.expectEqual(@as(usize, 6), result.bytecode.functions.len);
    const apply_body = result.functionNamed("Apply__body").?;
    try std.testing.expectEqual(@as(u16, 3), apply_body.params); // task + query + resource
    try std.testing.expectEqual(@as(usize, 2), countCallOps(apply_body));

    // Both forwarded handles are bare parameters loaded from locals.
    var index: usize = 0;
    var forwarded: usize = 0;
    while (index + 1 < apply_body.code.len) : (index += 1) {
        if (apply_body.code[index] != .load_local) continue;
        switch (apply_body.code[index + 1]) {
            .call => |call| {
                if (call.argc == 1) forwarded += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), forwarded);
    try bytecode.verify(std.testing.allocator, &result.bytecode);
}

test "rejects query projection, iteration, and resource projection in system bodies" {
    // Query projection: the synthetic row layout is not exposed to codegen.
    try std.testing.expectError(error.UnsupportedFeature, compile(
        std.testing.allocator,
        \\S <- struct
        \\    a: i32
        \\Tick <- sys(q: select &a from S):
        \\    x := q.a
        \\    x
    ,
        .{},
    ));

    // Iterating a query is likewise outside the opaque-handle boundary.
    try std.testing.expectError(error.UnsupportedFeature, compile(
        std.testing.allocator,
        \\S <- struct
        \\    a: i32
        \\Tick <- sys(q: select &a from S):
        \\    for row in q:
        \\        row.a
    ,
        .{},
    ));

    // Resource field access would treat the handle as a pointer: rejected
    // explicitly instead of being miscompiled.
    try std.testing.expectError(error.OpaqueHandleAccess, compile(
        std.testing.allocator,
        \\S <- struct
        \\    a: i32
        \\Tick <- sys(target: res &mut S):
        \\    target.a = 1
    ,
        .{},
    ));

    // Borrowing a handle is rejected for the same reason.
    try std.testing.expectError(error.OpaqueHandleAccess, compile(
        std.testing.allocator,
        \\S <- struct
        \\    a: i32
        \\Tick <- sys(target: res &mut S):
        \\    p := &target
        \\    p
    ,
        .{},
    ));
}

test "keeps zero-parameter trigger systems and rejects parameterized ones" {
    var result = try compile(
        std.testing.allocator,
        \\Update <- trigger
        \\    amount: i32
        \\@trigger(Update)
        \\Apply <- sys():
        \\    ret
        \\run <- async () -> ():
        \\    await Update(1)
    ,
        .{},
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 6), result.bytecode.functions.len);
    const apply_ctor = result.functionNamed("Apply").?;
    try std.testing.expectEqual(@as(u16, 0), apply_ctor.params);
    const apply_body = result.functionNamed("Apply__body").?;
    try std.testing.expectEqual(@as(u16, 1), apply_body.params); // task pointer only

    // The trigger body still spawns and awaits its systems.
    const trigger_body = result.functionNamed("Update__body").?;
    var spawned = false;
    for (trigger_body.code) |op| switch (op) {
        .task_spawn => spawned = true,
        else => {},
    };
    try std.testing.expect(spawned);
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    // Trigger fields are not yet bound into system parameters.
    try std.testing.expectError(error.UnsupportedFeature, compile(
        std.testing.allocator,
        \\Update <- trigger
        \\    amount: i32
        \\@trigger(Update)
        \\Apply <- sys(amount: i32):
        \\    ret
        \\run <- async () -> ():
        \\    await Update(1)
    ,
        .{},
    ));
}
