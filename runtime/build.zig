const std = @import("std");

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

    const runtime = b.addModule("runtime", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    runtime.addImport("scheduler", scheduler);
    runtime.addImport("compiler", compiler);
    runtime.addIncludePath(b.path("vendor"));
    runtime.linkSystemLibrary("LLVM-23", .{});
    // The scheduler is re-exported by runtime, so keep its native
    // dependencies available to downstream test/executable roots.
    runtime.linkSystemLibrary("lapack", .{});
    runtime.linkSystemLibrary("blas", .{});

    // Runtime FFI backends.  These are the multi-platform libraries used by the
    // intrinsic ABI: SDL3 windows, Vulkan surfaces, libcurl HTTP(S), ngtcp2
    // QUIC, libdatachannel WebRTC, and OpenSSL for QUIC's TLS 1.3 handshake.
    runtime.linkSystemLibrary("SDL3", .{});
    runtime.linkSystemLibrary("vulkan", .{});
    runtime.linkSystemLibrary("curl", .{});
    runtime.linkSystemLibrary("ssl", .{});
    runtime.linkSystemLibrary("crypto", .{});
    runtime.linkSystemLibrary("ngtcp2", .{});
    runtime.linkSystemLibrary("ngtcp2_crypto_ossl", .{});
    runtime.linkSystemLibrary("datachannel", .{});

    // Shader assets: `runtime/shaders/assets.zig` embeds the generated SPIR-V
    // from its own package directory.  `zig build shaders` regenerates the
    // .spv files from the HLSL-compatible Slang sources.
    const shader_assets = b.createModule(.{
        .root_source_file = b.path("shaders/assets.zig"),
    });
    runtime.addImport("shader_assets", shader_assets);

    const shader_step = b.step("shaders", "Compile runtime/shaders/*.slang to SPIR-V");
    const shader_build = b.addSystemCommand(&.{ "sh", b.pathFromRoot("shaders/build.sh") });
    shader_build.has_side_effects = true;
    shader_step.dependOn(&shader_build.step);

    // Native scene demo (`zig build run-scene` from the workspace root or
    // `zig build run-scene` here).  It links only SDL3 + Vulkan: the renderer,
    // window, and shader-asset modules have no compiler/JIT dependencies.
    const scene_demo = b.addExecutable(.{
        .name = "scene-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scene_demo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    scene_demo.root_module.addIncludePath(b.path("vendor"));
    scene_demo.root_module.addImport("shader_assets", shader_assets);
    scene_demo.root_module.linkSystemLibrary("SDL3", .{});
    scene_demo.root_module.linkSystemLibrary("vulkan", .{});
    // Generated SPIR-V must be current before the embedded shader module is
    // compiled into the demo.
    scene_demo.step.dependOn(&shader_build.step);
    b.installArtifact(scene_demo);

    const run_scene = b.addRunArtifact(scene_demo);
    if (b.args) |args| run_scene.addArgs(args);
    run_scene.has_side_effects = true;
    const run_scene_step = b.step("run-scene", "Build and run the Vulkan scene demo");
    run_scene_step.dependOn(&run_scene.step);

    const test_step = b.step("test", "Run runtime tests");
    const tests = b.addTest(.{ .root_module = runtime });
    // A plain Run inherits stdio and prints the full per-test transcript.  The
    // default `--listen=-` protocol hides it, and with runtime tests that start
    // worker threads it can report a spurious "failed command" after success.
    const run_tests = std.Build.Step.Run.create(b, "run runtime tests");
    run_tests.addArtifactArg(tests);
    run_tests.has_side_effects = true;
    test_step.dependOn(&run_tests.step);
}
