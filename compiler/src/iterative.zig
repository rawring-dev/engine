//! Iterative compilation driver built on LLVM's New Pass Manager.
//!
//! LLVM's pass manager is the in-process framework we use to run a pipeline,
//! observe the resulting IR, and repeat until the IR reaches a fixed point (or
//! a budget is exhausted).  This is the scaffolding for profile-guided and
//! search-based iterative compilation: later passes can be selected from
//! profiling data and this loop can compare candidate pipelines.
//!
//! The C API avoids a C++ shim and keeps the boundary small.
//!   [llvm] LLVM Project, "LLVM Language Reference Manual" and the
//!          "Using the New Pass Manager" documentation.

const std = @import("std");

const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/IRReader.h");
    @cInclude("llvm-c/Transforms/PassBuilder.h");
});

pub const Error = error{
    InvalidIr,
    OptimizationFailed,
    OutOfMemory,
};

pub const Config = struct {
    /// Stop after this many pipeline executions even if IR is still changing.
    max_iterations: usize = 8,
    /// Any pipeline accepted by `opt -passes=...`.
    passes: [:0]const u8 = "function(mem2reg,instcombine,simplifycfg)",
};

pub const Optimized = struct {
    ir: []u8,
    iterations: usize,
    reached_fixed_point: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Optimized) void {
        self.allocator.free(self.ir);
        self.* = undefined;
    }
};

/// Run `config.passes` until the printed module stops changing.
pub fn optimize(
    allocator: std.mem.Allocator,
    ir: []const u8,
    config: Config,
) Error!Optimized {
    if (config.max_iterations == 0) return error.OptimizationFailed;

    const context = c.LLVMContextCreate();
    defer c.LLVMContextDispose(context);

    const name: [*:0]const u8 = "engine7.iterative";
    const buffer = c.LLVMCreateMemoryBufferWithMemoryRangeCopy(
        @ptrCast(ir.ptr),
        ir.len,
        name,
    );
    defer c.LLVMDisposeMemoryBuffer(buffer);

    var module: c.LLVMModuleRef = undefined;
    var message: [*c]u8 = null;
    if (c.LLVMParseIRInContext2(context, buffer, &module, &message) != 0) {
        if (message != null) c.LLVMDisposeMessage(message);
        return error.InvalidIr;
    }
    defer c.LLVMDisposeModule(module);

    var current: ?[]u8 = null;
    defer if (current) |bytes| allocator.free(bytes);

    var iteration: usize = 0;
    var fixed_point = false;
    while (iteration < config.max_iterations) : (iteration += 1) {
        const options = c.LLVMCreatePassBuilderOptions();
        defer c.LLVMDisposePassBuilderOptions(options);

        const err = c.LLVMRunPasses(module, config.passes.ptr, null, options);
        if (err != null) {
            const text = c.LLVMGetErrorMessage(err);
            if (text != null) c.LLVMDisposeErrorMessage(text);
            return error.OptimizationFailed;
        }

        const printed = c.LLVMPrintModuleToString(module);
        if (printed == null) return error.OptimizationFailed;
        defer c.LLVMDisposeMessage(printed);
        const next = try allocator.dupe(u8, std.mem.span(printed));

        if (current) |previous| {
            const same = std.mem.eql(u8, previous, next);
            allocator.free(previous);
            current = next;
            if (same) {
                fixed_point = true;
                iteration += 1;
                break;
            }
        } else {
            current = next;
        }
    }

    const final_ir = current orelse return error.OptimizationFailed;
    current = null;
    return .{
        .ir = final_ir,
        .iterations = iteration,
        .reached_fixed_point = fixed_point,
        .allocator = allocator,
    };
}

const trivial_ir =
    \\define i32 @f(i32 %x) {
    \\entry:
    \\  %a = add i32 %x, 0
    \\  %b = mul i32 %a, 1
    \\  ret i32 %b
    \\}
;

test "iterative pipeline reaches a fixed point on trivial IR" {
    var result = try optimize(std.testing.allocator, trivial_ir, .{
        .max_iterations = 4,
    });
    defer result.deinit();

    try std.testing.expect(result.iterations >= 1);
    try std.testing.expect(std.mem.indexOf(u8, result.ir, "define i32 @f") != null);
    try std.testing.expect(result.reached_fixed_point);
}

test "invalid IR is rejected" {
    try std.testing.expectError(error.InvalidIr, optimize(
        std.testing.allocator,
        "not llvm ir",
        .{},
    ));
}
