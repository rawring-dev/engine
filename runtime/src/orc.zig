//! LLVM ORC (On-Request Compilation) bindings via the stable C API.
//!
//! `LLJIT` is the C entry point to ORC's layered JIT.  A module is parsed from
//! textual LLVM IR, wrapped in a threadsafe module, added to the JIT's main
//! `JITDylib`, and resolved by symbol lookup.  The wrapper owns the LLJIT
//! instance; compiled code and modules live until `deinit`.
//!
//! The C API is not ABI-stable across LLVM major versions, so the build links
//! the distribution's `LLVM-23` shared library explicitly.  Update the link
//! name in `build.zig` alongside the LLVM version.
//!
//!   [llvm] LLVM Project, "ORC Design and Implementation" and
//!          "LLVM-C: C API to LLVM" (LLJIT.h, Orc.h).

const std = @import("std");
const compiler = @import("compiler");
const bytecode_ir = @import("bytecode_ir.zig");
const task = @import("task.zig");
const lease = @import("lease.zig");
const aggregate = @import("aggregate.zig");
const ecs = @import("ecs.zig");
const engine = @import("engine.zig");
const float = @import("float.zig");
const json = @import("json.zig");
const image = @import("image.zig");
const text_render = @import("text.zig");

const c = @cImport({
    @cInclude("llvm-c/Core.h");
    @cInclude("llvm-c/Orc.h");
    @cInclude("llvm-c/LLJIT.h");
    @cInclude("llvm-c/IRReader.h");
    @cInclude("llvm-c/Target.h");
    @cInclude("llvm-c/TargetMachine.h");
});

pub const Error = error{
    JitCreateFailed,
    InvalidIr,
    AddModuleFailed,
    LookupFailed,
    DefineFailed,
    OutOfMemory,
    InvalidBytecode,
    OptimizationFailed,
};

/// A host address made visible to JITed modules under `name`.
///
/// LLJIT's default generator only sees symbols the dynamic loader exported from
/// the host process. Build artifacts and static libraries frequently do not
/// export runtime entry points, so the runtime registers each intrinsic
/// explicitly as an ORC absolute symbol instead.
pub const Symbol = @import("ffi/abi.zig").Symbol;

pub const Jit = struct {
    handle: c.LLVMOrcLLJITRef,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Error!Jit {
        _ = c.LLVMInitializeNativeTarget();
        _ = c.LLVMInitializeNativeAsmPrinter();
        _ = c.LLVMInitializeNativeAsmParser();

        var handle: c.LLVMOrcLLJITRef = undefined;
        const err = c.LLVMOrcCreateLLJIT(&handle, null);
        if (err != null) {
            disposeError(err);
            return error.JitCreateFailed;
        }
        return .{ .handle = handle, .allocator = allocator };
    }

    pub fn deinit(self: *Jit) void {
        const err = c.LLVMOrcDisposeLLJIT(self.handle);
        if (err != null) disposeError(err);
        task.shutdownGlobal();
        self.* = undefined;
    }

    /// Add textual LLVM IR to the main JITDylib.  The module is compiled
    /// lazily when a symbol from it is first looked up.
    pub fn addIr(self: *Jit, ir: []const u8, module_name: []const u8) Error!void {
        const context = c.LLVMContextCreate();
        // Ownership of `context` is transferred to the ThreadSafeContext.
        const ts_context = c.LLVMOrcCreateNewThreadSafeContextFromLLVMContext(context);
        defer c.LLVMOrcDisposeThreadSafeContext(ts_context);

        const name = self.allocator.dupeZ(u8, module_name) catch return error.OutOfMemory;
        defer self.allocator.free(name);

        const buffer = c.LLVMCreateMemoryBufferWithMemoryRangeCopy(
            @ptrCast(ir.ptr),
            ir.len,
            name.ptr,
        );
        defer c.LLVMDisposeMemoryBuffer(buffer);

        var module: c.LLVMModuleRef = undefined;
        var message: [*c]u8 = null;
        if (c.LLVMParseIRInContext2(context, buffer, &module, &message) != 0) {
            if (message != null) c.LLVMDisposeMessage(message);
            return error.InvalidIr;
        }

        // ORC's JITLink needs the module's target triple/data layout to match
        // the host LLJIT.  Both strings are owned by the LLJIT.
        c.LLVMSetTarget(module, c.LLVMOrcLLJITGetTripleString(self.handle));
        c.LLVMSetDataLayout(module, c.LLVMOrcLLJITGetDataLayoutStr(self.handle));

        const tsm = c.LLVMOrcCreateNewThreadSafeModule(module, ts_context);
        const err = c.LLVMOrcLLJITAddLLVMIRModule(
            self.handle,
            c.LLVMOrcLLJITGetMainJITDylib(self.handle),
            tsm,
        );
        if (err != null) {
            disposeError(err);
            c.LLVMOrcDisposeThreadSafeModule(tsm);
            return error.AddModuleFailed;
        }
    }

    /// Compile engine bytecode to LLVM IR, run the iterative LLVM pipeline to
    /// a fixed point, then add the optimized module to the JIT.
    pub fn addBytecode(self: *Jit, module: *const compiler.bytecode.Module, module_name: []const u8) Error!void {
        task.ensureGlobal(std.heap.c_allocator) catch return error.OutOfMemory;
        const task_symbols = task.symbols();
        try self.defineSymbols(&task_symbols);
        const lease_symbols = lease.symbols();
        try self.defineSymbols(&lease_symbols);
        const aggregate_symbols = aggregate.symbols();
        try self.defineSymbols(&aggregate_symbols);
        const ecs_symbols = ecs.symbols();
        try self.defineSymbols(&ecs_symbols);
        const engine_symbols = engine.symbols();
        try self.defineSymbols(&engine_symbols);
        const float_symbols = float.symbols();
        try self.defineSymbols(&float_symbols);
        const json_symbols = json.symbols();
        try self.defineSymbols(&json_symbols);
        const image_symbols = image.symbols();
        try self.defineSymbols(&image_symbols);
        const text_symbols = text_render.symbols();
        try self.defineSymbols(&text_symbols);
        const raw_ir = bytecode_ir.translate(self.allocator, module) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidBytecode => return error.InvalidBytecode,
        };
        defer self.allocator.free(raw_ir);

        var optimized = compiler.iterative.optimize(self.allocator, raw_ir, .{
            .max_iterations = 8,
        }) catch |err| switch (err) {
            error.InvalidIr => return error.InvalidIr,
            error.OptimizationFailed => return error.OptimizationFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer optimized.deinit();
        try self.addIr(optimized.ir, module_name);
    }

    /// Accept the serialized compiler artifact at the process boundary.  The
    /// bytes are decoded and verified before IR translation.
    pub fn addBytecodeBytes(self: *Jit, bytes: []const u8, module_name: []const u8) Error!void {
        var module = compiler.bytecode.decode(self.allocator, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidBytecode => return error.InvalidBytecode,
        };
        defer module.deinit();
        try self.addBytecode(&module, module_name);
    }

    /// Define host addresses in the main JITDylib.  This is how the runtime's
    /// `e7_*` intrinsic ABI becomes resolvable from generated IR without
    /// relying on dynamic symbol export from the executable.
    pub fn defineSymbols(self: *Jit, symbols: []const Symbol) Error!void {
        if (symbols.len == 0) return;

        const pairs = self.allocator.alloc(c.LLVMOrcCSymbolMapPair, symbols.len) catch return error.OutOfMemory;
        defer self.allocator.free(pairs);

        const session = c.LLVMOrcLLJITGetExecutionSession(self.handle);
        for (symbols, 0..) |symbol, index| {
            const name = self.allocator.dupeZ(u8, symbol.name) catch return error.OutOfMemory;
            defer self.allocator.free(name);
            const entry = c.LLVMOrcExecutionSessionIntern(session, name.ptr);

            var flags: u8 = @intCast(c.LLVMJITSymbolGenericFlagsExported);
            if (symbol.callable) flags |= @intCast(c.LLVMJITSymbolGenericFlagsCallable);
            pairs[index] = .{
                .Name = entry,
                .Sym = .{
                    .Address = @intCast(symbol.address),
                    .Flags = .{ .GenericFlags = flags, .TargetFlags = 0 },
                },
            };
        }

        const unit = c.LLVMOrcAbsoluteSymbols(pairs.ptr, pairs.len);
        const err = c.LLVMOrcJITDylibDefine(c.LLVMOrcLLJITGetMainJITDylib(self.handle), unit);
        if (err != null) {
            disposeError(err);
            c.LLVMOrcDisposeMaterializationUnit(unit);
            return error.DefineFailed;
        }
    }

    /// Resolve a symbol to an executable address.
    pub fn lookup(self: *Jit, name: []const u8) Error!usize {
        const c_name = self.allocator.dupeZ(u8, name) catch return error.OutOfMemory;
        defer self.allocator.free(c_name);

        var address: c.LLVMOrcExecutorAddress = 0;
        const err = c.LLVMOrcLLJITLookup(self.handle, &address, c_name.ptr);
        if (err != null) {
            disposeError(err);
            return error.LookupFailed;
        }
        return @intCast(address);
    }

    /// Resolve a symbol and cast it to a Zig function pointer type, e.g.
    /// `try jit.get(*const fn () callconv(.c) i32, "answer")`.
    pub fn get(self: *Jit, comptime T: type, name: []const u8) Error!T {
        const address = try self.lookup(name);
        return @ptrFromInt(address);
    }

    pub fn triple(self: *Jit) []const u8 {
        return std.mem.span(c.LLVMOrcLLJITGetTripleString(self.handle));
    }
};

fn disposeError(err: c.LLVMErrorRef) void {
    const text = c.LLVMGetErrorMessage(err);
    if (text != null) c.LLVMDisposeErrorMessage(text);
}

const answer_ir =
    \\define i32 @answer() {
    \\entry:
    \\  ret i32 42
    \\}
;

test "LLJIT compiles IR and resolves a function" {
    var jit = try Jit.init(std.testing.allocator);
    defer jit.deinit();

    try jit.addIr(answer_ir, "answer");
    const Answer = *const fn () callconv(.c) i32;
    const answer = try jit.get(Answer, "answer");
    try std.testing.expectEqual(@as(i32, 42), answer());
    try std.testing.expect(jit.triple().len > 0);
}

test "invalid IR is rejected" {
    var jit = try Jit.init(std.testing.allocator);
    defer jit.deinit();
    try std.testing.expectError(error.InvalidIr, jit.addIr("not ir", "bad"));
}

fn hostAddOne(value: i32) callconv(.c) i32 {
    return value + 1;
}

test "host symbols can be registered and called from JITed IR" {
    var jit = try Jit.init(std.testing.allocator);
    defer jit.deinit();

    try jit.defineSymbols(&.{
        .{ .name = "host_add_one", .address = @intFromPtr(&hostAddOne) },
    });

    const ir =
        \\declare i32 @host_add_one(i32)
        \\define i32 @call_host() {
        \\entry:
        \\  %r = call i32 @host_add_one(i32 41)
        \\  ret i32 %r
        \\}
    ;
    try jit.addIr(ir, "host-symbol");
    const CallHost = *const fn () callconv(.c) i32;
    const call_host = try jit.get(CallHost, "call_host");
    try std.testing.expectEqual(@as(i32, 42), call_host());
}
