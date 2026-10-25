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
    const runtime_dep = b.dependency("runtime", .{
        .target = target,
        .optimize = optimize,
    });
    const runtime = runtime_dep.module("runtime");

    const test_step = b.step("test", "Run scheduler, compiler, and runtime tests");
    addTests(b, test_step, "scheduler", scheduler);
    addTests(b, test_step, "compiler", compiler);
    addTests(b, test_step, "runtime", runtime);

    // Shader assets for the native scene demo.  Sources live in
    // runtime/shaders/*.slang; build.sh embeds/regenerates the checked-in
    // SPIR-V so builds work without slangc installed.
    const shaders_step = b.step("shaders", "Compile runtime/shaders/*.slang to SPIR-V");
    const shader_build = b.addSystemCommand(&.{ "sh", b.pathFromRoot("runtime/shaders/build.sh") });
    shader_build.has_side_effects = true;
    shaders_step.dependOn(&shader_build.step);

    // Native Vulkan scene demo (`zig build run-scene [-- --frames N]`).  The
    // demo executable is defined by runtime/build.zig.
    const scene_demo = runtime_dep.artifact("scene-demo");
    const run_scene = b.addRunArtifact(scene_demo);
    if (b.args) |args| run_scene.addArgs(args);
    run_scene.has_side_effects = true;
    const run_scene_step = b.step("run-scene", "Build and run the Vulkan scene demo");
    run_scene_step.dependOn(&run_scene.step);

    // Convenience step that compiles and runs every module root directly.
    const check_step = b.step("check", "Compile and test all workspace modules");
    inline for (.{
        .{ "scheduler", scheduler },
        .{ "compiler", compiler },
        .{ "runtime", runtime },
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
