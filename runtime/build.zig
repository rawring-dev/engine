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
