const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scheduler = b.addModule("scheduler", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Reference LAPACK/BLAS. Arch, Debian, and Homebrew all provide these
    // symlinks; systems with only a versioned .so can override the link name
    // in their own build invocation.
    scheduler.linkSystemLibrary("lapack", .{});
    scheduler.linkSystemLibrary("blas", .{});

    const test_step = b.step("test", "Run scheduler tests");
    const tests = b.addTest(.{ .root_module = scheduler });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
