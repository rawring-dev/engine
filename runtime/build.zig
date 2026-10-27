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
    runtime.linkSystemLibrary("LLVM-23", .{});
    // The scheduler is re-exported by runtime, so keep its native
    // dependencies available to downstream test/executable roots.
    runtime.linkSystemLibrary("lapack", .{});
    runtime.linkSystemLibrary("blas", .{});

    // Runtime FFI backends: libcurl HTTP(S), ngtcp2 QUIC, libdatachannel
    // WebRTC, and OpenSSL for QUIC's TLS 1.3 handshake.  SDL3 and Vulkan are
    // deliberately absent: e7 platform code binds them at runtime through the
    // generic C FFI.
    runtime.linkSystemLibrary("curl", .{});
    runtime.linkSystemLibrary("ssl", .{});
    runtime.linkSystemLibrary("crypto", .{});
    runtime.linkSystemLibrary("ngtcp2", .{});
    runtime.linkSystemLibrary("ngtcp2_crypto_ossl", .{});
    runtime.linkSystemLibrary("datachannel", .{});
    // Image asset decoding (PNG via libpng, JPEG via libjpeg-turbo) and text
    runtime.linkSystemLibrary("png", .{});
    runtime.linkSystemLibrary("turbojpeg", .{});

    // Shader assets: the canonical sources are e7s files in engine/shaders;
    // `zig build shaders` transpiles them with the e7s CLI and refreshes the
    // checked-in .spv files here and in engine/shaders.
    const transpiler_dep = b.dependency("transpiler", .{
        .target = target,
        .optimize = optimize,
    });

    const shader_step = b.step("shaders", "Transpile engine/shaders/*.e7 and compile to SPIR-V");
    const shader_build = b.addSystemCommand(&.{ "sh", b.pathFromRoot("shaders/build.sh") });
    shader_build.addArtifactArg(transpiler_dep.artifact("e7s"));
    shader_build.has_side_effects = true;
    shader_step.dependOn(&shader_build.step);

    // `engine-run`: the executable host for the e7 engine project.  It loads
    // engine/main.e7, JITs it, and awaits its compiled main.  e7 platform code
    // owns SDL/Vulkan; the host only links the LLVM/JIT stack and the remaining
    // runtime FFI backends.
    const engine_run = b.addExecutable(.{
        .name = "engine-run",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine_run.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    engine_run.root_module.addImport("compiler", compiler);
    // The runtime's `Symbol` manifests live in intrinsics.zig, so the host
    // transitively references every FFI backend the runtime supports.
    engine_run.root_module.linkSystemLibrary("LLVM-23", .{});
    engine_run.root_module.linkSystemLibrary("lapack", .{});
    engine_run.root_module.linkSystemLibrary("blas", .{});
    engine_run.root_module.linkSystemLibrary("curl", .{});
    engine_run.root_module.linkSystemLibrary("ssl", .{});
    engine_run.root_module.linkSystemLibrary("crypto", .{});
    engine_run.root_module.linkSystemLibrary("ngtcp2", .{});
    engine_run.root_module.linkSystemLibrary("ngtcp2_crypto_ossl", .{});
    engine_run.root_module.linkSystemLibrary("datachannel", .{});
    engine_run.root_module.linkSystemLibrary("png", .{});
    engine_run.root_module.linkSystemLibrary("turbojpeg", .{});
    b.installArtifact(engine_run);

    const run_engine = b.addRunArtifact(engine_run);
    if (b.args) |args| run_engine.addArgs(args);
    run_engine.has_side_effects = true;
    const run_engine_step = b.step("run-engine", "Build and run the e7 engine project");
    run_engine_step.dependOn(&run_engine.step);

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
