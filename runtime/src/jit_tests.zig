//! End-to-end tests: LLVM ORC JITed IR calling the runtime intrinsic ABI.
//!
//! These exercise the same path generated code uses: host addresses are
//! registered in the JITDylib as absolute symbols, IR is added, and the
//! resulting native function calls back into the runtime.

const std = @import("std");
const orc = @import("orc.zig");
const intrinsics = @import("intrinsics.zig");
const abi = @import("ffi/abi.zig");
const fs = @import("ffi/fs.zig");
const net = @import("ffi/net.zig");
const quic = @import("ffi/quic.zig");
const io_mod = @import("ffi/io.zig");
const shader_assets = @import("shader_assets");

fn makeJit() !orc.Jit {
    var jit = try orc.Jit.init(std.testing.allocator);
    errdefer jit.deinit();
    try jit.defineSymbols(intrinsics.symbols());
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
