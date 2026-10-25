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
