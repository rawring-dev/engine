//! Audit for direct `e7_*` intrinsic calls in engine e7 sources.
//!
//! Engine code and the e7-authored tests in `tests/e7` should reach the runtime
//! through language syntax (typed raw pointers and `as` casts) and the
//! compiler-known native methods in `native_methods.zig`, not by spelling the
//! C ABI itself.  This audit scans every `.e7` file under `engine/` and
//! `tests/e7/`, reports calls to a symbol in `intrinsics.zig`, and fails when a
//! call is outside the explicit boundary below.
//!
//! The audit is **report-only by default** while the engine migration is in
//! progress: it prints a summary and passes.  Set `E7_INTRINSIC_AUDIT=strict`
//! (or `1`) to enforce it; the migration task removes the remaining direct
//! calls so the strict run passes.
//!
//! `boundary` is the documented allowance list for intrinsics that must stay
//! reachable from e7 source (for example an engine/domain helper that has no
//! native method yet).  Keep it explicit and add a `reason` when extending it;
//! entries match a file suffix and a function name (empty matches anything).

const std = @import("std");
const builtin = @import("builtin");
const intrinsics = @import("intrinsics.zig");

pub const Boundary = struct {
    /// File suffix (for example "engine/platform/sdl.e7"); empty matches any.
    file: []const u8 = "",
    /// Enclosing function name; empty matches any function.
    function: []const u8 = "",
    /// Why this direct intrinsic call is allowed.
    reason: []const u8 = "",
};

pub const boundary = [_]Boundary{};

pub const Violation = struct {
    file: []const u8,
    line: usize,
    function: []const u8,
    name: []const u8,
};

fn strictMode() bool {
    if (!builtin.link_libc) return false;
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return false;
    const environ = std.c.environ;
    var index: usize = 0;
    while (environ[index]) |entry| : (index += 1) {
        const pair = std.mem.span(entry);
        const prefix = "E7_INTRINSIC_AUDIT=";
        if (!std.mem.startsWith(u8, pair, prefix)) continue;
        const value = pair[prefix.len..];
        return std.mem.eql(u8, value, "strict") or
            std.mem.eql(u8, value, "fail") or
            std.mem.eql(u8, value, "1");
    }
    return false;
}

fn isBoundaryAllowed(violation: Violation) bool {
    for (boundary) |entry| {
        if (entry.file.len != 0 and !std.mem.endsWith(u8, violation.file, entry.file)) continue;
        if (entry.function.len != 0 and !std.mem.eql(u8, violation.function, entry.function)) continue;
        return true;
    }
    return false;
}

fn collectE7Files(
    allocator: std.mem.Allocator,
    directory: []const u8,
    files: *std.ArrayList([]u8),
) !void {
    var directory_handle = std.Io.Dir.cwd().openDir(std.testing.io, directory, .{ .iterate = true }) catch return;
    defer directory_handle.close(std.testing.io);
    var iterator = directory_handle.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        const child = try std.fs.path.join(allocator, &.{ directory, entry.name });
        errdefer allocator.free(child);
        switch (entry.kind) {
            .directory => {
                try collectE7Files(allocator, child, files);
                allocator.free(child);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".e7")) {
                    try files.append(allocator, child);
                } else {
                    allocator.free(child);
                }
            },
            else => allocator.free(child),
        }
    }
}

fn isIdentifierByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// True when the trimmed line starts a `name <-` definition; returns the name.
fn functionDefinitionName(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    var rest = trimmed;
    if (std.mem.startsWith(u8, rest, "pub ")) rest = rest[4..];
    var end: usize = 0;
    while (end < rest.len and isIdentifierByte(rest[end])) end += 1;
    if (end == 0) return null;
    const name = rest[0..end];
    var after = end;
    while (after < rest.len and (rest[after] == ' ' or rest[after] == '\t')) after += 1;
    if (!std.mem.startsWith(u8, rest[after..], "<-")) return null;
    return name;
}

fn scanSource(
    allocator: std.mem.Allocator,
    file: []const u8,
    source: []const u8,
    violations: *std.ArrayList(Violation),
) !void {
    var current_function: []const u8 = "";
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: usize = 0;
    while (lines.next()) |line| {
        line_number += 1;
        if (functionDefinitionName(line)) |name| current_function = name;
        var index: usize = 0;
        var in_string = false;
        while (index < line.len) {
            const ch = line[index];
            if (in_string) {
                if (ch == '\\') {
                    index += 2;
                    continue;
                }
                if (ch == '"') in_string = false;
                index += 1;
                continue;
            }
            if (ch == '"') {
                in_string = true;
                index += 1;
                continue;
            }
            if (ch == '#') break;
            if (ch != 'e') {
                index += 1;
                continue;
            }
            var end = index;
            while (end < line.len and isIdentifierByte(line[end])) end += 1;
            const candidate = line[index..end];
            if (!std.mem.startsWith(u8, candidate, "e7_") or intrinsics.lookup(candidate) == null) {
                index = end;
                continue;
            }
            var call_index = end;
            while (call_index < line.len and (line[call_index] == ' ' or line[call_index] == '\t')) call_index += 1;
            if (call_index < line.len and line[call_index] == '(') {
                try violations.append(allocator, .{
                    .file = file,
                    .line = line_number,
                    // The scan source buffer is freed after this file, so the
                    // violation owns its function/name strings.
                    .function = try allocator.dupe(u8, current_function),
                    .name = try allocator.dupe(u8, candidate),
                });
            }
            index = end;
        }
    }
}

test "audit: engine and tests/e7 sources call intrinsics only inside the native boundary" {
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |file| std.testing.allocator.free(file);
        files.deinit(std.testing.allocator);
    }

    const roots = [_][]const u8{ "engine", "tests/e7" };
    const prefixes = [_][]const u8{ "", "../", "../../" };
    var roots_found: usize = 0;
    for (roots) |root| {
        for (prefixes) |prefix| {
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const candidate = std.fmt.bufPrint(&path_buffer, "{s}{s}", .{ prefix, root }) catch continue;
            var directory = std.Io.Dir.cwd().openDir(std.testing.io, candidate, .{ .iterate = true }) catch continue;
            directory.close(std.testing.io);
            try collectE7Files(std.testing.allocator, candidate, &files);
            roots_found += 1;
            break;
        }
    }
    if (roots_found == 0) return error.SkipZigTest;

    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(std.testing.allocator);
    defer for (violations.items) |violation| {
        std.testing.allocator.free(violation.function);
        std.testing.allocator.free(violation.name);
    };
    for (files.items) |file| {
        const source = try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            file,
            std.testing.allocator,
            .limited(8 * 1024 * 1024),
        );
        defer std.testing.allocator.free(source);
        try scanSource(std.testing.allocator, file, source, &violations);
    }

    var allowed_count: usize = 0;
    var reported: usize = 0;
    for (violations.items) |violation| {
        if (isBoundaryAllowed(violation)) {
            allowed_count += 1;
            continue;
        }
        if (reported < 5) {
            std.debug.print("intrinsic audit: {s}:{d} in {s}: {s}()\n", .{
                violation.file,
                violation.line,
                if (violation.function.len == 0) "<top level>" else violation.function,
                violation.name,
            });
        }
        reported += 1;
    }
    std.debug.print(
        "intrinsic audit: {d} intrinsic call(s) in {d} e7 file(s) under engine/ and tests/e7: {d} allowed, {d} outside the boundary ({s} mode)\n",
        .{ violations.items.len, files.items.len, allowed_count, reported, if (strictMode()) "strict" else "report" },
    );
    if (strictMode() and reported != 0) return error.TestUnexpectedResult;
}
