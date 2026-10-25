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
