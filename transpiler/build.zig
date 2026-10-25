const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The transpiler reuses engine7's real front end: lexer, parser, AST.
    const compiler = b.dependency("compiler", .{
        .target = target,
        .optimize = optimize,
    }).module("compiler");

    const transpiler = b.addModule("transpiler", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    transpiler.addImport("compiler", compiler);

    const exe = b.addExecutable(.{
        .name = "e7s",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("transpiler", transpiler);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the e7s transpiler");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = transpiler });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run transpiler tests");
    test_step.dependOn(&run_tests.step);
}
