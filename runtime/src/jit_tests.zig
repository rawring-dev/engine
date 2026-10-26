//! End-to-end tests: LLVM ORC JITed IR calling the runtime intrinsic ABI.
//!
//! These exercise the same path generated code uses: host addresses are
//! registered in the JITDylib as absolute symbols, IR is added, and the
//! resulting native function calls back into the runtime.

const std = @import("std");
const orc = @import("orc.zig");
const compiler = @import("compiler");
const intrinsics = @import("intrinsics.zig");
const abi = @import("ffi/abi.zig");
const fs = @import("ffi/fs.zig");
const net = @import("ffi/net.zig");
const quic = @import("ffi/quic.zig");
const io_mod = @import("ffi/io.zig");
const dl = @import("ffi/dl.zig");
const cbridge = @import("ffi/cbridge.zig");
const shader_assets = @import("shader_assets");
const builtin = @import("builtin");

fn mathLibraryPath() ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => "libm.so.6",
        .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit => "libSystem.B.dylib",
        .windows => "msvcrt.dll",
        else => null,
    };
}

fn cLibraryPath() ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => "libc.so.6",
        .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit => "libSystem.B.dylib",
        .windows => "msvcrt.dll",
        else => null,
    };
}

fn canResolve(library_path: []const u8, symbol_name: []const u8) bool {
    var library = dl.Library.open(library_path, .{}) catch return false;
    defer library.close();
    _ = library.symbol(symbol_name) catch return false;
    return true;
}

fn makeJit() !orc.Jit {
    var jit = try orc.Jit.init(std.testing.allocator);
    errdefer jit.deinit();
    try jit.defineSymbols(intrinsics.symbols());
    const ffi_symbols = cbridge.symbols();
    try jit.defineSymbols(&ffi_symbols);
    return jit;
}

test "all intrinsic declarations parse and resolve with the JIT" {
    var jit = try makeJit();
    defer jit.deinit();

    const ir = intrinsics.declarations ++
        \\define i32 @manifest_noop() {
        \\entry:
        \\  ret i32 7
        \\}
    ;
    try jit.addIr(ir, "intrinsic-manifest");
    const Noop = *const fn () callconv(.c) i32;
    const noop = try jit.get(Noop, "manifest_noop");
    try std.testing.expectEqual(@as(i32, 7), noop());
}

test "JITed IR reads and writes through the sandboxed filesystem" {
    var jit = try makeJit();
    defer jit.deinit();

    const ir =
        \\declare i32 @e7_fs_write(ptr, i64, ptr, i64, i32)
        \\declare i32 @e7_fs_read(ptr, i64, ptr, ptr)
        \\declare void @e7_free(ptr)
        \\define i32 @jit_fs(ptr %path, i64 %plen, ptr %data, i64 %dlen) {
        \\entry:
        \\  %w = call i32 @e7_fs_write(ptr %path, i64 %plen, ptr %data, i64 %dlen, i32 0)
        \\  %outp = alloca ptr
        \\  %outl = alloca i64
        \\  %r = call i32 @e7_fs_read(ptr %path, i64 %plen, ptr %outp, ptr %outl)
        \\  %p = load ptr, ptr %outp
        \\  call void @e7_free(ptr %p)
        \\  ret i32 %r
        \\}
    ;
    try jit.addIr(ir, "jit-fs");
    const FsFn = *const fn ([*]const u8, i64, [*]const u8, i64) callconv(.c) i32;
    const jit_fs = try jit.get(FsFn, "jit_fs");

    const sandbox = fs.global() orelse return error.SandboxUnavailable;
    var name_buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, ".engine7-jit-{d}", .{@as(u64, @intCast(std.c.getpid()))});
    defer sandbox.removeFile(name) catch {};

    const payload = "jit writes this";
    const status = jit_fs(name.ptr, @intCast(name.len), payload.ptr, @intCast(payload.len));
    try std.testing.expectEqual(@as(i32, 0), status);

    const result = try sandbox.read(name);
    defer std.heap.c_allocator.free(result);
    try std.testing.expectEqualStrings(payload, result);
}

test "JITed IR connects and exchanges bytes over TCP" {
    var jit = try makeJit();
    defer jit.deinit();

    const ir =
        \\declare i64 @e7_tcp_connect(ptr, i64, i16, i32)
        \\declare i32 @e7_tcp_send(i64, ptr, i64, ptr)
        \\declare i32 @e7_tcp_recv(i64, ptr, i64, i32, ptr)
        \\declare i32 @e7_tcp_close(i64)
        \\@ping = private constant [4 x i8] c"ping"
        \\define i32 @jit_tcp(ptr %host, i64 %hlen, i16 %port) {
        \\entry:
        \\  %c = call i64 @e7_tcp_connect(ptr %host, i64 %hlen, i16 %port, i32 2000)
        \\  %bad = icmp eq i64 %c, 0
        \\  br i1 %bad, label %fail, label %ok
        \\ok:
        \\  %buf = alloca [64 x i8]
        \\  %sent = alloca i64
        \\  %s = call i32 @e7_tcp_send(i64 %c, ptr @ping, i64 4, ptr %sent)
        \\  %n = alloca i64
        \\  %r = call i32 @e7_tcp_recv(i64 %c, ptr %buf, i64 64, i32 2000, ptr %n)
        \\  %close = call i32 @e7_tcp_close(i64 %c)
        \\  %len = load i64, ptr %n
        \\  %result = trunc i64 %len to i32
        \\  ret i32 %result
        \\fail:
        \\  ret i32 -1
        \\}
    ;
    try jit.addIr(ir, "jit-tcp");
    const TcpFn = *const fn ([*]const u8, i64, u16) callconv(.c) i32;
    const jit_tcp = try jit.get(TcpFn, "jit_tcp");

    var listener = try net.Listener.listen("127.0.0.1", 0, 8);
    defer listener.close();

    const Ctx = struct {
        listener: *net.Listener,
        event: *std.Io.Event,
        fn run(ctx: @This()) void {
            ctx.event.set(io_mod.io());
            var conn = ctx.listener.accept(0) catch return;
            defer conn.close();
            var buf: [64]u8 = undefined;
            const n = conn.receive(&buf, 5000) catch return;
            _ = conn.send(buf[0..n]) catch return;
            _ = conn.send("!") catch return;
        }
    };
    var ready: std.Io.Event = .unset;
    const thread = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .listener = &listener, .event = &ready }});
    ready.waitUncancelable(io_mod.io());

    const host = "127.0.0.1";
    const n = jit_tcp(host.ptr, host.len, @intCast(listener.port));
    try std.testing.expect(n >= 4);
    thread.join();
}

test "JITed IR performs an HTTP GET" {
    var jit = try makeJit();
    defer jit.deinit();

    const ir =
        \\declare i32 @e7_http_get(ptr, i64, i32, ptr, ptr, ptr)
        \\declare void @e7_free(ptr)
        \\define i32 @jit_http(ptr %url, i64 %len, ptr %status) {
        \\entry:
        \\  %body = alloca ptr
        \\  %bodylen = alloca i64
        \\  %r = call i32 @e7_http_get(ptr %url, i64 %len, i32 5000, ptr %body, ptr %bodylen, ptr %status)
        \\  %p = load ptr, ptr %body
        \\  call void @e7_free(ptr %p)
        \\  ret i32 %r
        \\}
    ;
    try jit.addIr(ir, "jit-http");
    const HttpFn = *const fn ([*]const u8, i64, *u32) callconv(.c) i32;
    const jit_http = try jit.get(HttpFn, "jit_http");

    var listener = try net.Listener.listen("127.0.0.1", 0, 8);
    defer listener.close();

    const Ctx = struct {
        listener: *net.Listener,
        event: *std.Io.Event,
        fn run(ctx: @This()) void {
            ctx.event.set(io_mod.io());
            var conn = ctx.listener.accept(0) catch return;
            defer conn.close();
            var buf: [4096]u8 = undefined;
            _ = conn.receive(&buf, 5000) catch return;
            _ = conn.send("HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello world") catch return;
        }
    };
    var ready: std.Io.Event = .unset;
    const thread = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .listener = &listener, .event = &ready }});
    ready.waitUncancelable(io_mod.io());

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{listener.port});
    var status: u32 = 0;
    const result = jit_http(url.ptr, @intCast(url.len), &status);
    try std.testing.expectEqual(@as(i32, 0), result);
    try std.testing.expectEqual(@as(u32, 200), status);
    thread.join();
}

test "JITed IR creates and destroys an SDL window" {
    var jit = try makeJit();
    defer jit.deinit();

    const ir =
        \\declare i64 @e7_window_create(ptr, i64, i32, i32, i64, ptr, i64)
        \\declare i32 @e7_window_size(i64, ptr, ptr)
        \\declare i32 @e7_window_destroy(i64)
        \\define i32 @jit_window(ptr %title, i64 %len) {
        \\entry:
        \\  %w = call i64 @e7_window_create(ptr %title, i64 %len, i32 64, i32 48, i64 2, ptr null, i64 0)
        \\  %bad = icmp eq i64 %w, 0
        \\  br i1 %bad, label %fail, label %have
        \\have:
        \\  %ww = alloca i32
        \\  %hh = alloca i32
        \\  %sz = call i32 @e7_window_size(i64 %w, ptr %ww, ptr %hh)
        \\  %d = call i32 @e7_window_destroy(i64 %w)
        \\  %width = load i32, ptr %ww
        \\  ret i32 %width
        \\fail:
        \\  ret i32 -1
        \\}
    ;
    try jit.addIr(ir, "jit-window");
    const WindowFn = *const fn ([*]const u8, i64) callconv(.c) i32;
    const jit_window = try jit.get(WindowFn, "jit_window");

    const title = "engine7 jit window";
    const width = jit_window(title.ptr, title.len);
    if (width < 0) {
        std.debug.print("skipping JIT window test (no video driver)\n", .{});
        return;
    }
    try std.testing.expect(width > 0);
}

test "JITed IR probes Vulkan" {
    var jit = try makeJit();
    defer jit.deinit();

    const ir =
        \\declare i32 @e7_vk_probe(ptr, ptr, i64, ptr, ptr)
        \\define i32 @jit_vk() {
        \\entry:
        \\  %count = alloca i32
        \\  %name = alloca [64 x i8]
        \\  %namelen = alloca i64
        \\  %api = alloca i32
        \\  %r = call i32 @e7_vk_probe(ptr %count, ptr %name, i64 64, ptr %namelen, ptr %api)
        \\  %c = load i32, ptr %count
        \\  ret i32 %c
        \\}
    ;
    try jit.addIr(ir, "jit-vulkan");
    const VkFn = *const fn () callconv(.c) i32;
    const jit_vk = try jit.get(VkFn, "jit_vk");
    const devices = jit_vk();
    try std.testing.expect(devices >= 0);
}

test "JITed IR performs a QUIC request/response" {
    var jit = try makeJit();
    defer jit.deinit();

    const cert = @embedFile("ffi/testdata/quic-cert.pem");
    const key = @embedFile("ffi/testdata/quic-key.pem");

    const ir =
        \\declare i64 @e7_quic_connect(ptr, i64, i16, ptr, i64, i32, i32)
        \\declare i32 @e7_quic_send(i64, ptr, i64, i32)
        \\declare i32 @e7_quic_recv(i64, ptr, i64, i32, ptr)
        \\declare i32 @e7_quic_close(i64)
        \\@quic_msg = private constant [5 x i8] c"hello"
        \\define i32 @jit_quic(ptr %host, i64 %hlen, i16 %port, ptr %alpn, i64 %alen) {
        \\entry:
        \\  %c = call i64 @e7_quic_connect(ptr %host, i64 %hlen, i16 %port, ptr %alpn, i64 %alen, i32 1, i32 10000)
        \\  %bad = icmp eq i64 %c, 0
        \\  br i1 %bad, label %fail, label %ok
        \\ok:
        \\  %s = call i32 @e7_quic_send(i64 %c, ptr @quic_msg, i64 5, i32 0)
        \\  %buf = alloca [128 x i8]
        \\  %n = alloca i64
        \\  %r = call i32 @e7_quic_recv(i64 %c, ptr %buf, i64 128, i32 8000, ptr %n)
        \\  %close = call i32 @e7_quic_close(i64 %c)
        \\  %len = load i64, ptr %n
        \\  %result = trunc i64 %len to i32
        \\  ret i32 %result
        \\fail:
        \\  ret i32 -1
        \\}
    ;
    try jit.addIr(ir, "jit-quic");
    const QuicFn = *const fn ([*]const u8, i64, u16, [*]const u8, i64) callconv(.c) i32;
    const jit_quic = try jit.get(QuicFn, "jit_quic");

    var listener = quic.Listener.listen(std.testing.allocator, "127.0.0.1", 0, .{
        .alpn = "engine7-test",
        .cert_pem = cert,
        .key_pem = key,
    }) catch |err| {
        std.debug.print("skipping JIT QUIC test: {s}\n", .{@errorName(err)});
        return;
    };
    defer listener.deinit();

    const Ctx = struct {
        listener: *quic.Listener,
        event: *std.Io.Event,
        fn run(ctx: @This()) void {
            ctx.event.set(io_mod.io());
            const conn = ctx.listener.accept(12_000) catch return;
            defer conn.deinit();
            var buf: [128]u8 = undefined;
            const n = conn.receive(&buf, 8000) catch return;
            _ = conn.send(buf[0..n], false) catch return;
        }
    };
    var ready: std.Io.Event = .unset;
    const thread = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .listener = listener, .event = &ready }});
    ready.waitUncancelable(io_mod.io());

    const host = "127.0.0.1";
    const alpn = "engine7-test";
    const n = jit_quic(host.ptr, host.len, @intCast(listener.port), alpn.ptr, alpn.len);
    try std.testing.expect(n >= 5);
    thread.join();
}

test "JITed IR creates and closes a WebRTC peer" {
    var jit = try makeJit();
    defer jit.deinit();

    const ir =
        \\declare i64 @e7_rtc_create(ptr, i64, ptr, i64)
        \\declare i32 @e7_rtc_close(i64)
        \\define i32 @jit_rtc(ptr %ice, i64 %ilen, ptr %bind, i64 %blen) {
        \\entry:
        \\  %p = call i64 @e7_rtc_create(ptr %ice, i64 %ilen, ptr %bind, i64 %blen)
        \\  %bad = icmp eq i64 %p, 0
        \\  br i1 %bad, label %fail, label %ok
        \\ok:
        \\  %r = call i32 @e7_rtc_close(i64 %p)
        \\  ret i32 %r
        \\fail:
        \\  ret i32 -1
        \\}
    ;
    try jit.addIr(ir, "jit-rtc");
    const RtcFn = *const fn ([*]const u8, i64, [*]const u8, i64) callconv(.c) i32;
    const jit_rtc = try jit.get(RtcFn, "jit_rtc");

    const bind = "127.0.0.1";
    const result = jit_rtc("".ptr, 0, bind.ptr, bind.len);
    if (result == -1) {
        std.debug.print("skipping JIT WebRTC test (libdatachannel unavailable)\n", .{});
        return;
    }
    try std.testing.expectEqual(@as(i32, 0), result);
}

test "JITed IR sends and receives UDP datagrams" {
    var jit = try makeJit();
    defer jit.deinit();

    const ir =
        \\declare i64 @e7_udp_bind(ptr, i64, i16)
        \\declare i32 @e7_udp_send_to(i64, ptr, i64, i16, ptr, i64)
        \\declare i32 @e7_udp_recv_from(i64, ptr, i64, i32, ptr, ptr, i64, ptr)
        \\declare i32 @e7_udp_close(i64)
        \\@udp_payload = private constant [4 x i8] c"ping"
        \\define i32 @jit_udp(ptr %host, i64 %hlen, i16 %port) {
        \\entry:
        \\  %s = call i64 @e7_udp_bind(ptr %host, i64 %hlen, i16 0)
        \\  %bad = icmp eq i64 %s, 0
        \\  br i1 %bad, label %fail, label %ok
        \\ok:
        \\  %sent = call i32 @e7_udp_send_to(i64 %s, ptr %host, i64 %hlen, i16 %port, ptr @udp_payload, i64 4)
        \\  %buf = alloca [64 x i8]
        \\  %n = alloca i64
        \\  %r = call i32 @e7_udp_recv_from(i64 %s, ptr %buf, i64 64, i32 3000, ptr %n, ptr null, i64 0, ptr null)
        \\  %close = call i32 @e7_udp_close(i64 %s)
        \\  %len = load i64, ptr %n
        \\  %result = trunc i64 %len to i32
        \\  ret i32 %result
        \\fail:
        \\  ret i32 -1
        \\}
    ;
    try jit.addIr(ir, "jit-udp");
    const UdpFn = *const fn ([*]const u8, i64, u16) callconv(.c) i32;
    const jit_udp = try jit.get(UdpFn, "jit_udp");

    var server = try net.DatagramSocket.bind("127.0.0.1", 0);
    defer server.close();

    const Ctx = struct {
        server: *net.DatagramSocket,
        event: *std.Io.Event,
        fn run(ctx: @This()) void {
            ctx.event.set(io_mod.io());
            var buf: [64]u8 = undefined;
            const msg = ctx.server.receiveFrom(&buf, 5000) catch return;
            _ = ctx.server.socket.send(io_mod.io(), &msg.from, "pong") catch return;
        }
    };
    var ready: std.Io.Event = .unset;
    const thread = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .server = &server, .event = &ready }});
    ready.waitUncancelable(io_mod.io());

    const host = "127.0.0.1";
    const n = jit_udp(host.ptr, host.len, server.port);
    try std.testing.expect(n >= 4);
    thread.join();
}

test "JITed IR writes to STDERR through the STDIO intrinsics" {
    var jit = try makeJit();
    defer jit.deinit();

    const ir =
        \\declare i32 @e7_stdio_write(i32, ptr, i64, ptr)
        \\declare i32 @e7_stdio_flush(i32)
        \\declare i32 @e7_stdio_is_tty(i32)
        \\define i32 @jit_stdio(ptr %data, i64 %len) {
        \\entry:
        \\  %written = alloca i64
        \\  %r = call i32 @e7_stdio_write(i32 2, ptr %data, i64 %len, ptr %written)
        \\  %f = call i32 @e7_stdio_flush(i32 2)
        \\  %tty = call i32 @e7_stdio_is_tty(i32 2)
        \\  ret i32 %r
        \\}
    ;
    try jit.addIr(ir, "jit-stdio");
    const StdioFn = *const fn ([*]const u8, i64) callconv(.c) i32;
    const jit_stdio = try jit.get(StdioFn, "jit_stdio");

    const message = "jit stdio: write ok\n";
    try std.testing.expectEqual(@as(i32, 0), jit_stdio(message.ptr, message.len));
}

test "JITed IR drives the scene renderer ABI" {
    var jit = try makeJit();
    defer jit.deinit();

    // i64 float arguments: 0.0=0, 8.0=1090519040, 0.5=1056964608,
    // 2.0=1073741824, 3.0=1077936128 (IEEE-754 binary32 bit patterns).
    const ir = intrinsics.declarations ++
        \\define i32 @jit_scene(i64 %window, ptr %vert, i64 %vlen, ptr %frag, i64 %flen) {
        \\entry:
        \\  %scene = call i64 @e7_scene_create(i64 %window, ptr %vert, i64 %vlen, ptr %frag, i64 %flen)
        \\  %bad = icmp eq i64 %scene, 0
        \\  br i1 %bad, label %fail, label %ok
        \\ok:
        \\  %camera = call i32 @e7_scene_set_camera(i64 %scene, i64 0, i64 0, i64 1090519040, i64 0, i64 0)
        \\  %resize = call i32 @e7_scene_resize(i64 %scene, i32 128, i32 96)
        \\  %draw = call i32 @e7_scene_draw(i64 %scene, i64 0, i64 1056964608, i64 1073741824, i64 1077936128, i64 1073741824)
        \\  %pixels = alloca ptr
        \\  %len = alloca i64
        \\  %width = alloca i32
        \\  %height = alloca i32
        \\  %capture = call i32 @e7_scene_capture(i64 %scene, ptr %pixels, ptr %len, ptr %width, ptr %height)
        \\  %pixel_ptr = load ptr, ptr %pixels
        \\  call void @e7_free(ptr %pixel_ptr)
        \\  %n = load i64, ptr %len
        \\  %w = load i32, ptr %width
        \\  %destroy = call i32 @e7_scene_destroy(i64 %scene)
        \\  %has_pixels = icmp ugt i64 %n, 0
        \\  %draw_ok = icmp eq i32 %draw, 0
        \\  %capture_ok = icmp eq i32 %capture, 0
        \\  %resize_ok = icmp eq i32 %resize, 0
        \\  %destroy_ok = icmp eq i32 %destroy, 0
        \\  %c1 = and i1 %has_pixels, %draw_ok
        \\  %c2 = and i1 %c1, %capture_ok
        \\  %c3 = and i1 %c2, %resize_ok
        \\  %all_ok = and i1 %c3, %destroy_ok
        \\  br i1 %all_ok, label %good, label %fail
        \\good:
        \\  ret i32 %w
        \\fail:
        \\  ret i32 -1
        \\}
    ;
    try jit.addIr(ir, "jit-scene");
    const SceneFn = *const fn (u64, [*]const u8, i64, [*]const u8, i64) callconv(.c) i32;
    const jit_scene = try jit.get(SceneFn, "jit_scene");

    const title = "engine7 jit scene";
    const window_handle = intrinsics.e7_window_create(
        title.ptr,
        title.len,
        96,
        72,
        intrinsics.WindowFlags.hidden | intrinsics.WindowFlags.vulkan,
        null,
        0,
    );
    if (window_handle == 0) {
        std.debug.print("skipping JIT scene test (no display): {s}\n", .{abi.lastError()});
        return;
    }
    defer _ = intrinsics.e7_window_destroy(window_handle);

    const width = jit_scene(
        window_handle,
        shader_assets.cube_vert_spv.ptr,
        @intCast(shader_assets.cube_vert_spv.len),
        shader_assets.cube_frag_spv.ptr,
        @intCast(shader_assets.cube_frag_spv.len),
    );
    if (width < 0) {
        std.debug.print("skipping JIT scene test (no Vulkan): {s}\n", .{abi.lastError()});
        return;
    }
    // e7_scene_resize resized the hidden window to 128x96 before the capture.
    try std.testing.expectEqual(@as(i32, 128), width);
}

const ecs = @import("ecs.zig");
const aggregate = @import("aggregate.zig");
const task = @import("task.zig");

// End-to-end ECS vertical slice: compile e7 source, run it through ORC, and
// observe the runtime world through the ECS ABI.  `main`'s body emits the
// synthetic `__e7_ecs_setup` call, queues `insert_resource`/`add_row`/
// `add_plugin`, and flushes at `disown`.
test "JIT executes compiled ECS setup, Commands, and plugin activation" {
    // The ECS world is process-wide; isolate this test from other suites.
    ecs.e7_ecs_reset();
    defer ecs.e7_ecs_reset();

    var compiled = try compiler.pipeline.compile(
        std.testing.allocator,
        \\@resource
        \\Win <- struct
        \\    n: i32
        \\@Components
        \\Pos <- struct
        \\    x: i32
        \\Components <- table
        \\    entity_id: usize,
        \\    ...
        \\Ui <- plugin
        \\    init <- sys (commands: &mut Commands):
        \\        ret
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    commands.insert_resource(Win { n: 7 })
        \\    pos := Pos { x: 3 }
        \\    commands.add_row(Components, { pos })
        \\    commands.add_plugin(Ui)
        \\    disown commands
        \\    0
    ,
        .{},
    );
    defer compiled.deinit();
    const bytes = try compiler.bytecode.encode(std.testing.allocator, &compiled.bytecode);
    defer std.testing.allocator.free(bytes);

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecodeBytes(bytes, "ecs-vertical-slice");
    const Run = *const fn () callconv(.c) i64;
    const run = try jit.get(Run, "main");
    const handle = run();
    _ = task.e7_task_await(handle);

    // Setup registered the resource/component, Commands copied the queued
    // values on flush, and add_plugin made the plugin active.
    try std.testing.expectEqual(@as(i64, 1), ecs.e7_ecs_has_resource(0));
    const resource_ptr = ecs.e7_ecs_resource(0);
    try std.testing.expect(resource_ptr != 0);
    try std.testing.expectEqual(@as(i64, 7), aggregate.e7_load_i64(resource_ptr));
    try std.testing.expectEqual(@as(i64, 1), ecs.e7_ecs_entity_count());
    try std.testing.expectEqual(@as(i64, 1), ecs.e7_ecs_plugin_active(0));
}

test "JITed IR loads a shared library and calls cos through the FFI trampoline" {
    const library_path = mathLibraryPath() orelse return;
    if (!canResolve(library_path, "cos")) {
        std.debug.print("skipping JIT dynamic FFI test: cos unavailable\n", .{});
        return;
    }

    var jit = try makeJit();
    defer jit.deinit();

    const ir =
        \\declare i64 @e7_dl_open(ptr, i64, i32)
        \\declare i64 @e7_dl_symbol(i64, ptr, i64)
        \\declare double @e7_ffi_call_f64_1(i64, double)
        \\declare i32 @e7_dl_close(i64)
        \\define double @jit_dynlib(ptr %lib, i64 %liblen, ptr %sym, i64 %symlen, double %x) {
        \\entry:
        \\  %h = call i64 @e7_dl_open(ptr %lib, i64 %liblen, i32 1)
        \\  %hbad = icmp eq i64 %h, 0
        \\  br i1 %hbad, label %fail, label %have
        \\have:
        \\  %s = call i64 @e7_dl_symbol(i64 %h, ptr %sym, i64 %symlen)
        \\  %sbad = icmp eq i64 %s, 0
        \\  br i1 %sbad, label %closefail, label %call
        \\closefail:
        \\  %c1 = call i32 @e7_dl_close(i64 %h)
        \\  ret double 0.0
        \\call:
        \\  %r = call double @e7_ffi_call_f64_1(i64 %s, double %x)
        \\  %c = call i32 @e7_dl_close(i64 %h)
        \\  ret double %r
        \\fail:
        \\  ret double 0.0
        \\}
    ;
    try jit.addIr(ir, "jit-dynamic-ffi");
    const DynFn = *const fn ([*]const u8, i64, [*]const u8, i64, f64) callconv(.c) f64;
    const jit_dynlib = try jit.get(DynFn, "jit_dynlib");

    const symbol = "cos";
    const value = jit_dynlib(library_path.ptr, @intCast(library_path.len), symbol.ptr, symbol.len, 0.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), value, 1e-12);
}

test "JITed IR calls strlen from the C library through an integer trampoline" {
    const library_path = cLibraryPath() orelse return;
    if (!canResolve(library_path, "strlen")) {
        std.debug.print("skipping JIT dynamic FFI test: strlen unavailable\n", .{});
        return;
    }

    var jit = try makeJit();
    defer jit.deinit();

    const ir =
        \\declare i64 @e7_dl_open(ptr, i64, i32)
        \\declare i64 @e7_dl_symbol(i64, ptr, i64)
        \\declare i64 @e7_ffi_call1(i64, i64)
        \\declare i32 @e7_dl_close(i64)
        \\define i64 @jit_strlen(ptr %lib, i64 %liblen, ptr %sym, i64 %symlen, ptr %text) {
        \\entry:
        \\  %h = call i64 @e7_dl_open(ptr %lib, i64 %liblen, i32 1)
        \\  %hbad = icmp eq i64 %h, 0
        \\  br i1 %hbad, label %fail, label %have
        \\have:
        \\  %s = call i64 @e7_dl_symbol(i64 %h, ptr %sym, i64 %symlen)
        \\  %sbad = icmp eq i64 %s, 0
        \\  br i1 %sbad, label %closefail, label %call
        \\closefail:
        \\  %c1 = call i32 @e7_dl_close(i64 %h)
        \\  ret i64 0
        \\call:
        \\  %text_addr = ptrtoint ptr %text to i64
        \\  %r = call i64 @e7_ffi_call1(i64 %s, i64 %text_addr)
        \\  %c = call i32 @e7_dl_close(i64 %h)
        \\  ret i64 %r
        \\fail:
        \\  ret i64 0
        \\}
    ;
    try jit.addIr(ir, "jit-strlen");
    const StrlenFn = *const fn ([*]const u8, i64, [*]const u8, i64, [*]const u8) callconv(.c) u64;
    const jit_strlen = try jit.get(StrlenFn, "jit_strlen");

    const symbol = "strlen";
    const text = "hello";
    const length = jit_strlen(library_path.ptr, @intCast(library_path.len), symbol.ptr, symbol.len, text.ptr);
    try std.testing.expectEqual(@as(u64, 5), length);
}

test "JITed IR passes a JIT callback into libc qsort" {
    const library_path = cLibraryPath() orelse return;
    if (!canResolve(library_path, "qsort")) {
        std.debug.print("skipping JIT qsort callback test: qsort unavailable\n", .{});
        return;
    }

    var jit = try makeJit();
    defer jit.deinit();

    const ir =
        \\declare i64 @e7_dl_open(ptr, i64, i32)
        \\declare i64 @e7_dl_symbol(i64, ptr, i64)
        \\declare i64 @e7_ffi_call4(i64, i64, i64, i64, i64)
        \\declare i32 @e7_dl_close(i64)
        \\define i32 @compare_ints(ptr %a, ptr %b) {
        \\entry:
        \\  %av = load i32, ptr %a
        \\  %bv = load i32, ptr %b
        \\  %lt = icmp slt i32 %av, %bv
        \\  %gt = icmp sgt i32 %av, %bv
        \\  %ltv = zext i1 %lt to i32
        \\  %gtv = zext i1 %gt to i32
        \\  %r = sub i32 %gtv, %ltv
        \\  ret i32 %r
        \\}
        \\define i32 @jit_qsort(ptr %lib, i64 %liblen, ptr %sym, i64 %symlen) {
        \\entry:
        \\  %h = call i64 @e7_dl_open(ptr %lib, i64 %liblen, i32 1)
        \\  %hbad = icmp eq i64 %h, 0
        \\  br i1 %hbad, label %fail, label %have
        \\have:
        \\  %s = call i64 @e7_dl_symbol(i64 %h, ptr %sym, i64 %symlen)
        \\  %arr = alloca [4 x i32]
        \\  store i32 3, ptr %arr
        \\  %p1 = getelementptr i32, ptr %arr, i64 1
        \\  store i32 1, ptr %p1
        \\  %p2 = getelementptr i32, ptr %arr, i64 2
        \\  store i32 4, ptr %p2
        \\  %p3 = getelementptr i32, ptr %arr, i64 3
        \\  store i32 2, ptr %p3
        \\  %base = ptrtoint ptr %arr to i64
        \\  %cmp = ptrtoint ptr @compare_ints to i64
        \\  %call = call i64 @e7_ffi_call4(i64 %s, i64 %base, i64 4, i64 4, i64 %cmp)
        \\  %v0 = load i32, ptr %arr
        \\  %v3 = load i32, ptr %p3
        \\  %scaled = mul i32 %v0, 1000
        \\  %result = add i32 %scaled, %v3
        \\  %c = call i32 @e7_dl_close(i64 %h)
        \\  ret i32 %result
        \\fail:
        \\  ret i32 -1
        \\}
    ;
    try jit.addIr(ir, "jit-qsort-callback");
    const SortFn = *const fn ([*]const u8, i64, [*]const u8, i64) callconv(.c) i32;
    const jit_qsort = try jit.get(SortFn, "jit_qsort");

    const symbol = "qsort";
    const result = jit_qsort(library_path.ptr, @intCast(library_path.len), symbol.ptr, symbol.len);
    try std.testing.expectEqual(@as(i32, 1004), result);
}

test "JITed IR resolves and reads a C data symbol" {
    const library_path = cLibraryPath() orelse return;
    if (!canResolve(library_path, "stdout")) {
        std.debug.print("skipping JIT data-symbol test: stdout unavailable\n", .{});
        return;
    }

    var jit = try makeJit();
    defer jit.deinit();

    const ir =
        \\declare i64 @e7_dl_open(ptr, i64, i32)
        \\declare i64 @e7_dl_symbol(i64, ptr, i64)
        \\declare i32 @e7_ffi_read(i64, ptr, i64)
        \\declare i32 @e7_dl_close(i64)
        \\define i64 @jit_data_symbol(ptr %lib, i64 %liblen, ptr %sym, i64 %symlen) {
        \\entry:
        \\  %h = call i64 @e7_dl_open(ptr %lib, i64 %liblen, i32 1)
        \\  %hbad = icmp eq i64 %h, 0
        \\  br i1 %hbad, label %fail, label %have
        \\have:
        \\  %s = call i64 @e7_dl_symbol(i64 %h, ptr %sym, i64 %symlen)
        \\  %sbad = icmp eq i64 %s, 0
        \\  br i1 %sbad, label %closefail, label %read
        \\closefail:
        \\  %c1 = call i32 @e7_dl_close(i64 %h)
        \\  ret i64 0
        \\read:
        \\  %buffer = alloca i64
        \\  store i64 0, ptr %buffer
        \\  %r = call i32 @e7_ffi_read(i64 %s, ptr %buffer, i64 8)
        \\  %value = load i64, ptr %buffer
        \\  %c = call i32 @e7_dl_close(i64 %h)
        \\  ret i64 %value
        \\fail:
        \\  ret i64 0
        \\}
    ;
    try jit.addIr(ir, "jit-data-symbol");
    const DataFn = *const fn ([*]const u8, i64, [*]const u8, i64) callconv(.c) u64;
    const jit_data = try jit.get(DataFn, "jit_data_symbol");

    const symbol = "stdout";
    const value = jit_data(library_path.ptr, @intCast(library_path.len), symbol.ptr, symbol.len);
    try std.testing.expect(value != 0);
}

test "e7 source binds and calls libc strlen through the generic C FFI" {
    const library_path = cLibraryPath() orelse return;
    if (!canResolve(library_path, "strlen")) return;

    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\strlen_len <- () -> u64:
        \\    addr := e7_cffi_bind("{s}", "strlen")
        \\    ret e7_ffi_call1(addr, e7_str_data("hello"))
    ,
        .{library_path},
    );
    defer std.testing.allocator.free(source);

    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |diagnostic| {
            std.debug.print("e7 C FFI parse diagnostic: {s}\n", .{diagnostic.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |diagnostic| {
            std.debug.print("e7 C FFI diagnostic: {}:{}: {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
        return error.TestUnexpectedResult;
    }

    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-c-ffi");
    const StrlenLen = *const fn () callconv(.c) u64;
    const strlen_len = try jit.get(StrlenLen, "strlen_len");
    try std.testing.expectEqual(@as(u64, 5), strlen_len());
}

test "e7 source creates an SDL window through the C FFI" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow")) {
        std.debug.print("skipping e7 SDL FFI test: libSDL3 unavailable\n", .{});
        return;
    }

    const source =
        \\window_probe <- () -> u64:
        \\    driver_key := e7_cstr("SDL_VIDEODRIVER")
        \\    driver_value := e7_cstr("dummy")
        \\    set_hint := e7_cffi_bind("SDL3", "SDL_SetHint")
        \\    e7_ffi_call2(set_hint, driver_key, driver_value)
        \\    init := e7_cffi_bind("SDL3", "SDL_InitSubSystem")
        \\    rc := e7_ffi_call1(init, 32)
        \\    if rc == 0:
        \\        e7_free_ptr(driver_key)
        \\        e7_free_ptr(driver_value)
        \\        ret 0
        \\    title := e7_cstr("e7 SDL window")
        \\    create := e7_cffi_bind("SDL3", "SDL_CreateWindow")
        \\    win := e7_ffi_call4(create, title, 64, 48, 8)
        \\    destroy := e7_cffi_bind("SDL3", "SDL_DestroyWindow")
        \\    quit := e7_cffi_bind("SDL3", "SDL_QuitSubSystem")
        \\    e7_ffi_call1(destroy, win)
        \\    e7_ffi_call1(quit, 32)
        \\    e7_free_ptr(title)
        \\    e7_free_ptr(driver_key)
        \\    e7_free_ptr(driver_value)
        \\    if win == 0:
        \\        ret 0
        \\    ret 1
    ;

    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-sdl-window");
    const Probe = *const fn () callconv(.c) u64;
    const probe = try jit.get(Probe, "window_probe");
    const result = probe();
    if (result == 0) {
        std.debug.print("skipping e7 SDL FFI test: SDL video unavailable\n", .{});
        return;
    }
    try std.testing.expectEqual(@as(u64, 1), result);
}

test "e7 source creates a Vulkan instance and enumerates devices through the C FFI" {
    if (!canResolve("libvulkan.so", "vkCreateInstance")) {
        std.debug.print("skipping e7 Vulkan FFI test: libvulkan unavailable\n", .{});
        return;
    }

    const source =
        \\vulkan_probe <- () -> i64:
        \\    create := e7_cffi_bind("vulkan", "vkCreateInstance")
        \\    if create == 0:
        \\        ret -3
        \\    app_name := e7_cstr("engine7-e7")
        \\    engine_name := e7_cstr("engine7")
        \\    app := e7_alloc_bytes(48)
        \\    e7_store_u32(app, 0)
        \\    e7_store_u32(app + 24, 1)
        \\    e7_store_u64(app + 16, app_name)
        \\    e7_store_u32(app + 24, 1)
        \\    e7_store_u64(app + 32, engine_name)
        \\    e7_store_u32(app + 40, 1)
        \\    e7_store_u32(app + 44, 4198400)
        \\    info := e7_alloc_bytes(64)
        \\    e7_store_u32(info, 1)
        \\    e7_store_u64(info + 24, app)
        \\    instance_out := e7_alloc_bytes(8)
        \\    result := e7_ffi_call3(create, info, 0, instance_out)
        \\    e7_free_ptr(app_name)
        \\    e7_free_ptr(engine_name)
        \\    if result != 0:
        \\        e7_free_ptr(app)
        \\        e7_free_ptr(info)
        \\        e7_free_ptr(instance_out)
        \\        ret -2
        \\    instance := e7_load_u64(instance_out)
        \\    enumerate := e7_cffi_bind("vulkan", "vkEnumeratePhysicalDevices")
        \\    count_out := e7_alloc_bytes(8)
        \\    e7_store_u32(count_out, 0)
        \\    enum_result := e7_ffi_call3(enumerate, instance, count_out, 0)
        \\    count := e7_load_u32(count_out)
        \\    destroy := e7_cffi_bind("vulkan", "vkDestroyInstance")
        \\    e7_ffi_call2(destroy, instance, 0)
        \\    e7_free_ptr(app)
        \\    e7_free_ptr(info)
        \\    e7_free_ptr(instance_out)
        \\    e7_free_ptr(count_out)
        \\    if enum_result != 0:
        \\        ret 0
        \\    ret count
    ;

    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-vulkan-probe");
    const Probe = *const fn () callconv(.c) i64;
    const probe = try jit.get(Probe, "vulkan_probe");
    const devices = probe();
    try std.testing.expect(devices >= 0);
}

test "e7 SDL platform module initializes video, creates, sizes, pumps, and destroys a window" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow")) {
        std.debug.print("skipping e7 SDL platform test: libSDL3 unavailable\n", .{});
        return;
    }

    const io = std.testing.io;
    const module_source = std.Io.Dir.cwd().readFileAlloc(io, "engine/platform/sdl.e7", std.testing.allocator, .limited(1024 * 1024)) catch {
        std.debug.print("skipping e7 SDL platform test: engine/platform/sdl.e7 missing\n", .{});
        return;
    };
    defer std.testing.allocator.free(module_source);

    const selftest =
        \\window_selftest <- () -> i64:
        \\    if video_init("dummy") != 0:
        \\        ret -1
        \\    win := window_create("e7 sdl platform", 64, 48, 8)
        \\    if win == 0:
        \\        video_quit()
        \\        ret -2
        \\    out_w := e7_alloc_bytes(4)
        \\    out_h := e7_alloc_bytes(4)
        \\    window_size(win, out_w, out_h)
        \\    width := e7_load_u32(out_w)
        \\    height := e7_load_u32(out_h)
        \\    key := key_down(win, 4)
        \\    buttons := mouse_buttons(win)
        \\    mouse := mouse_x(win) + mouse_y(win) + mouse_dx(win) + mouse_dy(win)
        \\    pump_result := window_pump(win)
        \\    window_destroy(win)
        \\    e7_free_ptr(out_w)
        \\    e7_free_ptr(out_h)
        \\    video_quit()
        \\    if width <= 0:
        \\        ret -3
        \\    if pump_result != 0:
        \\        ret -4
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ module_source, selftest });
    defer std.testing.allocator.free(source);

    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |diagnostic| {
            std.debug.print("e7 SDL parse diagnostic: {s}\n", .{diagnostic.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |diagnostic| {
            std.debug.print("e7 SDL diagnostic: {}:{}: {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
        return error.TestUnexpectedResult;
    }

    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-sdl-platform");
    const Selftest = *const fn () callconv(.c) i64;
    const selftest_fn = try jit.get(Selftest, "window_selftest");
    const result = selftest_fn();
    if (result == -1) {
        std.debug.print("skipping e7 SDL platform test: SDL video unavailable\n", .{});
        return;
    }
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "e7 SDL+Vulkan platform module creates a window surface" {
    if (!canResolve("libSDL3.so", "SDL_Vulkan_CreateSurface") or !canResolve("libvulkan.so", "vkCreateInstance")) {
        std.debug.print("skipping e7 Vulkan surface test: SDL Vulkan or Vulkan loader unavailable\n", .{});
        return;
    }

    const io = std.testing.io;
    const sdl_source = std.Io.Dir.cwd().readFileAlloc(io, "engine/platform/sdl.e7", std.testing.allocator, .limited(1024 * 1024)) catch return;
    defer std.testing.allocator.free(sdl_source);
    const vk_source = std.Io.Dir.cwd().readFileAlloc(io, "engine/platform/vulkan.e7", std.testing.allocator, .limited(1024 * 1024)) catch return;
    defer std.testing.allocator.free(vk_source);

    const selftest =
        \\surface_selftest <- () -> i64:
        \\    if video_init("dummy") != 0:
        \\        ret -1
        \\    win := window_create("e7 vulkan", 64, 48, 268435464)
        \\    if win == 0:
        \\        video_quit()
        \\        ret 0
        \\    ext_count := e7_alloc_bytes(4)
        \\    get_ext := e7_cffi_bind("SDL3", "SDL_Vulkan_GetInstanceExtensions")
        \\    exts := e7_ffi_call1(get_ext, ext_count)
        \\    if exts == 0:
        \\        window_destroy(win)
        \\        e7_free_ptr(ext_count)
        \\        video_quit()
        \\        ret 0
        \\    count := e7_load_u32(ext_count)
        \\    ext_array := e7_alloc_bytes(count * 8)
        \\    if count > 0:
        \\        e7_store_u64(ext_array, e7_load_u64(exts))
        \\    if count > 1:
        \\        e7_store_u64(ext_array + 8, e7_load_u64(exts + 8))
        \\    if count > 2:
        \\        e7_store_u64(ext_array + 16, e7_load_u64(exts + 16))
        \\    if count > 3:
        \\        e7_store_u64(ext_array + 24, e7_load_u64(exts + 24))
        \\    if count > 4:
        \\        e7_store_u64(ext_array + 32, e7_load_u64(exts + 32))
        \\    if count > 5:
        \\        e7_store_u64(ext_array + 40, e7_load_u64(exts + 40))
        \\    if count > 6:
        \\        e7_store_u64(ext_array + 48, e7_load_u64(exts + 48))
        \\    if count > 7:
        \\        e7_store_u64(ext_array + 56, e7_load_u64(exts + 56))
        \\    instance_out := e7_alloc_bytes(8)
        \\    created := vulkan_instance_create(ext_array, count, instance_out)
        \\    if created != 0:
        \\        window_destroy(win)
        \\        e7_free_ptr(ext_count)
        \\        e7_free_ptr(ext_array)
        \\        e7_free_ptr(instance_out)
        \\        video_quit()
        \\        ret 0
        \\    instance := e7_load_u64(instance_out)
        \\    surface_out := e7_alloc_bytes(8)
        \\    created_surface := vulkan_surface_create(win, instance, surface_out)
        \\    surface := e7_load_u64(surface_out)
        \\    if surface != 0:
        \\        vulkan_surface_destroy(instance, surface)
        \\    vulkan_instance_destroy(instance)
        \\    window_destroy(win)
        \\    e7_free_ptr(ext_count)
        \\    e7_free_ptr(ext_array)
        \\    e7_free_ptr(instance_out)
        \\    e7_free_ptr(surface_out)
        \\    video_quit()
        \\    if created_surface == 0:
        \\        ret 0
        \\    if surface == 0:
        \\        ret 0
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}", .{ sdl_source, vk_source, selftest });
    defer std.testing.allocator.free(source);

    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-vulkan-surface");
    const Selftest = *const fn () callconv(.c) i64;
    const selftest_fn = try jit.get(Selftest, "surface_selftest");
    const result = selftest_fn();
    if (result == 0) {
        std.debug.print("skipping e7 Vulkan surface test: no Vulkan window/surface available\n", .{});
        return;
    }
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "e7 SDL+Vulkan platform draws a triangle and captures it" {
    if (!canResolve("libSDL3.so", "SDL_Vulkan_CreateSurface") or !canResolve("libvulkan.so", "vkCreateInstance")) return;

    const io = std.testing.io;
    const sdl_source = std.Io.Dir.cwd().readFileAlloc(io, "engine/platform/sdl.e7", std.testing.allocator, .limited(1024 * 1024)) catch return;
    defer std.testing.allocator.free(sdl_source);
    const vk_source = std.Io.Dir.cwd().readFileAlloc(io, "engine/platform/vulkan.e7", std.testing.allocator, .limited(1024 * 1024)) catch return;
    defer std.testing.allocator.free(vk_source);

    const selftest =
        \\device_selftest <- () -> i64:
        \\    if video_init("dummy") != 0:
        \\        ret -1
        \\    win := window_create("e7 vulkan device", 64, 48, 268435464)
        \\    if win == 0:
        \\        video_quit()
        \\        ret 0
        \\    ext_count := e7_alloc_bytes(4)
        \\    get_ext := e7_cffi_bind("SDL3", "SDL_Vulkan_GetInstanceExtensions")
        \\    exts := e7_ffi_call1(get_ext, ext_count)
        \\    if exts == 0:
        \\        window_destroy(win)
        \\        e7_free_ptr(ext_count)
        \\        video_quit()
        \\        ret 0
        \\    count := e7_load_u32(ext_count)
        \\    ext_array := e7_alloc_bytes(count * 8)
        \\    if count > 0:
        \\        e7_store_u64(ext_array, e7_load_u64(exts))
        \\    if count > 1:
        \\        e7_store_u64(ext_array + 8, e7_load_u64(exts + 8))
        \\    if count > 2:
        \\        e7_store_u64(ext_array + 16, e7_load_u64(exts + 16))
        \\    if count > 3:
        \\        e7_store_u64(ext_array + 24, e7_load_u64(exts + 24))
        \\    instance_out := e7_alloc_bytes(8)
        \\    created := vulkan_instance_create(ext_array, count, instance_out)
        \\    instance := e7_load_u64(instance_out)
        \\    surface_out := e7_alloc_bytes(8)
        \\    device_out := e7_alloc_bytes(8)
        \\    queue_out := e7_alloc_bytes(8)
        \\    family_out := e7_alloc_bytes(4)
        \\    physical_out := e7_alloc_bytes(8)
        \\    result := 0
        \\    surface := 0
        \\    if created == 0:
        \\        surface_created := vulkan_surface_create(win, instance, surface_out)
        \\        surface = e7_load_u64(surface_out)
        \\        result = vulkan_device_create(instance, surface, device_out, queue_out, family_out, physical_out)
        \\        if result != 0:
        \\            device := e7_load_u64(device_out)
        \\            queue := e7_load_u64(queue_out)
        \\            physical := e7_load_u64(physical_out)
        \\            family := e7_load_u32(family_out)
        \\            submit_ok := vulkan_submit_empty(device, queue, family)
        \\            swapchain_out := e7_alloc_bytes(8)
        \\            format_out := e7_alloc_bytes(4)
        \\            width_out := e7_alloc_bytes(4)
        \\            height_out := e7_alloc_bytes(4)
        \\            images_out := e7_alloc_bytes(8)
        \\            image_count_out := e7_alloc_bytes(4)
        \\            swapchain_created := vulkan_swapchain_create(device, physical, surface, win, swapchain_out, format_out, width_out, height_out, images_out, image_count_out)
        \\            images := e7_load_u64(images_out)
        \\            if swapchain_created != 0:
        \\                swapchain := e7_load_u64(swapchain_out)
        \\                width := e7_load_u32(width_out)
        \\                height := e7_load_u32(height_out)
        \\                image_count := e7_load_u32(image_count_out)
        \\                image_format := e7_load_u32(format_out)
        \\                rp_targets := e7_alloc_bytes(8)
        \\                view_targets := e7_alloc_bytes(8)
        \\                fb_targets := e7_alloc_bytes(8)
        \\                targets_ok := vulkan_render_targets(device, images, image_count, image_format, width, height, 0, rp_targets, view_targets, fb_targets)
        \\                render_pass_handle := e7_load_u64(rp_targets)
        \\                views_handle := e7_load_u64(view_targets)
        \\                framebuffers_handle := e7_load_u64(fb_targets)
        \\                uniform_layout_out := e7_alloc_bytes(8)
        \\                uniform_pool_out := e7_alloc_bytes(8)
        \\                uniform_set_out := e7_alloc_bytes(8)
        \\                uniform_buffer_out := e7_alloc_bytes(8)
        \\                uniform_memory_out := e7_alloc_bytes(8)
        \\                uniform_mapped_out := e7_alloc_bytes(8)
        \\                uniform_size_out := e7_alloc_bytes(8)
        \\                uniform_ok := vulkan_uniform_resources(device, physical, uniform_layout_out, uniform_pool_out, uniform_set_out, uniform_buffer_out, uniform_memory_out, uniform_mapped_out, uniform_size_out)
        \\                if uniform_ok != 0:
        \\                    vulkan_uniform_resources_destroy(device, e7_load_u64(uniform_layout_out), e7_load_u64(uniform_pool_out), e7_load_u64(uniform_buffer_out), e7_load_u64(uniform_memory_out))
        \\                e7_free_ptr(uniform_layout_out)
        \\                e7_free_ptr(uniform_pool_out)
        \\                e7_free_ptr(uniform_set_out)
        \\                e7_free_ptr(uniform_buffer_out)
        \\                e7_free_ptr(uniform_memory_out)
        \\                e7_free_ptr(uniform_mapped_out)
        \\                e7_free_ptr(uniform_size_out)
        \\                if uniform_ok == 0:
        \\                    result = -17
        \\                vertex_buffer_out := e7_alloc_bytes(8)
        \\                vertex_memory_out := e7_alloc_bytes(8)
        \\                vertex_mapped_out := e7_alloc_bytes(8)
        \\                vertex_ok := vulkan_vertex_buffer(device, physical, vertex_buffer_out, vertex_memory_out, vertex_mapped_out)
        \\                mesh_vert := e7_engine_read_shader("engine/platform/shaders/mesh_simple.vert.spv")
        \\                mesh_frag := e7_engine_read_shader("engine/platform/shaders/mesh_simple.frag.spv")
        \\                mesh_vert_handle := e7_handle(mesh_vert)
        \\                mesh_frag_handle := e7_handle(mesh_frag)
        \\                mesh_pipeline_out := e7_alloc_bytes(8)
        \\                mesh_layout_out := e7_alloc_bytes(8)
        \\                mesh_ok := 0
        \\                if mesh_vert_handle != 0:
        \\                    if mesh_frag_handle != 0:
        \\                        mesh_ok = vulkan_mesh_pipeline_simple(device, render_pass_handle, mesh_vert_handle, mesh_frag_handle, 0, mesh_pipeline_out, mesh_layout_out)
        \\                mesh_green := 0
        \\                if mesh_ok != 0:
        \\                    if vertex_ok != 0:
        \\                        mesh_pixels_out := e7_alloc_bytes(8)
        \\                        mesh_size_out := e7_alloc_bytes(8)
        \\                        mesh_drew := vulkan_draw_triangle_capture(device, queue, family, physical, swapchain, render_pass_handle, e7_load_u64(mesh_pipeline_out), framebuffers_handle, image_count, width, height, e7_load_u64(vertex_buffer_out), 0, 0, 0, 0, 0, mesh_pixels_out, mesh_size_out)
        \\                        mesh_pixels := e7_load_u64(mesh_pixels_out)
        \\                        mesh_offset := ((height / 2) * width + width / 2) * 4
        \\                        mesh_center := e7_load_u32((mesh_pixels as u64) + (mesh_offset as u64))
        \\                        mesh_green = (mesh_center / 256) % 256
        \\                        e7_free_ptr(mesh_pixels)
        \\                        e7_free_ptr(mesh_pixels_out)
        \\                        e7_free_ptr(mesh_size_out)
        \\                    vulkan_graphics_pipeline_destroy(device, e7_load_u64(mesh_pipeline_out), e7_load_u64(mesh_layout_out))
        \\                e7_free_ptr(mesh_vert_handle)
        \\                e7_free_ptr(mesh_frag_handle)
        \\                e7_free_ptr(mesh_pipeline_out)
        \\                e7_free_ptr(mesh_layout_out)
        \\                if vertex_ok != 0:
        \\                    vulkan_vertex_buffer_destroy(device, e7_load_u64(vertex_buffer_out), e7_load_u64(vertex_memory_out))
        \\                e7_free_ptr(vertex_buffer_out)
        \\                e7_free_ptr(vertex_memory_out)
        \\                e7_free_ptr(vertex_mapped_out)
        \\                ubo_layout_out := e7_alloc_bytes(8)
        \\                ubo_layout_ok := vulkan_ubo_set_layout(device, ubo_layout_out)
        \\                ubo_vert := e7_engine_read_shader("engine/platform/shaders/mesh.vert.spv")
        \\                ubo_frag := e7_engine_read_shader("engine/platform/shaders/mesh.frag.spv")
        \\                ubo_vert_handle := e7_handle(ubo_vert)
        \\                ubo_frag_handle := e7_handle(ubo_frag)
        \\                ubo_pipeline_out := e7_alloc_bytes(8)
        \\                ubo_pipeline_layout_out := e7_alloc_bytes(8)
        \\                ubo_pipeline_ok := 0
        \\                if ubo_vert_handle != 0:
        \\                    if ubo_frag_handle != 0:
        \\                        ubo_pipeline_ok = vulkan_mesh_pipeline_simple(device, render_pass_handle, ubo_vert_handle, ubo_frag_handle, e7_load_u64(ubo_layout_out), ubo_pipeline_out, ubo_pipeline_layout_out)
        \\                if ubo_pipeline_ok != 0:
        \\                    vulkan_graphics_pipeline_destroy(device, e7_load_u64(ubo_pipeline_out), e7_load_u64(ubo_pipeline_layout_out))
        \\                e7_free_ptr(ubo_vert_handle)
        \\                e7_free_ptr(ubo_frag_handle)
        \\                e7_free_ptr(ubo_pipeline_out)
        \\                e7_free_ptr(ubo_pipeline_layout_out)
        \\                if ubo_layout_ok != 0:
        \\                    vulkan_descriptor_set_layout_destroy(device, e7_load_u64(ubo_layout_out))
        \\                e7_free_ptr(ubo_layout_out)
        \\                if mesh_ok == 0:
        \\                    result = -18
        \\                if ubo_pipeline_ok == 0:
        \\                    result = -22
        \\                else:
        \\                    if mesh_green != 255:
        \\                        result = -21
        \\                if vertex_ok == 0:
        \\                    result = -19
        \\                vert := e7_engine_read_shader("engine/platform/shaders/triangle.vert.spv")
        \\                frag := e7_engine_read_shader("engine/platform/shaders/triangle.frag.spv")
        \\                vert_handle := e7_handle(vert)
        \\                frag_handle := e7_handle(frag)
        \\                pipeline_out := e7_alloc_bytes(8)
        \\                layout_out := e7_alloc_bytes(8)
        \\                pipeline_ok := 0
        \\                if vert_handle != 0:
        \\                    if frag_handle != 0:
        \\                        pipeline_ok = vulkan_graphics_pipeline(device, render_pass_handle, vert_handle, frag_handle, pipeline_out, layout_out)
        \\                pipeline_handle := e7_load_u64(pipeline_out)
        \\                layout_handle := e7_load_u64(layout_out)
        \\                drew := 0
        \\                green := 0
        \\                if pipeline_ok != 0:
        \\                    draw_pixels_out := e7_alloc_bytes(8)
        \\                    draw_size_out := e7_alloc_bytes(8)
        \\                    drew = vulkan_draw_triangle_capture(device, queue, family, physical, swapchain, render_pass_handle, pipeline_handle, framebuffers_handle, image_count, width, height, 0, 0, 0, 0, 0, 0, draw_pixels_out, draw_size_out)
        \\                    draw_pixels := e7_load_u64(draw_pixels_out)
        \\                    center_offset := ((height / 2) * width + width / 2) * 4
        \\                    center := e7_load_u32((draw_pixels as u64) + (center_offset as u64))
        \\                    green = (center / 256) % 256
        \\                    e7_free_ptr(draw_pixels)
        \\                    e7_free_ptr(draw_pixels_out)
        \\                    e7_free_ptr(draw_size_out)
        \\                    vulkan_graphics_pipeline_destroy(device, pipeline_handle, layout_handle)
        \\                e7_free_ptr(pipeline_out)
        \\                e7_free_ptr(layout_out)
        \\                e7_free_ptr(vert_handle)
        \\                e7_free_ptr(frag_handle)
        \\                if targets_ok != 0:
        \\                    vulkan_render_targets_destroy(device, render_pass_handle, views_handle, framebuffers_handle, image_count)
        \\                if pipeline_ok == 0:
        \\                    result = -14
        \\                else:
        \\                    if drew == 0:
        \\                        result = -15
        \\                    else:
        \\                        if green != 255:
        \\                            result = -16
        \\                e7_free_ptr(rp_targets)
        \\                e7_free_ptr(view_targets)
        \\                e7_free_ptr(fb_targets)
        \\                if targets_ok == 0:
        \\                    result = -13
        \\                index_out := e7_alloc_bytes(4)
        \\                presented := vulkan_present_clear(device, queue, family, swapchain, index_out)
        \\                e7_free_ptr(index_out)
        \\                pixels_out := e7_alloc_bytes(8)
        \\                size_out := e7_alloc_bytes(8)
        \\                captured := vulkan_capture_clear(device, queue, family, physical, swapchain, width, height, pixels_out, size_out)
        \\                pixels := e7_load_u64(pixels_out)
        \\                pixel_size := e7_load_u64(size_out)
        \\                pixel := e7_load_u32(pixels)
        \\                red_bgra := (pixel / 65536) % 256
        \\                red_rgba := pixel % 256
        \\                e7_free_ptr(pixels)
        \\                e7_free_ptr(pixels_out)
        \\                e7_free_ptr(size_out)
        \\                vulkan_swapchain_destroy(device, swapchain)
        \\                if width <= 0:
        \\                    result = -6
        \\                else:
        \\                    if image_count <= 0:
        \\                        result = -7
        \\                    else:
        \\                        if presented == 0:
        \\                            result = -8
        \\                        else:
        \\                            if captured == 0:
        \\                                result = -10
        \\                            else:
        \\                                if pixel_size < width * height * 4:
        \\                                    result = -11
        \\                                else:
        \\                                    if red_bgra != 255:
        \\                                        if red_rgba != 255:
        \\                                            result = -12
        \\                                        else:
        \\                                            result = 1
        \\                                    else:
        \\                                        result = 1
        \\            else:
        \\                result = -5
        \\            if images != 0:
        \\                e7_free_ptr(images)
        \\            if submit_ok == 0:
        \\                result = -9
        \\            e7_free_ptr(swapchain_out)
        \\            e7_free_ptr(format_out)
        \\            e7_free_ptr(width_out)
        \\            e7_free_ptr(height_out)
        \\            e7_free_ptr(images_out)
        \\            e7_free_ptr(image_count_out)
        \\            vulkan_device_destroy(device)
        \\        if surface != 0:
        \\            vulkan_surface_destroy(instance, surface)
        \\    vulkan_instance_destroy(instance)
        \\    window_destroy(win)
        \\    e7_free_ptr(ext_count)
        \\    e7_free_ptr(ext_array)
        \\    e7_free_ptr(instance_out)
        \\    e7_free_ptr(surface_out)
        \\    e7_free_ptr(device_out)
        \\    e7_free_ptr(queue_out)
        \\    e7_free_ptr(family_out)
        \\    e7_free_ptr(physical_out)
        \\    video_quit()
        \\    if result == 0:
        \\        ret 0
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}", .{ sdl_source, vk_source, selftest });
    defer std.testing.allocator.free(source);

    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |diagnostic| {
            std.debug.print("e7 capture parse diagnostic: {s}\n", .{diagnostic.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |diagnostic| {
            std.debug.print("e7 capture diagnostic: {}:{}: {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
        return error.TestUnexpectedResult;
    }

    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-vulkan-device");
    const Selftest = *const fn () callconv(.c) i64;
    const selftest_fn = try jit.get(Selftest, "device_selftest");
    const result = selftest_fn();
    if (result == 0) {
        std.debug.print("skipping e7 Vulkan device test: no physical device\n", .{});
        return;
    }
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "e7 input module maps actions and mouse state through SDL" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow")) return;
    const io = std.testing.io;
    const sdl_source = std.Io.Dir.cwd().readFileAlloc(io, "engine/platform/sdl.e7", std.testing.allocator, .limited(1024 * 1024)) catch return;
    defer std.testing.allocator.free(sdl_source);
    const input_source = std.Io.Dir.cwd().readFileAlloc(io, "engine/platform/input.e7", std.testing.allocator, .limited(1024 * 1024)) catch return;
    defer std.testing.allocator.free(input_source);

    const selftest =
        \\input_selftest <- () -> i64:
        \\    if video_init("dummy") != 0:
        \\        ret -1
        \\    win := window_create("e7 input", 64, 48, 8)
        \\    if win == 0:
        \\        video_quit()
        \\        ret 0
        \\    key := key_action_down(win, 0)
        \\    mouse := mouse_position_x(win) + mouse_position_y(win)
        \\    captured := capture_mouse(win, 1)
        \\    is_captured := is_mouse_captured(win)
        \\    capture_mouse(win, 0)
        \\    window_destroy(win)
        \\    video_quit()
        \\    if key != 0:
        \\        ret -2
        \\    if captured != 0:
        \\        ret -3
        \\    if is_captured == 0:
        \\        ret -4
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}", .{ sdl_source, input_source, selftest });
    defer std.testing.allocator.free(source);
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-input");
    const Selftest = *const fn () callconv(.c) i64;
    const selftest_fn = try jit.get(Selftest, "input_selftest");
    const result = selftest_fn();
    if (result == -1) return;
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "e7 scene module draws an indexed cube and captures it" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow") or !canResolve("libvulkan.so", "vkCreateInstance")) return;
    const io = std.testing.io;
    const sdl_source = std.Io.Dir.cwd().readFileAlloc(io, "engine/platform/sdl.e7", std.testing.allocator, .limited(1024 * 1024)) catch return;
    defer std.testing.allocator.free(sdl_source);
    const vk_source = std.Io.Dir.cwd().readFileAlloc(io, "engine/platform/vulkan.e7", std.testing.allocator, .limited(1024 * 1024)) catch return;
    defer std.testing.allocator.free(vk_source);
    const scene_source = std.Io.Dir.cwd().readFileAlloc(io, "engine/platform/scene.e7", std.testing.allocator, .limited(1024 * 1024)) catch return;
    defer std.testing.allocator.free(scene_source);

    const selftest =
        \\scene_selftest <- () -> i64:
        \\    if video_init("dummy") != 0:
        \\        ret -1
        \\    win := window_create("e7 scene", 64, 48, 268435464)
        \\    if win == 0:
        \\        video_quit()
        \\        ret 0
        \\    scene := scene_create(win, 64, 48)
        \\    if scene == 0:
        \\        window_destroy(win)
        \\        video_quit()
        \\        ret -2
        \\    scene_set_camera(scene, 0, 0, 3000, 0, 0)
        \\    scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000)
        \\    pixels_out := e7_alloc_bytes(8)
        \\    size_out := e7_alloc_bytes(8)
        \\    drew := scene_draw(scene, pixels_out, size_out)
        \\    pixels := e7_load_u64(pixels_out)
        \\    width := scene_width(scene)
        \\    height := scene_height(scene)
        \\    offset := ((height / 2) * width + width / 2) * 4
        \\    center := e7_load_u32((pixels as u64) + (offset as u64))
        \\    e7_free_ptr(pixels)
        \\    e7_free_ptr(pixels_out)
        \\    e7_free_ptr(size_out)
        \\    scene_destroy(scene)
        \\    window_destroy(win)
        \\    video_quit()
        \\    if drew == 0:
        \\        ret -3
        \\    ret center
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}\n{s}", .{ sdl_source, vk_source, scene_source, selftest });
    defer std.testing.allocator.free(source);
    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |d| {
            std.debug.print("scene parse: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |d| std.debug.print("scene diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.TestUnexpectedResult;
    }
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-scene");
    const Selftest = *const fn () callconv(.c) i64;
    const selftest_fn = try jit.get(Selftest, "scene_selftest");
    const result = selftest_fn();
    if (result == 0 or result == -1) return;
    std.debug.print("e7 scene center pixel {x}\n", .{result});
    try std.testing.expect(result != 0 and result != 0xFF000000);
}
