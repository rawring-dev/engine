//! `run-editor`: compile the e7 project editor, JIT it, and run its `main`.
//!
//!     zig build run-editor
//!     zig build run-editor -- --frames 2 --headless --capture /tmp/editor.ppm
//!     zig build run-editor -- --frames 3 --headless --reload-test
//!
//! The e7 editor owns its main loop and resources for the whole session.
//! Successful edits are linked into resident JIT generations, then task entry
//! redirects are published after Render. No Init/DeInit or ECS reset on reload.
//! `--reload-test` requests one compatible reload while that same main runs.

const std = @import("std");
const compiler = @import("compiler");
const task = @import("task.zig");
const host = @import("host.zig");

const default_project = "engine/editor_main.e7";
const editor_host = @import("editor_host.zig");
const live_reload = @import("live_reload.zig");
var active_program: ?*live_reload.Program = null;
var active_project: []const u8 = default_project;

fn prepareReload() bool {
    const program = active_program orelse return false;
    const success = program.stagePath(active_project);
    editor_host.diagnostic = program.diagnostic;
    return success;
}

fn applyReload() bool {
    const program = active_program orelse return false;
    // --reload-test can request publication directly, without a script save.
    if (program.candidate == null and !prepareReload()) return false;
    const success = program.commit();
    editor_host.diagnostic = program.diagnostic;
    return success;
}

const Options = struct {
    project: []const u8 = default_project,
    project_explicit: bool = false,
    frames: i64 = 0,
    headless: bool = false,
    capture_path: ?[]const u8 = null,
    verbose: bool = false,
    reload_test: bool = false,
    code_path: []const u8 = "",
};

pub fn main(init: std.process.Init) !void {
    var options = Options{};
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--frames")) {
            const value = args.next() orelse return usageError("--frames requires a count");
            options.frames = std.fmt.parseInt(i64, value, 10) catch return usageError("invalid --frames count");
            if (options.frames < 0) return usageError("--frames must be non-negative");
        } else if (std.mem.eql(u8, arg, "--headless")) {
            options.headless = true;
        } else if (std.mem.eql(u8, arg, "--capture")) {
            options.capture_path = args.next() orelse return usageError("--capture requires a path");
            options.headless = true;
        } else if (std.mem.eql(u8, arg, "--project")) {
            options.project = args.next() orelse return usageError("--project requires a path");
            options.project_explicit = true;
        } else if (std.mem.eql(u8, arg, "--code")) {
            options.code_path = args.next() orelse return usageError("--code requires a script path");
        } else if (std.mem.eql(u8, arg, "--reload-test")) {
            options.reload_test = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else {
            std.debug.print("run-editor: unknown argument '{s}'\n", .{arg});
            return usageError("unknown argument");
        }
    }
    if (options.frames == 0 and options.capture_path != null) options.frames = 2;
    if (options.frames > 0) options.headless = true;
    if (!options.headless) {
        std.debug.print("run-editor: editor7; use the side-panel buttons to select/nudge objects, save the scene, or reload the project code\n", .{});
    }

    const allocator = std.heap.c_allocator;
    const project_path = try resolveProjectPath(init.io, options);

    // The editor main and all host/world resources live for this whole session.
    active_project = project_path;
    editor_host.initial_file = options.code_path;
    editor_host.check_callback = prepareReload;
    editor_host.apply_callback = applyReload;
    defer {
        editor_host.check_callback = null;
        editor_host.apply_callback = null;
        editor_host.close();
    }
    host.reset();
    host.setHeadless(options.headless);
    host.setMaxFrames(options.frames);
    host.setCaptureEnabled(options.capture_path != null);

    if (options.reload_test) host.requestReload();
    const outcome = try runProject(allocator, options, project_path);
    const reloads = outcome.reloads;
    const exit_code = outcome.code;
    if (options.reload_test and reloads != 1) return error.ReloadVerificationFailed;

    if (options.capture_path) |path| {
        var capture = host.takeCapture() orelse {
            std.debug.print("run-editor: no frame captured (window/scene creation failed?)\n", .{});
            return error.NoCapture;
        };
        defer capture.deinit();
        try host.writePpm(init.io, path, capture);
        std.debug.print(
            "run-editor: wrote {s} ({d}x{d}, {d} frames, {d} reloads{s})\n",
            .{
                path,
                capture.width,
                capture.height,
                host.frames(),
                reloads,
                if (host.captureHasContent(capture)) "" else ", empty frame",
            },
        );
        if (!host.captureHasContent(capture)) return error.CaptureEmpty;
    } else if (options.verbose) {
        std.debug.print("run-editor: main completed after {d} frames, {d} reloads\n", .{ host.frames(), reloads });
    }
    if (exit_code != 0) return error.EditorMainFailed;
}

/// Run the editor main exactly once. Candidate JITs never execute main/setup.
fn runProject(
    allocator: std.mem.Allocator,
    options: Options,
    project_path: []const u8,
) !struct { code: i64, reloads: usize } {
    const compiled = compiler.pipeline.compileProject(allocator, project_path, .{}) catch |err| {
        if (err == error.SemanticFailed) {
            if (compiler.pipeline.loadProject(allocator, project_path)) |loaded| {
                var project = loaded;
                defer project.deinit();
                if (compiler.semantic.analyze(allocator, project.root_ast.module)) |analysis| {
                    var owned = analysis;
                    defer owned.deinit();
                    for (owned.diagnostics) |diagnostic| {
                        std.debug.print("run-editor: {}:{}: {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
                    }
                } else |_| {}
            } else |_| {}
        }
        std.debug.print("run-editor: failed to compile project '{s}': {s}\n", .{ project_path, @errorName(err) });
        return error.ProjectCompileFailed;
    };
    var program = try live_reload.Program.init(allocator, compiled);
    defer program.deinit();
    active_program = &program;
    defer active_program = null;
    if (options.verbose) {
        std.debug.print("run-editor: resident editor '{s}', {d} code entry points\n", .{ project_path, program.generations.items[0].entries.count() });
    }
    task.e7_task_set_inline(1);
    defer task.e7_task_set_inline(0);
    const main_ctor = try program.main();
    const handle = main_ctor();
    if (handle == 0) return error.MainTaskFailed;
    const result = task.e7_task_await(handle);
    return .{ .code = result, .reloads = program.reloads() };
}

fn resolveProjectPath(io: std.Io, options: Options) ![]const u8 {
    if (options.project_explicit) return options.project;
    const candidates = [_][]const u8{
        options.project,
        "../engine/editor_main.e7",
        "../../engine/editor_main.e7",
    };
    for (candidates) |candidate| {
        var probe = std.Io.Dir.cwd().openFile(io, candidate, .{}) catch continue;
        probe.close(io);
        return candidate;
    }
    return options.project;
}

fn usageError(message: []const u8) error{InvalidArguments} {
    std.debug.print("run-editor: {s}\n", .{message});
    printHelp();
    return error.InvalidArguments;
}

fn printHelp() void {
    std.debug.print(
        \\Usage: run-editor [options]
        \\
        \\  --project PATH   e7 project root (default: engine/editor_main.e7)
        \\  --frames N       exit after N frames (enables the frame limiter)
        \\  --headless       hidden window (implied by --frames/--capture)
        \\  --capture PATH   write the last rendered frame as a PPM (P6) image
        \\  --code PATH      open the embedded Neovim workspace at PATH
        \\  --reload-test    verify one live reload without leaving the editor main
        \\  --verbose        print project/metadata details per generation
        \\  -h, --help       show this help
        \\
    , .{});
}
