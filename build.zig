const std = @import("std");

// Zig 0.16 toolchain [zig].
/// Workspace-level build graph.
///
/// Each subdirectory is also a standalone Zig package. The root build only
/// composes their public modules and test steps; project-specific compile
/// options and native link dependencies live in the subproject build files.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scheduler = b.dependency("scheduler", .{
        .target = target,
        .optimize = optimize,
    }).module("scheduler");
    const compiler = b.dependency("compiler", .{
        .target = target,
        .optimize = optimize,
    }).module("compiler");
    const transpiler_dep = b.dependency("transpiler", .{
        .target = target,
        .optimize = optimize,
    });
    const transpiler = transpiler_dep.module("transpiler");
    const runtime_dep = b.dependency("runtime", .{
        .target = target,
        .optimize = optimize,
    });
    const runtime = runtime_dep.module("runtime");

    const test_step = b.step("test", "Run scheduler, compiler, runtime, and transpiler tests");
    addTests(b, test_step, "scheduler", scheduler);
    addTests(b, test_step, "compiler", compiler);
    addTests(b, test_step, "runtime", runtime);
    addTests(b, test_step, "transpiler", transpiler);

    // Shader assets: the canonical sources are e7s files.  `zig build shaders`
    // transpiles them with the e7s CLI and compiles the generated Slang to
    // SPIR-V for both shader sets:
    //   * engine/shaders/       runtime scene shaders (also copied into
    //                           runtime/shaders for embedding);
    //   * engine/platform/      JIT-engine platform shaders (loaded from disk).
    // Checked-in SPIR-V keeps builds working without a shader compiler.
    const e7s_exe = transpiler_dep.artifact("e7s");
    const shaders_step = b.step("shaders", "Transpile all engine e7s shaders and compile to SPIR-V");
    const scene_shader_build = b.addSystemCommand(&.{ "sh", b.pathFromRoot("engine/shaders/build.sh") });
    scene_shader_build.addArtifactArg(e7s_exe);
    scene_shader_build.has_side_effects = true;
    shaders_step.dependOn(&scene_shader_build.step);
    const platform_shader_build = b.addSystemCommand(&.{
        "sh",
        b.pathFromRoot("engine/platform/shaders/build.sh"),
    });
    platform_shader_build.addArtifactArg(e7s_exe);
    platform_shader_build.has_side_effects = true;
    shaders_step.dependOn(&platform_shader_build.step);

    // Native Vulkan scene demo (`zig build run-scene [-- --frames N]`).  The
    // demo executable is defined by runtime/build.zig.
    const scene_demo = runtime_dep.artifact("scene-demo");
    const run_scene = b.addRunArtifact(scene_demo);
    if (b.args) |args| run_scene.addArgs(args);
    run_scene.has_side_effects = true;
    const run_scene_step = b.step("run-scene", "Build and run the Vulkan scene demo");
    run_scene_step.dependOn(&run_scene.step);

    // e7 engine host (`zig build run-engine [-- --frames 2 --headless --capture out.ppm]`).
    // The executable is defined by runtime/build.zig; this step forwards CLI
    // arguments and runs from the workspace root so `engine/main.e7` resolves.
    const engine_run = runtime_dep.artifact("engine-run");
    const run_engine = b.addRunArtifact(engine_run);
    if (b.args) |args| run_engine.addArgs(args);
    run_engine.has_side_effects = true;
    const run_engine_step = b.step("run-engine", "Compile and run the e7 engine project");
    run_engine_step.dependOn(&run_engine.step);

    // Convenience step that compiles and runs every module root directly.
    const check_step = b.step("check", "Compile and test all workspace modules");
    inline for (.{
        .{ "scheduler", scheduler },
        .{ "compiler", compiler },
        .{ "runtime", runtime },
        .{ "transpiler", transpiler },
    }) |entry| {
        const check = b.addTest(.{ .root_module = entry[1] });
        const run = std.Build.Step.Run.create(b, b.fmt("check {s} tests", .{entry[0]}));
        run.addArtifactArg(check);
        run.has_side_effects = true;
        check_step.dependOn(&run.step);
    }
}

fn addTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    name: []const u8,
    root_module: *std.Build.Module,
) void {
    const tests = b.addTest(.{ .root_module = root_module });
    // Plain Run: inherited stdio keeps the full per-test transcript visible and
    // avoids the listen-protocol's spurious failure marker after threaded tests.
    const run = std.Build.Step.Run.create(b, b.fmt("run {s} tests", .{name}));
    run.addArtifactArg(tests);
    run.has_side_effects = true;
    test_step.dependOn(&run.step);
}
