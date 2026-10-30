//! `e7-lsp`: the engine7 language server.
//!
//! A from-scratch LSP 3.17 implementation over stdio.  It reuses the compiler
//! front end (`compiler.lexer`, `compiler.parser`, `compiler.semantic`) for
//! diagnostics and declaration indexing; code generation and the runtime are
//! not linked in.
//!
//! Usage:
//!   e7-lsp                 # serve LSP over stdin/stdout
//!   e7-lsp --stdio         # explicit (same as default)
//!   e7-lsp --version
//!   e7-lsp --help
//!
//! Editor clients normally launch it automatically; see `editors/lsp/README.md`
//! and the Neovim plugin in `editors/neovim/`.

const std = @import("std");
const server_mod = @import("server.zig");

const Io = std.Io;

pub const name = "e7-lsp";
pub const version = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            var stdout_buffer: [128]u8 = undefined;
            var stdout_file = Io.File.stdout().writer(io, &stdout_buffer);
            try stdout_file.interface.print("{s} {s}\n", .{ name, version });
            try stdout_file.interface.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var stdout_buffer: [1024]u8 = undefined;
            var stdout_file = Io.File.stdout().writer(io, &stdout_buffer);
            try stdout_file.interface.writeAll(
                \\e7-lsp — engine7 language server
                \\
                \\Serves the Language Server Protocol over stdin/stdout.
                \\Options:
                \\  --stdio       serve over stdio (default)
                \\  --version     print the server version and exit
                \\  --help        show this message
                \\
            );
            try stdout_file.interface.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--stdio")) {
            // Default transport.
        } else {
            std.debug.print("e7-lsp: ignoring unknown argument '{s}'\n", .{arg});
        }
    }

    var stdin_buffer: [8192]u8 = undefined;
    var stdin_file = Io.File.stdin().reader(io, &stdin_buffer);
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_file.interface;

    var server = server_mod.Server.init(allocator, stdout);
    defer server.deinit();

    server.run(&stdin_file.interface) catch |err| {
        std.debug.print("e7-lsp: fatal: {s}\n", .{@errorName(err)});
        return err;
    };
    try stdout.flush();
}

// `zig build test-lsp` roots the test binary at this file, and test
// declarations in imported files are only emitted when the root refers to them
// explicitly.  Pull in every LSP module so `protocol.zig` (and any tests added
// to `server.zig` / `analysis.zig`) run as part of the suite.
test {
    _ = @import("server.zig");
}
