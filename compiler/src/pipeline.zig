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
    /// Parsed sibling modules loaded by `compileProject` (owned).  The root
    /// AST references their items, so these outlive analysis/lowering.
    module_asts: []parser.Ast = &.{},
    /// Source buffers owned by project loading; AST lexemes point into them.
    owned_sources: [][]u8 = &.{},
    /// Paths of loaded project files (owned strings).
    owned_paths: [][]u8 = &.{},

    pub fn deinit(self: *CompileResult) void {
        self.bytecode.deinit();
        self.analysis.deinit();
        self.parsed.deinit();
        for (self.module_asts) |*tree| tree.deinit();
        if (self.module_asts.len > 0) self.allocator.free(self.module_asts);
        for (self.owned_sources) |source| self.allocator.free(source);
        if (self.owned_sources.len > 0) self.allocator.free(self.owned_sources);
        for (self.owned_paths) |path| self.allocator.free(path);
        if (self.owned_paths.len > 0) self.allocator.free(self.owned_paths);
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

// ---------------------------------------------------------------------------
// Project loading
// ---------------------------------------------------------------------------

pub const ProjectError = error{
    OutOfMemory,
    /// A project file could not be read (missing, unreadable, or too large).
    ProjectIo,
    /// A project file failed to lex/parse.
    ProjectParse,
    /// External `mod` references nest beyond the loader's depth bound.
    ProjectCycle,
};

pub const ProjectFile = struct {
    /// Path exactly as resolved while loading (owned).
    path: []u8,
    /// File contents (owned); the parsed AST points into this buffer.
    source: []u8,
};

/// A loaded multi-file project: the root AST plus every sibling module.
pub const Project = struct {
    allocator: std.mem.Allocator,
    files: []ProjectFile,
    root_ast: parser.Ast,
    module_asts: []parser.Ast,

    pub fn deinit(self: *Project) void {
        self.root_ast.deinit();
        for (self.module_asts) |*tree| tree.deinit();
        self.allocator.free(self.module_asts);
        for (self.files) |file| {
            self.allocator.free(file.path);
            self.allocator.free(file.source);
        }
        self.allocator.free(self.files);
        self.* = undefined;
    }
};

const max_project_depth: usize = 16;
const max_project_file_size: usize = 64 * 1024 * 1024;

fn readProjectFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ProjectError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_project_file_size)) catch
        return error.ProjectIo;
}

fn parseProjectFile(allocator: std.mem.Allocator, source: []const u8) ProjectError!parser.Ast {
    const parsed_result = parser.parse(allocator, source) catch return error.OutOfMemory;
    return switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => error.ProjectParse,
    };
}

/// Load `root_path` and recursively inline module files for every external
/// `mod <name>` reference.  A module resolves to either `<dir>/<name>.e7` or a
/// nested `<dir>/<name>/main.e7`; child modules are resolved relative to the
/// file that declared them.  Semantic analysis sees prefixed modules
/// (`ui::Ui`, `core::window::Window`) exactly as if inline.
pub fn loadProject(allocator: std.mem.Allocator, root_path: []const u8) ProjectError!Project {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var files = std.ArrayList(ProjectFile).empty;
    errdefer {
        for (files.items) |file| {
            allocator.free(file.path);
            allocator.free(file.source);
        }
        files.deinit(allocator);
    }
    var module_asts = std.ArrayList(parser.Ast).empty;
    errdefer {
        for (module_asts.items) |*tree| tree.deinit();
        module_asts.deinit(allocator);
    }

    const root_source = try readProjectFile(allocator, io, root_path);
    var root_source_owned = true;
    errdefer if (root_source_owned) allocator.free(root_source);
    const root_path_owned = try allocator.dupe(u8, root_path);
    var root_path_owned_flag = true;
    errdefer if (root_path_owned_flag) allocator.free(root_path_owned);
    try files.append(allocator, .{ .path = root_path_owned, .source = root_source });
    // The file list now owns both allocations; its errdefer frees them once.
    root_source_owned = false;
    root_path_owned_flag = false;
    var root_ast = try parseProjectFile(allocator, root_source);
    errdefer root_ast.deinit();

    const directory = std.fs.path.dirname(root_path) orelse ".";
    try resolveExternalModules(
        allocator,
        io,
        &root_ast,
        directory,
        &files,
        &module_asts,
        0,
    );

    return .{
        .allocator = allocator,
        .files = try files.toOwnedSlice(allocator),
        .root_ast = root_ast,
        .module_asts = try module_asts.toOwnedSlice(allocator),
    };
}

fn loadModuleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
) ProjectError!struct { path: []u8, source: []u8 } {
    const flat_name = try std.fmt.allocPrint(allocator, "{s}.e7", .{name});
    defer allocator.free(flat_name);
    var path = try std.fs.path.join(allocator, &.{ directory, flat_name });
    if (readProjectFile(allocator, io, path)) |source| {
        return .{ .path = path, .source = source };
    } else |flat_error| {
        allocator.free(path);
        if (flat_error != error.ProjectIo) return flat_error;
    }
    path = try std.fs.path.join(allocator, &.{ directory, name, "main.e7" });
    const source = readProjectFile(allocator, io, path) catch |nested_error| {
        allocator.free(path);
        return nested_error;
    };
    return .{ .path = path, .source = source };
}

fn resolveExternalModules(
    allocator: std.mem.Allocator,
    io: std.Io,
    tree: *parser.Ast,
    directory: []const u8,
    files: *std.ArrayList(ProjectFile),
    module_asts: *std.ArrayList(parser.Ast),
    depth: usize,
) ProjectError!void {
    if (depth > max_project_depth) return error.ProjectCycle;
    for (tree.module.items) |item| {
        // Only external `mod name` references (no `{ ... }` body) need loading.
        switch (item.kind) {
            .mod => |module| {
                if (module.items != null) continue;
                const loaded = try loadModuleFile(allocator, io, directory, module.name);
                const path = loaded.path;
                const source = loaded.source;
                var path_owned = true;
                errdefer if (path_owned) allocator.free(path);
                var source_owned = true;
                errdefer if (source_owned) allocator.free(source);
                try files.append(allocator, .{ .path = path, .source = source });
                // Ownership moved into the file list.
                path_owned = false;
                source_owned = false;
                var child = try parseProjectFile(allocator, source);
                errdefer child.deinit();
                const child_directory = std.fs.path.dirname(path) orelse directory;
                try resolveExternalModules(allocator, io, &child, child_directory, files, module_asts, depth + 1);
                try module_asts.append(allocator, child);
                const module_decl: *ast.ModDecl = &item.kind.mod;
                module_decl.items = child.module.items;
            },
            else => {},
        }
    }
}

/// Compile every file of a project starting at `root_path`.  Equivalent to
/// `compile`, but external sibling modules are loaded first.
pub fn compileProject(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    options: Options,
) (Error || ProjectError)!CompileResult {
    var project = try loadProject(allocator, root_path);
    errdefer project.deinit();

    var analysis = try semantic.analyze(allocator, project.root_ast.module);
    errdefer analysis.deinit();
    if (!analysis.ok()) return error.SemanticFailed;

    var module = try codegen.lower(allocator, project.root_ast.module, &analysis, options.codegen);
    errdefer module.deinit();

    const stats = try bytecode.optimize(allocator, &module, options.optimize);
    try bytecode.verify(allocator, &module);

    var owned_sources = try allocator.alloc([]u8, project.files.len);
    var owned_paths = try allocator.alloc([]u8, project.files.len);
    for (project.files, 0..) |file, index| {
        owned_sources[index] = file.source;
        owned_paths[index] = file.path;
    }
    // Contents moved into the result; only the bookkeeping slice is freed.
    allocator.free(project.files);

    return .{
        .parsed = project.root_ast,
        .analysis = analysis,
        .bytecode = module,
        .optimization = stats,
        .allocator = allocator,
        .module_asts = project.module_asts,
        .owned_sources = owned_sources,
        .owned_paths = owned_paths,
    };
}

/// One in-memory project module for `compileProjectFromSources`.
pub const SourceFile = struct {
    /// External module name as written in `mod <name>`.
    name: []const u8,
    source: []const u8,
};

fn attachSourceModules(
    allocator: std.mem.Allocator,
    tree: *parser.Ast,
    modules: []const SourceFile,
    module_asts: []parser.Ast,
    attached: []bool,
    depth: usize,
) ProjectError!void {
    if (depth > max_project_depth) return error.ProjectCycle;
    for (tree.module.items) |item| {
        if (item.kind != .mod) continue;
        const module_decl: *ast.ModDecl = &item.kind.mod;
        if (module_decl.items != null) continue;
        var module_index: ?usize = null;
        for (modules, 0..) |module, index| {
            if (!std.mem.eql(u8, module.name, module_decl.name)) continue;
            module_index = index;
            break;
        }
        const index = module_index orelse return error.ProjectIo;
        if (attached[index]) return error.ProjectCycle;
        attached[index] = true;
        module_decl.items = module_asts[index].module.items;
        try attachSourceModules(
            allocator,
            &module_asts[index],
            modules,
            module_asts,
            attached,
            depth + 1,
        );
    }
}

/// Compile a project whose root and sibling module sources are supplied in
/// memory.  This is the embedding/test counterpart of `compileProject`: every
/// external `mod <name>` is resolved against the `modules` list instead of the
/// filesystem.  Source buffers are duplicated into the result so caller memory
/// may be released immediately after the call.
pub fn compileProjectFromSources(
    allocator: std.mem.Allocator,
    root_source: []const u8,
    modules: []const SourceFile,
    options: Options,
) (Error || ProjectError)!CompileResult {
    const file_count = modules.len + 1;
    const owned_sources = try allocator.alloc([]u8, file_count);
    var sources_initialized: usize = 0;
    errdefer {
        for (owned_sources[0..sources_initialized]) |source| allocator.free(source);
        allocator.free(owned_sources);
    }
    const owned_paths = try allocator.alloc([]u8, file_count);
    var paths_initialized: usize = 0;
    errdefer {
        for (owned_paths[0..paths_initialized]) |path| allocator.free(path);
        allocator.free(owned_paths);
    }

    owned_sources[0] = try allocator.dupe(u8, root_source);
    sources_initialized = 1;
    owned_paths[0] = try allocator.dupe(u8, "<memory-root>");
    paths_initialized = 1;
    for (modules, 0..) |module, index| {
        owned_sources[index + 1] = try allocator.dupe(u8, module.source);
        sources_initialized += 1;
        owned_paths[index + 1] = try allocator.dupe(u8, module.name);
        paths_initialized += 1;
    }

    var root_ast = try parseProjectFile(allocator, owned_sources[0]);
    errdefer root_ast.deinit();

    var module_asts = std.ArrayList(parser.Ast).empty;
    errdefer {
        for (module_asts.items) |*tree| tree.deinit();
        module_asts.deinit(allocator);
    }
    try module_asts.ensureTotalCapacity(allocator, modules.len);
    for (modules, 0..) |_, index| {
        const child = try parseProjectFile(allocator, owned_sources[index + 1]);
        // Capacity was reserved above; on a later error the module_asts
        // errdefer frees every parsed child exactly once.
        module_asts.appendAssumeCapacity(child);
    }

    const attached = try allocator.alloc(bool, modules.len);
    defer allocator.free(attached);
    @memset(attached, false);
    try attachSourceModules(
        allocator,
        &root_ast,
        modules,
        module_asts.items,
        attached,
        0,
    );

    var analysis = try semantic.analyze(allocator, root_ast.module);
    errdefer analysis.deinit();
    if (!analysis.ok()) return error.SemanticFailed;

    var module = try codegen.lower(allocator, root_ast.module, &analysis, options.codegen);
    errdefer module.deinit();

    const stats = try bytecode.optimize(allocator, &module, options.optimize);
    try bytecode.verify(allocator, &module);

    return .{
        .parsed = root_ast,
        .analysis = analysis,
        .bytecode = module,
        .optimization = stats,
        .allocator = allocator,
        .module_asts = try module_asts.toOwnedSlice(allocator),
        .owned_sources = owned_sources,
        .owned_paths = owned_paths,
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

test "compiles systems with resource, query, and Commands prologues" {
    var result = try compile(
        std.testing.allocator,
        \\@resource
        \\S <- struct
        \\    a: i32
        \\@Components
        \\C <- struct
        \\    b: i32
        \\@Components
        \\D <- struct
        \\    c: i32
        \\Components <- table
        \\    entity_id: usize,
        \\    ...
        \\Tick <- sys (
        \\    target: res &mut S,
        \\    items: select &mut C, &D from Components,
        \\    commands: &mut Commands,
        \\):
        \\    target.a = 1
        \\main <- async () -> i32:
        \\    window := await query &S
        \\    _ := window
        \\    await Tick()
        \\    7
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    // The setup function registers the ungated resource and the component.
    const setup = result.functionNamed("__e7_ecs_setup").?;
    var registered_resources: usize = 0;
    var registered_components: usize = 0;
    for (setup.code) |op| switch (op) {
        .runtime_call => |call| switch (call.function) {
            .ecs_register_resource => registered_resources += 1,
            .ecs_register_component => registered_components += 1,
            else => {},
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), registered_resources);
    try std.testing.expectEqual(@as(usize, 2), registered_components);

    // `main` runs the ECS setup before user code.
    const run_body = result.functionNamed("main__body").?;
    var calls_setup = false;
    for (run_body.code) |op| switch (op) {
        .call => |call| {
            if (result.bytecode.functions[call.function].name.len > 0 and
                std.mem.eql(u8, result.bytecode.functions[call.function].name, "__e7_ecs_setup")) calls_setup = true;
            if (std.mem.eql(u8, result.bytecode.functions[call.function].name, "Tick")) calls_setup = calls_setup;
        },
        else => {},
    };
    try std.testing.expect(calls_setup);

    // The system body fetches world handles for its declared parameters.
    const body = result.functionNamed("Tick__body").?;
    try std.testing.expectEqual(@as(u16, 4), body.params); // task + 3 system params
    var saw_resource = false;
    var saw_query = false;
    var saw_commands = false;
    for (body.code) |op| switch (op) {
        .runtime_call => |call| switch (call.function) {
            .ecs_resource => saw_resource = true,
            .ecs_query_begin => saw_query = true,
            .ecs_commands => saw_commands = true,
            else => {},
        },
        else => {},
    };
    try std.testing.expect(saw_resource and saw_query and saw_commands);
    // Projected id/mut arrays are 8-byte slots: writing entry 1 uses offset 8.
    var saw_slot_offset = false;
    for (body.code) |op| switch (op) {
        .push_i64 => |value| {
            if (value == 8) saw_slot_offset = true;
        },
        else => {},
    };
    try std.testing.expect(saw_slot_offset);

    // `await query &S` resolves to the resource pointer, not a Task.
    var lease_fetches: usize = 0;
    for (run_body.code) |op| switch (op) {
        .runtime_call => |call| switch (call.function) {
            .ecs_resource => lease_fetches += 1,
            else => {},
        },
        else => {},
    };
    try std.testing.expect(lease_fetches >= 1);
}

test "lowers Commands methods and plugin initialization" {
    var result = try compile(
        std.testing.allocator,
        \\@resource
        \\Win <- struct
        \\    n: i32
        \\@Components
        \\Pos <- struct
        \\    x: i32
        \\Components <- table
        \\    entity_id: usize,
        \\    ...
        \\Ui <- plugin
        \\    init <- sys (commands: &mut Commands):
        \\        commands.insert_resource(Win { n: 1 })
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    commands.insert_resource(Win { n: 2 })
        \\    pos := Pos { x: 3 }
        \\    commands.add_row(Components, { pos })
        \\    commands.add_plugin(Ui)
        \\    disown commands
        \\    0
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    try std.testing.expect(result.functionNamed("main") != null);
    try std.testing.expect(result.functionNamed("main__body") != null);
    try std.testing.expect(result.functionNamed("Ui::init") != null);
    try std.testing.expect(result.functionNamed("Ui::init__body") != null);

    const body = result.functionNamed("main__body").?;
    var insert_count: usize = 0;
    var row_begin = false;
    var row_add = false;
    var row_finish = false;
    var add_plugin = false;
    var flush_count: usize = 0;
    var commands_handles: usize = 0;
    for (body.code) |op| switch (op) {
        .runtime_call => |call| switch (call.function) {
            .ecs_commands => commands_handles += 1,
            .ecs_commands_insert_resource => insert_count += 1,
            .ecs_commands_row_begin => row_begin = true,
            .ecs_commands_row_add => row_add = true,
            .ecs_commands_row_finish => row_finish = true,
            .ecs_commands_add_plugin => add_plugin = true,
            .ecs_commands_flush => flush_count += 1,
            else => {},
        },
        else => {},
    };
    try std.testing.expect(commands_handles >= 1);
    try std.testing.expectEqual(@as(usize, 1), insert_count);
    try std.testing.expect(row_begin and row_add and row_finish);
    try std.testing.expect(add_plugin);
    // add_plugin flushes before running init; `disown` flushes again.
    try std.testing.expect(flush_count >= 2);

    // Plugin metadata: Ui owns id 0 and an init function.
    try std.testing.expectEqual(@as(usize, 1), result.analysis.plugins.len);
    try std.testing.expectEqual(@as(i64, 0), result.analysis.plugins[0].id);
    try std.testing.expectEqualStrings("Ui::init", result.analysis.plugins[0].init.?);
    try std.testing.expectEqual(@as(usize, 1), result.analysis.resources.len);
    try std.testing.expectEqual(@as(usize, 1), result.analysis.components.len);

    // The gated-resource registration path is exercised by plugin init's
    // insert_resource; Win itself is ungated and registered in setup.
    const init_body = result.functionNamed("Ui::init__body").?;
    var init_insert = false;
    for (init_body.code) |op| switch (op) {
        .runtime_call => |call| switch (call.function) {
            .ecs_commands_insert_resource => init_insert = true,
            else => {},
        },
        else => {},
    };
    try std.testing.expect(init_insert);
}

test "gates plugin systems and flushes at trigger completion" {
    var result = try compile(
        std.testing.allocator,
        \\@resource
        \\Win <- struct
        \\    n: i32
        \\Ui <- plugin
        \\    init <- sys (commands: &mut Commands):
        \\        ret
        \\Update <- trigger
        \\@plugin(Ui)
        \\@trigger(Update)
        \\gated <- sys (win: res &mut Win):
        \\    win.n = 1
        \\run <- async () -> ():
        \\    await Update()
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    // Metadata records the system gate.
    try std.testing.expectEqual(@as(i64, 0), result.analysis.systemGate("gated").?);

    const trigger_body = result.functionNamed("Update__body").?;
    var saw_gate = false;
    var saw_flush = false;
    var spawned = false;
    for (trigger_body.code) |op| switch (op) {
        .runtime_call => |call| switch (call.function) {
            .ecs_plugin_active => saw_gate = true,
            .ecs_commands_flush => saw_flush = true,
            else => {},
        },
        .task_spawn => spawned = true,
        else => {},
    };
    try std.testing.expect(saw_gate and saw_flush and spawned);
}

test "trigger systems may declare world parameters" {
    var result = try compile(
        std.testing.allocator,
        \\@resource
        \\R <- struct
        \\    n: i32
        \\Update <- trigger
        \\@trigger(Update)
        \\Tick <- sys (r: res &mut R):
        \\    r.n = 1
        \\run <- async () -> ():
        \\    await Update()
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    const trigger_body = result.functionNamed("Update__body").?;
    var spawned_system = false;
    for (trigger_body.code) |op| switch (op) {
        .call => |call| {
            if (std.mem.endsWith(u8, result.bytecode.functions[call.function].name, "Tick__trigger")) spawned_system = true;
            try std.testing.expectEqual(@as(u16, 0), call.argc);
        },
        else => {},
    };
    try std.testing.expect(spawned_system);

    // Plain (non-world) trigger system parameters are not bound from trigger
    // fields yet: they lower as placeholder zeroes.  This is the documented
    // trigger-field binding gap, not a hard rejection.
    var plain = try compile(
        std.testing.allocator,
        \\Update <- trigger
        \\@trigger(Update)
        \\Tick <- sys (amount: i32):
        \\    amount
        \\run <- async () -> ():
        \\    await Update()
    ,
        .{},
    );
    defer plain.deinit();
    try bytecode.verify(std.testing.allocator, &plain.bytecode);
}

test "lowers query projection iteration" {
    var result = try compile(
        std.testing.allocator,
        \\@Components
        \\C <- struct
        \\    b: i32
        \\@Components
        \\D <- struct
        \\    c: i32
        \\Components <- table
        \\    entity_id: usize,
        \\    ...
        \\Tuple <- sys (items: select &mut C, &D from Components):
        \\    for (c, d) in items:
        \\        c.b = c.b + d.c
        \\Single <- sys (items: select &mut C from Components):
        \\    for row in items:
        \\        row.b = row.b + 1
        \\Wild <- sys (items: select &C from Components):
        \\    for _ in items:
        \\        0
        \\Controls <- sys (items: select &mut C from Components):
        \\    for row in items:
        \\        if row.b > 0:
        \\            break
        \\        cont
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    const Counter = struct {
        fn count(function: *const bytecode.Function, wanted: bytecode.RuntimeFunction) usize {
            var total: usize = 0;
            for (function.code) |op| switch (op) {
                .runtime_call => |call| {
                    if (call.function == wanted) total += 1;
                },
                else => {},
            };
            return total;
        }
    };

    const tuple_body = result.functionNamed("Tuple__body").?;
    try std.testing.expectEqual(@as(usize, 1), Counter.count(tuple_body, .ecs_query_next));
    try std.testing.expectEqual(@as(usize, 2), Counter.count(tuple_body, .ecs_query_component));

    const single_body = result.functionNamed("Single__body").?;
    try std.testing.expectEqual(@as(usize, 1), Counter.count(single_body, .ecs_query_next));
    try std.testing.expectEqual(@as(usize, 1), Counter.count(single_body, .ecs_query_component));

    // A wildcard binding still advances the iterator but fetches no projections.
    const wild_body = result.functionNamed("Wild__body").?;
    try std.testing.expectEqual(@as(usize, 1), Counter.count(wild_body, .ecs_query_next));
    try std.testing.expectEqual(@as(usize, 0), Counter.count(wild_body, .ecs_query_component));

    // Projecting fields directly off the query handle is still unsupported;
    // bindings from iteration are the supported surface.
    try std.testing.expectError(error.UnsupportedFeature, compile(
        std.testing.allocator,
        \\@Components
        \\C <- struct
        \\    a: i32
        \\Components <- table
        \\    entity_id: usize,
        \\    ...
        \\Tick <- sys (q: select &a from Components):
        \\    x := q.a
        \\    x
    ,
        .{},
    ));

    // Resource parameters are real pointers: field reads/writes lower.
    var resource_result = try compile(
        std.testing.allocator,
        \\@resource
        \\R <- struct
        \\    n: i32
        \\Tick <- sys (target: res &mut R):
        \\    target.n = 1
    ,
        .{},
    );
    defer resource_result.deinit();
    try std.testing.expect(resource_result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &resource_result.bytecode);
}

test "compiles the engine main/ui project from disk" {
    // The test binary's working directory depends on whether the compiler
    // package or the workspace build graph is driving the tests.
    const candidates = [_][]const u8{
        "engine/main.e7",
        "../engine/main.e7",
        "../../engine/main.e7",
    };
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var root_path: []const u8 = "";
    for (candidates) |candidate| {
        var probe = std.Io.Dir.cwd().openFile(std.testing.io, candidate, .{}) catch continue;
        probe.close(std.testing.io);
        const absolute = std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, candidate, std.testing.allocator) catch continue;
        @memcpy(path_buffer[0..absolute.len], absolute);
        root_path = path_buffer[0..absolute.len];
        std.testing.allocator.free(absolute);
        break;
    }
    if (root_path.len == 0) return error.SkipZigTest;

    var result = compileProject(std.testing.allocator, root_path, .{}) catch |err| {
        std.debug.print("engine project compile error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer result.deinit();
    if (!result.analysis.ok()) {
        for (result.analysis.diagnostics) |d| std.debug.print("engine project diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
    }
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    // Root + ui module were loaded and prefixed.
    try std.testing.expect(result.owned_sources.len >= 2);
    try std.testing.expect(result.module_asts.len >= 1);
    try std.testing.expect(result.functionNamed("main") != null);
    try std.testing.expect(result.functionNamed("main__body") != null);
    try std.testing.expect(result.functionNamed("__e7_ecs_setup") != null);
    try std.testing.expect(result.functionNamed("ui::Ui::init") != null);
    try std.testing.expect(result.functionNamed("ui::Ui::init__body") != null);

    // ECS metadata is collected across the module tree; the UI plugin is one
    // of several engine plugins.
    try std.testing.expect(result.analysis.plugins.len >= 1);
    var found_ui = false;
    for (result.analysis.plugins) |plugin| {
        if (std.mem.eql(u8, plugin.name, "ui::Ui")) {
            found_ui = true;
            try std.testing.expectEqualStrings("ui::Ui::init", plugin.init.?);
        }
    }
    try std.testing.expect(found_ui);
    try std.testing.expect(result.analysis.resources.len >= 5);
    try std.testing.expect(result.analysis.components.len >= 6);
    try std.testing.expect(result.analysis.component_table != null);
    try std.testing.expect(result.analysis.component_table.?.columns.len >= 6);
    // `ui_interact`/`ui_render` are gated by the Ui plugin.
    try std.testing.expect(result.analysis.system_gates.len >= 2);

    const setup = result.functionNamed("__e7_ecs_setup").?;
    var registered_components: usize = 0;
    for (setup.code) |op| switch (op) {
        .runtime_call => |call| switch (call.function) {
            .ecs_register_component => registered_components += 1,
            else => {},
        },
        else => {},
    };
    try std.testing.expectEqual(result.analysis.components.len, registered_components);
}

test "compileProject loads sibling modules and prefixes their items" {
    const main_source =
        \\mod ui
        \\@resource
        \\Win <- struct
        \\    n: i32
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    commands.add_plugin(ui::Ui)
        \\    disown commands
        \\    0
    ;
    const ui_source =
        \\Ui <- plugin
        \\    init <- sys (commands: &mut Commands):
        \\        ret
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.e7", .data = main_source });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ui.e7", .data = ui_source });
    const root_path = try tmp.dir.realPathFileAlloc(std.testing.io, "main.e7", std.testing.allocator);
    defer std.testing.allocator.free(root_path);

    var result = compileProject(std.testing.allocator, root_path, .{}) catch |err| {
        std.debug.print("engine project compile error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer result.deinit();
    if (!result.analysis.ok()) {
        for (result.analysis.diagnostics) |d| std.debug.print("engine project diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
    }
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    // Two files, one external module with its items attached and prefixed.
    try std.testing.expectEqual(@as(usize, 2), result.owned_sources.len);
    try std.testing.expectEqual(@as(usize, 1), result.module_asts.len);
    const module = result.parsed.module.items[0].kind.mod;
    try std.testing.expect(module.items != null);
    try std.testing.expectEqual(@as(usize, 1), module.items.?.len);

    try std.testing.expect(result.functionNamed("main") != null);
    try std.testing.expect(result.functionNamed("ui::Ui::init") != null);
    try std.testing.expectEqual(@as(usize, 1), result.analysis.plugins.len);
    try std.testing.expectEqualStrings("ui::Ui", result.analysis.plugins[0].name);
    try std.testing.expectEqualStrings("ui::Ui::init", result.analysis.plugins[0].init.?);
}

test "compileProject loads nested module directories relative to their file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "nested");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.e7", .data =
        \\mod nested
        \\main <- () -> i32 = nested::child::value()
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/main.e7", .data =
        \\mod child
        \\pub root_value <- () -> i32 = 3
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nested/child.e7", .data =
        \\pub value <- () -> i32 = 7
    });
    const root_path = try tmp.dir.realPathFileAlloc(std.testing.io, "main.e7", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    var result = compileProject(std.testing.allocator, root_path, .{}) catch |err| {
        std.debug.print("engine project compile error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer result.deinit();
    if (!result.analysis.ok()) {
        for (result.analysis.diagnostics) |d| std.debug.print("engine project diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
    }
    try std.testing.expect(result.analysis.ok());
    try std.testing.expect(result.functionNamed("nested::child::value") != null);
    try bytecode.verify(std.testing.allocator, &result.bytecode);
}

test "lowers compiler-known engine intrinsics to runtime calls" {
    var result = try compile(
        std.testing.allocator,
        \\create <- () -> u64 = e7_engine_window_create("engine7", 960, 540)
        \\now <- () -> i64 = e7_engine_time_now_ms()
        \\pump <- (window: u64) -> i64 = e7_engine_window_pump(window)
        \\close <- () -> i64 = e7_engine_should_close()
        \\camera <- (scene: u64) -> i64 = e7_engine_scene_set_camera(scene, 0, 1500, 6000, 0, 0)
        \\angle <- (scene: u64) -> i64 = e7_engine_scene_set_cube_angle(scene, 1000)
        \\light <- (scene: u64) -> i64 = e7_engine_scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000)
        \\begin <- (scene: u64) -> i64 = e7_engine_scene_begin_frame(scene)
        \\mesh <- (scene: u64) -> i64 = e7_engine_scene_draw_mesh(scene)
        \\end_frame <- (scene: u64) -> i64 = e7_engine_scene_end_frame(scene)
        \\held <- (code: i64) -> i64 = e7_engine_key_down(code)
        \\mouse <- () -> i64 = e7_engine_mouse_dx()
        \\mouse_y <- () -> i64 = e7_engine_mouse_dy()
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    const expectations = [_]struct { function: []const u8, intrinsic: bytecode.RuntimeFunction }{
        .{ .function = "create", .intrinsic = .engine_window_create },
        .{ .function = "now", .intrinsic = .engine_time_now_ms },
        .{ .function = "pump", .intrinsic = .engine_window_pump },
        .{ .function = "close", .intrinsic = .engine_should_close },
        .{ .function = "camera", .intrinsic = .engine_scene_set_camera },
        .{ .function = "angle", .intrinsic = .engine_scene_set_cube_angle },
        .{ .function = "light", .intrinsic = .engine_scene_set_light },
        .{ .function = "begin", .intrinsic = .engine_scene_begin_frame },
        .{ .function = "mesh", .intrinsic = .engine_scene_draw_mesh },
        .{ .function = "end_frame", .intrinsic = .engine_scene_end_frame },
        .{ .function = "held", .intrinsic = .engine_key_down },
        .{ .function = "mouse", .intrinsic = .engine_mouse_dx },
        .{ .function = "mouse_y", .intrinsic = .engine_mouse_dy },
    };
    for (expectations) |expectation| {
        const function = result.functionNamed(expectation.function).?;
        var found = false;
        for (function.code) |op| switch (op) {
            .runtime_call => |call| {
                if (call.function == expectation.intrinsic) found = true;
            },
            else => {},
        };
        try std.testing.expect(found);
    }
}

test "lowers float arithmetic, comparisons, casts, and math intrinsics" {
    var result = try compile(
        std.testing.allocator,
        \\addf <- (a: f64, b: f64) -> f64 = a + b
        \\subf <- (a: f64, b: f64) -> f64 = a - b
        \\mulf <- (a: f64, b: f64) -> f64 = a * b
        \\divf <- (a: f64, b: f64) -> f64 = a / b
        \\negf <- (a: f64) -> f64 = -a
        \\ltf <- (a: f64, b: f64) -> bool = a < b
        \\lef <- (a: f64, b: f64) -> bool = a <= b
        \\gtf <- (a: f64, b: f64) -> bool = a > b
        \\gef <- (a: f64, b: f64) -> bool = a >= b
        \\eqf <- (a: f64, b: f64) -> bool = a == b
        \\nef <- (a: f64, b: f64) -> bool = a != b
        \\castin <- (a: i32) -> f64 = a as f64
        \\castout <- (x: f64) -> i64 = x as i64
        \\castcopy <- (x: f32) -> f64 = x as f64
        \\sinf <- (x: f64) -> f64 = e7_f32_sin(x)
        \\cosf <- (x: f64) -> f64 = e7_f32_cos(x)
        \\sqrtf <- (x: f64) -> f64 = e7_f32_sqrt(x)
        \\absf <- (x: f64) -> f64 = e7_f32_abs(x)
        \\clampf <- (x: f64, lo: f64, hi: f64) -> f64 = e7_f32_clamp(x, lo, hi)
        \\millif <- (x: f64) -> i64 = e7_f32_to_milli(x)
        \\frommilli <- (m: i64) -> f64 = e7_f32_from_milli(m)
        \\toint <- (x: f64) -> i64 = e7_f32_to_i64(x)
        \\fromint <- (i: i64) -> f64 = e7_f32_from_i64(i)
        \\f32add <- (a: f32, b: f32) -> f32 = a + b
        \\f32sin <- (x: f32) -> f32 = e7_f32_sin(x)
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    const expectations = [_]struct { function: []const u8, intrinsic: bytecode.RuntimeFunction }{
        .{ .function = "addf", .intrinsic = .float_add },
        .{ .function = "subf", .intrinsic = .float_sub },
        .{ .function = "mulf", .intrinsic = .float_mul },
        .{ .function = "divf", .intrinsic = .float_div },
        .{ .function = "negf", .intrinsic = .float_neg },
        .{ .function = "ltf", .intrinsic = .float_lt },
        .{ .function = "lef", .intrinsic = .float_le },
        .{ .function = "gtf", .intrinsic = .float_gt },
        .{ .function = "gef", .intrinsic = .float_ge },
        .{ .function = "eqf", .intrinsic = .float_eq },
        .{ .function = "nef", .intrinsic = .float_ne },
        .{ .function = "castin", .intrinsic = .float_from_i64 },
        .{ .function = "castout", .intrinsic = .float_to_i64 },
        .{ .function = "sinf", .intrinsic = .float_sin },
        .{ .function = "cosf", .intrinsic = .float_cos },
        .{ .function = "sqrtf", .intrinsic = .float_sqrt },
        .{ .function = "absf", .intrinsic = .float_abs },
        .{ .function = "clampf", .intrinsic = .float_clamp },
        .{ .function = "millif", .intrinsic = .float_to_milli },
        .{ .function = "frommilli", .intrinsic = .float_from_milli },
        .{ .function = "toint", .intrinsic = .float_to_i64 },
        .{ .function = "fromint", .intrinsic = .float_from_i64 },
        .{ .function = "f32add", .intrinsic = .float_add },
        .{ .function = "f32sin", .intrinsic = .float_sin },
    };
    for (expectations) |expectation| {
        const function = result.functionNamed(expectation.function).?;
        var found = false;
        for (function.code) |op| switch (op) {
            .runtime_call => |call| {
                if (call.function == expectation.intrinsic) found = true;
            },
            else => {},
        };
        try std.testing.expect(found);
    }

    // float -> float cast is a no-op (no runtime conversion calls).
    const copy = result.functionNamed("castcopy").?;
    for (copy.code) |op| switch (op) {
        .runtime_call => |call| switch (call.function) {
            .float_from_i64, .float_to_i64 => return error.TestUnexpectedResult,
            else => {},
        },
        else => {},
    };
}

test "lowers derived JSON encode/decode to schema-driven runtime calls" {
    var result = try compile(
        std.testing.allocator,
        \\@derive(Serialize, Deserialize)
        \\Point <- struct
        \\    x: f32
        \\    y: f32
        \\    name: str
        \\encode_point <- () -> str:
        \\    p := Point { x: 1.5, y: -2.0, name: "origin" }
        \\    json_encode(p)
        \\decode_point <- () -> Point:
        \\    json_decode::<Point>("{\"x\": 1.5, \"y\": -2.0, \"name\": \"origin\"}")
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    const point = result.analysis.derive("Point").?;
    try std.testing.expect(point.serialize and point.deserialize);
    try std.testing.expectEqualStrings("{x=f;y=f;name=s}", point.schema.?);

    const expectations = [_]struct { function: []const u8, intrinsic: bytecode.RuntimeFunction }{
        .{ .function = "encode_point", .intrinsic = .json_encode },
        .{ .function = "decode_point", .intrinsic = .json_decode },
    };
    for (expectations) |expectation| {
        const function = result.functionNamed(expectation.function).?;
        var found_call = false;
        var found_schema = false;
        for (function.code) |op| switch (op) {
            .runtime_call => |call| {
                if (call.function == expectation.intrinsic) found_call = true;
            },
            .string_lit => |literal| {
                if (std.mem.eql(u8, literal, "{x=f;y=f;name=s}")) found_schema = true;
            },
            else => {},
        };
        try std.testing.expect(found_call);
        try std.testing.expect(found_schema);
    }
}

fn readRepoText(comptime relative: []const u8) ?[]u8 {
    const candidates = [_][]const u8{
        relative,
        "../" ++ relative,
        "../../" ++ relative,
    };
    for (candidates) |candidate| {
        const data = std.Io.Dir.readFileAlloc(
            std.Io.Dir.cwd(),
            std.testing.io,
            candidate,
            std.testing.allocator,
            .limited(8 * 1024 * 1024),
        ) catch continue;
        return data;
    }
    return null;
}

test "lowers image and generic text intrinsics to runtime calls" {
    var result = try compile(
        std.testing.allocator,
        \\probe <- () -> i32:
        \\    lines := e7_str_lines("a\nb")
        \\    fields := e7_str_fields(" 1 2 ")
        \\    parts := e7_str_split("1/2/3", "/")
        \\    number := e7_parse_i64("-42")
        \\    value := e7_parse_f32("1.5")
        \\    values: [f32] := []
        \\    values = e7_vec_push(values, value)
        \\    image := e7_image_load("engine/assets/testdata/cube.png")
        \\    width := e7_image_width(image)
        \\    height := e7_image_height(image)
        \\    pixels := e7_image_pixels(image)
        \\    e7_image_free(image)
        \\    ret 0
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    const function = result.functionNamed("probe").?;
    var saw = [_]bool{false} ** 11;
    const wanted = [_]bytecode.RuntimeFunction{
        .image_load, .image_width, .image_height, .image_pixels, .image_free,
        .str_lines,  .str_fields,  .str_split,    .parse_i64,    .parse_f32,
        .vec_push,
    };
    for (function.code) |op| switch (op) {
        .runtime_call => |call| for (wanted, 0..) |function_kind, index| {
            if (call.function == function_kind) saw[index] = true;
        },
        else => {},
    };
    for (saw) |found| try std.testing.expect(found);
}

test "compiles the engine OBJ and asset libraries from sources" {
    const obj_source = readRepoText("engine/assets/obj.e7") orelse return error.SkipZigTest;
    defer std.testing.allocator.free(obj_source);
    const assets_source = readRepoText("engine/assets/main.e7") orelse return error.SkipZigTest;
    defer std.testing.allocator.free(assets_source);
    const ecs_source = readRepoText("engine/core/ecs.e7") orelse return error.SkipZigTest;
    defer std.testing.allocator.free(ecs_source);
    const gfx_source = readRepoText("engine/gfx/gpu.e7") orelse return error.SkipZigTest;
    defer std.testing.allocator.free(gfx_source);
    const window_source = readRepoText("engine/core/window.e7") orelse return error.SkipZigTest;
    defer std.testing.allocator.free(window_source);
    const events_source = readRepoText("engine/core/events.e7") orelse return error.SkipZigTest;
    const sdl_source = readRepoText("engine/platform/sdl.e7") orelse return error.SkipZigTest;
    const vulkan_source = readRepoText("engine/platform/vulkan.e7") orelse return error.SkipZigTest;
    const scene_source = readRepoText("engine/platform/scene.e7") orelse return error.SkipZigTest;
    const engine_window_source = readRepoText("engine/platform/engine_window.e7") orelse return error.SkipZigTest;
    const engine_scene_source = readRepoText("engine/platform/engine_scene.e7") orelse return error.SkipZigTest;
    defer std.testing.allocator.free(sdl_source);
    defer std.testing.allocator.free(vulkan_source);
    defer std.testing.allocator.free(scene_source);
    defer std.testing.allocator.free(engine_window_source);
    defer std.testing.allocator.free(engine_scene_source);
    defer std.testing.allocator.free(events_source);

    const root_source =
        \\mod platform
        \\mod core
        \\mod gfx
        \\mod assets
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    commands.add_plugin(assets::AssetsPlugin)
        \\    disown commands
        \\    0
    ;
    var result = compileProjectFromSources(
        std.testing.allocator,
        root_source,
        &.{
            .{ .name = "core", .source = "mod events\nmod window\nmod ecs\n" },
            .{ .name = "events", .source = events_source },
            .{ .name = "window", .source = window_source },
            .{ .name = "ecs", .source = ecs_source },
            .{ .name = "gfx", .source = "mod gpu\n" },
            .{ .name = "gpu", .source = gfx_source },
            .{ .name = "obj", .source = obj_source },
            .{ .name = "assets", .source = assets_source },
            .{ .name = "platform", .source = "mod sdl\nmod vulkan\nmod scene\nmod engine_window\nmod engine_scene\n" },
            .{ .name = "sdl", .source = sdl_source },
            .{ .name = "vulkan", .source = vulkan_source },
            .{ .name = "scene", .source = scene_source },
            .{ .name = "engine_window", .source = engine_window_source },
            .{ .name = "engine_scene", .source = engine_scene_source },
        },
        .{},
    ) catch |err| {
        std.debug.print("assets project compile error: {s}\n", .{@errorName(err)});
        return err;
    };
    defer result.deinit();
    if (!result.analysis.ok()) {
        for (result.analysis.diagnostics) |diagnostic| {
            std.debug.print("asset project semantic: {}:{} {s}\n", .{
                diagnostic.span.line,
                diagnostic.span.column,
                diagnostic.message,
            });
        }
    }
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);
    try std.testing.expect(result.functionNamed("main") != null);
    try std.testing.expect(result.functionNamed("assets::obj::parse_obj") != null);
    try std.testing.expect(result.functionNamed("assets::obj::load_obj") != null);
    try std.testing.expect(result.functionNamed("assets::load_image") != null);

    var found_assets_plugin = false;
    for (result.analysis.plugins) |plugin| {
        if (!std.mem.eql(u8, plugin.name, "assets::AssetsPlugin")) continue;
        found_assets_plugin = true;
        try std.testing.expectEqualStrings("assets::AssetsPlugin::assets_plugin_init", plugin.init.?);
    }
    try std.testing.expect(found_assets_plugin);
    try std.testing.expect(result.analysis.resource("assets::Assets") != null);
    try std.testing.expect(result.analysis.resource("assets::Image") != null);
}

test "compiles maps of vectors for spatial cells" {
    var result = try compile(
        std.testing.allocator,
        \\main <- () -> i32:
        \\    cells := map[i64, [i64]] {}
        \\    key := 7
        \\    list := cells[key]
        \\    list = e7_vec_push(list, 1)
        \\    list = e7_vec_push(list, 2)
        \\    cells[key] = list
        \\    got := cells[key]
        \\    ret got.len()
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try std.testing.expect(result.functionNamed("main") != null);
}

test "lowers ECS component removal, re-add, and despawn commands" {
    var result = try compile(
        std.testing.allocator,
        \\@Components
        \\Counter <- struct
        \\    b: i32
        \\@Components
        \\Held <- struct
        \\Components <- table
        \\    entity_id: usize,
        \\    ...
        \\Remove <- sys (commands: &mut Commands, pairs: select &mut Held, &mut Counter from Components):
        \\    for (held, counter) in pairs:
        \\        counter.b = counter.b + 1
        \\        commands.remove_component::<Held>(pairs.entity())
        \\Attach <- sys (commands: &mut Commands, counters: select &mut Counter from Components):
        \\    for counter in counters:
        \\        commands.add_component::<Held>(counters.entity(), Held {})
        \\Despawn <- sys (commands: &mut Commands, counters: select &mut Counter from Components):
        \\    for counter in counters:
        \\        commands.despawn(counters.entity())
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    counter := Counter { b: 0 }
        \\    held := Held
        \\    commands.add_row(Components, { counter, held })
        \\    disown commands
        \\    await Remove()
        \\    await Attach()
        \\    await Despawn()
        \\    ret 0
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    const expectations = [_]struct {
        function: []const u8,
        intrinsic: bytecode.RuntimeFunction,
    }{
        .{ .function = "Remove__body", .intrinsic = .ecs_query_entity },
        .{ .function = "Remove__body", .intrinsic = .ecs_commands_remove_component },
        .{ .function = "Attach__body", .intrinsic = .ecs_commands_add_component },
        .{ .function = "Despawn__body", .intrinsic = .ecs_commands_despawn },
    };
    for (expectations) |expectation| {
        const function = result.functionNamed(expectation.function).?;
        var found = false;
        for (function.code) |op| switch (op) {
            .runtime_call => |call| {
                if (call.function == expectation.intrinsic) found = true;
            },
            else => {},
        };
        try std.testing.expect(found);
    }
}

test "lowers inherent method calls with the receiver as the first argument" {
    var result = try compile(
        std.testing.allocator,
        \\R <- struct
        \\    n: i32
        \\impl R:
        \\    bump <- (r: &mut R) -> nil:
        \\        r.n = r.n + 1
        \\        ret
        \\    bump_by <- (r: &mut R, by: i32) -> i32:
        \\        r.n = r.n + by
        \\        ret r.n
        \\run <- () -> i32:
        \\    r := R { n: 1 }
        \\    r.bump()
        \\    r.bump_by(4)
    ,
        .{},
    );
    defer result.deinit();
    try std.testing.expect(result.analysis.ok());
    try bytecode.verify(std.testing.allocator, &result.bytecode);

    const bump = result.functionNamed("impl.R.bump").?;
    try std.testing.expectEqual(@as(u16, 1), bump.params); // receiver only
    const bump_by = result.functionNamed("impl.R.bump_by").?;
    try std.testing.expectEqual(@as(u16, 2), bump_by.params);
    const run = result.functionNamed("run").?;
    var bump_index: u16 = 0;
    var bump_by_index: u16 = 0;
    for (result.bytecode.functions, 0..) |function, index| {
        if (std.mem.eql(u8, function.name, "impl.R.bump")) bump_index = @intCast(index);
        if (std.mem.eql(u8, function.name, "impl.R.bump_by")) bump_by_index = @intCast(index);
    }
    var saw_bump = false;
    var saw_bump_by = false;
    for (run.code) |op| switch (op) {
        .call => |call| {
            if (call.function == bump_index) {
                saw_bump = true;
                try std.testing.expectEqual(@as(u16, 1), call.argc);
            }
            if (call.function == bump_by_index) {
                saw_bump_by = true;
                try std.testing.expectEqual(@as(u16, 2), call.argc);
            }
        },
        else => {},
    };
    try std.testing.expect(saw_bump and saw_bump_by);
}
