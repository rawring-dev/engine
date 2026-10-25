//! Multi-module project orchestration and filesystem loading.
//!
//! Each e7 module becomes one Slang module file (`module <name>;`).  External
//! e7 `mod` references are loaded from sibling `.e7` files, matching the
//! compiler's project loader.

const std = @import("std");
const compiler = @import("compiler");
const ast = compiler.ast;
const astx = @import("astx.zig");
const diag = @import("diag.zig");
const emit = @import("emit.zig");
const lower_items = @import("lower_items.zig");
const model = @import("model.zig");
const session_mod = @import("session.zig");

pub const InputModule = struct {
    name: []const u8,
    source: []const u8,
    is_root: bool = false,
};

pub const OutputFile = struct {
    module_name: []u8,
    source: []u8,
};

pub const Options = session_mod.Options;

pub const Result = union(enum) {
    ok: []OutputFile,
    diagnostics: []diag.Diagnostic,
};

pub fn freeResult(allocator: std.mem.Allocator, result: *Result) void {
    switch (result.*) {
        .ok => |files| {
            for (files) |file| {
                allocator.free(file.module_name);
                allocator.free(file.source);
            }
            allocator.free(files);
        },
        .diagnostics => |diagnostics| diag.List.freeSlice(allocator, diagnostics),
    }
    result.* = undefined;
}

/// Transpile a set of already-parsed-by-source modules.  `inputs[0]` should be
/// the root module, but the output includes a file for every input.
pub fn transpileModules(
    allocator: std.mem.Allocator,
    inputs: []const InputModule,
    options: Options,
) !Result {
    var diagnostics = diag.List.init(allocator);
    errdefer diagnostics.deinit();
    if (inputs.len == 0) {
        try diagnostics.add(.{}, "no input modules", .{});
        return .{ .diagnostics = try diagnostics.toOwnedSlice() };
    }

    // Validate module names and uniqueness before parsing anything.
    var seen_names: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_names.deinit(allocator);
    for (inputs) |input| {
        if (!isValidSlangIdentifier(input.name)) {
            try diagnostics.add(.{}, "invalid Slang module name `{s}`", .{input.name});
            continue;
        }
        if (std.mem.eql(u8, input.name, "core")) {
            try diagnostics.add(.{}, "module name `core` is reserved by Slang", .{});
            continue;
        }
        if (seen_names.contains(input.name)) {
            try diagnostics.add(.{}, "duplicate module `{s}`", .{input.name});
            continue;
        }
        try seen_names.put(allocator, input.name, {});
    }
    if (diagnostics.failed) return .{ .diagnostics = try diagnostics.toOwnedSlice() };

    // Parse every module with engine7's real front end.
    const asts = try allocator.alloc(compiler.parser.Ast, inputs.len);
    var parsed_count: usize = 0;
    errdefer {
        for (asts[0..parsed_count]) |*tree| tree.deinit();
        allocator.free(asts);
    }

    for (inputs, 0..) |input, index| {
        const parsed = compiler.parser.parse(allocator, input.source) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LexFailed => {
                try diagnostics.add(.{}, "lex error in module `{s}`", .{input.name});
                for (asts[0..parsed_count]) |*tree| tree.deinit();
                allocator.free(asts);
                return .{ .diagnostics = try diagnostics.toOwnedSlice() };
            },
        };
        switch (parsed) {
            .ast => |tree| {
                asts[index] = tree;
                parsed_count += 1;
            },
            .diagnostic => |parse_diagnostic| {
                try diagnostics.add(.{
                    .line = parse_diagnostic.line,
                    .column = parse_diagnostic.column,
                    .offset = parse_diagnostic.offset,
                }, "parse error in module `{s}`: {s}", .{ input.name, parse_diagnostic.message });
                for (asts[0..parsed_count]) |*tree| tree.deinit();
                allocator.free(asts);
                return .{ .diagnostics = try diagnostics.toOwnedSlice() };
            },
        }
    }
    defer {
        for (asts) |*tree| tree.deinit();
        allocator.free(asts);
    }

    const module_infos = try allocator.alloc(model.ModuleInfo, inputs.len);
    defer allocator.free(module_infos);
    for (inputs, 0..) |input, index| {
        module_infos[index] = .{
            .name = input.name,
            .source = input.source,
            .ast = &asts[index],
            .is_root = input.is_root,
        };
    }

    var program = try model.Program.collect(allocator, module_infos);
    defer program.deinit();

    var session = session_mod.Session.init(allocator, &program, options, &diagnostics, undefined);
    defer session.deinit();

    var outputs = std.ArrayList(OutputFile).empty;
    errdefer {
        for (outputs.items) |file| {
            allocator.free(file.module_name);
            allocator.free(file.source);
        }
        outputs.deinit(allocator);
    }

    for (module_infos) |module_info| {
        var writer = emit.Writer.init(allocator);
        defer writer.deinit();
        session.out = &writer;
        session.current_module = module_info.name;
        session.current_span = .{};

        emitModule(&session, module_info) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TranspileFailed => {
                for (outputs.items) |file| {
                    allocator.free(file.module_name);
                    allocator.free(file.source);
                }
                outputs.deinit(allocator);
                return .{ .diagnostics = try diagnostics.toOwnedSlice() };
            },
        };
        writer.finish();
        const source = try writer.take();
        errdefer allocator.free(source);
        const name = try allocator.dupe(u8, module_info.name);
        try outputs.append(allocator, .{ .module_name = name, .source = source });
    }

    return .{ .ok = try outputs.toOwnedSlice(allocator) };
}

fn emitModule(session: *session_mod.Session, module_info: model.ModuleInfo) !void {
    const out = session.out;
    session.used_bindings.clearRetainingCapacity();
    try out.line("// Generated by the engine7 e7s -> Slang transpiler. Do not edit.", .{});
    try out.line("// Source: {s}.e7", .{module_info.name});
    if (session.options.emit_module_decl) {
        try out.line("module {s};", .{module_info.name});
    }
    try out.blank();

    var imports = std.StringHashMapUnmanaged(void).empty;
    defer imports.deinit(session.allocator);
    try collectImports(session, module_info, &imports);

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(session.allocator);
    var iterator = imports.keyIterator();
    while (iterator.next()) |name| try names.append(session.allocator, name.*);
    std.mem.sort([]const u8, names.items, {}, lessThanString);

    for (names.items) |name| try out.line("import {s};", .{name});
    if (names.items.len > 0) try out.blank();

    try lower_items.emitItems(session, module_info.ast.module, module_info.ast.module.items, .module_file);
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn collectImports(
    session: *session_mod.Session,
    module_info: model.ModuleInfo,
    imports: *std.StringHashMapUnmanaged(void),
) !void {
    for (module_info.ast.module.items) |item| {
        switch (item.kind) {
            .mod => |mod_decl| {
                if (mod_decl.items != null) continue;
                try requireKnownModule(session, mod_decl.name);
                try imports.put(session.allocator, mod_decl.name, {});
            },
            .use => |use_decl| {
                session.setSpan(module_info.ast.module, item);
                try collectUseImports(session, use_decl.tree, imports);
            },
            else => {},
        }
    }
}

fn collectUseImports(
    session: *session_mod.Session,
    tree: ast.UseTree,
    imports: *std.StringHashMapUnmanaged(void),
) !void {
    switch (tree) {
        .path => |use_path| {
            if (use_path.alias != null) {
                return session.fail("`use ... as ...` aliases are not supported in e7s (Slang imports are unqualified)", .{});
            }
            try requireKnownModuleFromPath(session, use_path.path, imports);
        },
        .glob => |path| try requireKnownModuleFromPath(session, path, imports),
        .group => |group| try requireKnownModuleFromPath(session, group.prefix, imports),
    }
}

fn requireKnownModuleFromPath(
    session: *session_mod.Session,
    path: ast.Path,
    imports: *std.StringHashMapUnmanaged(void),
) !void {
    if (path.segments.len == 0) {
        return session.fail("empty `use` path", .{});
    }
    var index: usize = 0;
    while (index < path.segments.len and astx.isQualifierSegment(path.segments[index].name)) {
        if (!std.mem.eql(u8, path.segments[index].name, "crate")) {
            return session.fail("module-relative `self`/`super` imports are not supported in e7s", .{});
        }
        index += 1;
    }
    if (index >= path.segments.len) {
        return session.fail("`use crate` does not name a module", .{});
    }
    const name = path.segments[index].name;
    try requireKnownModule(session, name);
    if (session.program.isExternalModule(name) or !session.program.isInlineModule(name)) {
        try imports.put(session.allocator, name, {});
    }
}

fn requireKnownModule(session: *session_mod.Session, name: []const u8) !void {
    if (session.program.isExternalModule(name)) {
        if (session.program.hasModule(name)) return;
        return session.fail("module `{s}` is declared but no `{s}.e7` source was provided", .{ name, name });
    }
    if (session.program.hasModule(name)) return;
    if (session.program.isInlineModule(name)) return;
    return session.fail("unknown module `{s}` (declare it with `mod {s}` or provide {s}.e7)", .{ name, name, name });
}

// ---------------------------------------------------------------------------
// Filesystem project loading
// ---------------------------------------------------------------------------

pub const LoadError = error{
    OutOfMemory,
    ProjectIo,
    ProjectParse,
    ProjectCycle,
};

pub const LoadResult = union(enum) {
    ok: []InputModule,
    diagnostics: []diag.Diagnostic,
};

pub fn freeInputs(allocator: std.mem.Allocator, inputs: []InputModule) void {
    for (inputs) |input| {
        allocator.free(input.name);
        allocator.free(input.source);
    }
    allocator.free(inputs);
}

const max_project_depth = 16;
const max_module_file_size = 16 * 1024 * 1024;

/// Load a root `.e7` file and every sibling module referenced by an external
/// `mod name` declaration.  Each module's name is its file stem.
pub fn loadProject(allocator: std.mem.Allocator, root_path: []const u8) !LoadResult {
    const root_name = try moduleNameFromPath(allocator, root_path) orelse {
        var diagnostics = diag.List.init(allocator);
        try diagnostics.add(.{}, "cannot derive a Slang module name from `{s}`", .{root_path});
        return .{ .diagnostics = try diagnostics.toOwnedSlice() };
    };
    defer allocator.free(root_name);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var loaded = std.ArrayList(InputModule).empty;
    errdefer {
        for (loaded.items) |input| {
            allocator.free(input.name);
            allocator.free(input.source);
        }
        loaded.deinit(allocator);
    }

    var visiting = std.StringHashMapUnmanaged(void).empty;
    defer visiting.deinit(allocator);

    var diagnostics = diag.List.init(allocator);
    errdefer diagnostics.deinit();

    const root_source = readSource(allocator, io, root_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diagnostics.add(.{}, "cannot read `{s}`", .{root_path});
            return .{ .diagnostics = try diagnostics.toOwnedSlice() };
        },
    };
    const root_dir = std.fs.path.dirname(root_path) orelse ".";
    try loadOne(
        allocator,
        io,
        root_dir,
        root_name,
        root_source,
        true,
        &loaded,
        &visiting,
        &diagnostics,
        0,
    );

    if (diagnostics.failed) {
        for (loaded.items) |input| {
            allocator.free(input.name);
            allocator.free(input.source);
        }
        loaded.deinit(allocator);
        return .{ .diagnostics = try diagnostics.toOwnedSlice() };
    }

    return .{ .ok = try loaded.toOwnedSlice(allocator) };
}

fn loadOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
    source: []u8,
    is_root: bool,
    loaded: *std.ArrayList(InputModule),
    visiting: *std.StringHashMapUnmanaged(void),
    diagnostics: *diag.List,
    depth: usize,
) !void {
    if (depth > max_project_depth) {
        try diagnostics.add(.{}, "module nesting is too deep at `{s}`", .{name});
        allocator.free(source);
        return;
    }
    if (visiting.contains(name)) {
        try diagnostics.add(.{}, "cyclic module dependency involving `{s}`", .{name});
        allocator.free(source);
        return;
    }
    for (loaded.items) |existing| {
        if (std.mem.eql(u8, existing.name, name)) {
            // Already loaded from a previous `mod` reference.
            allocator.free(source);
            return;
        }
    }
    try visiting.put(allocator, name, {});

    const parsed = compiler.parser.parse(allocator, source) catch |err| switch (err) {
        error.OutOfMemory => {
            allocator.free(source);
            return error.OutOfMemory;
        },
        error.LexFailed => {
            try diagnostics.add(.{}, "lex error in module `{s}`", .{name});
            allocator.free(source);
            return;
        },
    };
    var tree = switch (parsed) {
        .ast => |ast_value| ast_value,
        .diagnostic => |parse_diagnostic| {
            try diagnostics.add(.{
                .line = parse_diagnostic.line,
                .column = parse_diagnostic.column,
                .offset = parse_diagnostic.offset,
            }, "parse error in module `{s}`: {s}", .{ name, parse_diagnostic.message });
            allocator.free(source);
            return;
        },
    };
    defer tree.deinit();

    try loaded.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .source = source,
        .is_root = is_root,
    });

    for (tree.module.items) |item| {
        switch (item.kind) {
            .mod => |mod_decl| {
                if (mod_decl.items != null) continue;
                if (mod_decl.name.len == 0) continue;
                const filename = try std.fmt.allocPrint(allocator, "{s}.e7", .{mod_decl.name});
                defer allocator.free(filename);
                const path = try std.fs.path.join(allocator, &.{ directory, filename });
                defer allocator.free(path);
                const child_source = readSource(allocator, io, path) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        try diagnostics.add(.{}, "cannot read `{s}` for `mod {s}`", .{ path, mod_decl.name });
                        continue;
                    },
                };
                try loadOne(
                    allocator,
                    io,
                    directory,
                    mod_decl.name,
                    child_source,
                    false,
                    loaded,
                    visiting,
                    diagnostics,
                    depth + 1,
                );
            },
            else => {},
        }
    }

    _ = visiting.remove(name);
}

fn readSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_module_file_size)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ProjectIo,
    };
}

fn moduleNameFromPath(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const base = std.fs.path.basename(path);
    const extension = std.fs.path.extension(base);
    if (!std.mem.eql(u8, extension, ".e7")) return null;
    const stem = base[0 .. base.len - extension.len];
    return try sanitizeModuleName(allocator, stem);
}

/// Turn a file stem into a valid Slang module name.  Dots and other invalid
/// identifier characters become `_` (so `triangle.vert.e7` -> `triangle_vert`),
/// a leading digit gets a `_` prefix, and Slang's reserved `core` module name
/// gets a suffix.
pub fn sanitizeModuleName(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0) return allocator.dupe(u8, "main");
    var out = try allocator.alloc(u8, raw.len + 1);
    var length: usize = 0;
    for (raw) |character| {
        if (std.ascii.isAlphanumeric(character) or character == '_') {
            out[length] = character;
        } else {
            out[length] = '_';
        }
        length += 1;
    }
    if (!std.ascii.isAlphabetic(out[0]) and out[0] != '_') {
        var shifted = try allocator.alloc(u8, length + 1);
        shifted[0] = '_';
        @memcpy(shifted[1..], out[0..length]);
        allocator.free(out);
        out = shifted;
        length += 1;
    }
    const result = try allocator.dupe(u8, out[0..length]);
    allocator.free(out);
    if (std.mem.eql(u8, result, "core")) {
        const suffixed = try std.fmt.allocPrint(allocator, "{s}_", .{result});
        allocator.free(result);
        return suffixed;
    }
    return result;
}

pub fn isValidSlangIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '_') return false;
    }
    return true;
}
