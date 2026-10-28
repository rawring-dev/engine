//! `run-editor`: compile the e7 project editor, JIT it, and run its `main`.
//!
//!     zig build run-editor
//!     zig build run-editor -- --frames 2 --headless --capture /tmp/editor.ppm
//!     zig build run-editor -- --frames 3 --headless --reload-test
//!
//! The editor project (`engine/editor_main.e7`) is an ordinary e7 project built
//! on the engine modules.  This host adds the one capability the engine demo
//! does not need: an in-process code swap loop.  The e7 editor main returns
//! code 42 when it sees a host reload request (`host::request_reload` /
//! `host::take_reload_request`); the host then drops the current JIT, recompiles
//! the project from disk, registers the (reset) ECS metadata, creates a fresh
//! JIT, and starts the new `main`.  Scene state survives a reload because the
//! editor saves its document before asking for the reload.
//!
//! `--reload-test` is a verification aid: the host requests one reload before
//! the first run so the reload path executes exactly once in a headless run.

const std = @import("std");
const compiler = @import("compiler");
const orc = @import("orc.zig");
const task = @import("task.zig");
const ecs = @import("ecs.zig");
const host = @import("host.zig");

const default_project = "engine/editor_main.e7";
/// e7 main return code meaning "reload this project".
const reload_marker: i64 = 42;
const max_reloads: i64 = 8;

const Options = struct {
    project: []const u8 = default_project,
    project_explicit: bool = false,
    frames: i64 = 0,
    headless: bool = false,
    capture_path: ?[]const u8 = null,
    verbose: bool = false,
    reload_test: bool = false,
};

const Outcome = union(enum) {
    exit: i64,
    reload,
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

    // The host frame limiter and capture buffer live across reload cycles; only
    // the compiled project and JIT are replaced.
    host.reset();
    host.setHeadless(options.headless);
    host.setMaxFrames(options.frames);
    host.setCaptureEnabled(options.capture_path != null);

    var reloads: i64 = 0;
    var exit_code: i64 = 0;
    while (true) {
        // A pending request from the previous run would be consumed by the new
        // e7 main loop; only `--reload-test` seeds one before the first run.
        if (options.reload_test and reloads == 0) host.requestReload();

        const outcome = try runProjectOnce(allocator, options, project_path, reloads);
        switch (outcome) {
            .reload => {
                reloads += 1;
                if (reloads > max_reloads) {
                    std.debug.print("run-editor: stopped after {d} project reloads (limit {d})\n", .{ reloads, max_reloads });
                    return error.TooManyReloads;
                }
                std.debug.print("run-editor: reloading project '{s}' (iteration {d})\n", .{ project_path, reloads });
            },
            .exit => |code| {
                exit_code = code;
                break;
            },
        }
    }

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

/// Compile, JIT, and run one generation of the project.  Returns `.reload` when
/// the compiled e7 main requested a code swap, `.exit` otherwise.
fn runProjectOnce(
    allocator: std.mem.Allocator,
    options: Options,
    project_path: []const u8,
    reloads: i64,
) !Outcome {
    var compiled = compiler.pipeline.compileProject(allocator, project_path, .{}) catch |err| {
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
    defer compiled.deinit();
    if (!compiled.analysis.ok()) {
        for (compiled.analysis.diagnostics) |diagnostic| {
            std.debug.print("run-editor: {}:{}: {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
        return error.ProjectSemanticFailed;
    }
    if (options.verbose) {
        std.debug.print(
            "run-editor: project '{s}' ({d} files): {d} functions, {d} resources, {d} components, {d} plugins (generation {d})\n",
            .{
                project_path,
                compiled.owned_sources.len,
                compiled.bytecode.functions.len,
                compiled.analysis.resources.len,
                compiled.analysis.components.len,
                compiled.analysis.plugins.len,
                reloads,
            },
        );
    }

    // Reset the columnar world and re-register analysis metadata for this code
    // generation.  Compiled `main` also installs the same ids via its synthetic
    // `__e7_ecs_setup`, so this is host-side bookkeeping/validation only.
    ecs.e7_ecs_reset();
    for (compiled.analysis.resources) |resource| {
        if (resource.plugin_id != null) continue;
        if (ecs.e7_ecs_register_resource(resource.id, @intCast(resource.slots)) != 0) {
            return error.EcsRegisterFailed;
        }
    }
    for (compiled.analysis.components) |component| {
        if (ecs.e7_ecs_register_component(component.id, @intCast(component.slots)) != 0) {
            return error.EcsRegisterFailed;
        }
    }

    const serialized = try compiler.bytecode.encode(allocator, &compiled.bytecode);
    defer allocator.free(serialized);

    var jit = try orc.Jit.init(allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(serialized, "editor-project");

    const SetInline = *const fn (i64) callconv(.c) void;
    const set_inline = try jit.get(SetInline, "e7_task_set_inline");
    set_inline(1);
    const MainCtor = *const fn () callconv(.c) i64;
    const main_ctor = jit.get(MainCtor, "main") catch {
        std.debug.print("run-editor: compiled project has no callable `main`\n", .{});
        return error.MissingMain;
    };
    const handle = main_ctor();
    if (handle == 0) return error.MainTaskFailed;
    const result = task.e7_task_await(handle);
    if (result == reload_marker) return .reload;
    return .{ .exit = result };
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
        \\  --reload-test    request one code reload before the first run
        \\  --verbose        print project/metadata details per generation
        \\  -h, --help       show this help
        \\
    , .{});
}
