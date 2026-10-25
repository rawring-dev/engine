//! e7s -> Khronos Slang transpiler.
//!
//! e7s is the shading-language subset of engine7.  Inputs are e7 source files
//! (the same surface grammar the engine7 compiler parses); outputs are Slang
//! modules.  See `docs/e7s.md` for the subset and the extension attributes
//! (`@binding`, `@vertex`, `@fragment`, `@compute`, `@location`, `@builtin`,
//! `@push_constant`, `@uniform`, `@flat`).
//!
//! The public API is intentionally small:
//!
//!     const api = @import("transpiler");
//!     var result = try api.transpile(allocator, source, .{ .module_name = "main" });
//!     defer api.freeResult(allocator, &result);
//!     switch (result) { ... }
//!
//! Multi-file projects use `transpileModules`; the CLI uses `loadProject` to
//! read sibling `.e7` modules from disk.

const std = @import("std");

pub const project = @import("project.zig");
pub const session = @import("session.zig");
pub const diag = @import("diag.zig");

pub const Options = session.Options;
pub const InputModule = project.InputModule;
pub const OutputFile = project.OutputFile;
pub const Result = project.Result;
pub const Diagnostic = diag.Diagnostic;
pub const LoadResult = project.LoadResult;

/// Transpile one e7s source buffer as a single Slang module.
pub fn transpile(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: Options,
) !Result {
    const inputs = [_]InputModule{.{ .name = options.module_name, .source = source, .is_root = true }};
    return project.transpileModules(allocator, &inputs, options);
}

pub fn transpileModules(
    allocator: std.mem.Allocator,
    inputs: []const InputModule,
    options: Options,
) !Result {
    return project.transpileModules(allocator, inputs, options);
}

pub fn loadProject(allocator: std.mem.Allocator, root_path: []const u8) !LoadResult {
    return project.loadProject(allocator, root_path);
}

pub fn freeResult(allocator: std.mem.Allocator, result: *Result) void {
    project.freeResult(allocator, result);
}

pub const sanitizeModuleName = project.sanitizeModuleName;

pub fn freeInputs(allocator: std.mem.Allocator, inputs: []InputModule) void {
    project.freeInputs(allocator, inputs);
}

test {
    _ = @import("tests.zig");
}
