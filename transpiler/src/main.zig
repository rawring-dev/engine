//! Command-line driver for the e7s -> Slang transpiler.
//!
//! Usage:
//!   e7s transpile <input.e7> [-o <out.slang|dir>] [--module-name <name>]
//!                            [--single-file] [--no-module-decl]
//!   e7s check <input.e7>
//!
//! With no subcommand, `transpile` is assumed.  External `mod foo` references
//! are loaded from sibling `foo.e7` files and emitted as `foo.slang` modules.

const std = @import("std");
const transpiler = @import("transpiler");

const Mode = enum { transpile, check };

const Cli = struct {
    mode: Mode = .transpile,
    help: bool = false,
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    module_name: ?[]const u8 = null,
    single_file: bool = false,
    emit_module_decl: bool = true,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_file.interface;
    var stderr_buffer: [8192]u8 = undefined;
    var stderr_file = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_file.interface;

    run(io, arena, args, stdout, stderr) catch |err| {
        switch (err) {
            error.Usage => {
                try stderr.print("e7s: invalid command line (use --help)\n", .{});
                try stderr.flush();
                std.process.exit(2);
            },
            error.Diagnostics => {
                try stdout.flush();
                try stderr.flush();
                std.process.exit(1);
            },
            else => {
                try stderr.print("e7s: error: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            },
        }
    };

    try stdout.flush();
    try stderr.flush();
}

const RunError = error{
    Usage,
    Diagnostics,
} || std.mem.Allocator.Error || anyerror;

fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const [:0]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) RunError!void {
    const cli = parseArgs(args) catch {
        try printUsage(stderr);
        return error.Usage;
    };
    if (cli.help) {
        try printUsage(stdout);
        return;
    }
    if (cli.input == null) {
        try printUsage(stderr);
        return error.Usage;
    }
    const input_path = cli.input.?;

    const options = transpiler.Options{
        .module_name = cli.module_name orelse try deriveModuleName(allocator, input_path),
        .emit_module_decl = cli.emit_module_decl,
    };

    if (cli.single_file) {
        const source = std.Io.Dir.cwd().readFileAlloc(io, input_path, allocator, .limited(64 * 1024 * 1024)) catch |err| {
            try stderr.print("e7s: cannot read `{s}`: {s}\n", .{ input_path, @errorName(err) });
            return error.Diagnostics;
        };
        const inputs = [_]transpiler.InputModule{.{
            .name = options.module_name,
            .source = source,
            .is_root = true,
        }};
        var result = transpiler.transpileModules(allocator, &inputs, options) catch |err| {
            try stderr.print("e7s: internal error: {s}\n", .{@errorName(err)});
            return error.Diagnostics;
        };
        switch (result) {
            .diagnostics => |diagnostics| {
                printDiagnostics(stderr, input_path, diagnostics);
                transpiler.freeResult(allocator, &result);
                return error.Diagnostics;
            },
            .ok => |files| {
                defer transpiler.freeResult(allocator, &result);
                try emitOutputs(io, allocator, input_path, cli, files, false, stdout, stderr);
            },
        }
        return;
    }

    const load_result = transpiler.loadProject(allocator, input_path) catch |err| {
        try stderr.print("e7s: cannot load project at `{s}`: {s}\n", .{ input_path, @errorName(err) });
        return error.Diagnostics;
    };
    const inputs = switch (load_result) {
        .diagnostics => |diagnostics| {
            printDiagnostics(stderr, input_path, diagnostics);
            return error.Diagnostics;
        },
        .ok => |loaded| loaded,
    };
    defer transpiler.freeInputs(allocator, inputs);

    var result = transpiler.transpileModules(allocator, inputs, options) catch |err| {
        try stderr.print("e7s: internal error: {s}\n", .{@errorName(err)});
        return error.Diagnostics;
    };
    switch (result) {
        .diagnostics => |diagnostics| {
            printDiagnostics(stderr, input_path, diagnostics);
            transpiler.freeResult(allocator, &result);
            return error.Diagnostics;
        },
        .ok => |files| {
            defer transpiler.freeResult(allocator, &result);
            try emitOutputs(io, allocator, input_path, cli, files, inputs.len > 1, stdout, stderr);
        },
    }
}

fn parseArgs(args: []const [:0]const u8) !Cli {
    var cli = Cli{};
    var index: usize = 1;
    if (index < args.len) {
        if (std.mem.eql(u8, args[index], "transpile")) {
            cli.mode = .transpile;
            index += 1;
        } else if (std.mem.eql(u8, args[index], "check")) {
            cli.mode = .check;
            index += 1;
        } else if (std.mem.eql(u8, args[index], "help") or
            std.mem.eql(u8, args[index], "--help") or
            std.mem.eql(u8, args[index], "-h"))
        {
            cli.help = true;
            return cli;
        }
    }

    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "-o") or std.mem.eql(u8, argument, "--output")) {
            index += 1;
            if (index >= args.len) return error.Usage;
            cli.output = args[index];
        } else if (std.mem.eql(u8, argument, "--module-name")) {
            index += 1;
            if (index >= args.len) return error.Usage;
            cli.module_name = args[index];
        } else if (std.mem.eql(u8, argument, "--single-file")) {
            cli.single_file = true;
        } else if (std.mem.eql(u8, argument, "--no-module-decl")) {
            cli.emit_module_decl = false;
        } else if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
            cli.help = true;
            return cli;
        } else if (std.mem.startsWith(u8, argument, "-") and !std.mem.eql(u8, argument, "-")) {
            return error.Usage;
        } else {
            if (cli.input != null) return error.Usage;
            cli.input = argument;
        }
    }
    return cli;
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\e7s — transpile the engine7 shading subset (e7s) to Khronos Slang
        \\
        \\Usage:
        \\  e7s transpile <input.e7> [-o <out.slang|dir>] [--module-name <name>]
        \\                           [--single-file] [--no-module-decl]
        \\  e7s check <input.e7>
        \\
        \\Project mode loads sibling modules for `mod name` declarations and
        \\writes one `<name>.slang` file per module.  A project with a single
        \\module writes a single output file.  `-o -` writes to stdout.
        \\
    );
}

fn deriveModuleName(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(path);
    const extension = std.fs.path.extension(base);
    var stem = base;
    if (extension.len > 0) stem = base[0 .. base.len - extension.len];
    return try transpiler.sanitizeModuleName(allocator, stem);
}

fn printDiagnostics(writer: *std.Io.Writer, path: []const u8, diagnostics: []const transpiler.Diagnostic) void {
    for (diagnostics) |diagnostic| {
        writer.print("{s}:{d}:{d}: error: {s}\n", .{
            path,
            diagnostic.line,
            diagnostic.column,
            diagnostic.message,
        }) catch {};
    }
}

fn emitOutputs(
    io: std.Io,
    allocator: std.mem.Allocator,
    input_path: []const u8,
    cli: Cli,
    files: []const transpiler.OutputFile,
    is_project: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    if (cli.mode == .check) {
        try stderr.print("e7s: {d} module(s) checked OK\n", .{files.len});
        return;
    }

    if (!is_project) {
        const output_path = try singleOutputPath(io, allocator, input_path, cli, files[0].module_name);
        if (std.mem.eql(u8, output_path, "-")) {
            try stdout.writeAll(files[0].source);
            try stdout.flush();
            return;
        }
        try writeOutputFile(io, output_path, files[0].source, stderr);
        try stderr.print("e7s: wrote {s}\n", .{output_path});
        return;
    }

    const output_dir = cli.output orelse (std.fs.path.dirname(input_path) orelse ".");
    std.Io.Dir.cwd().createDirPath(io, output_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    for (files) |file| {
        const path = try std.fs.path.join(allocator, &.{ output_dir, try std.fmt.allocPrint(allocator, "{s}.slang", .{file.module_name}) });
        try writeOutputFile(io, path, file.source, stderr);
    }
    try stderr.print("e7s: wrote {d} module(s) to {s}\n", .{ files.len, output_dir });
}

fn singleOutputPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    input_path: []const u8,
    cli: Cli,
    module_name: []const u8,
) ![]const u8 {
    const output = cli.output orelse return replaceExtension(allocator, input_path, ".slang");
    if (std.mem.eql(u8, output, "-")) return output;
    if (std.mem.endsWith(u8, output, "/") or isDirectory(io, output)) {
        std.Io.Dir.cwd().createDirPath(io, output) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return std.fs.path.join(allocator, &.{ output, try std.fmt.allocPrint(allocator, "{s}.slang", .{module_name}) });
    }
    return output;
}

fn isDirectory(io: std.Io, path: []const u8) bool {
    var directory = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    directory.close(io);
    return true;
}

fn writeOutputFile(io: std.Io, path: []const u8, data: []const u8, stderr: *std.Io.Writer) !void {
    if (std.fs.path.dirname(path)) |directory| {
        std.Io.Dir.cwd().createDirPath(io, directory) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                try stderr.print("e7s: cannot create `{s}`: {s}\n", .{ directory, @errorName(err) });
                return error.Diagnostics;
            },
        };
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch |err| {
        try stderr.print("e7s: cannot write `{s}`: {s}\n", .{ path, @errorName(err) });
        return error.Diagnostics;
    };
}

fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]const u8 {
    const current = std.fs.path.extension(path);
    const without = path[0 .. path.len - current.len];
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ without, extension });
}
