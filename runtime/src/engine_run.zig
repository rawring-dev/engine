//! `run-engine`: compile the e7 engine project, JIT it, and run its `main`.
//!
//!     zig build run-engine
//!     zig build run-engine -- --frames 2 --headless --capture /tmp/frame.ppm
//!
//! The host loads `engine/main.e7` (plus sibling `ui.e7`) through
//! `compiler.pipeline.compileProject`, registers ECS world metadata from the
//! analysis, JITs the bytecode with the runtime/ECS/engine symbol manifests, and
//! awaits the compiled async `main`.  The e7 side creates the window/scene with
//! the compiler-known `e7_engine_*` intrinsics; `--frames` drives the
//! deterministic frame limiter and `--capture` writes the captured PPM frame.

const std = @import("std");
const compiler = @import("compiler");
const orc = @import("orc.zig");
const task = @import("task.zig");
const ecs = @import("ecs.zig");
const engine = @import("engine.zig");

const default_project = "engine/main.e7";

const Options = struct {
    project: []const u8 = default_project,
    project_explicit: bool = false,
    frames: i64 = 0,
    headless: bool = false,
    capture_path: ?[]const u8 = null,
    verbose: bool = false,
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
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else {
            std.debug.print("run-engine: unknown argument '{s}'\n", .{arg});
            return usageError("unknown argument");
        }
    }
    if (options.frames == 0 and options.capture_path != null) options.frames = 2;
    if (options.frames > 0) options.headless = true;
    if (!options.headless) {
        std.debug.print("run-engine: first-person (WASD move, mouse look, Space jump, E interact); Esc frees the mouse, click the world to recapture, window close exits\n", .{});
    }

    const allocator = std.heap.c_allocator;

    // The host is runnable from the workspace root (`zig build run-engine`) and
    // from the runtime package directory; resolve the default project against
    // both layouts unless `--project` was given explicitly.
    const project_path = try resolveProjectPath(init.io, options);

    engine.reset();
    engine.setHeadless(options.headless);
    engine.setMaxFrames(options.frames);
    engine.setCaptureEnabled(options.capture_path != null);
    defer engine.shutdown();

    var compiled = compiler.pipeline.compileProject(allocator, project_path, .{}) catch |err| {
        if (err == error.SemanticFailed) {
            if (compiler.pipeline.loadProject(allocator, project_path)) |loaded| {
                var project = loaded;
                defer project.deinit();
                if (compiler.semantic.analyze(allocator, project.root_ast.module)) |analysis| {
                    var owned = analysis;
                    defer owned.deinit();
                    for (owned.diagnostics) |diagnostic| {
                        std.debug.print("run-engine: {}:{}: {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
                    }
                } else |_| {}
            } else |_| {}
        }
        std.debug.print("run-engine: failed to compile project '{s}': {s}\n", .{ project_path, @errorName(err) });
        return error.ProjectCompileFailed;
    };
    defer compiled.deinit();
    if (!compiled.analysis.ok()) {
        for (compiled.analysis.diagnostics) |diagnostic| {
            std.debug.print("run-engine: {}:{}: {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
        return error.ProjectSemanticFailed;
    }
    if (options.verbose) {
        std.debug.print(
            "run-engine: project '{s}' ({d} files): {d} functions, {d} resources, {d} components, {d} plugins\n",
            .{
                project_path,
                compiled.owned_sources.len,
                compiled.bytecode.functions.len,
                compiled.analysis.resources.len,
                compiled.analysis.components.len,
                compiled.analysis.plugins.len,
            },
        );
    }

    // Initialize the ECS world from analysis metadata.  Compiled `main` calls
    // the synthetic `__e7_ecs_setup` too (which resets and re-registers the
    // same ids), so this is mainly a host-side contract check that the
    // metadata is exposed and usable.
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
    try jit.addBytecodeBytes(serialized, "engine-project");

    const MainCtor = *const fn () callconv(.c) i64;
    const main_ctor = jit.get(MainCtor, "main") catch {
        std.debug.print("run-engine: compiled project has no callable `main`\n", .{});
        return error.MissingMain;
    };
    const handle = main_ctor();
    if (handle == 0) return error.MainTaskFailed;
    _ = task.e7_task_await(handle);

    if (options.verbose) {
        const stats = engine.renderStats();
        std.debug.print("run-engine: scene_draws={d} scene_boxes={d} textures={d} meshes={d} failed={d} frames={d}\n", .{ stats.scene_draws, stats.scene_boxes, stats.scene_textures, stats.scene_meshes, stats.scene_failed_draws, engine.frames() });
    }
    if (engine.lastFailure()) |message| {
        std.debug.print("run-engine: engine stopped: {s}\n", .{message});
        if (options.capture_path != null) return error.EngineUnavailable;
        return;
    }

    if (options.capture_path) |path| {
        var capture = engine.takeCapture() orelse {
            std.debug.print("run-engine: no frame captured (window/scene creation failed?)\n", .{});
            return error.NoCapture;
        };
        defer capture.deinit();
        try engine.writePpm(init.io, path, capture);
        std.debug.print(
            "run-engine: wrote {s} ({d}x{d}, {d} frames{s})\n",
            .{
                path,
                capture.width,
                capture.height,
                engine.frames(),
                if (engine.captureHasContent(capture)) "" else ", empty frame",
            },
        );
        if (!engine.captureHasContent(capture)) return error.CaptureEmpty;
    } else if (options.verbose) {
        std.debug.print("run-engine: main completed after {d} frames\n", .{engine.frames()});
    }
}

fn resolveProjectPath(io: std.Io, options: Options) ![]const u8 {
    if (options.project_explicit) return options.project;
    const candidates = [_][]const u8{
        options.project,
        "../engine/main.e7",
        "../../engine/main.e7",
    };
    for (candidates) |candidate| {
        var probe = std.Io.Dir.cwd().openFile(io, candidate, .{}) catch continue;
        probe.close(io);
        return candidate;
    }
    return options.project;
}

fn usageError(message: []const u8) error{InvalidArguments} {
    std.debug.print("run-engine: {s}\n", .{message});
    printHelp();
    return error.InvalidArguments;
}

fn printHelp() void {
    std.debug.print(
        \\Usage: run-engine [options]
        \\
        \\  --project PATH   e7 project root (default: engine/main.e7)
        \\  --frames N       exit after N frames (enables the frame limiter)
        \\  --headless       hidden window (implied by --frames/--capture)
        \\  --capture PATH   write the last rendered frame as a PPM (P6) image
        \\  --verbose        print project/metadata details
        \\  -h, --help       show this help
        \\
    , .{});
}
