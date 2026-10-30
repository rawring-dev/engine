//! `e7-fmt` command-line driver.
//!
//! Usage:
//!   e7-fmt [options] <path>...
//!
//! Options:
//!   --check            report files that would change, write nothing; exit 1
//!                      when any file is unformatted
//!   --list             print each file that was (or would be) formatted
//!   --stdout           write the formatted result of one file to stdout
//!   --stdin            read source from stdin, write formatted source to stdout
//!   --workspace <dir>  workspace root used for project-aware analysis
//!   --no-wrap          disable 80-column wrapping
//!   --no-immutable     keep `:=` bindings as written
//!   --version          print the version
//!   --help             show this message
//!
//! Directories are searched recursively for `*.e7` files (skipping
//! `.git`, `.zig-cache`, `zig-out`, `zig-pkg`, `node_modules`, `.team`,
//! `.tooling`, `.local-vulkan`, and `target`).
//!
//! Exit codes: 0 success/no changes needed, 1 `--check` found unformatted
//! files (or unreadable source was skipped), 2 usage or I/O error.
//!
//! Diagnostics (parse-error notes, over-long-line notes, write failures) go to
//! stderr; stdout carries only formatted source (`--stdout`/`--stdin`) or the
//! summary/listing.  The `--stdin` mode is what the Neovim plugin uses as a
//! formatting fallback, so it must never mix diagnostics into its output.

const std = @import("std");
const formatter = @import("formatter");
const project = @import("project");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const name = "e7-fmt";
pub const version = "0.1.0";

/// Longest e7 source accepted from disk or stdin.  Exceeding it is an error
/// rather than a silent truncation: the formatter must never lose data.
const max_source_bytes: usize = 16 * 1024 * 1024;

/// Recursion bound for directory walks.  Symlinked directories are not
/// followed (that is what would create cycles); this is a paranoia bound for
/// pathologically deep trees.
const max_scan_depth: usize = 64;

/// Directory names never walked for `*.e7` sources.
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

/// Files whose presence marks a workspace root.  Mirrors the language
/// server's convention so `e7-fmt` and `e7-lsp` agree on the project root.
const workspace_markers = [_][]const u8{ "build.zig.zon", "build.zig", ".git" };

const usage_text =
    \\Usage: e7-fmt [options] <path>...
    \\
    \\  --check            report files that would change, write nothing; exit 1
    \\                     when any file is unformatted
    \\  --list             print each file that was (or would be) formatted
    \\  --stdout           write the formatted result of one file to stdout
    \\  --stdin            read source from stdin, write formatted source to stdout
    \\  --workspace <dir>  workspace root used for project-aware analysis
    \\                     (default: nearest ancestor with build.zig.zon,
    \\                     build.zig, or .git)
    \\  --no-wrap          disable 80-column wrapping
    \\  --no-immutable     keep `:=` bindings as written
    \\  --version          print the version
    \\  --help             show this message
    \\
    \\Directories are searched recursively for `*.e7` files (skipping .git,
    \\.zig-cache, zig-out, zig-pkg, node_modules, .team, .tooling,
    \\.local-vulkan, and target).
    \\
    \\Exit codes: 0 success/no changes needed, 1 `--check` found unformatted
    \\files (or unreadable source was skipped), 2 usage or I/O error.
    \\
;

/// Command line being assembled by `parseArgs`.
const Options = struct {
    check: bool = false,
    list: bool = false,
    stdout: bool = false,
    stdin: bool = false,
    wrap_lines: bool = true,
    convert_mutable_bindings: bool = true,
    workspace: ?[]const u8 = null,
    /// Borrowed argument slices; valid for the whole process.
    paths: std.ArrayList([]const u8) = .empty,
};

const Action = enum { run, help, version };

/// Whole-run tallies used for the summary line.
const Stats = struct {
    formatted: usize = 0,
    unchanged: usize = 0,
    conversions: usize = 0,
    wrapped: usize = 0,
    remaining: usize = 0,
    failed: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var options = Options{};
    const action = parseArgs(arena, init.minimal.args, &options) catch |err| switch (err) {
        error.Usage => std.process.exit(2),
        error.OutOfMemory => {
            std.debug.print("e7-fmt: error: out of memory\n", .{});
            std.process.exit(2);
        },
    };

    // One buffered writer for everything stdout carries.  It is flushed on
    // every exit path so `--check`/`--list` output cannot be lost.
    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_file = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_file.interface;

    switch (action) {
        .help => {
            try stdout.writeAll(usage_text);
            try stdout.flush();
            return;
        },
        .version => {
            try stdout.print("{s} {s}\n", .{ name, version });
            try stdout.flush();
            return;
        },
        .run => {},
    }

    const status = run(io, gpa, arena, &options, stdout) catch |err| {
        stdout.flush() catch {};
        if (err != error.Reported) {
            std.debug.print("e7-fmt: error: {s}\n", .{@errorName(err)});
        }
        std.process.exit(2);
    };

    stdout.flush() catch |err| {
        std.debug.print("e7-fmt: error: cannot write to stdout: {s}\n", .{describeError(err)});
        std.process.exit(2);
    };

    if (status != 0) std.process.exit(status);
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

fn parseArgs(allocator: Allocator, args: std.process.Args, options: *Options) !Action {
    var iterator = args.iterate();
    _ = iterator.next(); // executable name

    var only_paths = false;
    while (iterator.next()) |arg| {
        if (!only_paths and arg.len > 1 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--")) {
                // Everything after `--` is a path, even if it looks like a flag.
                only_paths = true;
            } else if (std.mem.eql(u8, arg, "--check")) {
                options.check = true;
            } else if (std.mem.eql(u8, arg, "--list")) {
                options.list = true;
            } else if (std.mem.eql(u8, arg, "--stdout")) {
                options.stdout = true;
            } else if (std.mem.eql(u8, arg, "--stdin")) {
                options.stdin = true;
            } else if (std.mem.eql(u8, arg, "--no-wrap")) {
                options.wrap_lines = false;
            } else if (std.mem.eql(u8, arg, "--no-immutable")) {
                options.convert_mutable_bindings = false;
            } else if (std.mem.eql(u8, arg, "--workspace")) {
                options.workspace = iterator.next() orelse
                    return usageError("--workspace requires a directory", .{});
            } else if (std.mem.eql(u8, arg, "--version")) {
                return .version;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return .help;
            } else {
                return usageError("unknown option '{s}'", .{arg});
            }
        } else {
            try options.paths.append(allocator, arg);
        }
    }

    // Reject combinations that cannot have a meaningful result instead of
    // silently ignoring one of the flags.
    if (options.stdin) {
        if (options.paths.items.len != 0) {
            return usageError("--stdin does not accept file paths", .{});
        }
        if (options.check) return usageError("--stdin cannot be combined with --check", .{});
        if (options.list) return usageError("--stdin cannot be combined with --list", .{});
        if (options.stdout) return usageError("--stdin cannot be combined with --stdout", .{});
    }
    if (options.stdout) {
        if (options.check) return usageError("--stdout cannot be combined with --check", .{});
        if (options.paths.items.len != 1) {
            return usageError("--stdout requires exactly one file", .{});
        }
    }
    if (!options.stdin and options.paths.items.len == 0) {
        return usageError("no input files (pass paths, or --stdin for editor use)", .{});
    }
    return .run;
}

fn usageError(comptime format: []const u8, args: anytype) error{Usage} {
    std.debug.print("e7-fmt: error: " ++ format ++ "\n", args);
    std.debug.print("Try 'e7-fmt --help' for usage.\n", .{});
    return error.Usage;
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

fn run(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    options: *const Options,
    stdout: *Io.Writer,
) !u8 {
    // Resolve `--workspace` once.  A path that cannot be resolved at all is a
    // user error (exit 2); a directory that exists but cannot be indexed only
    // downgrades to per-file analysis (reported by the index cache).
    var explicit_workspace: ?[]const u8 = null;
    if (options.workspace) |dir| {
        explicit_workspace = std.Io.Dir.cwd().realPathFileAlloc(io, dir, arena) catch |err| {
            std.debug.print("e7-fmt: error: workspace '{s}': {s}\n", .{ dir, describeError(err) });
            return 2;
        };
    }

    var indexes = IndexCache{ .allocator = gpa };
    defer indexes.deinit();

    if (options.stdin) {
        return runStdin(io, gpa, options, stdout, explicit_workspace, &indexes);
    }

    // Paths are made absolute while collecting so deduplication and workspace
    // detection are independent of how the user spelled the argument.
    var files = std.ArrayList([]const u8).empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(arena);

    var status: u8 = 0;
    for (options.paths.items) |input| {
        collectFiles(io, arena, input, &files, &seen) catch |err| {
            std.debug.print("e7-fmt: error: {s}: {s}\n", .{ input, describeError(err) });
            status = @max(status, 2);
        };
    }

    // Deterministic order regardless of directory iteration order.
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    if (options.stdout and files.items.len != 1) {
        std.debug.print("e7-fmt: error: --stdout requires exactly one file\n", .{});
        return 2;
    }

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);

    var stats = Stats{};
    for (files.items) |path| {
        // Project-aware `:=` validation needs the workspace index; fall back to
        // local analysis when no workspace root can be found or indexed.
        var root: ?[]const u8 = explicit_workspace;
        if (root == null) root = findWorkspaceRoot(io, arena, path) catch |err| blk: {
            std.debug.print(
                "e7-fmt: note: {s}: workspace detection failed ({s}); using local analysis\n",
                .{ path, describeError(err) },
            );
            break :blk null;
        };
        const project_index = if (root) |workspace_root| try indexes.get(workspace_root) else null;

        status = @max(status, try processFile(
            io,
            gpa,
            options,
            &stats,
            stdout,
            cwd,
            project_index,
            path,
        ));
    }

    if (stats.failed > 0) {
        std.debug.print("e7-fmt: {d} file(s) failed; see errors above\n", .{stats.failed});
    }
    if (!options.stdout) {
        try stdout.print(
            "e7-fmt: {d} file(s) formatted, {d} unchanged, {d} conversion(s), {d} wrapped line(s)\n",
            .{ stats.formatted, stats.unchanged, stats.conversions, stats.wrapped },
        );
        if (stats.remaining > 0) {
            try stdout.print(
                "e7-fmt: {d} line(s) remain over {d} columns\n",
                .{ stats.remaining, formatter.max_line_length },
            );
        }
    }
    return status;
}

/// Format one file, honouring `--check`/`--stdout` and writing in place
/// otherwise.  Returns this file's contribution to the process exit code.
fn processFile(
    io: Io,
    allocator: Allocator,
    options: *const Options,
    stats: *Stats,
    stdout: *Io.Writer,
    cwd: []const u8,
    project_index: ?*project.Index,
    path: []const u8,
) !u8 {
    const display = displayPath(cwd, path);

    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_source_bytes)) catch |err| {
        std.debug.print("e7-fmt: error: {s}: cannot read: {s}\n", .{ display, describeError(err) });
        stats.failed += 1;
        return 2;
    };
    defer allocator.free(source);

    if (!std.unicode.utf8ValidateSlice(source)) {
        // The formatter has no meaningful interpretation of the bytes and the
        // file must not be rewritten; skip it and mark the run unsuccessful.
        std.debug.print("e7-fmt: error: {s}: not valid UTF-8; skipped\n", .{display});
        stats.failed += 1;
        return 1;
    }

    var result = formatter.format(allocator, source, .{
        .path = path,
        .project_index = project_index,
        .convert_mutable_bindings = options.convert_mutable_bindings,
        .wrap_lines = options.wrap_lines,
    }) catch |err| {
        std.debug.print("e7-fmt: error: {s}: formatter failed: {s}\n", .{ display, @errorName(err) });
        stats.failed += 1;
        return 2;
    };
    defer result.deinit();

    if (!result.parse_ok) {
        // The core still returns whitespace-normalized text, which is safe to
        // apply; the note tells the user the file has a syntax error.
        std.debug.print("e7-fmt: note: {s}: parse error; only whitespace normalized\n", .{display});
    }
    stats.conversions += result.conversions;
    stats.wrapped += result.wrapped;
    stats.remaining += result.unformatted.len;
    // Per-file detail is only requested by `--list`; the summary always
    // reports the aggregate count.  Notes go to stderr so `--stdout`/`--list`
    // output stays machine-readable.
    if (options.list) {
        for (result.unformatted) |line| {
            std.debug.print("e7-fmt: note: {s}:{d}: over {d} columns ({s})\n", .{
                display, line.line, formatter.max_line_length, line.reason,
            });
        }
    }

    // `--stdout` is an explicit request for source on stdout: never write the
    // file and never print a summary.
    if (options.stdout) {
        try stdout.writeAll(result.text);
        return 0;
    }

    if (options.check) {
        if (!result.changed) {
            stats.unchanged += 1;
            return 0;
        }
        try stdout.print("{s}\n", .{display});
        stats.formatted += 1;
        return 1;
    }

    if (!result.changed) {
        stats.unchanged += 1;
        return 0;
    }

    // Truncating in place keeps the existing inode and therefore its
    // permissions/ownership, which matters for checked-out e7 sources.  If the
    // write fails part-way, put the original back.
    writeFileInPlace(io, path, result.text) catch |err| {
        std.debug.print("e7-fmt: error: {s}: cannot write: {s}\n", .{ display, describeError(err) });
        writeFileInPlace(io, path, source) catch {};
        stats.failed += 1;
        return 2;
    };
    stats.formatted += 1;
    if (options.list) try stdout.print("{s}\n", .{display});
    return 0;
}

/// `--stdin` mode: read one buffer, format it, write the result to stdout.
fn runStdin(
    io: Io,
    allocator: Allocator,
    options: *const Options,
    stdout: *Io.Writer,
    explicit_workspace: ?[]const u8,
    indexes: *IndexCache,
) !u8 {
    var reader_buffer: [16 * 1024]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &reader_buffer);
    const source = stdin_reader.interface.allocRemaining(allocator, .limited(max_source_bytes)) catch |err| {
        std.debug.print("e7-fmt: error: cannot read stdin: {s}\n", .{describeError(err)});
        return 2;
    };
    defer allocator.free(source);

    if (!std.unicode.utf8ValidateSlice(source)) {
        std.debug.print("e7-fmt: error: stdin is not valid UTF-8\n", .{});
        return 1;
    }

    const project_index = if (explicit_workspace) |root| try indexes.get(root) else null;

    var result = formatter.format(allocator, source, .{
        .path = null,
        .project_index = project_index,
        .convert_mutable_bindings = options.convert_mutable_bindings,
        .wrap_lines = options.wrap_lines,
    }) catch |err| {
        std.debug.print("e7-fmt: error: formatter failed: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer result.deinit();

    if (!result.parse_ok) {
        std.debug.print("e7-fmt: note: stdin: parse error; only whitespace normalized\n", .{});
    }
    try stdout.writeAll(result.text);
    return 0;
}

// ---------------------------------------------------------------------------
// Input collection
// ---------------------------------------------------------------------------

/// Adds everything named by `input` (a file or a recursive directory) to
/// `files`, de-duplicated by absolute path.
fn collectFiles(
    io: Io,
    allocator: Allocator,
    input: []const u8,
    files: *std.ArrayList([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    const stat = try std.Io.Dir.cwd().statFile(io, input, .{});
    switch (stat.kind) {
        .directory => {
            const root = try std.Io.Dir.cwd().realPathFileAlloc(io, input, allocator);
            try walkDirectory(io, allocator, root, 0, files, seen);
        },
        .file => {
            const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, input, allocator);
            try addFile(allocator, absolute, files, seen);
        },
        else => return error.NotAFileOrDirectory,
    }
}

fn walkDirectory(
    io: Io,
    allocator: Allocator,
    absolute_dir: []const u8,
    depth: usize,
    files: *std.ArrayList([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    if (depth > max_scan_depth) return;

    var dir = std.Io.Dir.cwd().openDir(io, absolute_dir, .{ .iterate = true }) catch |err| switch (err) {
        // A workspace tree may contain unreadable corners; formatting the rest
        // is more useful than aborting, so treat these as "nothing here".
        error.FileNotFound, error.NotDir, error.AccessDenied, error.PermissionDenied => return,
        else => return err,
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (isPrunedDirectory(entry.name)) continue;
                const child = try std.fs.path.join(allocator, &.{ absolute_dir, entry.name });
                try walkDirectory(io, allocator, child, depth + 1, files, seen);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".e7")) continue;
                const path = try std.fs.path.join(allocator, &.{ absolute_dir, entry.name });
                try addFile(allocator, path, files, seen);
            },
            .sym_link => {
                // Follow symlinked *files*, but never recurse into symlinked
                // directories: that is how a walk can loop forever.
                if (!std.mem.endsWith(u8, entry.name, ".e7")) continue;
                const path = try std.fs.path.join(allocator, &.{ absolute_dir, entry.name });
                const target = std.Io.Dir.cwd().statFile(io, path, .{}) catch continue;
                if (target.kind == .file) try addFile(allocator, path, files, seen);
            },
            else => {},
        }
    }
}

fn addFile(
    allocator: Allocator,
    absolute: []const u8,
    files: *std.ArrayList([]const u8),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    if (seen.contains(absolute)) return;
    try seen.put(allocator, absolute, {});
    try files.append(allocator, absolute);
}

fn isPrunedDirectory(directory_name: []const u8) bool {
    for (pruned_directories) |pruned| {
        if (std.mem.eql(u8, directory_name, pruned)) return true;
    }
    return false;
}

/// Nearest ancestor directory (including the file's own directory) containing
/// a workspace marker, or null when the file is standalone.
fn findWorkspaceRoot(io: Io, allocator: Allocator, file_path: []const u8) !?[]const u8 {
    var dir = std.fs.path.dirname(file_path) orelse return null;
    while (true) {
        for (workspace_markers) |marker| {
            const candidate = try std.fs.path.join(allocator, &.{ dir, marker });
            std.Io.Dir.cwd().access(io, candidate, .{}) catch continue;
            return try allocator.dupe(u8, dir);
        }
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
}

// ---------------------------------------------------------------------------
// Project index cache
// ---------------------------------------------------------------------------

/// One `project.Index` per workspace root, built on first use.  A root that
/// fails to index is memoized as `null` so the formatter keeps working with
/// local analysis instead of retrying (and failing) for every file.
const IndexCache = struct {
    allocator: Allocator,
    /// Keys are workspace root slices owned by the process arena (valid for
    /// the whole run); values are owned `project.Index` instances or null.
    indexes: std.StringHashMapUnmanaged(?*project.Index) = .empty,

    fn deinit(self: *IndexCache) void {
        var iterator = self.indexes.valueIterator();
        while (iterator.next()) |value_ptr| {
            if (value_ptr.*) |index| {
                index.deinit();
                self.allocator.destroy(index);
            }
        }
        self.indexes.deinit(self.allocator);
        self.* = undefined;
    }

    fn get(self: *IndexCache, root: []const u8) !?*project.Index {
        if (self.indexes.get(root)) |cached| return cached;

        var created: ?*project.Index = null;
        const index: ?*project.Index = blk: {
            const storage = try self.allocator.create(project.Index);
            storage.* = project.Index.init(self.allocator, root) catch |err| {
                self.allocator.destroy(storage);
                std.debug.print(
                    "e7-fmt: note: cannot index workspace '{s}' ({s}); using local analysis\n",
                    .{ root, @errorName(err) },
                );
                break :blk null;
            };
            created = storage;
            break :blk storage;
        };
        errdefer if (created) |storage| {
            storage.deinit();
            self.allocator.destroy(storage);
        };
        try self.indexes.put(self.allocator, root, index);
        created = null;
        return index;
    }
};

// ---------------------------------------------------------------------------
// Filesystem helpers and diagnostics
// ---------------------------------------------------------------------------

/// Rewrites `path` with `text`, truncating in place.  Truncating (instead of
/// replacing the inode) preserves the file's mode and owner.
fn writeFileInPlace(io: Io, path: []const u8, text: []const u8) !void {
    var file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true })
    else
        try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, text);
}

/// Renders an absolute path relative to `cwd` when possible, so listings read
/// like the arguments the user typed.
fn displayPath(cwd: []const u8, path: []const u8) []const u8 {
    if (std.mem.eql(u8, cwd, "/")) {
        return if (path.len > 1 and path[0] == '/') path[1..] else path;
    }
    if (std.mem.startsWith(u8, path, cwd) and
        path.len > cwd.len + 1 and path[cwd.len] == std.fs.path.sep)
    {
        return path[cwd.len + 1 ..];
    }
    return path;
}

fn describeError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file or directory",
        error.NotDir => "not a directory",
        error.IsDir => "is a directory",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.ReadOnlyFileSystem => "read-only file system",
        error.NameTooLong => "path too long",
        error.StreamTooLong => "file too large",
        error.FileTooBig => "file too large",
        error.WorkspaceUnreadable => "workspace unreadable",
        error.NotAFileOrDirectory => "not a file or directory",
        else => @errorName(err),
    };
}
