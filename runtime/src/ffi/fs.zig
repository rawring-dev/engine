//! Filesystem FFI restricted to the executable's directory and descendants.
//!
//! Every path is interpreted relative to the directory containing the running
//! executable.  Absolute paths, `..` components, and symlinks that resolve
//! outside that directory are rejected before any I/O is performed.  The check
//! is lexical first and then canonical (realpath) based; the kernel is also
//! asked to enforce containment where it supports `resolve_beneath`.
//!
//! This is a capability boundary for generated code, not a defence against a
//! hostile process running as the same user with direct syscall access.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io.zig");

pub const max_file_size = 64 * 1024 * 1024;
pub const max_path_size = std.fs.max_path_bytes;

pub const Error = error{
    AccessDenied,
    InvalidPath,
    NotFound,
    TooLarge,
    OutOfMemory,
};

pub const EntryKind = enum(i32) {
    unknown = 0,
    file = 1,
    directory = 2,
    symlink = 3,
    other = 4,
};

pub const Stat = struct {
    size: u64,
    kind: EntryKind,
    mtime_ns: i128,
};

pub const Sandbox = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    root: []u8,

    pub fn init(allocator: std.mem.Allocator) !Sandbox {
        var threaded = std.Io.Threaded.init(allocator, .{});
        errdefer threaded.deinit();
        const io_impl = threaded.io();

        const exe_dir = try std.process.executableDirPathAlloc(io_impl, allocator);
        defer allocator.free(exe_dir);

        const root = try std.Io.Dir.realPathFileAbsoluteAlloc(io_impl, exe_dir, allocator);
        errdefer allocator.free(root);

        var trimmed: []const u8 = root;
        while (trimmed.len > 1 and isSep(trimmed[trimmed.len - 1])) {
            trimmed = trimmed[0 .. trimmed.len - 1];
        }
        const owned = try allocator.dupe(u8, trimmed);
        allocator.free(root);

        return .{ .allocator = allocator, .threaded = threaded, .root = owned };
    }

    pub fn deinit(self: *Sandbox) void {
        self.allocator.free(self.root);
        self.threaded.deinit();
        self.* = undefined;
    }

    fn io(self: *Sandbox) std.Io {
        return self.threaded.io();
    }

    pub fn rootPath(self: *const Sandbox) []const u8 {
        return self.root;
    }

    /// Validate `rel` lexically.  The path must be relative and must not
    /// contain a parent-directory component.
    pub fn validate(self: *const Sandbox, rel: []const u8) Error!void {
        _ = self;
        if (rel.len == 0 or rel.len > max_path_size) return error.InvalidPath;
        if (std.mem.indexOfScalar(u8, rel, 0) != null) return error.InvalidPath;
        if (std.fs.path.isAbsolute(rel)) return error.InvalidPath;
        if (rel[0] == '/' or rel[0] == '\\') return error.InvalidPath;

        var it = std.mem.splitAny(u8, rel, "/\\");
        while (it.next()) |part| {
            if (part.len == 0) continue;
            if (std.mem.eql(u8, part, "..")) return error.AccessDenied;
            if (part.len > std.fs.max_name_bytes) return error.InvalidPath;
        }
    }

    fn withinRoot(self: *const Sandbox, path: []const u8) bool {
        if (path.len < self.root.len) return false;
        const prefix = path[0..self.root.len];
        const equal = if (builtin.os.tag == .windows)
            std.ascii.eqlIgnoreCase(prefix, self.root)
        else
            std.mem.eql(u8, prefix, self.root);
        if (!equal) return false;
        if (path.len == self.root.len) return true;
        return isSep(path[self.root.len]);
    }

    /// Canonicalize an existing path and verify containment.
    fn resolveExisting(self: *Sandbox, rel: []const u8) ![]u8 {
        try self.validate(rel);
        const joined = try std.fs.path.join(self.allocator, &.{ self.root, rel });
        defer self.allocator.free(joined);

        const real_z = std.Io.Dir.realPathFileAbsoluteAlloc(self.io(), joined, self.allocator) catch |err| {
            return switch (err) {
                error.FileNotFound, error.NotDir => error.NotFound,
                error.AccessDenied, error.PermissionDenied => error.AccessDenied,
                else => error.NotFound,
            };
        };
        defer self.allocator.free(real_z);

        if (!self.withinRoot(real_z)) return error.AccessDenied;
        return self.allocator.dupe(u8, real_z);
    }

    /// Canonicalize the nearest existing ancestor and keep the remaining
    /// components.  Used for create/mkdir/rename destinations.
    fn resolveForCreate(self: *Sandbox, rel: []const u8) ![]u8 {
        try self.validate(rel);
        const joined = try std.fs.path.join(self.allocator, &.{ self.root, rel });
        defer self.allocator.free(joined);

        if (std.Io.Dir.realPathFileAbsoluteAlloc(self.io(), joined, self.allocator)) |real_z| {
            defer self.allocator.free(real_z);
            if (!self.withinRoot(real_z)) return error.AccessDenied;
            return self.allocator.dupe(u8, real_z);
        } else |_| {}

        var current: []const u8 = joined;
        while (true) {
            const parent = std.fs.path.dirname(current) orelse return error.AccessDenied;
            if (std.Io.Dir.realPathFileAbsoluteAlloc(self.io(), parent, self.allocator)) |real_parent_z| {
                defer self.allocator.free(real_parent_z);
                if (!self.withinRoot(real_parent_z)) return error.AccessDenied;

                const suffix = current[parent.len..];
                return std.fs.path.join(self.allocator, &.{ real_parent_z, suffix[1..] });
            } else |err| switch (err) {
                error.FileNotFound, error.NotDir => {},
                error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
                else => return error.NotFound,
            }
            if (current.len <= self.root.len) return error.AccessDenied;
            current = parent;
        }
    }

    pub fn read(self: *Sandbox, rel: []const u8) ![]u8 {
        const abs = try self.resolveExisting(rel);
        defer self.allocator.free(abs);

        const data = std.Io.Dir.readFileAlloc(
            std.Io.Dir.cwd(),
            self.io(),
            abs,
            self.allocator,
            .limited(max_file_size),
        ) catch |err| switch (err) {
            error.StreamTooLong => return error.TooLarge,
            error.FileNotFound => return error.NotFound,
            error.AccessDenied, error.PermissionDenied => return error.AccessDenied,
            error.IsDir => return error.InvalidPath,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NotFound,
        };
        return data;
    }

    pub fn write(self: *Sandbox, rel: []const u8, data: []const u8, append: bool) !void {
        if (data.len > max_file_size) return error.TooLarge;
        const abs = try self.resolveForCreate(rel);
        defer self.allocator.free(abs);

        if (!append) {
            var file = std.Io.Dir.cwd().createFile(self.io(), abs, .{
                .truncate = true,
                .resolve_beneath = true,
            }) catch |err| return mapIo(err);
            defer file.close(self.io());
            file.writeStreamingAll(self.io(), data) catch |err| return mapIo(err);
            return;
        }

        var file = std.Io.Dir.cwd().createFile(self.io(), abs, .{
            .read = true,
            .truncate = false,
            .resolve_beneath = true,
        }) catch |err| return mapIo(err);
        defer file.close(self.io());
        const size = (file.stat(self.io()) catch |err| return mapIo(err)).size;
        file.writePositionalAll(self.io(), data, size) catch |err| return mapIo(err);
    }

    pub fn stat(self: *Sandbox, rel: []const u8) !Stat {
        const abs = try self.resolveExisting(rel);
        defer self.allocator.free(abs);

        const st = std.Io.Dir.cwd().statFile(self.io(), abs, .{}) catch |err| return mapIo(err);
        return .{
            .size = st.size,
            .kind = kindOf(st.kind),
            .mtime_ns = st.mtime.nanoseconds,
        };
    }

    pub fn exists(self: *Sandbox, rel: []const u8) bool {
        const abs = self.resolveExisting(rel) catch return false;
        defer self.allocator.free(abs);
        std.Io.Dir.cwd().access(self.io(), abs, .{}) catch return false;
        return true;
    }

    /// List one directory level as newline-separated names.  Directory entries
    /// carry a trailing `/`.
    pub fn list(self: *Sandbox, rel: []const u8) ![]u8 {
        const abs = try self.resolveExisting(rel);
        defer self.allocator.free(abs);

        var dir = std.Io.Dir.openDirAbsolute(self.io(), abs, .{ .iterate = true }) catch |err| return mapIo(err);
        defer dir.close(self.io());

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var it = dir.iterate();
        while (it.next(self.io()) catch |err| return mapIo(err)) |entry| {
            try out.appendSlice(self.allocator, entry.name);
            if (entry.kind == .directory) try out.append(self.allocator, '/');
            try out.append(self.allocator, '\n');
        }
        if (out.items.len > max_file_size) return error.TooLarge;
        return out.toOwnedSlice(self.allocator);
    }

    pub fn mkdir(self: *Sandbox, rel: []const u8) !void {
        const abs = try self.resolveForCreate(rel);
        defer self.allocator.free(abs);
        std.Io.Dir.cwd().createDirPath(self.io(), abs) catch |err| return mapIo(err);
    }

    pub fn removeFile(self: *Sandbox, rel: []const u8) !void {
        const abs = try self.resolveExisting(rel);
        defer self.allocator.free(abs);
        std.Io.Dir.cwd().deleteFile(self.io(), abs) catch |err| return mapIo(err);
    }

    pub fn removeTree(self: *Sandbox, rel: []const u8) !void {
        if (rel.len == 0) return error.AccessDenied;
        const abs = try self.resolveExisting(rel);
        defer self.allocator.free(abs);
        if (std.mem.eql(u8, abs, self.root)) return error.AccessDenied;
        std.Io.Dir.cwd().deleteTree(self.io(), abs) catch |err| return mapIo(err);
    }

    pub fn rename(self: *Sandbox, from: []const u8, to: []const u8) !void {
        const abs_from = try self.resolveExisting(from);
        defer self.allocator.free(abs_from);
        const abs_to = try self.resolveForCreate(to);
        defer self.allocator.free(abs_to);
        std.Io.Dir.rename(std.Io.Dir.cwd(), abs_from, std.Io.Dir.cwd(), abs_to, self.io()) catch |err| return mapIo(err);
    }
};

fn isSep(c: u8) bool {
    return c == '/' or (builtin.os.tag == .windows and c == '\\');
}

fn kindOf(kind: std.Io.File.Kind) EntryKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .symlink,
        .unknown => .unknown,
        else => .other,
    };
}

fn mapIo(err: anyerror) Error {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.FileNotFound, error.NotDir => error.NotFound,
        error.NameTooLong, error.InvalidUtf8, error.BadPathName => error.InvalidPath,
        error.IsDir => error.InvalidPath,
        error.OutOfMemory => error.OutOfMemory,
        error.FileTooBig, error.StreamTooLong => error.TooLarge,
        else => error.NotFound,
    };
}

var global_mutex: io_mod.Mutex = .{};
var global_sandbox: ?Sandbox = null;
var global_init_error: bool = false;

/// Process-wide sandbox rooted at the executable directory, used by the FFI
/// entry points.  The first caller initializes it; subsequent callers share it.
pub fn global() ?*Sandbox {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_sandbox != null) return &global_sandbox.?;
    if (global_init_error) return null;

    global_sandbox = Sandbox.init(std.heap.c_allocator) catch {
        global_init_error = true;
        return null;
    };
    return &global_sandbox.?;
}

test "sandbox reads, writes, lists, and rejects escapes" {
    var sandbox = try Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    const dir = try std.fmt.allocPrint(
        std.testing.allocator,
        ".engine7-fs-test-{d}-{d}",
        .{ @as(u64, @intCast(std.c.getpid())), std.Io.Timestamp.now(io_mod.io(), .awake).nanoseconds },
    );
    defer std.testing.allocator.free(dir);

    try sandbox.mkdir(dir);
    defer sandbox.removeTree(dir) catch {};

    const nested = try std.fs.path.join(std.testing.allocator, &.{ dir, "nested" });
    defer std.testing.allocator.free(nested);
    try sandbox.mkdir(nested);

    const file = try std.fs.path.join(std.testing.allocator, &.{ nested, "hello.txt" });
    defer std.testing.allocator.free(file);

    try sandbox.write(file, "hello", false);
    try sandbox.write(file, " world", true);

    const data = try sandbox.read(file);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("hello world", data);

    const st = try sandbox.stat(file);
    try std.testing.expectEqual(EntryKind.file, st.kind);
    try std.testing.expectEqual(@as(u64, 11), st.size);
    try std.testing.expect(sandbox.exists(file));

    const listing = try sandbox.list(nested);
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "hello.txt") != null);

    try std.testing.expectError(error.AccessDenied, sandbox.read("../escape"));
    try std.testing.expectError(error.AccessDenied, sandbox.write("../escape", "x", false));
    try std.testing.expectError(error.InvalidPath, sandbox.read("/etc/passwd"));
    try std.testing.expectError(error.AccessDenied, sandbox.removeTree("."));
    try std.testing.expectError(error.AccessDenied, sandbox.removeTree(""));

    if (builtin.os.tag != .windows) {
        const link = try std.fs.path.join(std.testing.allocator, &.{ dir, "escape-link" });
        defer std.testing.allocator.free(link);
        const link_abs = try std.fs.path.join(std.testing.allocator, &.{ sandbox.rootPath(), link });
        defer std.testing.allocator.free(link_abs);

        if (std.Io.Dir.symLinkAbsolute(sandbox.io(), "/etc", link_abs, .{})) |_| {
            const escaped = try std.fs.path.join(std.testing.allocator, &.{ link, "hostname" });
            defer std.testing.allocator.free(escaped);
            try std.testing.expectError(error.AccessDenied, sandbox.read(escaped));
            try std.testing.expectError(error.AccessDenied, sandbox.write(escaped, "x", false));
        } else |_| {}
    }
}
