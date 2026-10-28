const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zpars = b.dependency("zpars", .{
        .target = target,
        .optimize = optimize,
    }).module("zpars");

    const compiler = b.addModule("compiler", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    compiler.addImport("zpars", zpars);
    // LLVM's New Pass Manager is the iterative-compilation framework used by
    // `src/iterative.zig`. Linking the shared LLVM library keeps the pipeline
    // in-process and avoids shelling out to `opt`.
    compiler.linkSystemLibrary("LLVM-23", .{});

    const test_step = b.step("test", "Run compiler tests");
    const tests = b.addTest(.{ .root_module = compiler });
    // A plain Run inherits stdio and keeps the full per-test transcript (and
    // stderr notes such as the intrinsic audit) visible without the listen
    // protocol's spurious failure marker after a test writes to stderr.
    const run_tests = std.Build.Step.Run.create(b, "run compiler tests");
    run_tests.addArtifactArg(tests);
    run_tests.has_side_effects = true;
    test_step.dependOn(&run_tests.step);
}
