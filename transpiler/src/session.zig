//! Shared lowering session: output writer, diagnostics, program model, and
//! the per-item source span used for error messages.

const std = @import("std");
const ast = @import("compiler").ast;
const diag = @import("diag.zig");
const emit = @import("emit.zig");
const model = @import("model.zig");

pub const Error = error{ OutOfMemory, TranspileFailed };

pub const Options = struct {
    /// Slang module name for a single source buffer.  The CLI derives this from
    /// the file stem when omitted.
    module_name: []const u8 = "main",
    /// Emit `module <name>;` at the top of the generated file.
    emit_module_decl: bool = true,
    /// Maximum diagnostic count before lowering stops early.
    max_diagnostics: usize = 32,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    program: *model.Program,
    options: Options,
    diagnostics: *diag.List,
    out: *emit.Writer,
    /// Scratch arena for per-file lowering allocations (scopes, temporary
    /// slices).  Reset automatically when the session ends.
    scratch_arena: std.heap.ArenaAllocator,

    current_module: []const u8 = "",
    current_span: ast.Span = .{},
    /// `(set << 32) | binding` values already used by resource declarations.
    used_bindings: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        program: *model.Program,
        options: Options,
        diagnostics: *diag.List,
        out: *emit.Writer,
    ) Session {
        return .{
            .allocator = allocator,
            .program = program,
            .options = options,
            .diagnostics = diagnostics,
            .out = out,
            .scratch_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn scratch(self: *Session) std.mem.Allocator {
        return self.scratch_arena.allocator();
    }

    pub fn deinit(self: *Session) void {
        self.used_bindings.deinit(self.allocator);
        self.scratch_arena.deinit();
    }

    pub fn fail(self: *Session, comptime fmt: []const u8, args: anytype) Error {
        return self.failAt(self.current_span, fmt, args);
    }

    pub fn failAt(self: *Session, span: ast.Span, comptime fmt: []const u8, args: anytype) Error {
        self.diagnostics.add(span, fmt, args) catch return error.OutOfMemory;
        if (self.diagnostics.items.items.len >= self.options.max_diagnostics) {
            self.diagnostics.add(span, "too many errors; stopping", .{}) catch {};
        }
        return error.TranspileFailed;
    }

    pub fn setSpan(self: *Session, module: *const ast.Module, pointer: *const anyopaque) void {
        self.current_span = @import("astx.zig").spanOf(module, pointer);
    }
};
