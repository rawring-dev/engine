//! Workspace/project layer for the e7 language server.
//!
//! The language server analyzes one open buffer at a time.  Real e7 projects
//! are multi-file trees (`mod platform` pulls in `platform.e7` or
//! `platform/main.e7`, which may pull in more), so analyzing a single buffer
//! in isolation reports hundreds of false "unknown type/name/plugin"
//! diagnostics.  This module supplies the missing context:
//!
//!   * `Index` — a recursively scanned, in-memory index of every `*.e7` file
//!     in the workspace, with the external `mod` dependencies of each file and
//!     the resolved project root for any indexed file.
//!   * `Loaded` — one project loaded from a root file: the root AST with every
//!     external `mod` replaced by the child module's items, the exact source
//!     buffers the ASTs point into, and the module path of every file
//!     (`""` for the root, `core::window` for a nested external module).
//!   * Module-path attribution helpers — the compiler's semantic diagnostics
//!     carry a `module_path`; `ownsModulePath` / `fileForModulePath` map them
//!     back to the file that should show the squiggle.
//!
//! Nothing here runs the semantic analyzer or codegen: only the parser is
//! used, to discover `mod` declarations and to build the attachable ASTs.
//!
//! ## Integration contract (`analysis.zig` / `server.zig`)
//!
//! `Loaded` keeps three parallel, owned arrays:
//!
//!   * `files[0]` is the root file and `files[0].module_path` is `""`.
//!   * `sources[i]` is exactly the buffer that `files[i]`'s AST points into.
//!   * `module_asts[i]` is the attached AST for `files[i + 1]` (root AST lives
//!     in `root_ast`).
//!
//! So a diagnostic whose `module_path` is attributed to `files[i]` has byte
//! spans that index into `sources[i]`; `sourceForModulePath`/`sourceForFile`
//! return those buffers directly.
//!
//! ## Filesystem convention
//!
//! Mirrors `compiler/src/pipeline.zig`: inside a file declaring `mod name`,
//! the child lives at `<dir>/<name>.e7` first, then `<dir>/<name>/main.e7`.
//! All paths exposed by this module are absolute and normalized
//! (`std.fs.path.resolve`).
//!
//! Everything is best-effort and bounded: the scanner skips unreadable and
//! oversized files instead of failing, and the loader reports budget/cycle
//! problems through a typed error set rather than panicking.

const std = @import("std");
const compiler = @import("compiler");

const parser = compiler.parser;
const ast = compiler.ast;

const Allocator = std.mem.Allocator;

/// Maximum number of files indexed in one workspace / loaded in one project.
pub const max_files: usize = 4096;
/// Maximum size of a single e7 source file.
pub const max_source_bytes: usize = 4 * 1024 * 1024;
/// Maximum total source bytes indexed in a workspace / loaded in a project.
pub const max_total_bytes: usize = 64 * 1024 * 1024;
/// Maximum external `mod` nesting accepted by `Index.load`.
pub const max_depth: usize = 16;

/// Directory recursion bound for `Index.init` (deeply nested trees are
/// truncated instead of spending unbounded time scanning).
const max_scan_depth: usize = 64;

/// Directory names never scanned for e7 sources.
const pruned_directories = [_][]const u8{
    ".git",
    ".zig-cache",
    "zig-out",
    "zig-pkg",
    "node_modules",
    ".team",
    ".tooling",
    ".local-vulkan",
    "target",
};

/// A source buffer that overrides the on-disk contents of one file.  Used for
/// the buffer the editor has open: it may be newer than the file on disk.
pub const Override = struct {
    /// Absolute or workspace-relative path of the overridden file.
    path: []const u8,
    source: []const u8,
};

/// One file participating in a loaded project.
pub const File = struct {
    /// Absolute normalized path.
    path: []const u8,
    /// `::`-qualified module path: `""` for the project root, `core`,
    /// `core::window`, ... for loaded external modules.
    module_path: []const u8,
};

pub const LoadError = error{
    OutOfMemory,
    WorkspaceUnreadable,
    /// A `mod name` reference could not be resolved to an existing file.
    ModuleNotFound,
    /// The root or one of the modules failed to parse.
    ParseFailed,
    /// An external module (transitively) imports one of its ancestors.
    CycleDetected,
    /// External modules nest deeper than `max_depth`.
    DepthExceeded,
    /// More than `max_files` files would participate in the project.
    FileLimitExceeded,
    /// More than `max_total_bytes` source bytes would participate.
    ByteLimitExceeded,
};

pub const IndexError = error{
    OutOfMemory,
    /// `workspace_root` does not exist or is not a directory.
    WorkspaceUnreadable,
};

/// A project loaded from one root file.
pub const Loaded = struct {
    allocator: Allocator,
    /// Absolute normalized path of the root file (owned).
    root_path: []const u8,
    /// Source buffers the ASTs point into (owned); `sources[i]` belongs to
    /// `files[i]`.
    sources: [][]u8,
    /// Root file first, then every loaded module in load order (owned).
    files: []File,
    root_ast: parser.Ast,
    /// Attached ASTs for `files[1..]`, same order (owned).
    module_asts: []parser.Ast,

    pub fn deinit(self: *Loaded) void {
        self.root_ast.deinit();
        for (self.module_asts) |*tree| tree.deinit();
        self.allocator.free(self.module_asts);
        for (self.files) |file| {
            self.allocator.free(file.path);
            self.allocator.free(file.module_path);
        }
        self.allocator.free(self.files);
        for (self.sources) |source| self.allocator.free(source);
        self.allocator.free(self.sources);
        self.allocator.free(self.root_path);
        self.* = undefined;
    }

    /// Module path recorded for `path`, or null when the file is not part of
    /// this project.  `path` may be absolute or workspace-relative.
    pub fn modulePathForFile(self: *const Loaded, path: []const u8) ?[]const u8 {
        for (self.files) |file| {
            if (pathMatches(self.allocator, file.path, path)) return file.module_path;
        }
        return null;
    }

    /// True when a diagnostic reported in `module_path` belongs to
    /// `file_path`.
    ///
    /// Rule: the longest `::`-prefix of `module_path` that names a loaded
    /// external module decides.  Paths with no such prefix are inline modules
    /// of the root file, so only the root owns them.
    pub fn ownsModulePath(self: *const Loaded, file_path: []const u8, module_path: []const u8) bool {
        const owner = moduleOwnerIndex(self.files, module_path);
        return pathMatches(self.allocator, self.files[owner].path, file_path);
    }

    /// File that owns `module_path` under the attribution rule.
    pub fn fileForModulePath(self: *const Loaded, module_path: []const u8) File {
        if (self.files.len == 0) {
            return .{ .path = self.root_path, .module_path = "" };
        }
        return self.files[moduleOwnerIndex(self.files, module_path)];
    }

    /// Source buffer for `path` (absolute or workspace-relative), or null.
    pub fn sourceForFile(self: *const Loaded, path: []const u8) ?[]const u8 {
        for (self.files, 0..) |file, index| {
            if (pathMatches(self.allocator, file.path, path)) return self.sources[index];
        }
        return null;
    }

    /// Source buffer for the file that owns `module_path`, or null.
    pub fn sourceForModulePath(self: *const Loaded, module_path: []const u8) ?[]const u8 {
        if (self.files.len == 0) return null;
        return self.sources[moduleOwnerIndex(self.files, module_path)];
    }
};

/// One resolved external `mod` reference of an indexed file.
const Dependency = struct {
    /// Name as written in `mod <name>` (owned).
    name: []u8,
    /// Resolved absolute path, or null when no file exists (owned).
    path: ?[]u8,
};

const IndexedFile = struct {
    /// Owned copy of the file contents.
    source: []u8,
    /// External `mod` references (owned slice; `name`/`path` owned).
    deps: []Dependency,
};

/// Recursively scanned workspace index.
pub const Index = struct {
    allocator: Allocator,
    /// Absolute, symlink-resolved workspace root (owned sentinel slice).
    workspace_root: [:0]u8,
    /// Absolute path -> source + external dependencies (keys owned).
    files: std.StringHashMapUnmanaged(IndexedFile),
    total_bytes: usize,
    /// Memoized `projectRoot` results.  Keys are owned absolute paths; values
    /// borrow a key slice from `files` (or null for standalone documents).
    root_cache: std.StringHashMapUnmanaged(?[]const u8),

    pub fn init(allocator: Allocator, workspace_root: []const u8) IndexError!Index {
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const root = std.Io.Dir.cwd().realPathFileAlloc(io, workspace_root, allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.WorkspaceUnreadable,
        };

        var index = Index{
            .allocator = allocator,
            .workspace_root = root,
            .files = .empty,
            .total_bytes = 0,
            .root_cache = .empty,
        };
        index.scanDirectory(io, index.workspace_root, 0);
        return index;
    }

    pub fn deinit(self: *Index) void {
        var iterator = self.files.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.source);
            freeDependencies(self.allocator, entry.value_ptr.deps);
            self.allocator.free(entry.value_ptr.deps);
        }
        self.files.deinit(self.allocator);
        self.invalidateRootCache();
        self.root_cache.deinit(self.allocator);
        self.allocator.free(self.workspace_root);
        self.* = undefined;
    }

    /// Root project file for `target`, or null when it is a standalone
    /// document (no external deps and nothing imports it).
    ///
    /// Candidate roots are the indexed files whose transitive dependency
    /// closure contains `target`; candidates imported by another candidate are
    /// discarded, and ties are broken lexicographically.  Results are cached
    /// until the next `refresh`/on-demand index update.
    pub fn projectRoot(self: *Index, target: []const u8) ?[]const u8 {
        const normalized = self.normalizeTarget(target) orelse return null;
        defer self.allocator.free(normalized);

        if (self.root_cache.get(normalized)) |cached| return cached;

        // Resolve to the index's own key slice: `computeProjectRoot` may return
        // the target itself, and `normalized` is freed when this function
        // returns.
        const target_key = self.findIndexedKey(normalized) orelse {
            self.cacheProjectRoot(normalized, null);
            return null;
        };
        const root = self.computeProjectRoot(target_key);
        self.cacheProjectRoot(normalized, root);
        return root;
    }

    /// Indexed source text for `path`, or null when the file is not indexed.
    pub fn sourceFor(self: *const Index, path: []const u8) ?[]const u8 {
        const normalized = self.normalizeTarget(path) orelse return null;
        defer self.allocator.free(normalized);
        const key = self.findIndexedKey(normalized) orelse return null;
        const entry = self.files.get(key) orelse return null;
        return entry.source;
    }

    /// Re-read `path` after a save; adds it to the index when new.  Best
    /// effort: unreadable files keep their previously indexed contents.
    pub fn refresh(self: *Index, path: []const u8) void {
        const normalized = self.normalizeTarget(path) orelse return;
        defer self.allocator.free(normalized);

        var threaded = std.Io.Threaded.init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        self.refreshFile(io, normalized) catch {};
        self.invalidateRootCache();
    }

    /// Load, parse, and attach the project rooted at `root_path`.
    ///
    /// `override` replaces the on-disk source of one file (the editor buffer);
    /// it is matched on the normalized path.  The returned `Loaded` owns all
    /// its memory and must be deinitialized by the caller.
    pub fn load(
        self: *Index,
        allocator: Allocator,
        root_path: []const u8,
        override: ?Override,
    ) LoadError!Loaded {
        const normalized_root = std.fs.path.resolve(allocator, &.{ self.workspace_root, root_path }) catch
            return error.OutOfMemory;
        errdefer allocator.free(normalized_root);

        var normalized_override: ?[]u8 = null;
        if (override) |over| {
            normalized_override = std.fs.path.resolve(allocator, &.{ self.workspace_root, over.path }) catch
                return error.OutOfMemory;
        }
        defer if (normalized_override) |path| allocator.free(path);

        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        var loader = Loader{
            .index = self,
            .allocator = allocator,
            .io = io,
            .override_path = normalized_override,
            .override_source = if (override) |over| over.source else "",
        };
        defer loader.deinit();

        try loader.loadRoot(normalized_root);

        const sources = try loader.sources.toOwnedSlice(allocator);
        errdefer freeSources(allocator, sources);
        const files = try loader.files.toOwnedSlice(allocator);
        errdefer freeFiles(allocator, files);
        const module_asts = try loader.module_asts.toOwnedSlice(allocator);
        errdefer freeAsts(allocator, module_asts);
        var root_ast = loader.root_ast orelse return error.ParseFailed;
        loader.root_ast = null;
        errdefer root_ast.deinit();

        return .{
            .allocator = allocator,
            .root_path = normalized_root,
            .sources = sources,
            .files = files,
            .root_ast = root_ast,
            .module_asts = module_asts,
        };
    }

    // -----------------------------------------------------------------------
    // Scanning and indexing
    // -----------------------------------------------------------------------

    fn scanDirectory(self: *Index, io: std.Io, absolute_dir: []const u8, depth: usize) void {
        if (depth > max_scan_depth) return;
        if (self.files.count() >= max_files) return;

        var dir = std.Io.Dir.cwd().openDir(io, absolute_dir, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var iterator = dir.iterate();
        while (true) {
            const maybe_entry = iterator.next(io) catch return;
            const entry = maybe_entry orelse break;
            if (self.files.count() >= max_files) return;

            switch (entry.kind) {
                .directory => {
                    if (isPrunedDirectory(entry.name)) continue;
                    const child = std.fs.path.join(self.allocator, &.{ absolute_dir, entry.name }) catch return;
                    defer self.allocator.free(child);
                    self.scanDirectory(io, child, depth + 1);
                },
                .file => {
                    if (!std.mem.endsWith(u8, entry.name, ".e7")) continue;
                    const path = std.fs.path.join(self.allocator, &.{ absolute_dir, entry.name }) catch return;
                    defer self.allocator.free(path);
                    self.indexFile(io, path);
                },
                else => {},
            }
        }
    }

    fn indexFile(self: *Index, io: std.Io, path: []const u8) void {
        if (self.files.contains(path)) return;
        if (self.files.count() >= max_files) return;
        if (self.total_bytes >= max_total_bytes) return;

        const source = readSourceFile(self.allocator, io, path, max_source_bytes) catch return;
        if (self.total_bytes + source.len > max_total_bytes) {
            self.allocator.free(source);
            return;
        }
        self.addFile(io, path, source) catch {
            self.allocator.free(source);
            return;
        };
    }

    /// Adds a file to the index; takes ownership of `source` on success.
    fn addFile(self: *Index, io: std.Io, path: []const u8, source: []u8) !void {
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);

        const deps = try self.collectDeps(io, path, source);
        errdefer {
            freeDependencies(self.allocator, deps);
            self.allocator.free(deps);
        }

        try self.files.put(self.allocator, key, .{ .source = source, .deps = deps });
        self.total_bytes += source.len;
        self.invalidateRootCache();
    }

    fn refreshFile(self: *Index, io: std.Io, path: []const u8) !void {
        const source = readSourceFile(self.allocator, io, path, max_source_bytes) catch return;
        errdefer self.allocator.free(source);

        if (self.files.getPtr(path)) |entry| {
            const deps = try self.collectDeps(io, path, source);
            self.total_bytes -= entry.source.len;
            self.allocator.free(entry.source);
            freeDependencies(self.allocator, entry.deps);
            self.allocator.free(entry.deps);
            entry.source = source;
            entry.deps = deps;
            self.total_bytes += source.len;
            self.invalidateRootCache();
            return;
        }

        self.indexFile(io, path); // reads the file again; new files are rare
        self.allocator.free(source);
    }

    /// Reads `path` only when the file is not indexed yet (dependency that
    /// appeared after the initial scan).  Best effort; failures just mean the
    /// file stays unindexed.
    fn ensureIndexed(self: *Index, io: std.Io, path: []const u8) void {
        if (self.files.contains(path)) return;
        self.indexFile(io, path);
    }

    fn collectDeps(self: *Index, io: std.Io, path: []const u8, source: []const u8) ![]Dependency {
        var deps: std.ArrayListUnmanaged(Dependency) = .empty;
        errdefer {
            freeDependencies(self.allocator, deps.items);
            deps.deinit(self.allocator);
        }

        // Cheap rejection: without a `mod` token there is nothing to parse for.
        if (!mayContainModuleDecl(source)) return deps.toOwnedSlice(self.allocator);

        const directory = std.fs.path.dirname(path) orelse "";

        const parsed = parser.parse(self.allocator, source) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return deps.toOwnedSlice(self.allocator),
        };
        switch (parsed) {
            .ast => |tree_value| {
                var tree = tree_value;
                defer tree.deinit();
                for (tree.module.items) |item| {
                    switch (item.kind) {
                        .mod => {},
                        else => continue,
                    }
                    const module_decl: *ast.ModDecl = &item.kind.mod;
                    if (module_decl.items != null) continue; // inline module

                    var duplicate = false;
                    for (deps.items) |existing| {
                        if (std.mem.eql(u8, existing.name, module_decl.name)) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (duplicate) continue;

                    const name_copy = try self.allocator.dupe(u8, module_decl.name);
                    const resolved = resolveModulePath(self.allocator, io, directory, module_decl.name) catch |err| {
                        self.allocator.free(name_copy);
                        return err;
                    };
                    deps.append(self.allocator, .{ .name = name_copy, .path = resolved }) catch |err| {
                        self.allocator.free(name_copy);
                        if (resolved) |dep_path| self.allocator.free(dep_path);
                        return err;
                    };
                }
            },
            .diagnostic => {},
        }
        return deps.toOwnedSlice(self.allocator);
    }

    // -----------------------------------------------------------------------
    // Project root selection
    // -----------------------------------------------------------------------

    fn computeProjectRoot(self: *Index, target_key: []const u8) ?[]const u8 {
        const target_file = self.files.getPtr(target_key) orelse return null;

        // Reverse adjacency: child path -> files that `mod` it.
        var reverse: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
        defer {
            var iterator = reverse.iterator();
            while (iterator.next()) |entry| entry.value_ptr.deinit(self.allocator);
            reverse.deinit(self.allocator);
        }
        {
            var iterator = self.files.iterator();
            while (iterator.next()) |entry| {
                for (entry.value_ptr.deps) |dep| {
                    const dep_path = dep.path orelse continue;
                    if (!self.files.contains(dep_path)) continue;
                    const gop = reverse.getOrPut(self.allocator, dep_path) catch return null;
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    gop.value_ptr.append(self.allocator, entry.key_ptr.*) catch return null;
                }
            }
        }

        // Ancestors of the target (reverse BFS), including the target itself.
        var ancestors: std.StringHashMapUnmanaged(void) = .empty;
        defer ancestors.deinit(self.allocator);
        var queue: std.ArrayListUnmanaged([]const u8) = .empty;
        defer queue.deinit(self.allocator);
        ancestors.put(self.allocator, target_key, {}) catch return null;
        queue.append(self.allocator, target_key) catch return null;
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const parents = reverse.get(queue.items[head]) orelse continue;
            for (parents.items) |parent| {
                const gop = ancestors.getOrPut(self.allocator, parent) catch return null;
                if (gop.found_existing) continue;
                queue.append(self.allocator, parent) catch return null;
            }
        }

        // Candidates imported by another candidate are not project roots; only
        // ancestors with no parent at all survive.
        var candidates: std.ArrayListUnmanaged([]const u8) = .empty;
        defer candidates.deinit(self.allocator);
        {
            var iterator = ancestors.iterator();
            while (iterator.next()) |entry| {
                const path = entry.key_ptr.*;
                if (reverse.get(path)) |parents| {
                    if (parents.items.len > 0) continue;
                }
                candidates.append(self.allocator, path) catch return null;
            }
        }
        if (candidates.items.len == 0) return null;
        std.mem.sort([]const u8, candidates.items, {}, lessThanString);

        const root = candidates.items[0];
        // A file with nothing importing it and no external deps is a
        // standalone document, not a project.
        if (candidates.items.len == 1 and std.mem.eql(u8, root, target_key) and
            target_file.deps.len == 0)
        {
            return null;
        }
        return root;
    }

    fn cacheProjectRoot(self: *Index, normalized_target: []const u8, root: ?[]const u8) void {
        const key = self.allocator.dupe(u8, normalized_target) catch return;
        self.root_cache.put(self.allocator, key, root) catch self.allocator.free(key);
    }

    fn invalidateRootCache(self: *Index) void {
        var iterator = self.root_cache.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        self.root_cache.clearRetainingCapacity();
    }

    // -----------------------------------------------------------------------
    // Path helpers
    // -----------------------------------------------------------------------

    fn normalizeTarget(self: *const Index, path: []const u8) ?[]u8 {
        return std.fs.path.resolve(self.allocator, &.{ self.workspace_root, path }) catch null;
    }

    fn findIndexedKey(self: *const Index, query: []const u8) ?[]const u8 {
        if (self.files.getKey(query)) |key| return key;

        // The scanner's root is symlink-resolved, so a path derived from a
        // symlinked spelling may differ in its prefix.  Match on the longest
        // common component suffix (at least one directory + the file name).
        var best: ?[]const u8 = null;
        var best_match: usize = 0;
        var iterator = self.files.keyIterator();
        while (iterator.next()) |key| {
            const common = commonSuffixComponents(key.*, query);
            if (common < 2 or common <= best_match) continue;
            best_match = common;
            best = key.*;
        }
        return best;
    }
};

// ===========================================================================
// Loader
// ===========================================================================

/// Loads one project and owns everything it produces until it is transferred
/// into the returned `Loaded`.
const Loader = struct {
    index: *Index,
    allocator: Allocator,
    io: std.Io,
    override_path: ?[]const u8,
    override_source: []const u8,
    sources: std.ArrayListUnmanaged([]u8) = .empty,
    files: std.ArrayListUnmanaged(File) = .empty,
    module_asts: std.ArrayListUnmanaged(parser.Ast) = .empty,
    root_ast: ?parser.Ast = null,
    /// Paths of the modules currently being loaded (cycle detection).
    in_progress: std.StringHashMapUnmanaged(void) = .empty,
    total_bytes: usize = 0,

    fn deinit(self: *Loader) void {
        if (self.root_ast) |*tree| tree.deinit();
        for (self.module_asts.items) |*tree| tree.deinit();
        self.module_asts.deinit(self.allocator);
        for (self.files.items) |file| {
            self.allocator.free(file.path);
            self.allocator.free(file.module_path);
        }
        self.files.deinit(self.allocator);
        for (self.sources.items) |source| self.allocator.free(source);
        self.sources.deinit(self.allocator);
        self.in_progress.deinit(self.allocator);
    }

    /// Reads one project file: the override buffer, the index copy, or (for a
    /// dependency that appeared after the initial scan) the file on disk.
    fn readFile(self: *Loader, path: []const u8) LoadError![]u8 {
        if (self.override_path) |override_path| {
            if (std.mem.eql(u8, override_path, path)) {
                return self.allocator.dupe(u8, self.override_source) catch return error.OutOfMemory;
            }
        }
        if (self.index.files.get(path)) |indexed| {
            return self.allocator.dupe(u8, indexed.source) catch return error.OutOfMemory;
        }
        self.index.ensureIndexed(self.io, path);
        if (self.index.files.get(path)) |indexed| {
            return self.allocator.dupe(u8, indexed.source) catch return error.OutOfMemory;
        }
        return error.ModuleNotFound;
    }

    fn loadRoot(self: *Loader, path: []const u8) LoadError!void {
        const source = try self.readFile(path);
        var source_owned = true;
        errdefer if (source_owned) self.allocator.free(source);
        if (self.total_bytes + source.len > max_total_bytes) return error.ByteLimitExceeded;

        var tree = try parseSource(self.allocator, source);
        var tree_owned = true;
        errdefer if (tree_owned) tree.deinit();

        const path_copy = try self.allocator.dupe(u8, path);
        var path_owned = true;
        errdefer if (path_owned) self.allocator.free(path_copy);
        const module_path_copy = try self.allocator.dupe(u8, "");
        var module_path_owned = true;
        errdefer if (module_path_owned) self.allocator.free(module_path_copy);

        const items = tree.module.items;
        self.total_bytes += source.len;
        try self.sources.append(self.allocator, source);
        source_owned = false;
        try self.files.append(self.allocator, .{ .path = path_copy, .module_path = module_path_copy });
        path_owned = false;
        module_path_owned = false;
        self.root_ast = tree;
        tree_owned = false;

        try self.in_progress.put(self.allocator, path_copy, {});
        defer _ = self.in_progress.remove(path_copy);

        try self.attachItems(items, path, "", 0);
    }

    fn loadModule(
        self: *Loader,
        path: []const u8,
        module_path: []const u8,
        depth: usize,
    ) LoadError!usize {
        if (depth > max_depth) return error.DepthExceeded;
        if (self.files.items.len >= max_files) return error.FileLimitExceeded;
        if (self.in_progress.contains(path)) return error.CycleDetected;

        const source = try self.readFile(path);
        var source_owned = true;
        errdefer if (source_owned) self.allocator.free(source);
        if (self.total_bytes + source.len > max_total_bytes) return error.ByteLimitExceeded;

        var tree = try parseSource(self.allocator, source);
        var tree_owned = true;
        errdefer if (tree_owned) tree.deinit();

        const path_copy = try self.allocator.dupe(u8, path);
        var path_owned = true;
        errdefer if (path_owned) self.allocator.free(path_copy);
        const module_path_copy = try self.allocator.dupe(u8, module_path);
        var module_path_owned = true;
        errdefer if (module_path_owned) self.allocator.free(module_path_copy);

        self.total_bytes += source.len;
        try self.sources.append(self.allocator, source);
        source_owned = false;
        try self.files.append(self.allocator, .{ .path = path_copy, .module_path = module_path_copy });
        path_owned = false;
        module_path_owned = false;
        try self.module_asts.append(self.allocator, tree);
        tree_owned = false;

        try self.in_progress.put(self.allocator, path_copy, {});
        defer _ = self.in_progress.remove(path_copy);

        const ast_index = self.module_asts.items.len - 1;
        const items = self.module_asts.items[ast_index].module.items;
        try self.attachItems(items, path, module_path, depth);
        return ast_index;
    }

    /// Replaces every external `mod name` in `items` with the child module's
    /// items, recursively.  Declarations are patched in place, exactly like
    /// `compiler/src/pipeline.zig` does, so the semantic analyzer sees a single
    /// merged module tree with `::`-qualified module paths.
    fn attachItems(
        self: *Loader,
        items: []*ast.Item,
        file_path: []const u8,
        module_path: []const u8,
        depth: usize,
    ) LoadError!void {
        const directory = std.fs.path.dirname(file_path) orelse "";

        for (items) |item| {
            switch (item.kind) {
                .mod => {},
                else => continue,
            }
            const module_decl: *ast.ModDecl = &item.kind.mod;
            if (module_decl.items != null) continue; // inline module: nothing to load

            const child_path = try self.resolveModule(directory, module_decl.name) orelse
                return error.ModuleNotFound;
            defer self.allocator.free(child_path);

            const child_module_path = try joinModulePath(self.allocator, module_path, module_decl.name);
            defer self.allocator.free(child_module_path);

            const child_index = try self.loadModule(child_path, child_module_path, depth + 1);
            module_decl.items = self.module_asts.items[child_index].module.items;
        }
    }

    fn resolveModule(self: *Loader, directory: []const u8, name: []const u8) LoadError!?[]u8 {
        return resolveModulePath(self.allocator, self.io, directory, name);
    }
};

// ===========================================================================
// Filesystem helpers
// ===========================================================================

fn readSourceFile(allocator: Allocator, io: std.Io, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(limit));
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Resolves `mod <name>` relative to `directory`: `<dir>/<name>.e7` first,
/// then `<dir>/<name>/main.e7`.  Returns null when neither exists.
fn resolveModulePath(
    allocator: Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
) LoadError!?[]u8 {
    const flat_name = std.fmt.allocPrint(allocator, "{s}.e7", .{name}) catch return error.OutOfMemory;
    defer allocator.free(flat_name);

    const flat_path = std.fs.path.join(allocator, &.{ directory, flat_name }) catch return error.OutOfMemory;
    if (fileExists(io, flat_path)) return flat_path;
    allocator.free(flat_path);

    const nested_path = std.fs.path.join(allocator, &.{ directory, name, "main.e7" }) catch
        return error.OutOfMemory;
    if (fileExists(io, nested_path)) return nested_path;
    allocator.free(nested_path);
    return null;
}

fn parseSource(allocator: Allocator, source: []const u8) LoadError!parser.Ast {
    const result = parser.parse(allocator, source) catch return error.OutOfMemory;
    return switch (result) {
        .ast => |tree| tree,
        .diagnostic => error.ParseFailed,
    };
}

/// Appends `name` to a `::`-qualified module path (`""` means root).
fn joinModulePath(allocator: Allocator, parent: []const u8, name: []const u8) LoadError![]u8 {
    if (parent.len == 0) return allocator.dupe(u8, name) catch return error.OutOfMemory;
    return std.fmt.allocPrint(allocator, "{s}::{s}", .{ parent, name }) catch return error.OutOfMemory;
}

// ===========================================================================
// Pure helpers
// ===========================================================================

fn freeDependencies(allocator: Allocator, deps: []Dependency) void {
    for (deps) |dep| {
        allocator.free(dep.name);
        if (dep.path) |path| allocator.free(path);
    }
}

fn freeSources(allocator: Allocator, sources: [][]u8) void {
    for (sources) |source| allocator.free(source);
    allocator.free(sources);
}

fn freeFiles(allocator: Allocator, files: []File) void {
    for (files) |file| {
        allocator.free(file.path);
        allocator.free(file.module_path);
    }
    allocator.free(files);
}

fn freeAsts(allocator: Allocator, trees: []parser.Ast) void {
    for (trees) |*tree| tree.deinit();
    allocator.free(trees);
}

fn isPrunedDirectory(name: []const u8) bool {
    for (pruned_directories) |pruned| {
        if (std.mem.eql(u8, name, pruned)) return true;
    }
    return false;
}

fn isIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// Cheap pre-filter: true when the buffer contains a `mod` token (a `mod`
/// whose next byte is a space or tab and which is not part of a longer
/// identifier).  Used to skip parsing files that cannot declare modules.
fn mayContainModuleDecl(source: []const u8) bool {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, source, search_from, "mod")) |at| {
        const after = at + 3;
        if (after < source.len) {
            const next = source[after];
            if (next == ' ' or next == '\t') {
                if (at == 0 or !isIdentifierByte(source[at - 1])) return true;
            }
        }
        search_from = after;
    }
    return false;
}

/// Index into `files` of the file that owns `module_path`: the longest loaded
/// external module path that is a segment-prefix of `module_path`, or 0 (the
/// root file) when there is none.
fn moduleOwnerIndex(files: []const File, module_path: []const u8) usize {
    var owner: usize = 0;
    var owner_len: usize = 0;
    for (files, 0..) |file, index| {
        if (file.module_path.len == 0) continue;
        if (!modulePathHasPrefix(module_path, file.module_path)) continue;
        if (file.module_path.len <= owner_len) continue;
        owner_len = file.module_path.len;
        owner = index;
    }
    return owner;
}

/// True when `prefix` is a `::`-segment prefix of `full` (`core` is a prefix
/// of `core` and `core::window`, but not of `corex`).
fn modulePathHasPrefix(full: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    if (!std.mem.startsWith(u8, full, prefix)) return false;
    if (full.len == prefix.len) return true;
    return full.len > prefix.len + 1 and full[prefix.len] == ':' and full[prefix.len + 1] == ':';
}

/// Compares a stored absolute path with a query that may be absolute,
/// workspace-relative, or stale (`./engine/../engine/x.e7`).
fn pathMatches(allocator: Allocator, stored: []const u8, query: []const u8) bool {
    if (std.mem.eql(u8, stored, query)) return true;

    if (std.fs.path.isAbsolute(query)) {
        const normalized = std.fs.path.resolve(allocator, &.{query}) catch return false;
        defer allocator.free(normalized);
        return std.mem.eql(u8, stored, normalized);
    }

    // Relative: normalize then compare on a path-component boundary so
    // "engine/window.e7" matches "/repo/engine/window.e7" but not
    // "/repo/engine/other/window.e7".
    const normalized = std.fs.path.resolve(allocator, &.{query}) catch return false;
    defer allocator.free(normalized);
    if (std.mem.eql(u8, stored, normalized)) return true;
    if (stored.len <= normalized.len) return false;
    if (stored[stored.len - normalized.len - 1] != std.fs.path.sep) return false;
    return std.mem.endsWith(u8, stored, normalized);
}

fn commonSuffixComponents(lhs: []const u8, rhs: []const u8) usize {
    var lhs_parts = std.mem.splitBackwardsScalar(u8, lhs, std.fs.path.sep);
    var rhs_parts = std.mem.splitBackwardsScalar(u8, rhs, std.fs.path.sep);
    var count: usize = 0;
    while (true) {
        const lhs_part = lhs_parts.next() orelse break;
        const rhs_part = rhs_parts.next() orelse break;
        if (!std.mem.eql(u8, lhs_part, rhs_part)) break;
        count += 1;
    }
    return count;
}

fn lessThanString(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "module path joining and prefix ownership" {
    const allocator = testing.allocator;

    const core_path = try joinModulePath(allocator, "", "core");
    defer allocator.free(core_path);
    try testing.expectEqualStrings("core", core_path);

    const window_path = try joinModulePath(allocator, "core", "window");
    defer allocator.free(window_path);
    try testing.expectEqualStrings("core::window", window_path);

    const inline_path = try joinModulePath(allocator, "core::window", "inline");
    defer allocator.free(inline_path);
    try testing.expectEqualStrings("core::window::inline", inline_path);

    // Segment-aligned prefix matching: "core" must not match "corex".
    try testing.expect(modulePathHasPrefix("core::window", "core"));
    try testing.expect(modulePathHasPrefix("core", "core"));
    try testing.expect(modulePathHasPrefix("core::window::inline", "core::window"));
    try testing.expect(!modulePathHasPrefix("corex::window", "core"));
    try testing.expect(!modulePathHasPrefix("core", "core::window"));
    try testing.expect(!modulePathHasPrefix("co", "core"));

    const files = [_]File{
        .{ .path = "/workspace/editor_main.e7", .module_path = "" },
        .{ .path = "/workspace/core/main.e7", .module_path = "core" },
        .{ .path = "/workspace/core/window.e7", .module_path = "core::window" },
        .{ .path = "/workspace/editor/model.e7", .module_path = "editor::model" },
    };

    try testing.expectEqual(@as(usize, 0), moduleOwnerIndex(&files, ""));
    try testing.expectEqual(@as(usize, 1), moduleOwnerIndex(&files, "core"));
    try testing.expectEqual(@as(usize, 2), moduleOwnerIndex(&files, "core::window"));
    try testing.expectEqual(@as(usize, 2), moduleOwnerIndex(&files, "core::window::inline"));
    try testing.expectEqual(@as(usize, 3), moduleOwnerIndex(&files, "editor::model"));
    try testing.expectEqual(@as(usize, 3), moduleOwnerIndex(&files, "editor::model::inline"));
    // Unmapped module paths (an inline module of the root, or a module that
    // was not loaded) fall back to the root file.
    try testing.expectEqual(@as(usize, 0), moduleOwnerIndex(&files, "editor::workspace"));
    try testing.expectEqual(@as(usize, 0), moduleOwnerIndex(&files, "unknown::thing"));
}

test "path normalization and matching" {
    const allocator = testing.allocator;

    const resolved = std.fs.path.resolve(allocator, &.{ "/workspace", "engine/main.e7" }) catch
        return error.TestUnexpectedResult;
    defer allocator.free(resolved);
    try testing.expectEqualStrings("/workspace/engine/main.e7", resolved);

    // Absolute query components reset the accumulated path.
    const reset = std.fs.path.resolve(allocator, &.{ "/workspace", "/root/../root/x.e7" }) catch
        return error.TestUnexpectedResult;
    defer allocator.free(reset);
    try testing.expectEqualStrings("/root/x.e7", reset);

    const stored = "/workspace/engine/window.e7";
    try testing.expect(pathMatches(allocator, stored, stored));
    try testing.expect(pathMatches(allocator, stored, "engine/window.e7"));
    try testing.expect(pathMatches(allocator, stored, "./engine/../engine/window.e7"));
    try testing.expect(pathMatches(allocator, stored, "/workspace/engine/window.e7"));
    try testing.expect(!pathMatches(allocator, stored, "engine/main.e7"));
    try testing.expect(!pathMatches(allocator, stored, "/workspace/engine/main.e7"));
    // Suffix matches must sit on a component boundary.
    try testing.expect(!pathMatches(allocator, "/workspace/engine/other/window.e7", "engine/window.e7"));
    try testing.expectEqual(@as(usize, 2), commonSuffixComponents(
        "/workspace/engine/window.e7",
        "/elsewhere/engine/window.e7",
    ));
    try testing.expectEqual(@as(usize, 1), commonSuffixComponents(
        "/workspace/engine/window.e7",
        "/workspace/core/window.e7",
    ));
}

fn writeTestFile(io: std.Io, dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = name, .data = data });
}

test "loader reports missing modules, cycles, and depth overruns" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buffer);
    const tmp_path = path_buffer[0..path_len];

    // A module that exists, an inline module (no file), and a cycle.
    try writeTestFile(io, tmp.dir, "solo.e7", "# standalone document\n");
    try writeTestFile(io, tmp.dir, "inline.e7", "mod inner {\n}\n");
    try writeTestFile(io, tmp.dir, "a.e7", "mod b\n");
    try writeTestFile(io, tmp.dir, "b.e7", "mod a\n");
    try writeTestFile(io, tmp.dir, "missing.e7", "mod nonexistent\n");

    // A chain deeper than `max_depth`: d0 -> d1 -> ... -> d17.
    const chain_len = max_depth + 2;
    for (0..chain_len) |index| {
        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "d{d}.e7", .{index});
        var body_buffer: [64]u8 = undefined;
        const body = if (index + 1 < chain_len)
            try std.fmt.bufPrint(&body_buffer, "mod d{d}\n", .{index + 1})
        else
            "# end of chain\n";
        try writeTestFile(io, tmp.dir, name, body);
    }

    var index = try Index.init(allocator, tmp_path);
    defer index.deinit();

    try testing.expectEqual(@as(?[]const u8, null), index.projectRoot("solo.e7"));
    try testing.expectEqual(@as(?[]const u8, null), index.projectRoot("a.e7")); // degenerate cycle

    const inline_path = try std.fs.path.join(allocator, &.{ tmp_path, "inline.e7" });
    defer allocator.free(inline_path);
    var inline_loaded = try index.load(allocator, inline_path, null);
    defer inline_loaded.deinit();
    try testing.expectEqual(@as(usize, 1), inline_loaded.files.len);
    try testing.expectEqual(@as(usize, 0), inline_loaded.module_asts.len);
    try testing.expectEqualStrings("", inline_loaded.files[0].module_path);
    try testing.expectEqualStrings(
        "",
        inline_loaded.modulePathForFile(inline_path) orelse return error.TestUnexpectedResult,
    );
    try testing.expect(inline_loaded.ownsModulePath(inline_path, "inner"));

    const missing_path = try std.fs.path.join(allocator, &.{ tmp_path, "missing.e7" });
    defer allocator.free(missing_path);
    try testing.expectError(error.ModuleNotFound, index.load(allocator, missing_path, null));

    const cycle_path = try std.fs.path.join(allocator, &.{ tmp_path, "a.e7" });
    defer allocator.free(cycle_path);
    try testing.expectError(error.CycleDetected, index.load(allocator, cycle_path, null));

    const deep_path = try std.fs.path.join(allocator, &.{ tmp_path, "d0.e7" });
    defer allocator.free(deep_path);
    try testing.expectError(error.DepthExceeded, index.load(allocator, deep_path, null));
}

/// Opens the repository workspace, or skips when the test binary does not run
/// from the engine7 repository root.
fn initRepositoryIndex() !Index {
    return Index.init(testing.allocator, ".") catch |err| switch (err) {
        error.WorkspaceUnreadable => return error.SkipZigTest,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

test "repository index selects project roots" {
    var index = try initRepositoryIndex();
    defer index.deinit();

    // Skip when the expected engine sources are not part of the workspace.
    if (index.sourceFor("engine/editor/main.e7") == null) return error.SkipZigTest;

    const editor_root = index.projectRoot("engine/editor/main.e7") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.endsWith(u8, editor_root, "engine/editor_main.e7"));
    try testing.expect(editor_root.len > "engine/editor_main.e7".len); // absolute path

    // A project entry point with external modules is its own root.
    const engine_root = index.projectRoot("engine/main.e7") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.endsWith(u8, engine_root, "engine/main.e7"));

    // Calling it again is served from the cache and returns the same slice.
    const cached = index.projectRoot("engine/editor/main.e7") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@intFromPtr(editor_root.ptr), @intFromPtr(cached.ptr));

    // A test file with no external modules and no importer is standalone.
    if (index.sourceFor("tests/e7/aggregate_defaults.e7") != null) {
        try testing.expect(index.projectRoot("tests/e7/aggregate_defaults.e7") == null);
    }
}

test "repository project loads and attributes module paths" {
    const allocator = testing.allocator;
    var index = try initRepositoryIndex();
    defer index.deinit();

    if (index.sourceFor("engine/editor/main.e7") == null) return error.SkipZigTest;

    const root_path = index.projectRoot("engine/editor/main.e7") orelse return error.TestUnexpectedResult;

    const original_root_source = index.sourceFor(root_path) orelse return error.TestUnexpectedResult;
    const overridden_root = try std.fmt.allocPrint(allocator, "{s}\n# overridden by test\n", .{original_root_source});
    defer allocator.free(overridden_root);

    // Override the root and one nested module to prove buffers (not disk) are
    // what the loaded ASTs point into.
    const window_path = "engine/core/window.e7";
    const original_window_source = index.sourceFor(window_path) orelse return error.SkipZigTest;
    const overridden_window = try std.fmt.allocPrint(allocator, "{s}\n# window override\n", .{original_window_source});
    defer allocator.free(overridden_window);

    var loaded = index.load(allocator, root_path, .{
        .path = root_path,
        .source = overridden_root,
    }) catch |err| switch (err) {
        error.ModuleNotFound, error.ParseFailed => return error.SkipZigTest,
        else => return err,
    };
    defer loaded.deinit();

    // Parallel arrays are aligned: one source and one file per loaded module.
    try testing.expect(loaded.files.len > 1);
    try testing.expectEqual(loaded.files.len, loaded.sources.len);
    try testing.expectEqual(loaded.files.len - 1, loaded.module_asts.len);
    try testing.expectEqualStrings("", loaded.files[0].module_path);
    try testing.expectEqualStrings(overridden_root, loaded.sources[0]);
    try testing.expectEqualStrings(root_path, loaded.files[0].path);

    // Module paths reflect the `mod` nesting of the loaded tree.
    try testing.expectEqualStrings(
        "core::window",
        loaded.modulePathForFile("engine/core/window.e7") orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings(
        "editor::model",
        loaded.modulePathForFile("engine/editor/model.e7") orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings(
        "",
        loaded.modulePathForFile("engine/editor_main.e7") orelse return error.TestUnexpectedResult,
    );
    if (loaded.modulePathForFile("tests/e7/aggregate_defaults.e7") != null) {
        return error.TestUnexpectedResult; // unrelated files must not be loaded
    }

    // Attribution: longest loaded module path wins; inline modules belong to
    // the file that declares them.
    try testing.expect(loaded.ownsModulePath("engine/editor/model.e7", "editor::model"));
    try testing.expect(loaded.ownsModulePath("engine/editor/model.e7", "editor::model::inline"));
    try testing.expect(!loaded.ownsModulePath("engine/editor/model.e7", "editor::workspace"));
    try testing.expect(loaded.ownsModulePath("engine/core/window.e7", "core::window"));
    try testing.expect(loaded.ownsModulePath("engine/editor_main.e7", ""));
    try testing.expect(!loaded.ownsModulePath("engine/editor/model.e7", ""));
    try testing.expect(loaded.ownsModulePath("engine/editor_main.e7", "inline_without_module"));

    const model_file = loaded.fileForModulePath("editor::model::inline");
    try testing.expect(std.mem.endsWith(u8, model_file.path, "engine/editor/model.e7"));
    try testing.expectEqualStrings("editor::model", model_file.module_path);
    try testing.expectEqualStrings(
        loaded.sourceForFile("engine/editor/model.e7") orelse return error.TestUnexpectedResult,
        loaded.sourceForModulePath("editor::model::inline") orelse return error.TestUnexpectedResult,
    );

    // Every external `mod` of the root AST is attached (no dangling reference).
    var attached: usize = 0;
    for (loaded.root_ast.module.items) |item| {
        switch (item.kind) {
            .mod => {},
            else => continue,
        }
        const module_decl: *ast.ModDecl = &item.kind.mod;
        try testing.expect(module_decl.items != null);
        attached += 1;
    }
    try testing.expect(attached > 0);

    // The module ASTs are attached to modules too, not just the root.
    var nested_attached: usize = 0;
    for (loaded.module_asts) |tree| {
        for (tree.module.items) |item| {
            switch (item.kind) {
                .mod => {},
                else => continue,
            }
            const module_decl: *ast.ModDecl = &item.kind.mod;
            if (module_decl.items != null) nested_attached += 1;
        }
    }
    try testing.expect(nested_attached > 0);

    // Now load again with the module override in place; an extra module-level
    // override does not disturb the already-proven root override.
    var window_loaded = index.load(allocator, root_path, .{
        .path = window_path,
        .source = overridden_window,
    }) catch |err| switch (err) {
        error.ModuleNotFound, error.ParseFailed => return error.SkipZigTest,
        else => return err,
    };
    defer window_loaded.deinit();
    try testing.expectEqualStrings(
        overridden_window,
        window_loaded.sourceForFile(window_path) orelse return error.TestUnexpectedResult,
    );

    // refresh() re-reads the file and invalidates the root cache.
    index.refresh(root_path);
    try testing.expect(index.sourceFor(root_path) != null);
}
