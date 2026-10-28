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
const host_mod = @import("host.zig");
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

/// Read a checked-in repo source relative to the workspace root.  Missing
/// files are repo/build failures, not skips: a test that needs engine source
/// must fail loudly instead of silently passing.
fn readRepoSource(allocator: std.mem.Allocator, relative: []const u8) ![]u8 {
    const prefixes = [_][]const u8{ "", "../", "../../" };
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    for (prefixes) |prefix| {
        const candidate = std.fmt.bufPrint(&buffer, "{s}{s}", .{ prefix, relative }) catch continue;
        const data = std.Io.Dir.readFileAlloc(
            std.Io.Dir.cwd(),
            std.testing.io,
            candidate,
            allocator,
            .limited(8 * 1024 * 1024),
        ) catch continue;
        return data;
    }
    std.debug.print("missing checked-in engine source: {s}\n", .{relative});
    return error.TestUnexpectedResult;
}

/// Read one RGBA8 pixel from a captured frame.
fn capturePixel(pixels: []const u8, width: usize, x: usize, y: usize) u32 {
    const offset = (y * width + x) * 4;
    return std.mem.readInt(u32, pixels[offset..][0..4], .little);
}

/// Engine model-matrix parity helpers.  These mirror the removed Zig renderer
/// (`translate * Rz * Ry * Rx * scale`, column-major `Mat4[col][row]`) without
/// calling into the e7 implementation, so a wrong e7 formula fails the tests.
fn parityMilliToF32(value: i64) f32 {
    return @floatCast(@as(f64, @floatFromInt(value)) / 1000.0);
}

fn parityRadians(value: i64) f64 {
    return @as(f64, @floatFromInt(value)) / 1000.0;
}

fn parityModelMatrix(sx_milli: i64, sy_milli: i64, sz_milli: i64, rx_milli: i64, ry_milli: i64, rz_milli: i64) [16]f32 {
    const scale_x: f64 = parityMilliToF32(sx_milli);
    const scale_y: f64 = parityMilliToF32(sy_milli);
    const scale_z: f64 = parityMilliToF32(sz_milli);
    const rx = parityRadians(rx_milli);
    const ry = parityRadians(ry_milli);
    const rz = parityRadians(rz_milli);
    const cx = @cos(rx);
    const sin_x = @sin(rx);
    const cy = @cos(ry);
    const sin_y = @sin(ry);
    const cz = @cos(rz);
    const sin_z = @sin(rz);
    // R = Rz * Ry * Rx columns, each scaled by (sx, sy, sz); column 3 is the
    // identity translation so object_model_matrix can be compared directly.
    var out: [16]f32 = undefined;
    out[0] = @floatCast((cy * cz) * scale_x);
    out[1] = @floatCast((cy * sin_z) * scale_x);
    out[2] = @floatCast((-sin_y) * scale_x);
    out[3] = 0.0;
    out[4] = @floatCast((((sin_y * sin_x) * cz) - (cx * sin_z)) * scale_y);
    out[5] = @floatCast((((sin_y * sin_x) * sin_z) + (cx * cz)) * scale_y);
    out[6] = @floatCast((cy * sin_x) * scale_y);
    out[7] = 0.0;
    out[8] = @floatCast((((sin_y * cx) * cz) + (sin_x * sin_z)) * scale_z);
    out[9] = @floatCast((((sin_y * cx) * sin_z) - (sin_x * cz)) * scale_z);
    out[10] = @floatCast((cy * cx) * scale_z);
    out[11] = 0.0;
    out[12] = 0.0;
    out[13] = 0.0;
    out[14] = 0.0;
    out[15] = 1.0;
    return out;
}

const ParityBox = struct {
    min_col: f64,
    max_col: f64,
    min_row: f64,
    max_row: f64,
};

/// Project the unit box [-1,1]^3 through `model` and the test camera
/// (eye (0,0,5), 60 degree vertical FOV, square target), returning the
/// continuous pixel-space bounding box.  Callers compare it with the captured
/// silhouette using a small rasterisation tolerance.
fn parityProjectBox(model: [16]f32, width: f64, height: f64) ParityBox {
    const f = 1.0 / @tan(std.math.pi / 6.0);
    const aspect = width / height;
    var out = ParityBox{
        .min_col = std.math.inf(f64),
        .max_col = -std.math.inf(f64),
        .min_row = std.math.inf(f64),
        .max_row = -std.math.inf(f64),
    };
    for ([_]f64{ -1.0, 1.0 }) |x| {
        for ([_]f64{ -1.0, 1.0 }) |y| {
            for ([_]f64{ -1.0, 1.0 }) |z| {
                const m0: f64 = model[0];
                const m1: f64 = model[1];
                const m2: f64 = model[2];
                const m4: f64 = model[4];
                const m5: f64 = model[5];
                const m6: f64 = model[6];
                const m8: f64 = model[8];
                const m9: f64 = model[9];
                const m10: f64 = model[10];
                const world_x = m0 * x + m4 * y + m8 * z;
                const world_y = m1 * x + m5 * y + m9 * z;
                const world_z = m2 * x + m6 * y + m10 * z;
                const view_z = world_z - 5.0;
                const clip_w = -view_z;
                if (clip_w <= 0.0) continue;
                const ndc_x = (f / aspect) * world_x / clip_w;
                const ndc_y = (-f) * world_y / clip_w;
                const col = (ndc_x + 1.0) * 0.5 * width;
                const row = (1.0 + ndc_y) * 0.5 * height;
                out.min_col = @min(out.min_col, col);
                out.max_col = @max(out.max_col, col);
                out.min_row = @min(out.min_row, row);
                out.max_row = @max(out.max_row, row);
            }
        }
    }
    return out;
}

const BoxMetrics = struct {
    count: i64,
    min_row: i64,
    max_row: i64,
    min_col: i64,
    max_col: i64,
    top_min_col: i64,

    fn decode(value: i64) @This() {
        var rest = value;
        const top_min_col = @mod(rest, 100);
        rest = @divTrunc(rest, 100);
        const max_col = @mod(rest, 100);
        rest = @divTrunc(rest, 100);
        const min_col = @mod(rest, 100);
        rest = @divTrunc(rest, 100);
        const max_row = @mod(rest, 100);
        rest = @divTrunc(rest, 100);
        const min_row = @mod(rest, 100);
        rest = @divTrunc(rest, 100);
        return .{
            .count = rest,
            .min_row = min_row,
            .max_row = max_row,
            .min_col = min_col,
            .max_col = max_col,
            .top_min_col = top_min_col,
        };
    }
};

fn expectParityBox(measured: BoxMetrics, expected: ParityBox, tolerance: f64) !void {
    try std.testing.expect(@abs(@as(f64, @floatFromInt(measured.min_col)) - expected.min_col) <= tolerance);
    try std.testing.expect(@abs(@as(f64, @floatFromInt(measured.max_col)) - expected.max_col) <= tolerance);
    try std.testing.expect(@abs(@as(f64, @floatFromInt(measured.min_row)) - expected.min_row) <= tolerance);
    try std.testing.expect(@abs(@as(f64, @floatFromInt(measured.max_row)) - expected.max_row) <= tolerance);
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
        return error.SkipZigTest;
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
        return error.SkipZigTest;
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
    const library_path = mathLibraryPath() orelse return error.SkipZigTest;
    if (!canResolve(library_path, "cos")) {
        std.debug.print("skipping JIT dynamic FFI test: cos unavailable\n", .{});
        return error.SkipZigTest;
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
    const library_path = cLibraryPath() orelse return error.SkipZigTest;
    if (!canResolve(library_path, "strlen")) {
        std.debug.print("skipping JIT dynamic FFI test: strlen unavailable\n", .{});
        return error.SkipZigTest;
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
    const library_path = cLibraryPath() orelse return error.SkipZigTest;
    if (!canResolve(library_path, "qsort")) {
        std.debug.print("skipping JIT qsort callback test: qsort unavailable\n", .{});
        return error.SkipZigTest;
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
    const library_path = cLibraryPath() orelse return error.SkipZigTest;
    if (!canResolve(library_path, "stdout")) {
        std.debug.print("skipping JIT data-symbol test: stdout unavailable\n", .{});
        return error.SkipZigTest;
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

test "e7 host frame limit and capture intrinsics" {
    host_mod.reset();
    defer host_mod.reset();
    host_mod.setHeadless(true);
    host_mod.setMaxFrames(1);
    host_mod.setCaptureEnabled(true);

    const source =
        \\host_probe <- () -> i64:
        \\    if host::headless() == 0:
        \\        ret -1
        \\    pixels := ptr::alloc(64) as u64
        \\    ptr::store_u32(pixels + 0, 4294967295)
        \\    ptr::store_u32(pixels + 4, 4294967295)
        \\    ptr::store_u32(pixels + 8, 4294967295)
        \\    ptr::store_u32(pixels + 12, 4294967295)
        \\    ptr::store_u32(pixels + 16, 4294967295)
        \\    ptr::store_u32(pixels + 20, 4294967295)
        \\    ptr::store_u32(pixels + 24, 4294967295)
        \\    ptr::store_u32(pixels + 28, 4294967295)
        \\    ptr::store_u32(pixels + 32, 4294967295)
        \\    ptr::store_u32(pixels + 36, 4294967295)
        \\    ptr::store_u32(pixels + 40, 4294967295)
        \\    ptr::store_u32(pixels + 44, 4294967295)
        \\    ptr::store_u32(pixels + 48, 4294967295)
        \\    ptr::store_u32(pixels + 52, 4294967295)
        \\    ptr::store_u32(pixels + 56, 4294967295)
        \\    ptr::store_u32(pixels + 60, 4294967295)
        \\    captured := host::capture(pixels as u64, 4, 4)
        \\    ptr::free(pixels)
        \\    if captured != 0:
        \\        ret -2
        \\    host::note_frame()
        \\    if host::should_close() == 0:
        \\        ret -3
        \\    ret 0
    ;
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-host-probe");
    const Probe = *const fn () callconv(.c) i64;
    const probe = try jit.get(Probe, "host_probe");
    try std.testing.expectEqual(@as(i64, 0), probe());
    try std.testing.expect(host_mod.shouldClose());
    var capture = host_mod.takeCapture() orelse return error.TestUnexpectedResult;
    defer capture.deinit();
    try std.testing.expectEqual(@as(u32, 4), capture.width);
    try std.testing.expectEqual(@as(u32, 4), capture.height);
    try std.testing.expectEqual(@as(u8, 255), capture.pixels[0]);
    try std.testing.expectEqual(@as(u8, 255), capture.pixels[3]);
}

test "e7 source binds and calls libc strlen through the generic C FFI" {
    const library_path = cLibraryPath() orelse return error.SkipZigTest;
    if (!canResolve(library_path, "strlen")) return error.SkipZigTest;

    const source = try std.fmt.allocPrint(
        std.testing.allocator,
        \\strlen_len <- () -> u64:
        \\    addr := ffi::bind("{s}", "strlen")
        \\    ret ffi::call1(addr, str::data("hello") as u64)
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
        return error.SkipZigTest;
    }

    const source =
        \\window_probe <- () -> u64:
        \\    driver_key := str::cstr("SDL_VIDEODRIVER") as u64
        \\    driver_value := str::cstr("dummy") as u64
        \\    set_hint := ffi::bind("SDL3", "SDL_SetHint")
        \\    ffi::call2(set_hint, driver_key, driver_value)
        \\    init := ffi::bind("SDL3", "SDL_InitSubSystem")
        \\    rc := ffi::call1(init, 32)
        \\    if rc == 0:
        \\        ptr::free(driver_key)
        \\        ptr::free(driver_value)
        \\        ret 0
        \\    title := str::cstr("e7 SDL window") as u64
        \\    create := ffi::bind("SDL3", "SDL_CreateWindow")
        \\    win := ffi::call4(create, title, 64, 48, 8)
        \\    destroy := ffi::bind("SDL3", "SDL_DestroyWindow")
        \\    quit := ffi::bind("SDL3", "SDL_QuitSubSystem")
        \\    ffi::call1(destroy, win)
        \\    ffi::call1(quit, 32)
        \\    ptr::free(title)
        \\    ptr::free(driver_key)
        \\    ptr::free(driver_value)
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
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(u64, 1), result);
}

test "e7 source creates a Vulkan instance and enumerates devices through the C FFI" {
    if (!canResolve("libvulkan.so", "vkCreateInstance")) {
        std.debug.print("skipping e7 Vulkan FFI test: libvulkan unavailable\n", .{});
        return error.SkipZigTest;
    }

    const source =
        \\vulkan_probe <- () -> i64:
        \\    create := ffi::bind("vulkan", "vkCreateInstance")
        \\    if create == 0:
        \\        ret -3
        \\    app_name := str::cstr("engine7-e7") as u64
        \\    engine_name := str::cstr("engine7") as u64
        \\    app := ptr::alloc(48) as u64
        \\    ptr::store_u32(app, 0)
        \\    ptr::store_u32(app + 24, 1)
        \\    ptr::store_u64(app + 16, app_name)
        \\    ptr::store_u32(app + 24, 1)
        \\    ptr::store_u64(app + 32, engine_name)
        \\    ptr::store_u32(app + 40, 1)
        \\    ptr::store_u32(app + 44, 4198400)
        \\    info := ptr::alloc(64) as u64
        \\    ptr::store_u32(info, 1)
        \\    ptr::store_u64(info + 24, app)
        \\    instance_out := ptr::alloc(8) as u64
        \\    result := ffi::call3(create, info, 0, instance_out)
        \\    ptr::free(app_name)
        \\    ptr::free(engine_name)
        \\    if result != 0:
        \\        ptr::free(app)
        \\        ptr::free(info)
        \\        ptr::free(instance_out)
        \\        ret -2
        \\    instance := ptr::load_u64(instance_out)
        \\    enumerate := ffi::bind("vulkan", "vkEnumeratePhysicalDevices")
        \\    count_out := ptr::alloc(8) as u64
        \\    ptr::store_u32(count_out, 0)
        \\    enum_result := ffi::call3(enumerate, instance, count_out, 0)
        \\    count := ptr::load_u32(count_out)
        \\    destroy := ffi::bind("vulkan", "vkDestroyInstance")
        \\    ffi::call2(destroy, instance, 0)
        \\    ptr::free(app)
        \\    ptr::free(info)
        \\    ptr::free(instance_out)
        \\    ptr::free(count_out)
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
        return error.SkipZigTest;
    }

    const module_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(module_source);

    const selftest =
        \\window_selftest <- () -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret -1
        \\    win := window_create("e7 sdl platform", 64, 48, 8)
        \\    if win == 0:
        \\        video_quit()
        \\        ret -2
        \\    out_w := ptr::alloc(4) as u64
        \\    out_h := ptr::alloc(4) as u64
        \\    window_size(win, out_w, out_h)
        \\    width := ptr::load_u32(out_w)
        \\    height := ptr::load_u32(out_h)
        \\    key := key_down(win, 4)
        \\    buttons := mouse_buttons(win)
        \\    mouse := mouse_x(win) + mouse_y(win) + mouse_dx(win) + mouse_dy(win)
        \\    pump_result := window_pump(win)
        \\    window_destroy(win)
        \\    ptr::free(out_w)
        \\    ptr::free(out_h)
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
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "e7 SDL platform decodes SDL3 mouse motion fields and accumulates deltas" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow")) {
        std.debug.print("skipping e7 SDL mouse test: libSDL3 unavailable\n", .{});
        return error.SkipZigTest;
    }

    const module_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(module_source);

    const selftest =
        \\mouse_selftest <- () -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret -1
        \\    win := window_create("e7 sdl mouse", 64, 48, 8)
        \\    if win == 0:
        \\        video_quit()
        \\        ret -2
        \\    ev := ptr::alloc(128) as u64
        \\    ptr::store_u32(ev, 1024)
        \\    ptr::store_f32(ev + 28, 100.0)
        \\    ptr::store_f32(ev + 32, 200.0)
        \\    ptr::store_f32(ev + 36, 5.0)
        \\    ptr::store_f32(ev + 40, -7.0)
        \\    window_handle_event(win, ev)
        \\    x1 := mouse_x(win)
        \\    y1 := mouse_y(win)
        \\    dx1 := mouse_dx(win)
        \\    dy1 := mouse_dy(win)
        \\    ptr::store_f32(ev + 28, 110.0)
        \\    ptr::store_f32(ev + 32, 220.0)
        \\    ptr::store_f32(ev + 36, 7.0)
        \\    ptr::store_f32(ev + 40, -3.0)
        \\    window_handle_event(win, ev)
        \\    x2 := mouse_x(win)
        \\    y2 := mouse_y(win)
        \\    dx2 := mouse_dx(win)
        \\    dy2 := mouse_dy(win)
        \\    ptr::free(ev)
        \\    window_destroy(win)
        \\    video_quit()
        \\    if x1 != 100 or y1 != 200 or dx1 != 5 or dy1 != -7:
        \\        ret -3
        \\    if x2 != 110 or y2 != 220 or dx2 != 12 or dy2 != -10:
        \\        ret -4
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ module_source, selftest });
    defer std.testing.allocator.free(source);

    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |diagnostic| {
            std.debug.print("e7 SDL mouse parse diagnostic: {s}\n", .{diagnostic.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |diagnostic| {
            std.debug.print("e7 SDL mouse diagnostic: {}:{}: {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
        return error.TestUnexpectedResult;
    }

    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());

    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-sdl-mouse");
    const Selftest = *const fn () callconv(.c) i64;
    const selftest_fn = try jit.get(Selftest, "mouse_selftest");
    const result = selftest_fn();
    if (result == -1) {
        std.debug.print("skipping e7 SDL mouse test: SDL video unavailable\n", .{});
        return error.SkipZigTest;
    }
    if (result != 1) std.debug.print("e7 SDL mouse selftest result {d}\n", .{result});
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "e7 SDL platform reports a window resize once" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow")) return error.SkipZigTest;
    const module_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(module_source);
    const selftest =
        \\resize_track_selftest <- () -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret -1
        \\    win := window_create("e7 sdl resize", 64, 48, 8)
        \\    if win == 0:
        \\        video_quit()
        \\        ret -2
        \\    set_size := bind_sdl("SDL_SetWindowSize")
        \\    ffi::call3(set_size, ptr::load_u64(win), 80, 60)
        \\    window_sync_size(win)
        \\    out_w := ptr::alloc(4) as u64
        \\    out_h := ptr::alloc(4) as u64
        \\    first := window_take_resize(win, out_w, out_h)
        \\    width := ptr::load_u32(out_w)
        \\    height := ptr::load_u32(out_h)
        \\    second := window_take_resize(win, out_w, out_h)
        \\    ptr::free(out_w)
        \\    ptr::free(out_h)
        \\    window_destroy(win)
        \\    video_quit()
        \\    if first == 0 or width != 80 or height != 60:
        \\        ret -3
        \\    if second != 0:
        \\        ret -4
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ module_source, selftest });
    defer std.testing.allocator.free(source);
    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |d| {
            std.debug.print("e7 SDL resize parse: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |d| std.debug.print("e7 SDL resize diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.TestUnexpectedResult;
    }
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-sdl-resize");
    const Selftest = *const fn () callconv(.c) i64;
    const selftest_fn = try jit.get(Selftest, "resize_track_selftest");
    const result = selftest_fn();
    if (result == -1) return error.SkipZigTest;
    if (result != 1) std.debug.print("SDL resize selftest result {d}\n", .{result});
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "e7 SDL+Vulkan platform module creates a window surface" {
    if (!canResolve("libSDL3.so", "SDL_Vulkan_CreateSurface") or !canResolve("libvulkan.so", "vkCreateInstance")) {
        std.debug.print("skipping e7 Vulkan surface test: SDL Vulkan or Vulkan loader unavailable\n", .{});
        return error.SkipZigTest;
    }

    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);

    const selftest =
        \\surface_selftest <- () -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret -1
        \\    win := window_create("e7 vulkan", 64, 48, 268435464)
        \\    if win == 0:
        \\        video_quit()
        \\        ret 0
        \\    ext_count := ptr::alloc(4) as u64
        \\    get_ext := ffi::bind("SDL3", "SDL_Vulkan_GetInstanceExtensions")
        \\    exts := ffi::call1(get_ext, ext_count)
        \\    if exts == 0:
        \\        window_destroy(win)
        \\        ptr::free(ext_count)
        \\        video_quit()
        \\        ret 0
        \\    count := ptr::load_u32(ext_count)
        \\    ext_array := ptr::alloc(count * 8) as u64
        \\    if count > 0:
        \\        ptr::store_u64(ext_array, ptr::load_u64(exts))
        \\    if count > 1:
        \\        ptr::store_u64(ext_array + 8, ptr::load_u64(exts + 8))
        \\    if count > 2:
        \\        ptr::store_u64(ext_array + 16, ptr::load_u64(exts + 16))
        \\    if count > 3:
        \\        ptr::store_u64(ext_array + 24, ptr::load_u64(exts + 24))
        \\    if count > 4:
        \\        ptr::store_u64(ext_array + 32, ptr::load_u64(exts + 32))
        \\    if count > 5:
        \\        ptr::store_u64(ext_array + 40, ptr::load_u64(exts + 40))
        \\    if count > 6:
        \\        ptr::store_u64(ext_array + 48, ptr::load_u64(exts + 48))
        \\    if count > 7:
        \\        ptr::store_u64(ext_array + 56, ptr::load_u64(exts + 56))
        \\    instance_out := ptr::alloc(8) as u64
        \\    created := vulkan_instance_create(ext_array, count, instance_out)
        \\    if created != 0:
        \\        window_destroy(win)
        \\        ptr::free(ext_count)
        \\        ptr::free(ext_array)
        \\        ptr::free(instance_out)
        \\        video_quit()
        \\        ret 0
        \\    instance := ptr::load_u64(instance_out)
        \\    surface_out := ptr::alloc(8) as u64
        \\    created_surface := vulkan_surface_create(win, instance, surface_out)
        \\    surface := ptr::load_u64(surface_out)
        \\    if surface != 0:
        \\        vulkan_surface_destroy(instance, surface)
        \\    vulkan_instance_destroy(instance)
        \\    window_destroy(win)
        \\    ptr::free(ext_count)
        \\    ptr::free(ext_array)
        \\    ptr::free(instance_out)
        \\    ptr::free(surface_out)
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
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "e7 SDL+Vulkan platform draws a triangle and captures it" {
    if (!canResolve("libSDL3.so", "SDL_Vulkan_CreateSurface") or !canResolve("libvulkan.so", "vkCreateInstance")) return error.SkipZigTest;

    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);

    const selftest =
        \\device_selftest <- () -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret -1
        \\    win := window_create("e7 vulkan device", 64, 48, 268435464)
        \\    if win == 0:
        \\        video_quit()
        \\        ret 0
        \\    ext_count := ptr::alloc(4) as u64
        \\    get_ext := ffi::bind("SDL3", "SDL_Vulkan_GetInstanceExtensions")
        \\    exts := ffi::call1(get_ext, ext_count)
        \\    if exts == 0:
        \\        window_destroy(win)
        \\        ptr::free(ext_count)
        \\        video_quit()
        \\        ret 0
        \\    count := ptr::load_u32(ext_count)
        \\    ext_array := ptr::alloc(count * 8) as u64
        \\    if count > 0:
        \\        ptr::store_u64(ext_array, ptr::load_u64(exts))
        \\    if count > 1:
        \\        ptr::store_u64(ext_array + 8, ptr::load_u64(exts + 8))
        \\    if count > 2:
        \\        ptr::store_u64(ext_array + 16, ptr::load_u64(exts + 16))
        \\    if count > 3:
        \\        ptr::store_u64(ext_array + 24, ptr::load_u64(exts + 24))
        \\    instance_out := ptr::alloc(8) as u64
        \\    created := vulkan_instance_create(ext_array, count, instance_out)
        \\    instance := ptr::load_u64(instance_out)
        \\    surface_out := ptr::alloc(8) as u64
        \\    device_out := ptr::alloc(8) as u64
        \\    queue_out := ptr::alloc(8) as u64
        \\    family_out := ptr::alloc(4) as u64
        \\    physical_out := ptr::alloc(8) as u64
        \\    result := 0
        \\    surface := 0
        \\    if created == 0:
        \\        surface_created := vulkan_surface_create(win, instance, surface_out)
        \\        surface = ptr::load_u64(surface_out)
        \\        result = vulkan_device_create(instance, surface, device_out, queue_out, family_out, physical_out)
        \\        if result != 0:
        \\            device := ptr::load_u64(device_out)
        \\            queue := ptr::load_u64(queue_out)
        \\            physical := ptr::load_u64(physical_out)
        \\            family := ptr::load_u32(family_out)
        \\            submit_ok := vulkan_submit_empty(device, queue, family)
        \\            swapchain_out := ptr::alloc(8) as u64
        \\            format_out := ptr::alloc(4) as u64
        \\            width_out := ptr::alloc(4) as u64
        \\            height_out := ptr::alloc(4) as u64
        \\            images_out := ptr::alloc(8) as u64
        \\            image_count_out := ptr::alloc(4) as u64
        \\            swapchain_created := vulkan_swapchain_create(device, physical, surface, win, swapchain_out, format_out, width_out, height_out, images_out, image_count_out)
        \\            images := ptr::load_u64(images_out)
        \\            if swapchain_created != 0:
        \\                swapchain := ptr::load_u64(swapchain_out)
        \\                width := ptr::load_u32(width_out)
        \\                height := ptr::load_u32(height_out)
        \\                image_count := ptr::load_u32(image_count_out)
        \\                image_format := ptr::load_u32(format_out)
        \\                rp_targets := ptr::alloc(8) as u64
        \\                view_targets := ptr::alloc(8) as u64
        \\                fb_targets := ptr::alloc(8) as u64
        \\                targets_ok := vulkan_render_targets(device, images, image_count, image_format, width, height, 0, rp_targets, view_targets, fb_targets)
        \\                render_pass_handle := ptr::load_u64(rp_targets)
        \\                views_handle := ptr::load_u64(view_targets)
        \\                framebuffers_handle := ptr::load_u64(fb_targets)
        \\                uniform_layout_out := ptr::alloc(8) as u64
        \\                uniform_pool_out := ptr::alloc(8) as u64
        \\                uniform_set_out := ptr::alloc(8) as u64
        \\                uniform_buffer_out := ptr::alloc(8) as u64
        \\                uniform_memory_out := ptr::alloc(8) as u64
        \\                uniform_mapped_out := ptr::alloc(8) as u64
        \\                uniform_size_out := ptr::alloc(8) as u64
        \\                uniform_ok := vulkan_uniform_resources(device, physical, 1, uniform_layout_out, uniform_pool_out, uniform_set_out, uniform_buffer_out, uniform_memory_out, uniform_mapped_out, uniform_size_out)
        \\                if uniform_ok != 0:
        \\                    vulkan_uniform_resources_destroy(device, ptr::load_u64(uniform_layout_out), ptr::load_u64(uniform_pool_out), ptr::load_u64(uniform_buffer_out), ptr::load_u64(uniform_memory_out))
        \\                ptr::free(uniform_layout_out)
        \\                ptr::free(uniform_pool_out)
        \\                ptr::free(uniform_set_out)
        \\                ptr::free(uniform_buffer_out)
        \\                ptr::free(uniform_memory_out)
        \\                ptr::free(uniform_mapped_out)
        \\                ptr::free(uniform_size_out)
        \\                if uniform_ok == 0:
        \\                    result = -17
        \\                vertex_buffer_out := ptr::alloc(8) as u64
        \\                vertex_memory_out := ptr::alloc(8) as u64
        \\                vertex_mapped_out := ptr::alloc(8) as u64
        \\                vertex_ok := vulkan_vertex_buffer(device, physical, vertex_buffer_out, vertex_memory_out, vertex_mapped_out)
        \\                mesh_vert := host::read_shader("engine/platform/shaders/mesh_simple.vert.spv")
        \\                mesh_frag := host::read_shader("engine/platform/shaders/mesh_simple.frag.spv")
        \\                mesh_vert_handle := ffi::handle(mesh_vert)
        \\                mesh_frag_handle := ffi::handle(mesh_frag)
        \\                mesh_pipeline_out := ptr::alloc(8) as u64
        \\                mesh_layout_out := ptr::alloc(8) as u64
        \\                mesh_ok := 0
        \\                if mesh_vert_handle != 0:
        \\                    if mesh_frag_handle != 0:
        \\                        mesh_ok = vulkan_mesh_pipeline_simple(device, render_pass_handle, mesh_vert, mesh_frag, 0, mesh_pipeline_out, mesh_layout_out)
        \\                mesh_green := 0
        \\                if mesh_ok != 0:
        \\                    if vertex_ok != 0:
        \\                        mesh_pixels_out := ptr::alloc(8) as u64
        \\                        mesh_size_out := ptr::alloc(8) as u64
        \\                        mesh_drew := vulkan_draw_triangle_capture(device, queue, family, physical, swapchain, render_pass_handle, ptr::load_u64(mesh_pipeline_out), framebuffers_handle, image_count, width, height, ptr::load_u64(vertex_buffer_out), 0, 0, 0, 0, 0, 0, 0, 0, 0, mesh_pixels_out, mesh_size_out)
        \\                        mesh_pixels := ptr::load_u64(mesh_pixels_out)
        \\                        mesh_offset := ((height / 2) * width + width / 2) * 4
        \\                        mesh_center := ptr::load_u32((mesh_pixels as u64) + (mesh_offset as u64))
        \\                        mesh_green = (mesh_center / 256) % 256
        \\                        ptr::free(mesh_pixels)
        \\                        ptr::free(mesh_pixels_out)
        \\                        ptr::free(mesh_size_out)
        \\                    vulkan_graphics_pipeline_destroy(device, ptr::load_u64(mesh_pipeline_out), ptr::load_u64(mesh_layout_out))
        \\                ptr::free(mesh_vert_handle)
        \\                ptr::free(mesh_frag_handle)
        \\                ptr::free(mesh_pipeline_out)
        \\                ptr::free(mesh_layout_out)
        \\                if vertex_ok != 0:
        \\                    vulkan_vertex_buffer_destroy(device, ptr::load_u64(vertex_buffer_out), ptr::load_u64(vertex_memory_out))
        \\                ptr::free(vertex_buffer_out)
        \\                ptr::free(vertex_memory_out)
        \\                ptr::free(vertex_mapped_out)
        \\                ubo_layout_out := ptr::alloc(8) as u64
        \\                ubo_layout_ok := vulkan_ubo_set_layout(device, ubo_layout_out)
        \\                ubo_vert := host::read_shader("engine/platform/shaders/mesh.vert.spv")
        \\                ubo_frag := host::read_shader("engine/platform/shaders/mesh.frag.spv")
        \\                ubo_vert_handle := ffi::handle(ubo_vert)
        \\                ubo_frag_handle := ffi::handle(ubo_frag)
        \\                ubo_pipeline_out := ptr::alloc(8) as u64
        \\                ubo_pipeline_layout_out := ptr::alloc(8) as u64
        \\                ubo_pipeline_ok := 0
        \\                if ubo_vert_handle != 0:
        \\                    if ubo_frag_handle != 0:
        \\                        ubo_pipeline_ok = vulkan_mesh_pipeline_simple(device, render_pass_handle, ubo_vert, ubo_frag, ptr::load_u64(ubo_layout_out), ubo_pipeline_out, ubo_pipeline_layout_out)
        \\                if ubo_pipeline_ok != 0:
        \\                    vulkan_graphics_pipeline_destroy(device, ptr::load_u64(ubo_pipeline_out), ptr::load_u64(ubo_pipeline_layout_out))
        \\                ptr::free(ubo_vert_handle)
        \\                ptr::free(ubo_frag_handle)
        \\                ptr::free(ubo_pipeline_out)
        \\                ptr::free(ubo_pipeline_layout_out)
        \\                if ubo_layout_ok != 0:
        \\                    vulkan_descriptor_set_layout_destroy(device, ptr::load_u64(ubo_layout_out))
        \\                ptr::free(ubo_layout_out)
        \\                if mesh_ok == 0:
        \\                    result = -18
        \\                if ubo_pipeline_ok == 0:
        \\                    result = -22
        \\                else:
        \\                    if mesh_green != 255:
        \\                        result = -21
        \\                if vertex_ok == 0:
        \\                    result = -19
        \\                vert := host::read_shader("engine/platform/shaders/triangle.vert.spv")
        \\                frag := host::read_shader("engine/platform/shaders/triangle.frag.spv")
        \\                vert_handle := ffi::handle(vert)
        \\                frag_handle := ffi::handle(frag)
        \\                pipeline_out := ptr::alloc(8) as u64
        \\                layout_out := ptr::alloc(8) as u64
        \\                pipeline_ok := 0
        \\                if vert_handle != 0:
        \\                    if frag_handle != 0:
        \\                        pipeline_ok = vulkan_graphics_pipeline(device, render_pass_handle, vert, frag, pipeline_out, layout_out)
        \\                pipeline_handle := ptr::load_u64(pipeline_out)
        \\                layout_handle := ptr::load_u64(layout_out)
        \\                drew := 0
        \\                green := 0
        \\                if pipeline_ok != 0:
        \\                    draw_pixels_out := ptr::alloc(8) as u64
        \\                    draw_size_out := ptr::alloc(8) as u64
        \\                    drew = vulkan_draw_triangle_capture(device, queue, family, physical, swapchain, render_pass_handle, pipeline_handle, framebuffers_handle, image_count, width, height, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, draw_pixels_out, draw_size_out)
        \\                    draw_pixels := ptr::load_u64(draw_pixels_out)
        \\                    center_offset := ((height / 2) * width + width / 2) * 4
        \\                    center := ptr::load_u32((draw_pixels as u64) + (center_offset as u64))
        \\                    green = (center / 256) % 256
        \\                    ptr::free(draw_pixels)
        \\                    ptr::free(draw_pixels_out)
        \\                    ptr::free(draw_size_out)
        \\                    vulkan_graphics_pipeline_destroy(device, pipeline_handle, layout_handle)
        \\                ptr::free(pipeline_out)
        \\                ptr::free(layout_out)
        \\                ptr::free(vert_handle)
        \\                ptr::free(frag_handle)
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
        \\                ptr::free(rp_targets)
        \\                ptr::free(view_targets)
        \\                ptr::free(fb_targets)
        \\                if targets_ok == 0:
        \\                    result = -13
        \\                index_out := ptr::alloc(4) as u64
        \\                presented := vulkan_present_clear(device, queue, family, swapchain, index_out)
        \\                ptr::free(index_out)
        \\                pixels_out := ptr::alloc(8) as u64
        \\                size_out := ptr::alloc(8) as u64
        \\                captured := vulkan_capture_clear(device, queue, family, physical, swapchain, width, height, pixels_out, size_out)
        \\                pixels := ptr::load_u64(pixels_out)
        \\                pixel_size := ptr::load_u64(size_out)
        \\                pixel := ptr::load_u32(pixels)
        \\                red_bgra := (pixel / 65536) % 256
        \\                red_rgba := pixel % 256
        \\                ptr::free(pixels)
        \\                ptr::free(pixels_out)
        \\                ptr::free(size_out)
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
        \\                ptr::free(images)
        \\            if submit_ok == 0:
        \\                result = -9
        \\            ptr::free(swapchain_out)
        \\            ptr::free(format_out)
        \\            ptr::free(width_out)
        \\            ptr::free(height_out)
        \\            ptr::free(images_out)
        \\            ptr::free(image_count_out)
        \\            vulkan_device_destroy(device)
        \\        if surface != 0:
        \\            vulkan_surface_destroy(instance, surface)
        \\    vulkan_instance_destroy(instance)
        \\    window_destroy(win)
        \\    ptr::free(ext_count)
        \\    ptr::free(ext_array)
        \\    ptr::free(instance_out)
        \\    ptr::free(surface_out)
        \\    ptr::free(device_out)
        \\    ptr::free(queue_out)
        \\    ptr::free(family_out)
        \\    ptr::free(physical_out)
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
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "e7 audio platform loads a WAV and plays through the SDL dummy driver" {
    if (!canResolve("libSDL3.so", "SDL_OpenAudioDeviceStream")) return error.SkipZigTest;
    const audio_source = try readRepoSource(std.testing.allocator, "engine/platform/audio.e7");
    defer std.testing.allocator.free(audio_source);

    const probe =
        \\load_probe_tone <- () -> AudioClip:
        \\    first := audio_load_wav("engine/assets/testdata/tone.wav")
        \\    if first.valid():
        \\        ret first
        \\    second := audio_load_wav("../engine/assets/testdata/tone.wav")
        \\    if second.valid():
        \\        ret second
        \\    ret audio_load_wav("../../engine/assets/testdata/tone.wav")
        \\
        \\is_dummy_driver <- () -> i64:
        \\    name := audio_current_driver()
        \\    if str::len(name) != 5:
        \\        ret 0
        \\    data := str::data(name) as u64
        \\    if ptr::load_u8(data) != 100:
        \\        ret 0
        \\    if ptr::load_u8(data + 1) != 117:
        \\        ret 0
        \\    if ptr::load_u8(data + 2) != 109:
        \\        ret 0
        \\    if ptr::load_u8(data + 3) != 109:
        \\        ret 0
        \\    if ptr::load_u8(data + 4) != 121:
        \\        ret 0
        \\    ret 1
        \\
        \\audio_probe <- () -> i64:
        \\    if audio_init("dummy") == 0:
        \\        ret 0
        \\    if is_dummy_driver() == 0:
        \\        ret -1
        \\    clip := load_probe_tone()
        \\    if not clip.valid():
        \\        ret -2
        \\    if clip.length != 8820:
        \\        ret -3
        \\    if clip.channels as i64 != 1:
        \\        ret -4
        \\    if clip.freq as i64 != 44100:
        \\        ret -5
        \\    if clip.bytes_per_frame() != 2:
        \\        ret -6
        \\    if clip.frame_count() != 4410:
        \\        ret -7
        \\    if clip.duration_ms() != 100:
        \\        ret -8
        \\    missing := audio_load_wav("engine/assets/testdata/missing-tone.wav")
        \\    if missing.valid():
        \\        ret -9
        \\    missing.free()
        \\    invalid := audio_load_wav("engine/assets/testdata/cube.png")
        \\    if invalid.valid():
        \\        ret -10
        \\    invalid.free()
        \\    system := AudioSystem { ready: true, volume: 1.0, stream: 0 }
        \\    if system.play(&clip) != 1:
        \\        ret -11
        \\    system.set_volume(0.25)
        \\    system.stop()
        \\    if system.playing() != 0:
        \\        ret -12
        \\    system.shutdown()
        \\    clip.free()
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ audio_source, probe });
    defer std.testing.allocator.free(source);
    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |d| {
            std.debug.print("e7 audio parse: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |d| std.debug.print("e7 audio diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.TestUnexpectedResult;
    }
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-audio");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "audio_probe");
    const result = probe_fn();
    if (result == 0) {
        std.debug.print("skipping e7 audio test: SDL audio unavailable\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "e7 input module maps actions and mouse state through SDL" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const input_source = try readRepoSource(std.testing.allocator, "engine/platform/input.e7");
    defer std.testing.allocator.free(input_source);

    const selftest =
        \\input_selftest <- () -> i64:
        \\    if video_init("dummy") == 0:
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
    if (result == -1) {
        std.debug.print("skipping e7 input test: SDL video unavailable\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "e7 engine scene module renders and captures a frame" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow") or !canResolve("libvulkan.so", "vkCreateInstance")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);
    const window_source = try readRepoSource(std.testing.allocator, "engine/platform/engine_window.e7");
    defer std.testing.allocator.free(window_source);
    const engine_scene_source = try readRepoSource(std.testing.allocator, "engine/platform/engine_scene.e7");
    defer std.testing.allocator.free(engine_scene_source);
    const probe =
        \\scene_probe <- () -> i64:
        \\    win := e7_engine_window_create("e7 engine scene", 64, 48)
        \\    if win == 0:
        \\        ret 0
        \\    scene := e7_engine_scene_create(win, "", "")
        \\    if scene == 0:
        \\        e7_engine_window_destroy(win)
        \\        ret -2
        \\    e7_engine_scene_set_camera(scene, 0, 0, 3000, 0, 0)
        \\    e7_engine_scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000)
        \\    e7_engine_scene_begin_frame(scene)
        \\    e7_engine_scene_draw_box(scene, 0, 0, 0, 1000, 1000, 1000, 1000, 1000, 1000, 0)
        \\    e7_engine_scene_end_frame(scene)
        \\    e7_engine_scene_destroy(scene)
        \\    e7_engine_window_destroy(win)
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{ sdl_source, vk_source, scene_source, window_source, engine_scene_source, probe });
    defer std.testing.allocator.free(source);
    host_mod.reset();
    defer host_mod.reset();
    host_mod.setHeadless(true);
    host_mod.setCaptureEnabled(true);
    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |d| {
            std.debug.print("engine scene parse: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |d| std.debug.print("engine scene diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.TestUnexpectedResult;
    }
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-engine-scene");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "scene_probe");
    const result = probe_fn();
    if (result == 0) {
        std.debug.print("skipping e7 scene test: window/scene unavailable\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(i64, 1), result);
    try std.testing.expect(host_mod.frames() == 1);
    var capture = host_mod.takeCapture() orelse return error.TestUnexpectedResult;
    defer capture.deinit();
    try std.testing.expectEqual(@as(u32, 64), capture.width);
    try std.testing.expectEqual(@as(u32, 48), capture.height);
    try std.testing.expectEqual(@as(usize, 64 * 48 * 4), capture.pixels.len);
    // The probe draws a lit box over a black clear colour, so the captured
    // frame must contain that geometry instead of an empty buffer.
    const center = capturePixel(capture.pixels, 64, 32, 24);
    try std.testing.expect(center != 0xFF000000);
    try std.testing.expect(center != capturePixel(capture.pixels, 64, 0, 0));
    var non_zero: usize = 0;
    for (capture.pixels) |byte| {
        if (byte != 0) non_zero += 1;
    }
    try std.testing.expect(non_zero > 1000);
}

test "e7 scene resize recreates the swapchain and capture size" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow") or !canResolve("libvulkan.so", "vkCreateInstance")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);
    const window_source = try readRepoSource(std.testing.allocator, "engine/platform/engine_window.e7");
    defer std.testing.allocator.free(window_source);
    const engine_scene_source = try readRepoSource(std.testing.allocator, "engine/platform/engine_scene.e7");
    defer std.testing.allocator.free(engine_scene_source);
    const probe =
        \\scene_resize_probe <- () -> i64:
        \\    win := e7_engine_window_create("e7 resize scene", 64, 48)
        \\    if win == 0:
        \\        ret 0
        \\    scene := e7_engine_scene_create(win, "", "")
        \\    if scene == 0:
        \\        e7_engine_window_destroy(win)
        \\        ret -2
        \\    set_size := bind_sdl("SDL_SetWindowSize")
        \\    ffi::call3(set_size, ptr::load_u64(win), 96, 64)
        \\    window_pump(win)
        \\    window_pump(win)
        \\    window_sync_size(win)
        \\    e7_engine_scene_resize(scene, 96, 64)
        \\    if scene_width(scene) != 96 or scene_height(scene) != 64:
        \\        e7_engine_scene_destroy(scene)
        \\        e7_engine_window_destroy(win)
        \\        ret -3
        \\    e7_engine_scene_set_camera(scene, 0, 0, 3000, 0, 0)
        \\    e7_engine_scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000)
        \\    e7_engine_scene_begin_frame(scene)
        \\    e7_engine_scene_draw_box(scene, 0, 0, 0, 1000, 1000, 1000, 1000, 1000, 1000, 0)
        \\    e7_engine_scene_end_frame(scene)
        \\    e7_engine_scene_destroy(scene)
        \\    e7_engine_window_destroy(win)
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{ sdl_source, vk_source, scene_source, window_source, engine_scene_source, probe });
    defer std.testing.allocator.free(source);
    host_mod.reset();
    defer host_mod.reset();
    host_mod.setHeadless(true);
    host_mod.setCaptureEnabled(true);
    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |d| {
            std.debug.print("resize scene parse: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |d| std.debug.print("resize scene diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.TestUnexpectedResult;
    }
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-resize-scene");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "scene_resize_probe");
    const result = probe_fn();
    if (result == 0) return error.SkipZigTest;
    if (result != 1) std.debug.print("resize scene probe result {d}\n", .{result});
    try std.testing.expectEqual(@as(i64, 1), result);
    var capture = host_mod.takeCapture() orelse return error.TestUnexpectedResult;
    defer capture.deinit();
    try std.testing.expectEqual(@as(u32, 96), capture.width);
    try std.testing.expectEqual(@as(u32, 64), capture.height);
    try std.testing.expectEqual(@as(usize, 96 * 64 * 4), capture.pixels.len);
    const center = capturePixel(capture.pixels, 96, 48, 32);
    try std.testing.expect(center != 0xFF000000);
}

test "e7 async task returns an i64 result" {
    const source =
        \\async_seven <- async () -> i64:
        \\    ret 7
    ;
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-async-result");
    task.e7_task_set_inline(1);
    defer task.e7_task_set_inline(0);
    const Fn = *const fn () callconv(.c) i64;
    const fn_ptr = try jit.get(Fn, "async_seven");
    const handle = fn_ptr();
    try std.testing.expect(handle != 0);
    const result = task.e7_task_await(handle);
    try std.testing.expectEqual(@as(i64, 7), result);
}

test "e7 scene renders through separate modules" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow") or !canResolve("libvulkan.so", "vkCreateInstance")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);
    const root_source =
        \\mod sdl
        \\mod vulkan
        \\mod scene
        \\use sdl::*;
        \\use scene::*;
        \\module_scene_probe <- () -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret -1
        \\    win := window_create("e7 module scene", 64, 48, 268435464)
        \\    if win == 0:
        \\        ret 0
        \\    scene := scene_create(win, 64, 48)
        \\    if scene == 0:
        \\        window_destroy(win)
        \\        ret -2
        \\    scene_set_camera(scene, 0, 0, 3000, 0, 0)
        \\    scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000)
        \\    scene_set_cube_angle(scene, 600)
        \\    scene_begin_frame(scene)
        \\    scene_draw_box(scene, 0, 0, 0, 1000, 1000, 1000, 1000, 1000, 1000, 0)
        \\    pixels_out := ptr::alloc(8) as u64
        \\    size_out := ptr::alloc(8) as u64
        \\    drew := scene_draw(scene, pixels_out, size_out)
        \\    pixels := ptr::load_u64(pixels_out)
        \\    width := scene_width(scene)
        \\    height := scene_height(scene)
        \\    center := ptr::load_u32((pixels as u64) + ((((height / 2) * width) + (width / 2)) * 4) as u64)
        \\    ptr::free(pixels)
        \\    ptr::free(pixels_out)
        \\    ptr::free(size_out)
        \\    scene_destroy(scene)
        \\    window_destroy(win)
        \\    if drew == 0:
        \\        ret -3
        \\    ret center as i64
    ;
    var compiled = compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        &.{
            .{ .name = "sdl", .source = sdl_source },
            .{ .name = "vulkan", .source = vk_source },
            .{ .name = "scene", .source = scene_source },
        },
        .{},
    ) catch |err| {
        std.debug.print("module scene compile error: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer compiled.deinit();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-module-scene");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "module_scene_probe");
    const result = probe_fn();
    if (result == 0) {
        std.debug.print("skipping e7 scene test: window/scene unavailable\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expect(result > 0);
    try std.testing.expect(@as(u64, @intCast(result)) >> 24 == 0xFF);
    try std.testing.expect(result != 0xFF000000);
}

test "e7 window state returned from a helper is valid" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const root_source =
        \\mod sdl
        \\use sdl::*;
        \\create_win <- (title: str, width: i64, height: i64) -> u64:
        \\    ret window_create(title, width, height, 268435464)
        \\window_probe <- () -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret -1
        \\    win := create_win("e7 helper window", 64, 48)
        \\    if win == 0:
        \\        ret -2
        \\    width_out := ptr::alloc(4) as u64
        \\    height_out := ptr::alloc(4) as u64
        \\    window_size(win, width_out, height_out)
        \\    width := ptr::load_u32(width_out)
        \\    height := ptr::load_u32(height_out)
        \\    ptr::free(width_out)
        \\    ptr::free(height_out)
        \\    flags := window_flags(win)
        \\    window_destroy(win)
        \\    ret flags
    ;
    var compiled = compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        &.{.{ .name = "sdl", .source = sdl_source }},
        .{},
    ) catch |err| {
        std.debug.print("helper window compile error: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer compiled.deinit();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-helper-window");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "window_probe");
    const result = probe_fn();
    if (result == 0) {
        std.debug.print("skipping e7 scene test: window/scene unavailable\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expect((result & 0x10000000) != 0);
}

test "e7 scene renders inside a helper function" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow") or !canResolve("libvulkan.so", "vkCreateInstance")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);
    const root_source =
        \\mod sdl
        \\mod vulkan
        \\mod scene
        \\use sdl::*;
        \\use scene::*;
        \\helper_scene_center <- () -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret -1
        \\    win := window_create("e7 helper scene", 64, 48, 268435464)
        \\    if win == 0:
        \\        ret 0
        \\    scene := scene_create(win, 64, 48)
        \\    if scene == 0:
        \\        window_destroy(win)
        \\        ret -2
        \\    scene_set_camera(scene, 0, 0, 3000, 0, 0)
        \\    scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000)
        \\    scene_set_cube_angle(scene, 600)
        \\    scene_begin_frame(scene)
        \\    scene_draw_box(scene, 0, 0, 0, 1000, 1000, 1000, 1000, 1000, 1000, 0)
        \\    pixels_out := ptr::alloc(8) as u64
        \\    size_out := ptr::alloc(8) as u64
        \\    drew := scene_draw(scene, pixels_out, size_out)
        \\    pixels := ptr::load_u64(pixels_out)
        \\    width := scene_width(scene)
        \\    height := scene_height(scene)
        \\    center := ptr::load_u32((pixels as u64) + ((((height / 2) * width) + (width / 2)) * 4) as u64)
        \\    ptr::free(pixels)
        \\    ptr::free(pixels_out)
        \\    ptr::free(size_out)
        \\    scene_destroy(scene)
        \\    if drew == 0:
        \\        ret -3
        \\    ret center as i64
        \\helper_probe <- () -> i64:
        \\    ret helper_scene_center()
    ;
    var compiled = compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        &.{
            .{ .name = "sdl", .source = sdl_source },
            .{ .name = "vulkan", .source = vk_source },
            .{ .name = "scene", .source = scene_source },
        },
        .{},
    ) catch |err| {
        std.debug.print("helper scene compile error: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer compiled.deinit();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-helper-scene");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "helper_probe");
    const result = probe_fn();
    if (result == 0) {
        std.debug.print("skipping e7 scene test: window/scene unavailable\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expect(result > 0);
    try std.testing.expect(@as(u64, @intCast(result)) >> 24 == 0xFF);
    try std.testing.expect(result != 0xFF000000);
}

test "e7 scene renders on a helper-created window after pumping" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow") or !canResolve("libvulkan.so", "vkCreateInstance")) return error.SkipZigTest;
    host_mod.reset();
    defer host_mod.reset();
    host_mod.setHeadless(true);
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);
    const window_source = try readRepoSource(std.testing.allocator, "engine/platform/engine_window.e7");
    defer std.testing.allocator.free(window_source);
    const root_source =
        \\mod sdl
        \\mod vulkan
        \\mod scene
        \\mod engine_window
        \\use scene::*;
        \\use engine_window::*;
        \\helper_window_probe <- () -> i64:
        \\    win := e7_engine_window_create("e7 helper window scene", 960, 540)
        \\    if win == 0:
        \\        ret 0
        \\    scene := scene_create(win, 960, 540)
        \\    if scene == 0:
        \\        window_destroy(win)
        \\        ret -2
        \\    scene_set_camera(scene, 0, 0, 3000, 0, 0)
        \\    scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000)
        \\    scene_set_cube_angle(scene, 600)
        \\    scene_begin_frame(scene)
        \\    scene_draw_box(scene, 0, 0, 0, 1000, 1000, 1000, 1000, 1000, 1000, 0)
        \\    pixels_out := ptr::alloc(8) as u64
        \\    size_out := ptr::alloc(8) as u64
        \\    drew := scene_draw(scene, pixels_out, size_out)
        \\    pixels := ptr::load_u64(pixels_out)
        \\    width := scene_width(scene)
        \\    height := scene_height(scene)
        \\    center := ptr::load_u32((pixels as u64) + ((((height / 2) * width) + (width / 2)) * 4) as u64)
        \\    ptr::free(pixels)
        \\    ptr::free(pixels_out)
        \\    ptr::free(size_out)
        \\    scene_destroy(scene)
        \\    if drew == 0:
        \\        ret -3
        \\    ret center as i64
    ;
    var compiled = compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        &.{
            .{ .name = "sdl", .source = sdl_source },
            .{ .name = "vulkan", .source = vk_source },
            .{ .name = "scene", .source = scene_source },
            .{ .name = "engine_window", .source = window_source },
        },
        .{},
    ) catch |err| {
        std.debug.print("helper window scene compile error: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer compiled.deinit();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-helper-window-scene");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "helper_window_probe");
    const result = probe_fn();
    if (result == 0) {
        std.debug.print("skipping e7 scene test: window/scene unavailable\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expect(result > 0);
    try std.testing.expect(@as(u64, @intCast(result)) >> 24 == 0xFF);
    try std.testing.expect(result != 0xFF000000);
}

test "e7 scene_draw from a different function than begin/draw" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow") or !canResolve("libvulkan.so", "vkCreateInstance")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);
    const root_source =
        \\mod sdl
        \\mod vulkan
        \\mod scene
        \\use sdl::*;
        \\use scene::*;
        \\draw_helper <- (scene: u64) -> i64:
        \\    pixels_out := ptr::alloc(8) as u64
        \\    size_out := ptr::alloc(8) as u64
        \\    drew := scene_draw(scene, pixels_out, size_out)
        \\    pixels := ptr::load_u64(pixels_out)
        \\    width := scene_width(scene)
        \\    height := scene_height(scene)
        \\    center := ptr::load_u32((pixels as u64) + ((((height / 2) * width) + (width / 2)) * 4) as u64)
        \\    ptr::free(pixels)
        \\    ptr::free(pixels_out)
        \\    ptr::free(size_out)
        \\    if drew == 0:
        \\        ret -3
        \\    ret center as i64
        \\split_probe <- () -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret -1
        \\    win := window_create("e7 split scene", 64, 48, 268435464)
        \\    if win == 0:
        \\        ret 0
        \\    scene := scene_create(win, 64, 48)
        \\    if scene == 0:
        \\        window_destroy(win)
        \\        ret -2
        \\    scene_set_camera(scene, 0, 0, 3000, 0, 0)
        \\    scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000)
        \\    scene_set_cube_angle(scene, 600)
        \\    scene_begin_frame(scene)
        \\    scene_draw_box(scene, 0, 0, 0, 1000, 1000, 1000, 1000, 1000, 1000, 0)
        \\    center := draw_helper(scene)
        \\    scene_destroy(scene)
        \\    ret center
    ;
    var compiled = compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        &.{
            .{ .name = "sdl", .source = sdl_source },
            .{ .name = "vulkan", .source = vk_source },
            .{ .name = "scene", .source = scene_source },
        },
        .{},
    ) catch |err| {
        std.debug.print("split scene compile error: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer compiled.deinit();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-split-scene");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "split_probe");
    const result = probe_fn();
    if (result == 0) {
        std.debug.print("skipping e7 scene test: window/scene unavailable\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expect(result > 0);
    try std.testing.expect(@as(u64, @intCast(result)) >> 24 == 0xFF);
    try std.testing.expect(result != 0xFF000000);
}

test "e7 scene_draw called from another module" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow") or !canResolve("libvulkan.so", "vkCreateInstance")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);
    const driver_source =
        \\use scene::*;
        \\draw_driver <- (scene: u64) -> i64:
        \\    pixels_out := ptr::alloc(8) as u64
        \\    size_out := ptr::alloc(8) as u64
        \\    drew := scene_draw(scene, pixels_out, size_out)
        \\    pixels := ptr::load_u64(pixels_out)
        \\    width := scene_width(scene)
        \\    height := scene_height(scene)
        \\    center := ptr::load_u32((pixels as u64) + ((((height / 2) * width) + (width / 2)) * 4) as u64)
        \\    ptr::free(pixels)
        \\    ptr::free(pixels_out)
        \\    ptr::free(size_out)
        \\    if drew == 0:
        \\        ret -3
        \\    ret center as i64
    ;
    const root_source =
        \\mod sdl
        \\mod vulkan
        \\mod scene
        \\mod driver
        \\use sdl::*;
        \\use scene::*;
        \\use driver::*;
        \\module_draw_probe <- () -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret -1
        \\    win := window_create("e7 module draw", 64, 48, 268435464)
        \\    if win == 0:
        \\        ret 0
        \\    scene := scene_create(win, 64, 48)
        \\    if scene == 0:
        \\        window_destroy(win)
        \\        ret -2
        \\    scene_set_camera(scene, 0, 0, 3000, 0, 0)
        \\    scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000)
        \\    scene_set_cube_angle(scene, 600)
        \\    scene_begin_frame(scene)
        \\    scene_draw_box(scene, 0, 0, 0, 1000, 1000, 1000, 1000, 1000, 1000, 0)
        \\    center := draw_driver(scene)
        \\    scene_destroy(scene)
        \\    ret center
    ;
    var compiled = compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        &.{
            .{ .name = "sdl", .source = sdl_source },
            .{ .name = "vulkan", .source = vk_source },
            .{ .name = "scene", .source = scene_source },
            .{ .name = "driver", .source = driver_source },
        },
        .{},
    ) catch |err| {
        std.debug.print("module draw compile error: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer compiled.deinit();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-module-draw");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "module_draw_probe");
    const result = probe_fn();
    if (result == 0) {
        std.debug.print("skipping e7 scene test: window/scene unavailable\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expect(result > 0);
    try std.testing.expect(@as(u64, @intCast(result)) >> 24 == 0xFF);
    try std.testing.expect(result != 0xFF000000);
}

test "e7 scene_draw through a method receiver" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow") or !canResolve("libvulkan.so", "vkCreateInstance")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);
    const root_source =
        \\mod sdl
        \\mod vulkan
        \\mod scene
        \\use sdl::*;
        \\use scene::*;
        \\Drawer <- struct
        \\    scene: u64
        \\impl Drawer:
        \\    draw <- (d: &Drawer) -> i64:
        \\        pixels_out := ptr::alloc(8) as u64
        \\        size_out := ptr::alloc(8) as u64
        \\        drew := scene_draw(d.scene, pixels_out, size_out)
        \\        pixels := ptr::load_u64(pixels_out)
        \\        width := scene_width(d.scene)
        \\        height := scene_height(d.scene)
        \\        center := ptr::load_u32((pixels as u64) + ((((height / 2) * width) + (width / 2)) * 4) as u64)
        \\        ptr::free(pixels)
        \\        ptr::free(pixels_out)
        \\        ptr::free(size_out)
        \\        if drew == 0:
        \\            ret -3
        \\        ret center as i64
        \\method_draw_probe <- () -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret -1
        \\    win := window_create("e7 method draw", 64, 48, 268435464)
        \\    if win == 0:
        \\        ret 0
        \\    scene := scene_create(win, 64, 48)
        \\    if scene == 0:
        \\        window_destroy(win)
        \\        ret -2
        \\    scene_set_camera(scene, 0, 0, 3000, 0, 0)
        \\    scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000)
        \\    scene_set_cube_angle(scene, 600)
        \\    scene_begin_frame(scene)
        \\    scene_draw_box(scene, 0, 0, 0, 1000, 1000, 1000, 1000, 1000, 1000, 0)
        \\    drawer := Drawer { scene: scene }
        \\    center := drawer.draw()
        \\    scene_destroy(scene)
        \\    ret center
    ;
    var compiled = compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        &.{
            .{ .name = "sdl", .source = sdl_source },
            .{ .name = "vulkan", .source = vk_source },
            .{ .name = "scene", .source = scene_source },
        },
        .{},
    ) catch |err| {
        std.debug.print("method draw compile error: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer compiled.deinit();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-method-draw");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "method_draw_probe");
    const result = probe_fn();
    if (result == 0) {
        std.debug.print("skipping e7 scene test: window/scene unavailable\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expect(result > 0);
    try std.testing.expect(@as(u64, @intCast(result)) >> 24 == 0xFF);
    try std.testing.expect(result != 0xFF000000);
}

test "e7 scene draw inside an inline async task" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow") or !canResolve("libvulkan.so", "vkCreateInstance")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);
    const root_source =
        \\mod sdl
        \\mod vulkan
        \\mod scene
        \\use sdl::*;
        \\use scene::*;
        \\async_scene_center <- async () -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret -1
        \\    win := window_create("e7 async draw", 64, 48, 268435464)
        \\    if win == 0:
        \\        ret 0
        \\    scene := scene_create(win, 64, 48)
        \\    if scene == 0:
        \\        window_destroy(win)
        \\        ret -2
        \\    scene_set_camera(scene, 0, 0, 3000, 0, 0)
        \\    scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000)
        \\    scene_set_cube_angle(scene, 600)
        \\    scene_begin_frame(scene)
        \\    scene_draw_box(scene, 0, 0, 0, 1000, 1000, 1000, 1000, 1000, 1000, 0)
        \\    pixels_out := ptr::alloc(8) as u64
        \\    size_out := ptr::alloc(8) as u64
        \\    drew := scene_draw(scene, pixels_out, size_out)
        \\    pixels := ptr::load_u64(pixels_out)
        \\    width := scene_width(scene)
        \\    height := scene_height(scene)
        \\    center := ptr::load_u32((pixels as u64) + ((((height / 2) * width) + (width / 2)) * 4) as u64)
        \\    ptr::free(pixels)
        \\    ptr::free(pixels_out)
        \\    ptr::free(size_out)
        \\    scene_destroy(scene)
        \\    if drew == 0:
        \\        ret -3
        \\    ret center as i64
    ;
    var compiled = compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        &.{
            .{ .name = "sdl", .source = sdl_source },
            .{ .name = "vulkan", .source = vk_source },
            .{ .name = "scene", .source = scene_source },
        },
        .{},
    ) catch |err| {
        std.debug.print("async draw compile error: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    defer compiled.deinit();
    task.e7_task_set_inline(1);
    defer task.e7_task_set_inline(0);
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-async-draw");
    const Async = *const fn () callconv(.c) i64;
    const async_scene = try jit.get(Async, "async_scene_center");
    const handle = async_scene();
    try std.testing.expect(handle != 0);
    const result = task.e7_task_await(handle);
    if (result == 0) {
        std.debug.print("skipping e7 scene test: window/scene unavailable\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expect(result > 0);
    try std.testing.expect(@as(u64, @intCast(result)) >> 24 == 0xFF);
    try std.testing.expect(result != 0xFF000000);
}

test "e7 engine window module creates, pumps, and destroys a window" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow")) return error.SkipZigTest;
    host_mod.reset();
    defer host_mod.reset();
    host_mod.setHeadless(true);
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const window_source = try readRepoSource(std.testing.allocator, "engine/platform/engine_window.e7");
    defer std.testing.allocator.free(window_source);
    const probe =
        \\window_probe <- () -> i64:
        \\    win := e7_engine_window_create("e7 engine window", 64, 48)
        \\    if win == 0:
        \\        ret 0
        \\    if e7_engine_window_pump(win) != 0:
        \\        e7_engine_window_destroy(win)
        \\        ret -2
        \\    if e7_engine_key_down(win, 0) != 0:
        \\        e7_engine_window_destroy(win)
        \\        ret -3
        \\    e7_engine_window_destroy(win)
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}", .{ sdl_source, window_source, probe });
    defer std.testing.allocator.free(source);
    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |d| {
            std.debug.print("engine window parse: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |d| std.debug.print("engine window diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.TestUnexpectedResult;
    }
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-engine-window");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "window_probe");
    const result = probe_fn();
    if (result == 0) {
        std.debug.print("skipping e7 scene test: window/scene unavailable\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "e7 engine text input buffers UTF-8 events and clears on read" {
    if (!canResolve("libSDL3.so", "SDL_strlen")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const probe =
        \\text_input_probe <- () -> i64:
        \\    state := ptr::alloc(256) as u64
        \\    event := ptr::alloc(128) as u64
        \\    first := ptr::alloc(8) as u64
        \\    ptr::store_u8(first, 195)
        \\    ptr::store_u8(first + 1, 169)
        \\    ptr::store_u8(first + 2, 0)
        \\    ptr::store_u32(event, 771)
        \\    ptr::store_u64(event + 24, first)
        \\    window_handle_event(state, event)
        \\    second := ptr::alloc(8) as u64
        \\    ptr::store_u8(second, 97)
        \\    ptr::store_u8(second + 1, 98)
        \\    ptr::store_u8(second + 2, 0)
        \\    ptr::store_u64(event + 24, second)
        \\    window_handle_event(state, event)
        \\    capacity := ptr::load_u32(state + 204)
        \\    pending := ptr::load_u32(state + 200)
        \\    typed := text_input_pending(state)
        \\    length := str::len(typed)
        \\    data := str::data(typed) as u64
        \\    b0 := ptr::load_u8(data)
        \\    b1 := ptr::load_u8(data + 1)
        \\    b2 := ptr::load_u8(data + 2)
        \\    b3 := ptr::load_u8(data + 3)
        \\    again := text_input_pending(state)
        \\    again_length := str::len(again)
        \\    ptr::free(typed)
        \\    ptr::free(again)
        \\    text_input_reset(state)
        \\    cleared := text_input_pending(state)
        \\    cleared_length := str::len(cleared)
        \\    ptr::free(cleared)
        \\    free_text_buffer(state)
        \\    ptr::free(state)
        \\    ptr::free(event)
        \\    ptr::free(first)
        \\    ptr::free(second)
        \\    if capacity != 256:
        \\        ret -1
        \\    if pending != 4:
        \\        ret -2
        \\    if length != 4:
        \\        ret -3
        \\    if b0 != 195:
        \\        ret -4
        \\    if b1 != 169:
        \\        ret -5
        \\    if b2 != 97:
        \\        ret -6
        \\    if b3 != 98:
        \\        ret -7
        \\    if again_length != 0:
        \\        ret -8
        \\    if cleared_length != 0:
        \\        ret -9
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ sdl_source, probe });
    defer std.testing.allocator.free(source);
    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |d| {
            std.debug.print("e7 text input parse: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |d| std.debug.print("e7 text input diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.TestUnexpectedResult;
    }
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-text-input");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "text_input_probe");
    try std.testing.expectEqual(@as(i64, 1), probe_fn());
}

test "e7 engine mouse capture flag and button decode" {
    if (!canResolve("libSDL3.so", "SDL_SetWindowRelativeMouseMode")) return error.SkipZigTest;
    host_mod.reset();
    defer host_mod.reset();
    host_mod.setHeadless(true);
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const window_source = try readRepoSource(std.testing.allocator, "engine/platform/engine_window.e7");
    defer std.testing.allocator.free(window_source);
    const probe =
        \\mouse_probe <- () -> i64:
        \\    win := e7_engine_window_create("e7 engine mouse", 64, 48)
        \\    if win == 0:
        \\        ret 0
        \\    before := e7_engine_mouse_captured(win)
        \\    e7_engine_capture_mouse(win, 1)
        \\    captured_on := e7_engine_mouse_captured(win)
        \\    e7_engine_capture_mouse(win, 0)
        \\    captured_off := e7_engine_mouse_captured(win)
        \\    left := mouse_button_mask_down(7, 0)
        \\    right := mouse_button_mask_down(7, 1)
        \\    middle := mouse_button_mask_down(7, 2)
        \\    left_only_right := mouse_button_mask_down(1, 1)
        \\    middle_only_middle := mouse_button_mask_down(2, 2)
        \\    middle_only_right := mouse_button_mask_down(2, 1)
        \\    right_only_right := mouse_button_mask_down(4, 1)
        \\    right_only_middle := mouse_button_mask_down(4, 2)
        \\    extra := mouse_button_mask_down(7, 3)
        \\    state_left := e7_engine_mouse_down(win, 0)
        \\    e7_engine_window_destroy(win)
        \\    if before != 0:
        \\        ret -1
        \\    if captured_on != 1:
        \\        ret -2
        \\    if captured_off != 0:
        \\        ret -3
        \\    if left != 1:
        \\        ret -4
        \\    if right != 1:
        \\        ret -5
        \\    if middle != 1:
        \\        ret -6
        \\    if left_only_right != 0:
        \\        ret -7
        \\    if middle_only_middle != 1:
        \\        ret -8
        \\    if middle_only_right != 0:
        \\        ret -9
        \\    if right_only_right != 1:
        \\        ret -10
        \\    if right_only_middle != 0:
        \\        ret -11
        \\    if extra != 0:
        \\        ret -12
        \\    if state_left != 0:
        \\        ret -13
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}", .{ sdl_source, window_source, probe });
    defer std.testing.allocator.free(source);
    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |d| {
            std.debug.print("e7 mouse parse: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |d| std.debug.print("e7 mouse diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.TestUnexpectedResult;
    }
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-engine-mouse");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "mouse_probe");
    const result = probe_fn();
    if (result == 0) {
        std.debug.print("skipping e7 mouse test: window unavailable\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "e7 engine headless window creation uses hidden dummy mode" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow")) return error.SkipZigTest;
    host_mod.reset();
    defer host_mod.reset();
    host_mod.setHeadless(true);
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const window_source = try readRepoSource(std.testing.allocator, "engine/platform/engine_window.e7");
    defer std.testing.allocator.free(window_source);
    const probe =
        \\headless_window_probe <- () -> i64:
        \\    if host::headless() == 0:
        \\        ret -1
        \\    if e7_engine_window_flags(1) != 268435496:
        \\        ret -2
        \\    if e7_engine_window_flags(0) != 268435488:
        \\        ret -3
        \\    win := e7_engine_window_create("e7 headless window", 64, 48)
        \\    if win == 0:
        \\        ret 0
        \\    flags := window_flags(win)
        \\    hidden := (flags / 8) % 2
        \\    resizable := (flags / 32) % 2
        \\    vulkan := (flags / 268435456) % 2
        \\    out_w := ptr::alloc(4) as u64
        \\    out_h := ptr::alloc(4) as u64
        \\    window_size(win, out_w, out_h)
        \\    width := ptr::load_u32(out_w)
        \\    height := ptr::load_u32(out_h)
        \\    captured := e7_engine_mouse_captured(win)
        \\    ptr::free(out_w)
        \\    ptr::free(out_h)
        \\    e7_engine_window_destroy(win)
        \\    if hidden != 1:
        \\        ret -4
        \\    if resizable != 1:
        \\        ret -5
        \\    if vulkan != 1:
        \\        ret -6
        \\    if width != 64:
        \\        ret -7
        \\    if height != 48:
        \\        ret -8
        \\    if captured != 0:
        \\        ret -9
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}", .{ sdl_source, window_source, probe });
    defer std.testing.allocator.free(source);
    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |d| {
            std.debug.print("e7 headless window parse: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |d| std.debug.print("e7 headless window diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.TestUnexpectedResult;
    }
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-engine-headless-window");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "headless_window_probe");
    const result = probe_fn();
    if (result == 0) {
        std.debug.print("skipping e7 headless window test: window unavailable\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "e7 text image uploads through the UI texture path" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow") or !canResolve("libvulkan.so", "vkCreateInstance")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);
    const text_source = try readRepoSource(std.testing.allocator, "engine/platform/text.e7");
    defer std.testing.allocator.free(text_source);
    const probe =
        \\text_ui_probe <- () -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret -1
        \\    win := window_create("e7 text ui", 64, 48, 268435464)
        \\    if win == 0:
        \\        video_quit()
        \\        ret 0
        \\    scene := scene_create(win, 64, 48)
        \\    if scene == 0:
        \\        window_destroy(win)
        \\        video_quit()
        \\        ret -2
        \\    font := e7_font_load("/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf", 24)
        \\    if font == 0:
        \\        scene_destroy(scene)
        \\        video_quit()
        \\        ret -3
        \\    image := e7_text_image(font, "Hello", 255, 255, 255)
        \\    if image == 0:
        \\        e7_font_free(font)
        \\        scene_destroy(scene)
        \\        video_quit()
        \\        ret -4
        \\    image_width := image::width(image)
        \\    image_height := image::height(image)
        \\    image_pixels := image::pixels(image)
        \\    pixel_ptr := str::data(image_pixels) as u64
        \\    if scene_set_ui_texture(scene, pixel_ptr as u64, image_width, image_height) == 0:
        \\        image::free(image)
        \\        e7_font_free(font)
        \\        scene_destroy(scene)
        \\        video_quit()
        \\        ret -5
        \\    image::free(image)
        \\    e7_font_free(font)
        \\    scene_destroy(scene)
        \\    video_quit()
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}\n{s}\n{s}", .{ sdl_source, vk_source, scene_source, text_source, probe });
    defer std.testing.allocator.free(source);
    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |d| {
            std.debug.print("text ui parse: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |d| std.debug.print("text ui diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.TestUnexpectedResult;
    }
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-text-ui");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "text_ui_probe");
    const result = probe_fn();
    if (result == 0 or result == -1 or result == -3) {
        std.debug.print("skipping e7 text UI test: window/device/font unavailable (code {d})\n", .{result});
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(i64, 1), result);
}

test "e7 scene module draws an indexed cube and captures it" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow") or !canResolve("libvulkan.so", "vkCreateInstance")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);

    const selftest =
        \\scene_selftest <- () -> i64:
        \\    if video_init("dummy") == 0:
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
        \\    scene_set_cube_angle(scene, 600)
        \\    scene_begin_frame(scene)
        \\    scene_draw_box(scene, 0, 0, 0, 1000, 1000, 1000, 1000, 1000, 1000, 0)
        \\    scene_draw_box(scene, 1500, 0, 0, 700, 700, 700, 1000, 200, 200, 0)
        \\    scene_draw_box(scene, -1500, 0, 0, 600, 600, 600, 200, 1000, 200, 0)
        \\    scene_draw_box(scene, 0, 1200, 0, 500, 500, 500, 200, 200, 1000, 0)
        \\    scene_draw_box(scene, 1500, 1200, 0, 400, 400, 400, 1000, 1000, 200, 0)
        \\    scene_draw_box(scene, -1500, 1200, 0, 400, 400, 400, 200, 1000, 1000, 0)
        \\    scene_draw_box(scene, 0, -1200, 0, 400, 400, 400, 1000, 200, 1000, 0)
        \\    scene_draw_box(scene, 0, 0, 900, 300, 300, 300, 800, 800, 800, 0)
        \\    scene_draw_box(scene, 600, -1200, 0, 300, 300, 300, 1000, 600, 400, 0)
        \\    scene_draw_box(scene, 800, -1350, 0, 300, 300, 300, 1000, 600, 400, 0)
        \\    scene_draw_box(scene, 1000, -1500, 0, 300, 300, 300, 1000, 600, 400, 0)
        \\    scene_draw_box(scene, 1200, -1650, 0, 300, 300, 300, 1000, 600, 400, 0)
        \\    scene_draw_box(scene, 1400, -1800, 0, 300, 300, 300, 1000, 600, 400, 0)
        \\    scene_draw_box(scene, 1600, -1950, 0, 300, 300, 300, 1000, 600, 400, 0)
        \\    scene_draw_box(scene, 1800, -2100, 0, 300, 300, 300, 1000, 600, 400, 0)
        \\    scene_draw_box(scene, 2000, -2250, 0, 300, 300, 300, 1000, 600, 400, 0)
        \\    pixels_out := ptr::alloc(8) as u64
        \\    size_out := ptr::alloc(8) as u64
        \\    drew := scene_draw(scene, pixels_out, size_out)
        \\    pixels := ptr::load_u64(pixels_out)
        \\    width := scene_width(scene)
        \\    height := scene_height(scene)
        \\    offset := ((height / 2) * width + width / 2) * 4
        \\    center := ptr::load_u32((pixels as u64) + (offset as u64))
        \\    ptr::free(pixels)
        \\    ptr::free(pixels_out)
        \\    ptr::free(size_out)
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
    if (result == 0 or result == -1) {
        std.debug.print("skipping e7 test: window/device unavailable (code {d})\n", .{result});
        return error.SkipZigTest;
    }
    try std.testing.expect(result > 0);
    try std.testing.expect(@as(u64, @intCast(result)) >> 24 == 0xFF);
    try std.testing.expect(result != 0xFF000000);
}

test "e7 procedural shapes render sphere, capsule, and plane silhouettes" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow") or !canResolve("libvulkan.so", "vkCreateInstance")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);

    // Render one procedural shape at the origin on a black 96x96 frame and
    // return count * 1000000 + widest row * 1000 + silhouette rows.  The
    // camera sits at (0, eye_y, 5.0) looking down -Z, so a flat XZ plane is
    // edge-on at eye_y = 0 and visible from above at eye_y = 1000.
    const probe =
        \\shape_metric <- (kind: i64, eye_y: i64) -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret -1
        \\    win := window_create("e7 shape probe", 96, 96, 268435464)
        \\    if win == 0:
        \\        video_quit()
        \\        ret -2
        \\    scene := scene_create(win, 96, 96)
        \\    if scene == 0:
        \\        window_destroy(win)
        \\        video_quit()
        \\        ret -3
        \\    scene_set_camera(scene, 0, eye_y, 5000, 0, 0)
        \\    scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000)
        \\    scene_begin_frame(scene)
        \\    scene_draw_shape_rot(scene, kind as i32, 0, 0, 0, 1000, 1000, 1000, 0, 0, 0, 1000, 1000, 1000, 0 as u64)
        \\    pixels_out := ptr::alloc(8) as u64
        \\    size_out := ptr::alloc(8) as u64
        \\    drew := scene_draw(scene, pixels_out, size_out)
        \\    pixels := ptr::load_u64(pixels_out) as u64
        \\    count := 0
        \\    max_row := 0
        \\    rows := 0
        \\    row := 0
        \\    while row < 96:
        \\        row_count := 0
        \\        col := 0
        \\        while col < 96:
        \\            offset := ((row * 96 + col) * 4) as u64
        \\            pixel := ptr::load_u32(pixels + offset)
        \\            if pixel != 0 and pixel != 4278190080:
        \\                row_count = row_count + 1
        \\            col = col + 1
        \\        count = count + row_count
        \\        if row_count > max_row:
        \\            max_row = row_count
        \\        if row_count > 0:
        \\            rows = rows + 1
        \\        row = row + 1
        \\    ptr::free(pixels)
        \\    ptr::free(pixels_out)
        \\    ptr::free(size_out)
        \\    scene_destroy(scene)
        \\    window_destroy(win)
        \\    video_quit()
        \\    if drew == 0:
        \\        ret -4
        \\    # Round-trip the counters through float helpers: besides checking the
        \\    # float ABI, this keeps the loop-heavy helper under the LLVM
        \\    # InstCombine fixed-point attribute LLVM 23 requires for such IR.
        \\    count_value := ((count) as f32) as i64
        \\    width_value := ((max_row) as f32) as i64
        \\    rows_value := ((rows) as f32) as i64
        \\    ret count_value * 1000000 + width_value * 1000 + rows_value
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}\n{s}", .{ sdl_source, vk_source, scene_source, probe });
    defer std.testing.allocator.free(source);

    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |d| {
            std.debug.print("shape probe parse: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |d| std.debug.print("shape probe diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.TestUnexpectedResult;
    }
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-shape-probe");
    const Probe = *const fn (i64, i64) callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "shape_metric");

    const Metrics = struct {
        count: i64,
        width: i64,
        rows: i64,
        fn decode(value: i64) @This() {
            return .{
                .count = @divTrunc(value, 1_000_000),
                .width = @mod(@divTrunc(value, 1000), 1000),
                .rows = @mod(value, 1000),
            };
        }
        fn fill(self: @This()) f64 {
            if (self.width <= 0 or self.rows <= 0) return 0;
            return @as(f64, @floatFromInt(self.count)) / @as(f64, @floatFromInt(self.width * self.rows));
        }
    };

    const box = probe_fn(0, 0);
    const sphere = probe_fn(1, 0);
    const capsule = probe_fn(2, 0);
    const plane_edge_on = probe_fn(3, 0);
    const plane_above = probe_fn(3, 1000);
    if (box < 0 or sphere < 0 or capsule < 0 or plane_edge_on < 0 or plane_above < 0) {
        std.debug.print("skipping e7 procedural shape test: scene/device unavailable\n", .{});
        return error.SkipZigTest;
    }
    const box_m = Metrics.decode(box);
    const sphere_m = Metrics.decode(sphere);
    const capsule_m = Metrics.decode(capsule);
    const plane_edge_m = Metrics.decode(plane_edge_on);
    const plane_above_m = Metrics.decode(plane_above);

    // Every kind must render something: the box reference and the sphere,
    // capsule and plane (the plane also from above, where it is face-on).
    try std.testing.expect(box_m.count > 100);
    try std.testing.expect(sphere_m.count > 50);
    try std.testing.expect(capsule_m.count > 100);
    try std.testing.expect(plane_above_m.count > 20);

    // The box silhouette is a full square: every pixel of its bounding box is
    // covered.
    try std.testing.expect(box_m.fill() > 0.9);

    // The sphere silhouette is a disc: square bounding box (width == rows) but
    // ~pi/4 = 0.785 of the bounding box area instead of a full square, and its
    // inscribed diameter is smaller than the box front face (depth parallax).
    try std.testing.expect(sphere_m.fill() > 0.72 and sphere_m.fill() < 0.85);
    try std.testing.expect(@abs(sphere_m.width - sphere_m.rows) <= 2);
    try std.testing.expect(sphere_m.width * 100 >= box_m.width * 75);
    try std.testing.expect(sphere_m.width * 100 <= box_m.width * 95);
    try std.testing.expect(sphere_m.count < box_m.count);

    // The capsule keeps the sphere radius on x/z but its cylinder band doubles
    // the silhouette height relative to the box.
    try std.testing.expect(capsule_m.width <= sphere_m.width + 2);
    try std.testing.expect(capsule_m.rows > box_m.rows + 10);
    try std.testing.expect(capsule_m.rows <= box_m.rows * 2 + 8);
    try std.testing.expect(capsule_m.count > sphere_m.count);

    // The capsule silhouette is a cylinder band plus two half-disc caps: its
    // bounding-box fill is between the sphere's pi/4 disc and the box's square
    // (28x56 px measured: (pi/4*28^2 + 28*28) / (28*56) ~= 0.89).
    try std.testing.expect(capsule_m.fill() > sphere_m.fill());
    try std.testing.expect(capsule_m.fill() < box_m.fill());
    try std.testing.expect(capsule_m.fill() > 0.85);

    // A flat XZ plane is invisible edge-on at eye level, while it covers real
    // area from above: flatness instead of a box slab silhouette.
    try std.testing.expect(plane_edge_m.count * 10 < box_m.count);
    try std.testing.expect(plane_above_m.count > plane_edge_m.count * 3 + 10);
}

test "e7 model matrix matches translate * Rz * Ry * Rx * scale" {
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);

    // The removed Zig renderer composed `translate * Rz * Ry * Rx * scale` into
    // four contiguous column-major columns.  This exercises the e7 helper that
    // fills those columns directly (no GPU needed).
    const probe =
        \\matrix_probe <- (out: i64, sx: i64, sy: i64, sz: i64, rx: i64, ry: i64, rz: i64) -> i64:
        \\    object_model_matrix(out, sx, sy, sz, rx, ry, rz)
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}\n{s}", .{ sdl_source, vk_source, scene_source, probe });
    defer std.testing.allocator.free(source);

    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |d| {
            std.debug.print("matrix probe parse: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |d| std.debug.print("matrix probe diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.TestUnexpectedResult;
    }
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-model-matrix");
    const Probe = *const fn (i64, i64, i64, i64, i64, i64, i64) callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "matrix_probe");

    const Case = struct { sx: i64, sy: i64, sz: i64, rx: i64, ry: i64, rz: i64 };
    const cases = [_]Case{
        // Independent X, Y and Z rotations with asymmetric scales.
        .{ .sx = 2000, .sy = 1000, .sz = 1000, .rx = 500, .ry = 0, .rz = 0 },
        .{ .sx = 2000, .sy = 1000, .sz = 1000, .rx = 0, .ry = 500, .rz = 0 },
        .{ .sx = 2000, .sy = 1000, .sz = 1000, .rx = 0, .ry = 0, .rz = 500 },
        // Combined intrinsic-XYZ order; Rz is applied last.
        .{ .sx = 2000, .sy = 500, .sz = 1000, .rx = 300, .ry = 400, .rz = 500 },
        // Negative angles and a different scale assignment.
        .{ .sx = 500, .sy = 2000, .sz = 1000, .rx = -700, .ry = -400, .rz = 250 },
        // Unit scale, rotations only.
        .{ .sx = 1000, .sy = 1000, .sz = 1000, .rx = 700, .ry = 900, .rz = 1100 },
    };
    for (cases) |case| {
        var got: [16]f32 = undefined;
        const result = probe_fn(
            @as(i64, @intCast(@intFromPtr(&got))),
            case.sx,
            case.sy,
            case.sz,
            case.rx,
            case.ry,
            case.rz,
        );
        try std.testing.expectEqual(@as(i64, 1), result);
        const want = parityModelMatrix(case.sx, case.sy, case.sz, case.rx, case.ry, case.rz);
        for (want, 0..) |expected, index| {
            try std.testing.expectApproxEqAbs(expected, got[index], 1e-5);
        }
    }
}

test "e7 box scale and axis rotation projects match the zig renderer" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow") or !canResolve("libvulkan.so", "vkCreateInstance")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);

    // Render one unit box (kind 0, span [-1, 1] before scale) on a black 96x96
    // frame and return count*100 + min_row, max_row, min_col, max_col and the
    // topmost row's first column packed in base 100.  The camera sits at
    // (0, 0, 5.0) with a 60 degree vertical field of view.
    const probe =
        \\box_metric <- (sx: i64, sy: i64, sz: i64, rx: i64, ry: i64, rz: i64) -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret -1
        \\    win := window_create("e7 box parity", 96, 96, 268435464)
        \\    if win == 0:
        \\        video_quit()
        \\        ret -2
        \\    scene := scene_create(win, 96, 96)
        \\    if scene == 0:
        \\        window_destroy(win)
        \\        video_quit()
        \\        ret -3
        \\    scene_set_camera(scene, 0, 0, 5000, 0, 0)
        \\    scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000)
        \\    scene_begin_frame(scene)
        \\    scene_draw_shape_rot(scene, 0, 0, 0, 0, sx, sy, sz, rx, ry, rz, 1000, 1000, 1000, 0 as u64)
        \\    pixels_out := ptr::alloc(8) as u64
        \\    size_out := ptr::alloc(8) as u64
        \\    drew := scene_draw(scene, pixels_out, size_out)
        \\    pixels := ptr::load_u64(pixels_out) as u64
        \\    count := 0
        \\    min_row := 96
        \\    max_row := 0
        \\    min_col := 96
        \\    max_col := 0
        \\    top_min_col := 0
        \\    row := 0
        \\    while row < 96:
        \\        col := 0
        \\        while col < 96:
        \\            offset := ((row * 96 + col) * 4) as u64
        \\            pixel := ptr::load_u32(pixels + offset)
        \\            if pixel != 0 and pixel != 4278190080:
        \\                count = count + 1
        \\                if row < min_row:
        \\                    min_row = row
        \\                    top_min_col = col
        \\                elif row == min_row:
        \\                    if col < top_min_col:
        \\                        top_min_col = col
        \\                if row > max_row:
        \\                    max_row = row
        \\                if col < min_col:
        \\                    min_col = col
        \\                if col > max_col:
        \\                    max_col = col
        \\            col = col + 1
        \\        row = row + 1
        \\    ptr::free(pixels)
        \\    ptr::free(pixels_out)
        \\    ptr::free(size_out)
        \\    scene_destroy(scene)
        \\    window_destroy(win)
        \\    video_quit()
        \\    if drew == 0:
        \\        ret -4
        \\    count_value := ((count) as f32) as i64
        \\    min_row_value := ((min_row) as f32) as i64
        \\    max_row_value := ((max_row) as f32) as i64
        \\    min_col_value := ((min_col) as f32) as i64
        \\    max_col_value := ((max_col) as f32) as i64
        \\    top_value := ((top_min_col) as f32) as i64
        \\    ret (((((count_value * 100 + min_row_value) * 100 + max_row_value) * 100 + min_col_value) * 100 + max_col_value) * 100 + top_value)
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}\n{s}", .{ sdl_source, vk_source, scene_source, probe });
    defer std.testing.allocator.free(source);

    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |d| {
            std.debug.print("box parity probe parse: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |d| std.debug.print("box parity diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.TestUnexpectedResult;
    }
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-box-parity");
    const Probe = *const fn (i64, i64, i64, i64, i64, i64) callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "box_metric");

    // Unit box, half-extent scale 1: the old renderer's [-1,1] cube projects
    // to 27.2..68.8 px.  A half-sized ([-0.5,0.5]) cube would land near
    // 38.8..57.2, which the parity tolerance rejects.
    const size_one = probe_fn(1000, 1000, 1000, 0, 0, 0);
    const size_half = probe_fn(500, 500, 500, 0, 0, 0);
    // Asymmetric boxes rotated about each axis independently.  These bounding
    // boxes are perspective-asymmetric, so an inverted rotation fails them.
    const rx_pos = probe_fn(2000, 1000, 1000, 500, 0, 0);
    const rx_neg = probe_fn(2000, 1000, 1000, -500, 0, 0);
    const ry_pos = probe_fn(2000, 1000, 1000, 0, 700, 0);
    const ry_neg = probe_fn(2000, 1000, 1000, 0, -700, 0);
    const rz_pos = probe_fn(2000, 1000, 1000, 0, 0, 700);
    const rz_neg = probe_fn(2000, 1000, 1000, 0, 0, -700);
    const combined = probe_fn(2000, 500, 1000, 300, 400, 500);
    const values = [_]i64{ size_one, size_half, rx_pos, rx_neg, ry_pos, ry_neg, rz_pos, rz_neg, combined };
    for (values) |value| {
        if (value < 0) {
            std.debug.print("skipping e7 box parity test: scene/device unavailable ({d})\n", .{value});
            return error.SkipZigTest;
        }
    }
    const size_one_m = BoxMetrics.decode(size_one);
    const size_half_m = BoxMetrics.decode(size_half);
    const rx_pos_m = BoxMetrics.decode(rx_pos);
    const rx_neg_m = BoxMetrics.decode(rx_neg);
    const ry_pos_m = BoxMetrics.decode(ry_pos);
    const ry_neg_m = BoxMetrics.decode(ry_neg);
    const rz_pos_m = BoxMetrics.decode(rz_pos);
    const rz_neg_m = BoxMetrics.decode(rz_neg);
    const combined_m = BoxMetrics.decode(combined);

    const tolerance = 2.0;
    // Every case must render a solid silhouette; the smallest is the 0.5
    // half-extent box at ~18x18 px (~340 covered pixels).
    for ([_]*const BoxMetrics{ &size_one_m, &size_half_m, &rx_pos_m, &rx_neg_m, &ry_pos_m, &ry_neg_m, &rz_pos_m, &rz_neg_m, &combined_m }) |metric| {
        try std.testing.expect(metric.count > 200);
    }

    // Size parity: [-1,1] extents at half-extent scales 1.0 and 0.5.
    try expectParityBox(size_one_m, parityProjectBox(parityModelMatrix(1000, 1000, 1000, 0, 0, 0), 96, 96), tolerance);
    try expectParityBox(size_half_m, parityProjectBox(parityModelMatrix(500, 500, 500, 0, 0, 0), 96, 96), tolerance);

    // Axis rotation magnitudes and composition order.
    try expectParityBox(rx_pos_m, parityProjectBox(parityModelMatrix(2000, 1000, 1000, 500, 0, 0), 96, 96), tolerance);
    try expectParityBox(rx_neg_m, parityProjectBox(parityModelMatrix(2000, 1000, 1000, -500, 0, 0), 96, 96), tolerance);
    try expectParityBox(ry_pos_m, parityProjectBox(parityModelMatrix(2000, 1000, 1000, 0, 700, 0), 96, 96), tolerance);
    try expectParityBox(ry_neg_m, parityProjectBox(parityModelMatrix(2000, 1000, 1000, 0, -700, 0), 96, 96), tolerance);
    try expectParityBox(rz_pos_m, parityProjectBox(parityModelMatrix(2000, 1000, 1000, 0, 0, 700), 96, 96), tolerance);
    try expectParityBox(combined_m, parityProjectBox(parityModelMatrix(2000, 500, 1000, 300, 400, 500), 96, 96), tolerance);

    // Rotation direction: +X brings the far top face towards the camera (larger
    // bottom extent), +Y moves the left/large half towards the camera (smaller
    // left margin), and +Z raises the +X end (topmost row starts right of
    // centre).  Inverted or transposed matrices fail these relations.
    try std.testing.expect(rx_pos_m.max_row > rx_neg_m.max_row + 2);
    try std.testing.expect(ry_pos_m.min_col < ry_neg_m.min_col - 4);
    try std.testing.expect(rz_pos_m.top_min_col > 48);
    try std.testing.expect(rz_neg_m.top_min_col < 48);
}

test "e7 text module loads a font, measures, and rasterizes text" {
    const text_source = try readRepoSource(std.testing.allocator, "engine/platform/text.e7");
    defer std.testing.allocator.free(text_source);
    const selftest =
        \\text_selftest <- () -> i64:
        \\    font := e7_font_load("/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf", 24)
        \\    if font == 0:
        \\        ret 0
        \\    packed := e7_text_measure(font, "Hello")
        \\    width := packed / 4294967296
        \\    image := e7_text_image(font, "Hello", 255, 255, 255)
        \\    image_width := image::width(image)
        \\    image::free(image)
        \\    e7_font_free(font)
        \\    if width <= 0:
        \\        ret -2
        \\    if image == 0:
        \\        ret -3
        \\    if image_width <= 0:
        \\        ret -4
        \\    ret 1
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}", .{ text_source, selftest });
    defer std.testing.allocator.free(source);
    const parsed_result = try compiler.parser.parse(std.testing.allocator, source);
    var parsed = switch (parsed_result) {
        .ast => |tree| tree,
        .diagnostic => |d| {
            std.debug.print("text parse: {s}\n", .{d.message});
            return error.TestUnexpectedResult;
        },
    };
    defer parsed.deinit();
    var analysis = try compiler.semantic.analyze(std.testing.allocator, parsed.module);
    defer analysis.deinit();
    if (!analysis.ok()) {
        for (analysis.diagnostics) |d| std.debug.print("text diagnostic: {}:{}: {s}\n", .{ d.span.line, d.span.column, d.message });
        return error.TestUnexpectedResult;
    }
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "e7-text");
    const Selftest = *const fn () callconv(.c) i64;
    const selftest_fn = try jit.get(Selftest, "text_selftest");
    const result = selftest_fn();
    if (result == 0) {
        std.debug.print("skipping e7 text test: font unavailable\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(i64, 1), result);
}

// ---------------------------------------------------------------------------
// Engine physics regression: wake sleeping bodies when their support is removed
// ---------------------------------------------------------------------------

/// Checked-in engine modules needed to compile the physics step end to end
/// (core pulls in the e7 platform window/input layer).
const JitPhysicsRepoModule = struct {
    name: []const u8,
    path: ?[]const u8 = null,
    source: ?[]const u8 = null,
};

const jit_physics_module_specs = [_]JitPhysicsRepoModule{
    .{ .name = "platform", .path = "engine/platform/main.e7" },
    .{ .name = "text", .path = "engine/platform/text.e7" },
    .{ .name = "sdl", .path = "engine/platform/sdl.e7" },
    .{ .name = "vulkan", .path = "engine/platform/vulkan.e7" },
    .{ .name = "scene", .path = "engine/platform/scene.e7" },
    .{ .name = "engine_window", .path = "engine/platform/engine_window.e7" },
    .{ .name = "engine_scene", .path = "engine/platform/engine_scene.e7" },
    .{ .name = "audio", .path = "engine/platform/audio.e7" },
    .{ .name = "core", .source = "mod events\nmod ecs\nmod time\nmod input\nmod camera\nmod window\n" },
    .{ .name = "events", .path = "engine/core/events.e7" },
    .{ .name = "ecs", .path = "engine/core/ecs.e7" },
    .{ .name = "time", .path = "engine/core/time.e7" },
    .{ .name = "input", .path = "engine/core/input.e7" },
    .{ .name = "camera", .path = "engine/core/camera.e7" },
    .{ .name = "window", .path = "engine/core/window.e7" },
    .{ .name = "physics", .path = "engine/physics/main.e7" },
    .{ .name = "broadphase", .path = "engine/physics/broadphase.e7" },
    .{ .name = "narrowphase", .path = "engine/physics/narrowphase.e7" },
};

const JitLoadedPhysicsModules = struct {
    sources: []compiler.pipeline.SourceFile,
    owned: [][]u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *JitLoadedPhysicsModules) void {
        for (self.owned) |buffer| self.allocator.free(buffer);
        self.allocator.free(self.owned);
        self.allocator.free(self.sources);
    }
};

fn loadJitPhysicsModules(allocator: std.mem.Allocator) !JitLoadedPhysicsModules {
    const sources = try allocator.alloc(compiler.pipeline.SourceFile, jit_physics_module_specs.len);
    errdefer allocator.free(sources);
    const owned = try allocator.alloc([]u8, jit_physics_module_specs.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |buffer| allocator.free(buffer);
        allocator.free(owned);
    }
    for (jit_physics_module_specs, 0..) |spec, index| {
        const data: []u8 = if (spec.source) |literal| blk: {
            break :blk try allocator.dupe(u8, literal);
        } else blk: {
            const path = spec.path orelse return error.TestUnexpectedResult;
            break :blk try readRepoSource(allocator, path);
        };
        owned[index] = data;
        sources[index] = .{ .name = spec.name, .source = data };
        initialized = index + 1;
    }
    return .{ .sources = sources, .owned = owned, .allocator = allocator };
}

test "physics sleeping stack wakes when its support is removed" {
    var modules = try loadJitPhysicsModules(std.testing.allocator);
    defer modules.deinit();

    // Two pre-settled two-box stacks are seeded already asleep (sleep_state
    // [timer, 1.0]) with a 1 cm rest overlap so the support query sees contact.
    // Stack A despawns its lower box; stack B moves its lower box away.  Both
    // top boxes must wake in the next Update and then fall to the ground.
    const root_source =
        \\mod platform
        \\mod core
        \\mod physics
        \\use core::events::*;
        \\use core::ecs::*;
        \\use core::time::*;
        \\use core::input::*;
        \\use core::camera::*;
        \\use physics::broadphase::*;
        \\use physics::narrowphase::*;
        \\use physics::*;
        \\@resource
        \\pub Probe <- struct
        \\    top_a_sleep_before: i64
        \\    top_a_y_before: i64
        \\    bottom_a_sleep_before: i64
        \\    top_b_sleep_before: i64
        \\    top_a_sleep_after: i64
        \\    top_b_sleep_after: i64
        \\    top_a_y_after: i64
        \\    top_b_y_after: i64
        \\    support_a_rows_after: i64
        \\    support_b_rows_after: i64
        \\pub SnapshotBefore <- trigger
        \\pub RemoveSupport <- trigger
        \\pub SnapshotAfter <- trigger
        \\pub SnapshotFell <- trigger
        \\pub SleepStackScene <- plugin
        \\    sleep_stack_scene_plugin_init <- sys (commands: &mut Commands):
        \\        commands.insert_resource(Probe {
        \\            top_a_sleep_before: -1,
        \\            top_a_y_before: 0,
        \\            bottom_a_sleep_before: -1,
        \\            top_b_sleep_before: -1,
        \\            top_a_sleep_after: -1,
        \\            top_b_sleep_after: -1,
        \\            top_a_y_after: 0,
        \\            top_b_y_after: 0,
        \\            support_a_rows_after: 0,
        \\            support_b_rows_after: 0,
        \\        })
        \\        commands.insert_resource(Input {
        \\            window: 0,
        \\            move_forward: false, move_backward: false, move_left: false, move_right: false,
        \\            move_up: false, move_down: false, sprint: false,
        \\            look_left: false, look_right: false, look_up: false, look_down: false,
        \\            look_dx: 0.0, look_dy: 0.0,
        \\            jump_pressed: false, jump_down: false, jump_was_down: false,
        \\            interact: false, interact_pressed: false, interact_was_down: false,
        \\        })
        \\        sleepers := map[i64, [f32]] {}
        \\        sleepers[10] = [1.0, 1.0]
        \\        sleepers[11] = [1.0, 1.0]
        \\        sleepers[12] = [1.0, 1.0]
        \\        sleepers[13] = [1.0, 1.0]
        \\        commands.insert_resource(PhysicsWorld {
        \\            gravity_y: -30.0,
        \\            max_step: 0.05,
        \\            grounded: false,
        \\            jump_latched: false,
        \\            player_x: 0.0,
        \\            player_y: 0.0,
        \\            player_z: 0.0,
        \\            camera_yaw: 0.0,
        \\            camera_pitch: 0.0,
        \\            move_speed: 4.0,
        \\            quaternions: map[i64, [f32]] {},
        \\            plane_normal: [0.0, 1.0, 0.0],
        \\            plane_offset: 0.0,
        \\            friction: 0.9,
        \\            friction_static: 1.15,
        \\            pending_impulses: map[i64, [f32]] {},
        \\            sleep_state: sleepers,
        \\        })
        \\        index := 0
        \\        while index < 4:
        \\            body_id := 10 + index
        \\            x := 0.0
        \\            y := 0.5
        \\            if index == 1:
        \\                y = 1.49
        \\            if index == 2:
        \\                x = 5.0
        \\            if index == 3:
        \\                x = 5.0
        \\                y = 1.49
        \\            transform := Transform { translation: [x, y, 0.0], rotation: [0.0, 0.0, 0.0], scale: [1.0, 1.0, 1.0] }
        \\            id := BodyId { id: body_id }
        \\            bounds := BodyBounds { half_extents: [0.5, 0.5, 0.5] }
        \\            body := RigidBody {
        \\                velocity: [0.0, 0.0, 0.0],
        \\                angular_velocity: [0.0, 0.0, 0.0],
        \\                orientation: [0.0, 0.0, 0.0],
        \\                inv_mass: 1.0,
        \\                gravity_scale: 1.0,
        \\                rotation_locked: false,
        \\                is_static: false,
        \\            }
        \\            collider := BoxCollider { half_extents: [0.5, 0.5, 0.5] }
        \\            flags := BodyFlags { shape: 0, radius: 0.0, half_height: 0.0, is_player: false, is_pickup: false, target_id: body_id, held_by: 0 }
        \\            commands.add_row(Components, { transform, id, bounds, body, collider, flags })
        \\            index = index + 1
        \\@trigger(SnapshotBefore)
        \\pub snapshot_before <- sys (
        \\    world: res &PhysicsWorld,
        \\    rows: select &Transform, &BodyId from Components,
        \\    probe: res &mut Probe,
        \\):
        \\    for (transform, id) in rows:
        \\        sleeping := 0
        \\        entry := world.sleep_state[id.id]
        \\        if entry.len() >= 2:
        \\            if entry[1] > 0.5:
        \\                sleeping = 1
        \\        if id.id == 10:
        \\            probe.bottom_a_sleep_before = sleeping
        \\        if id.id == 11:
        \\            probe.top_a_sleep_before = sleeping
        \\            probe.top_a_y_before = f32::to_milli(transform.translation[1])
        \\        if id.id == 13:
        \\            probe.top_b_sleep_before = sleeping
        \\@trigger(RemoveSupport)
        \\pub remove_support <- sys (
        \\    rows: select &mut Transform, &BodyId from Components,
        \\    commands: &mut Commands,
        \\):
        \\    for (transform, id) in rows:
        \\        if id.id == 10:
        \\            commands.despawn(rows.entity())
        \\        if id.id == 12:
        \\            transform.translation[0] = 20.0
        \\@trigger(SnapshotAfter)
        \\pub snapshot_after <- sys (
        \\    world: res &PhysicsWorld,
        \\    rows: select &Transform, &BodyId from Components,
        \\    probe: res &mut Probe,
        \\):
        \\    for (transform, id) in rows:
        \\        sleeping := 0
        \\        entry := world.sleep_state[id.id]
        \\        if entry.len() >= 2:
        \\            if entry[1] > 0.5:
        \\                sleeping = 1
        \\        if id.id == 10:
        \\            probe.support_a_rows_after = probe.support_a_rows_after + 1
        \\        if id.id == 11:
        \\            probe.top_a_sleep_after = sleeping
        \\        if id.id == 12:
        \\            probe.support_b_rows_after = probe.support_b_rows_after + 1
        \\        if id.id == 13:
        \\            probe.top_b_sleep_after = sleeping
        \\@trigger(SnapshotFell)
        \\pub snapshot_fell <- sys (
        \\    rows: select &Transform, &BodyId from Components,
        \\    probe: res &mut Probe,
        \\):
        \\    for (transform, id) in rows:
        \\        if id.id == 11:
        \\            probe.top_a_y_after = f32::to_milli(transform.translation[1])
        \\        if id.id == 13:
        \\            probe.top_b_y_after = f32::to_milli(transform.translation[1])
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    commands.add_plugin(physics::broadphase::BroadphasePlugin)
        \\    commands.add_plugin(physics::narrowphase::NarrowphasePlugin)
        \\    commands.add_plugin(physics::PhysicsPlugin)
        \\    commands.add_plugin(SleepStackScene)
        \\    disown commands
        \\    await Init()
        \\    await Update()
        \\    await SnapshotBefore()
        \\    await RemoveSupport()
        \\    await Update()
        \\    await SnapshotAfter()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await SnapshotFell()
        \\    ret 0
    ;
    var compiled = try compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        modules.sources,
        .{},
    );
    defer compiled.deinit();
    if (!compiled.analysis.ok()) {
        for (compiled.analysis.diagnostics) |diagnostic| {
            std.debug.print("sleep support diagnostic {d}:{d} {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
    }
    try std.testing.expect(compiled.analysis.ok());
    ecs.e7_ecs_reset();
    defer ecs.e7_ecs_reset();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "physics-sleep-support");
    const Main = *const fn () callconv(.c) i64;
    const main_ctor = try jit.get(Main, "main");
    const handle = main_ctor();
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(handle));
    var probe_id: i64 = -1;
    for (compiled.analysis.resources) |resource| {
        if (std.mem.endsWith(u8, resource.name, "Probe")) probe_id = resource.id;
    }
    try std.testing.expect(probe_id >= 0);
    const probe_ptr = ecs.e7_ecs_resource(probe_id);
    try std.testing.expect(probe_ptr != 0);
    const top_a_sleep_before = aggregate.e7_load_i64(probe_ptr);
    const top_a_y_before = aggregate.e7_load_i64(probe_ptr + 8);
    const bottom_a_sleep_before = aggregate.e7_load_i64(probe_ptr + 16);
    const top_b_sleep_before = aggregate.e7_load_i64(probe_ptr + 24);
    const top_a_sleep_after = aggregate.e7_load_i64(probe_ptr + 32);
    const top_b_sleep_after = aggregate.e7_load_i64(probe_ptr + 40);
    const top_a_y_after = aggregate.e7_load_i64(probe_ptr + 48);
    const top_b_y_after = aggregate.e7_load_i64(probe_ptr + 56);
    const support_a_rows_after = aggregate.e7_load_i64(probe_ptr + 64);
    const support_b_rows_after = aggregate.e7_load_i64(probe_ptr + 72);
    // Both seeded stacks start asleep; the support pass must not wake them.
    try std.testing.expectEqual(@as(i64, 1), bottom_a_sleep_before);
    try std.testing.expectEqual(@as(i64, 1), top_a_sleep_before);
    try std.testing.expectEqual(@as(i64, 1), top_b_sleep_before);
    try std.testing.expectEqual(@as(i64, 1490), top_a_y_before);
    // Despawned support is gone; moved support still exists.
    try std.testing.expectEqual(@as(i64, 0), support_a_rows_after);
    try std.testing.expectEqual(@as(i64, 1), support_b_rows_after);
    // Wake-on-support-loss: one Update after removing/moving the support both
    // upper bodies are awake instead of frozen.
    try std.testing.expectEqual(@as(i64, 0), top_a_sleep_after);
    try std.testing.expectEqual(@as(i64, 0), top_b_sleep_after);
    // The woken bodies then fall: y drops from 1.49 to roughly the box rest
    // height (0.5) and stays above the ground plane.
    try std.testing.expect(top_a_y_after < 1200);
    try std.testing.expect(top_b_y_after < 1200);
    try std.testing.expect(top_a_y_after > 0);
    try std.testing.expect(top_b_y_after > 0);
}

// ---------------------------------------------------------------------------
// Quaternion-only rotation path (physics -> render)
// ---------------------------------------------------------------------------

test "quaternion model matrix matches the rotation formula" {
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);

    const probe =
        \\matrix_probe <- () -> i64:
        \\    out := ptr::alloc(64) as i64
        \\    score := 0
        \\    # Identity quaternion: R = I, scaled by (1, 1, 1) in metres.
        \\    object_model_matrix_quat(out, 1000, 1000, 1000, 0.0, 0.0, 0.0, 1.0)
        \\    if f32::abs(ptr::load_f32(out) - 1.0) < 0.0005:
        \\        score = score + 1
        \\    if f32::abs(ptr::load_f32(out + 20) - 1.0) < 0.0005:
        \\        score = score + 1
        \\    if f32::abs(ptr::load_f32(out + 40) - 1.0) < 0.0005:
        \\        score = score + 1
        \\    if f32::abs(ptr::load_f32(out + 60) - 1.0) < 0.0001:
        \\        score = score + 1
        \\    # +90 deg about Y with non-uniform scale (2, 3, 4) metres.
        \\    # R = [[0,0,1],[0,1,0],[-1,0,0]]; columns are (0,0,-2), (0,3,0), (4,0,0).
        \\    object_model_matrix_quat(out, 2000, 3000, 4000, 0.0, 0.7071067811865476, 0.0, 0.7071067811865476)
        \\    if f32::abs(ptr::load_f32(out)) < 1.0:
        \\        score = score + 1
        \\    if f32::abs(ptr::load_f32(out + 4)) < 1.0:
        \\        score = score + 1
        \\    if f32::abs(ptr::load_f32(out + 8) + 2.0) < 0.001:
        \\        score = score + 1
        \\    if f32::abs(ptr::load_f32(out + 16)) < 1.0:
        \\        score = score + 1
        \\    if f32::abs(ptr::load_f32(out + 20) - 3.0) < 0.001:
        \\        score = score + 1
        \\    if f32::abs(ptr::load_f32(out + 24)) < 1.0:
        \\        score = score + 1
        \\    if f32::abs(ptr::load_f32(out + 32) - 4.0) < 0.001:
        \\        score = score + 1
        \\    if f32::abs(ptr::load_f32(out + 36)) < 1.0:
        \\        score = score + 1
        \\    if f32::abs(ptr::load_f32(out + 40)) < 1.0:
        \\        score = score + 1
        \\    # A non-unit quaternion normalises to the same rotation.
        \\    object_model_matrix_quat(out, 2000, 3000, 4000, 0.0, 2.0, 0.0, 2.0)
        \\    if f32::abs(ptr::load_f32(out + 8) + 2.0) < 0.001:
        \\        score = score + 1
        \\    if f32::abs(ptr::load_f32(out + 32) - 4.0) < 0.001:
        \\        score = score + 1
        \\    # +90 deg about X: R = [[1,0,0],[0,0,-1],[0,1,0]]; columns (1,0,0),(0,0,1),(0,-1,0).
        \\    object_model_matrix_quat(out, 1000, 1000, 1000, 0.7071067811865476, 0.0, 0.0, 0.7071067811865476)
        \\    if f32::abs(ptr::load_f32(out) - 1.0) < 0.001:
        \\        score = score + 1
        \\    if f32::abs(ptr::load_f32(out + 24) - 1.0) < 0.001:
        \\        score = score + 1
        \\    if f32::abs(ptr::load_f32(out + 36) + 1.0) < 0.001:
        \\        score = score + 1
        \\    ptr::free(out)
        \\    ret score
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}\n{s}", .{ sdl_source, vk_source, scene_source, probe });
    defer std.testing.allocator.free(source);
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "quat-model-matrix");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "matrix_probe");
    try std.testing.expectEqual(@as(i64, 18), probe_fn());
}

test "quaternion draw uses the physics orientation for procedural meshes" {
    if (!canResolve("libSDL3.so", "SDL_CreateWindow") or !canResolve("libvulkan.so", "vkCreateInstance")) return error.SkipZigTest;
    const sdl_source = try readRepoSource(std.testing.allocator, "engine/platform/sdl.e7");
    defer std.testing.allocator.free(sdl_source);
    const vk_source = try readRepoSource(std.testing.allocator, "engine/platform/vulkan.e7");
    defer std.testing.allocator.free(vk_source);
    const scene_source = try readRepoSource(std.testing.allocator, "engine/platform/scene.e7");
    defer std.testing.allocator.free(scene_source);

    const probe =
        \\bright_width <- (scene: u64) -> i64:
        \\    pixels_out := ptr::alloc(8) as u64
        \\    size_out := ptr::alloc(8) as u64
        \\    drew := scene_draw(scene, pixels_out, size_out)
        \\    if drew == 0:
        \\        ptr::free(pixels_out)
        \\        ptr::free(size_out)
        \\        ret -1
        \\    pixels := ptr::load_u64(pixels_out)
        \\    width := scene_width(scene)
        \\    height := scene_height(scene)
        \\    min_x := width
        \\    max_x := -1
        \\    y := 0
        \\    while y < height:
        \\        x := 0
        \\        while x < width:
        \\            pixel := ptr::load_u32(pixels + (y * width + x) * 4)
        \\            # Ignore the alpha byte: only background RGB is zero.
        \\            if pixel % 16777216 != 0:
        \\                if x < min_x:
        \\                    min_x = x
        \\                if x > max_x:
        \\                    max_x = x
        \\            x = x + 1
        \\        y = y + 1
        \\    ptr::free(pixels)
        \\    ptr::free(pixels_out)
        \\    ptr::free(size_out)
        \\    if max_x < 0:
        \\        ret 0
        \\    span := max_x - min_x + 1
        \\    ret ((span) as f32) as i64
        \\render_probe <- () -> i64:
        \\    if video_init("dummy") == 0:
        \\        ret 0
        \\    win := window_create("e7 quat draw", 64, 48, 268435464)
        \\    if win == 0:
        \\        ret 0
        \\    scene := scene_create(win, 64, 48)
        \\    if scene == 0:
        \\        window_destroy(win)
        \\        ret -2
        \\    scene_set_camera(scene, 0, 0, 4000, 0, 0)
        \\    scene_set_light(scene, 2600, 3000, 2600, 1000, 900, 800, 4000)
        \\    # Elongated box (4 m wide, 2 m deep) seen down -Z: wide silhouette.
        \\    scene_begin_frame(scene)
        \\    scene_draw_shape_quat(scene, 0, 0, 0, 0, 2000, 1000, 1000, 0.0, 0.0, 0.0, 1.0, 1000, 1000, 1000, 0 as u64)
        \\    identity_width := bright_width(scene)
        \\    # +90 deg yaw from a quaternion: the same box now shows its 2 m side.
        \\    scene_begin_frame(scene)
        \\    sin_half := f32::sqrt(0.5)
        \\    scene_draw_shape_quat(scene, 0, 0, 0, 0, 2000, 1000, 1000, 0.0, sin_half, 0.0, sin_half, 1000, 1000, 1000, 0 as u64)
        \\    rotated_width := bright_width(scene)
        \\    scene_destroy(scene)
        \\    window_destroy(win)
        \\    video_quit()
        \\    if identity_width <= 0:
        \\        ret -3
        \\    if rotated_width <= 0:
        \\        ret -4
        \\    ret identity_width * 10000 + rotated_width
    ;
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}\n{s}\n{s}", .{ sdl_source, vk_source, scene_source, probe });
    defer std.testing.allocator.free(source);
    var compiled = try compiler.pipeline.compile(std.testing.allocator, source, .{});
    defer compiled.deinit();
    try std.testing.expect(compiled.analysis.ok());
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "quat-draw-width");
    const Probe = *const fn () callconv(.c) i64;
    const probe_fn = try jit.get(Probe, "render_probe");
    const result = probe_fn();
    if (result <= 0) {
        std.debug.print("skipping quaternion draw test: window/scene unavailable (code {d})\n", .{result});
        return error.SkipZigTest;
    }
    const identity_width: i64 = @divTrunc(result, 10000);
    const rotated_width: i64 = @mod(result, 10000);
    // A +90 deg yaw turns the 4 m along X into depth, so the projected width
    // must shrink by the box's 2:1 axis ratio (allow pipeline/pixel slack).
    try std.testing.expect(identity_width > rotated_width + 8);
    try std.testing.expect(rotated_width > 2);
}

/// Reference implementation of the fixed-step angular integration: q' =
/// normalize(q + 0.5 * dt * omega (x) q) with the same per-step 0.995 damping.
fn referenceAngularQuaternion(steps: usize) [4]f64 {
    var q = [4]f64{ 0.0, 0.0, 0.0, 1.0 };
    var omega: f64 = 2.0;
    const dt: f64 = 0.016;
    var step: usize = 0;
    while (step < steps) : (step += 1) {
        const half_dt = 0.5 * dt;
        const wy = omega * half_dt;
        const nx = q[0] + wy * q[2];
        const ny = q[1] + wy * q[3];
        const nz = q[2] - wy * q[0];
        const nw = q[3] - wy * q[1];
        const length = @sqrt(nx * nx + ny * ny + nz * nz + nw * nw);
        q = .{ nx / length, ny / length, nz / length, nw / length };
        omega *= 0.995;
    }
    return q;
}

fn expectMilliNear(expected: f64, actual: i64, tolerance: i64) !void {
    const expected_milli: i64 = @intFromFloat(expected * 1000000.0);
    const delta = if (actual >= expected_milli) actual - expected_milli else expected_milli - actual;
    try std.testing.expect(delta <= tolerance);
}

test "physics publishes the integrated quaternion with no Euler round-trip" {
    var modules = try loadJitPhysicsModules(std.testing.allocator);
    defer modules.deinit();
    const root_source =
        \\mod platform
        \\mod core
        \\mod physics
        \\use core::events::*;
        \\use core::ecs::*;
        \\use core::time::*;
        \\use core::input::*;
        \\use core::camera::*;
        \\use physics::broadphase::*;
        \\use physics::narrowphase::*;
        \\use physics::*;
        \\use platform::scene::*;
        \\@resource
        \\pub Probe <- struct
        \\    qx: i64
        \\    qy: i64
        \\    qz: i64
        \\    qw: i64
        \\    map_qx: i64
        \\    map_qy: i64
        \\    map_qz: i64
        \\    map_qw: i64
        \\    m00: i64
        \\    m02: i64
        \\    m20: i64
        \\    m22: i64
        \\    rot_x: i64
        \\    rot_y: i64
        \\    rot_z: i64
        \\pub Capture <- trigger
        \\pub QuatScene <- plugin
        \\    quat_scene_plugin_init <- sys (commands: &mut Commands):
        \\        commands.insert_resource(Probe { qx: 0, qy: 0, qz: 0, qw: 0, map_qx: 0, map_qy: 0, map_qz: 0, map_qw: 0, m00: 0, m02: 0, m20: 0, m22: 0, rot_x: 0, rot_y: 0, rot_z: 0 })
        \\        commands.insert_resource(Input {
        \\            window: 0,
        \\            move_forward: false, move_backward: false, move_left: false, move_right: false,
        \\            move_up: false, move_down: false, sprint: false,
        \\            look_left: false, look_right: false, look_up: false, look_down: false,
        \\            look_dx: 0.0, look_dy: 0.0,
        \\            jump_pressed: false, jump_down: false, jump_was_down: false,
        \\            interact: false, interact_pressed: false, interact_was_down: false,
        \\        })
        \\        commands.insert_resource(PhysicsWorld {
        \\            gravity_y: 0.0,
        \\            max_step: 0.05,
        \\            grounded: false,
        \\            jump_latched: false,
        \\            player_x: 0.0,
        \\            player_y: 0.0,
        \\            player_z: 0.0,
        \\            camera_yaw: 0.0,
        \\            camera_pitch: 0.0,
        \\            move_speed: 4.0,
        \\            quaternions: map[i64, [f32]] {},
        \\            plane_normal: [0.0, 1.0, 0.0],
        \\            plane_offset: 0.0,
        \\            friction: 0.9,
        \\            friction_static: 1.15,
        \\            pending_impulses: map[i64, [f32]] {},
        \\            sleep_state: map[i64, [f32]] {},
        \\        })
        \\        body_transform := Transform { translation: [0.0, 100.0, 0.0], rotation: [0.0, 0.0, 0.0], scale: [1.0, 1.0, 1.0] }
        \\        body_id := BodyId { id: 7 }
        \\        body_bounds := BodyBounds { half_extents: [0.5, 0.5, 0.5] }
        \\        body := RigidBody {
        \\            velocity: [0.0, 0.0, 0.0],
        \\            angular_velocity: [0.0, 2.0, 0.0],
        \\            orientation: [0.0, 0.0, 0.0],
        \\            inv_mass: 1.0,
        \\            gravity_scale: 1.0,
        \\            rotation_locked: false,
        \\            is_static: false,
        \\        }
        \\        collider := BoxCollider { half_extents: [0.5, 0.5, 0.5] }
        \\        flags := BodyFlags { shape: 0, radius: 0.0, half_height: 0.0, is_player: false, is_pickup: false, target_id: 7, held_by: 0 }
        \\        orientation := BodyOrientation { x: 0.0, y: 0.0, z: 0.0, w: 1.0 }
        \\        commands.add_row(Components, { body_transform, body_id, body_bounds, body, collider, flags, orientation })
        \\@trigger(Capture)
        \\pub capture <- sys (
        \\    world: res &PhysicsWorld,
        \\    orientations: select &BodyOrientation, &BodyId from Components,
        \\    bodies: select &Transform, &BodyId from Components,
        \\    probe: res &mut Probe,
        \\):
        \\    for (orientation, id) in orientations:
        \\        if id.id == 7:
        \\            probe.qx = (orientation.x * 1000000.0) as i64
        \\            probe.qy = (orientation.y * 1000000.0) as i64
        \\            probe.qz = (orientation.z * 1000000.0) as i64
        \\            probe.qw = (orientation.w * 1000000.0) as i64
        \\            out := ptr::alloc(64) as i64
        \\            object_model_matrix_quat(out, 1000, 1000, 1000, orientation.x, orientation.y, orientation.z, orientation.w)
        \\            probe.m00 = (ptr::load_f32(out) * 1000000.0) as i64
        \\            probe.m02 = (ptr::load_f32(out + 8) * 1000000.0) as i64
        \\            probe.m20 = (ptr::load_f32(out + 32) * 1000000.0) as i64
        \\            probe.m22 = (ptr::load_f32(out + 40) * 1000000.0) as i64
        \\            ptr::free(out)
        \\            qv := world.quaternions[id.id]
        \\            if qv.len() >= 4:
        \\                probe.map_qx = (qv[0] * 1000000.0) as i64
        \\                probe.map_qy = (qv[1] * 1000000.0) as i64
        \\                probe.map_qz = (qv[2] * 1000000.0) as i64
        \\                probe.map_qw = (qv[3] * 1000000.0) as i64
        \\    for (transform, id) in bodies:
        \\        if id.id == 7:
        \\            probe.rot_x = (transform.rotation[0] * 1000000.0) as i64
        \\            probe.rot_y = (transform.rotation[1] * 1000000.0) as i64
        \\            probe.rot_z = (transform.rotation[2] * 1000000.0) as i64
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    commands.add_plugin(physics::broadphase::BroadphasePlugin)
        \\    commands.add_plugin(physics::narrowphase::NarrowphasePlugin)
        \\    commands.add_plugin(physics::PhysicsPlugin)
        \\    commands.add_plugin(QuatScene)
        \\    disown commands
        \\    await Init()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await PostUpdate()
        \\    await Capture()
        \\    ret 0
    ;
    var compiled = try compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        modules.sources,
        .{},
    );
    defer compiled.deinit();
    if (!compiled.analysis.ok()) {
        for (compiled.analysis.diagnostics) |diagnostic| {
            std.debug.print("quat integration diagnostic {d}:{d} {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
    }
    try std.testing.expect(compiled.analysis.ok());
    ecs.e7_ecs_reset();
    defer ecs.e7_ecs_reset();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "quat-integration");
    const Main = *const fn () callconv(.c) i64;
    const main_ctor = try jit.get(Main, "main");
    const handle = main_ctor();
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(handle));

    var probe_id: i64 = -1;
    for (compiled.analysis.resources) |resource| {
        if (std.mem.endsWith(u8, resource.name, "Probe")) probe_id = resource.id;
    }
    try std.testing.expect(probe_id >= 0);
    const probe_ptr = ecs.e7_ecs_resource(probe_id);
    try std.testing.expect(probe_ptr != 0);
    const qx = aggregate.e7_load_i64(probe_ptr);
    const qy = aggregate.e7_load_i64(probe_ptr + 8);
    const qz = aggregate.e7_load_i64(probe_ptr + 16);
    const qw = aggregate.e7_load_i64(probe_ptr + 24);
    const map_qx = aggregate.e7_load_i64(probe_ptr + 32);
    const map_qy = aggregate.e7_load_i64(probe_ptr + 40);
    const map_qz = aggregate.e7_load_i64(probe_ptr + 48);
    const map_qw = aggregate.e7_load_i64(probe_ptr + 56);
    const m00 = aggregate.e7_load_i64(probe_ptr + 64);
    const m02 = aggregate.e7_load_i64(probe_ptr + 72);
    const m20 = aggregate.e7_load_i64(probe_ptr + 80);
    const m22 = aggregate.e7_load_i64(probe_ptr + 88);
    const rot_x = aggregate.e7_load_i64(probe_ptr + 96);
    const rot_y = aggregate.e7_load_i64(probe_ptr + 104);
    const rot_z = aggregate.e7_load_i64(probe_ptr + 112);

    // No collisions: the physics quaternion matches the reference integration.
    const expected = referenceAngularQuaternion(100);
    try expectMilliNear(expected[0], qx, 3);
    try expectMilliNear(expected[1], qy, 3);
    try expectMilliNear(expected[2], qz, 3);
    try expectMilliNear(expected[3], qw, 3);
    // BodyOrientation is exactly the physics quaternion (render source).
    try std.testing.expect(@abs(qx - map_qx) <= 1);
    try std.testing.expect(@abs(qy - map_qy) <= 1);
    try std.testing.expect(@abs(qz - map_qz) <= 1);
    try std.testing.expect(@abs(qw - map_qw) <= 1);
    // The quaternion stays normalised.
    const norm = @sqrt(@as(f64, @floatFromInt(qx * qx + qy * qy + qz * qz + qw * qw)) / 1000000000000.0);
    try std.testing.expect(@abs(norm - 1.0) < 0.0005);
    // The model matrix is built from that quaternion (R entries for a pure-Y spin).
    const ex = expected[0];
    const ey = expected[1];
    const ez = expected[2];
    const ew = expected[3];
    try expectMilliNear(1.0 - 2.0 * (ey * ey + ez * ez), m00, 3);
    // out is column-major: m02 (slot +8) is R20, m20 (slot +32) is R02.
    try expectMilliNear(2.0 * (ex * ez - ew * ey), m02, 3);
    try expectMilliNear(2.0 * (ex * ez + ew * ey), m20, 3);
    try expectMilliNear(1.0 - 2.0 * (ex * ex + ey * ey), m22, 3);
    // Dynamic bodies never write the Euler Transform mirror.
    try std.testing.expectEqual(@as(i64, 0), rot_x);
    try std.testing.expectEqual(@as(i64, 0), rot_y);
    try std.testing.expectEqual(@as(i64, 0), rot_z);
}

test "quaternion stack contacts keep render orientation consistent" {
    var modules = try loadJitPhysicsModules(std.testing.allocator);
    defer modules.deinit();
    const root_source =
        \\mod platform
        \\mod core
        \\mod physics
        \\use core::events::*;
        \\use core::ecs::*;
        \\use core::time::*;
        \\use core::input::*;
        \\use core::camera::*;
        \\use physics::broadphase::*;
        \\use physics::narrowphase::*;
        \\use physics::*;
        \\use platform::scene::*;
        \\@resource
        \\pub Probe <- struct
        \\    up_qx: i64
        \\    up_qy: i64
        \\    up_qz: i64
        \\    up_qw: i64
        \\    map_qx: i64
        \\    map_qy: i64
        \\    map_qz: i64
        \\    map_qw: i64
        \\    m00: i64
        \\    m02: i64
        \\    m20: i64
        \\    m22: i64
        \\    rot_x: i64
        \\    rot_y: i64
        \\    rot_z: i64
        \\    low_y: i64
        \\    up_y: i64
        \\pub Capture <- trigger
        \\pub StackQuatScene <- plugin
        \\    stack_quat_scene_plugin_init <- sys (commands: &mut Commands):
        \\        commands.insert_resource(Probe { up_qx: 0, up_qy: 0, up_qz: 0, up_qw: 0, map_qx: 0, map_qy: 0, map_qz: 0, map_qw: 0, m00: 0, m02: 0, m20: 0, m22: 0, rot_x: 0, rot_y: 0, rot_z: 0, low_y: 0, up_y: 0 })
        \\        commands.insert_resource(Input {
        \\            window: 0,
        \\            move_forward: false, move_backward: false, move_left: false, move_right: false,
        \\            move_up: false, move_down: false, sprint: false,
        \\            look_left: false, look_right: false, look_up: false, look_down: false,
        \\            look_dx: 0.0, look_dy: 0.0,
        \\            jump_pressed: false, jump_down: false, jump_was_down: false,
        \\            interact: false, interact_pressed: false, interact_was_down: false,
        \\        })
        \\        commands.insert_resource(PhysicsWorld {
        \\            gravity_y: -30.0,
        \\            max_step: 0.05,
        \\            grounded: false,
        \\            jump_latched: false,
        \\            player_x: 0.0,
        \\            player_y: 0.0,
        \\            player_z: 0.0,
        \\            camera_yaw: 0.0,
        \\            camera_pitch: 0.0,
        \\            move_speed: 4.0,
        \\            quaternions: map[i64, [f32]] {},
        \\            plane_normal: [0.0, 1.0, 0.0],
        \\            plane_offset: 0.0,
        \\            friction: 0.9,
        \\            friction_static: 1.15,
        \\            pending_impulses: map[i64, [f32]] {},
        \\            sleep_state: map[i64, [f32]] {},
        \\        })
        \\        lower_transform := Transform { translation: [0.0, 0.5, 0.0], rotation: [0.04, 0.0, 0.03], scale: [1.0, 1.0, 1.0] }
        \\        lower_id := BodyId { id: 10 }
        \\        lower_bounds := BodyBounds { half_extents: [0.5, 0.5, 0.5] }
        \\        lower_body := RigidBody { velocity: [0.0, 0.0, 0.0], angular_velocity: [0.0, 0.0, 0.0], orientation: [0.0, 0.0, 0.0], inv_mass: 1.0, gravity_scale: 1.0, rotation_locked: false, is_static: false }
        \\        lower_collider := BoxCollider { half_extents: [0.5, 0.5, 0.5] }
        \\        lower_flags := BodyFlags { shape: 0, radius: 0.0, half_height: 0.0, is_player: false, is_pickup: false, target_id: 10, held_by: 0 }
        \\        lower_orientation := BodyOrientation { x: 0.0, y: 0.0, z: 0.0, w: 1.0 }
        \\        commands.add_row(Components, { lower_transform, lower_id, lower_bounds, lower_body, lower_collider, lower_flags, lower_orientation })
        \\        upper_transform := Transform { translation: [0.0, 1.5, 0.0], rotation: [0.04, 0.0, 0.03], scale: [1.0, 1.0, 1.0] }
        \\        upper_id := BodyId { id: 11 }
        \\        upper_bounds := BodyBounds { half_extents: [0.5, 0.5, 0.5] }
        \\        upper_body := RigidBody { velocity: [0.0, 0.0, 0.0], angular_velocity: [0.0, 0.0, 0.0], orientation: [0.0, 0.0, 0.0], inv_mass: 1.0, gravity_scale: 1.0, rotation_locked: false, is_static: false }
        \\        upper_collider := BoxCollider { half_extents: [0.5, 0.5, 0.5] }
        \\        upper_flags := BodyFlags { shape: 0, radius: 0.0, half_height: 0.0, is_player: false, is_pickup: false, target_id: 11, held_by: 0 }
        \\        upper_orientation := BodyOrientation { x: 0.0, y: 0.0, z: 0.0, w: 1.0 }
        \\        commands.add_row(Components, { upper_transform, upper_id, upper_bounds, upper_body, upper_collider, upper_flags, upper_orientation })
        \\@trigger(Capture)
        \\pub capture <- sys (
        \\    world: res &PhysicsWorld,
        \\    orientations: select &BodyOrientation, &BodyId from Components,
        \\    bodies: select &Transform, &BodyId from Components,
        \\    probe: res &mut Probe,
        \\):
        \\    for (orientation, id) in orientations:
        \\        if id.id == 11:
        \\            probe.up_qx = (orientation.x * 1000000.0) as i64
        \\            probe.up_qy = (orientation.y * 1000000.0) as i64
        \\            probe.up_qz = (orientation.z * 1000000.0) as i64
        \\            probe.up_qw = (orientation.w * 1000000.0) as i64
        \\            out := ptr::alloc(64) as i64
        \\            object_model_matrix_quat(out, 1000, 1000, 1000, orientation.x, orientation.y, orientation.z, orientation.w)
        \\            probe.m00 = (ptr::load_f32(out) * 1000000.0) as i64
        \\            probe.m02 = (ptr::load_f32(out + 8) * 1000000.0) as i64
        \\            probe.m20 = (ptr::load_f32(out + 32) * 1000000.0) as i64
        \\            probe.m22 = (ptr::load_f32(out + 40) * 1000000.0) as i64
        \\            ptr::free(out)
        \\            qv := world.quaternions[id.id]
        \\            if qv.len() >= 4:
        \\                probe.map_qx = (qv[0] * 1000000.0) as i64
        \\                probe.map_qy = (qv[1] * 1000000.0) as i64
        \\                probe.map_qz = (qv[2] * 1000000.0) as i64
        \\                probe.map_qw = (qv[3] * 1000000.0) as i64
        \\    for (transform, id) in bodies:
        \\        if id.id == 10:
        \\            probe.low_y = f32::to_milli(transform.translation[1])
        \\        if id.id == 11:
        \\            probe.up_y = f32::to_milli(transform.translation[1])
        \\            probe.rot_x = (transform.rotation[0] * 1000000.0) as i64
        \\            probe.rot_y = (transform.rotation[1] * 1000000.0) as i64
        \\            probe.rot_z = (transform.rotation[2] * 1000000.0) as i64
        \\main <- async () -> i32:
        \\    commands := await query &mut Commands
        \\    commands.add_plugin(physics::broadphase::BroadphasePlugin)
        \\    commands.add_plugin(physics::narrowphase::NarrowphasePlugin)
        \\    commands.add_plugin(physics::PhysicsPlugin)
        \\    commands.add_plugin(StackQuatScene)
        \\    disown commands
        \\    await Init()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await Update()
        \\    await PostUpdate()
        \\    await Capture()
        \\    ret 0
    ;
    var compiled = try compiler.pipeline.compileProjectFromSources(
        std.testing.allocator,
        root_source,
        modules.sources,
        .{},
    );
    defer compiled.deinit();
    if (!compiled.analysis.ok()) {
        for (compiled.analysis.diagnostics) |diagnostic| {
            std.debug.print("stack quat diagnostic {d}:{d} {s}\n", .{ diagnostic.span.line, diagnostic.span.column, diagnostic.message });
        }
    }
    try std.testing.expect(compiled.analysis.ok());
    ecs.e7_ecs_reset();
    defer ecs.e7_ecs_reset();
    var jit = try orc.Jit.init(std.testing.allocator);
    defer jit.deinit();
    try jit.addBytecode(&compiled.bytecode, "stack-quat");
    const Main = *const fn () callconv(.c) i64;
    const main_ctor = try jit.get(Main, "main");
    const handle = main_ctor();
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(handle));

    var probe_id: i64 = -1;
    for (compiled.analysis.resources) |resource| {
        if (std.mem.endsWith(u8, resource.name, "Probe")) probe_id = resource.id;
    }
    try std.testing.expect(probe_id >= 0);
    const probe_ptr = ecs.e7_ecs_resource(probe_id);
    try std.testing.expect(probe_ptr != 0);
    const up_qx = aggregate.e7_load_i64(probe_ptr);
    const up_qy = aggregate.e7_load_i64(probe_ptr + 8);
    const up_qz = aggregate.e7_load_i64(probe_ptr + 16);
    const up_qw = aggregate.e7_load_i64(probe_ptr + 24);
    const map_qx = aggregate.e7_load_i64(probe_ptr + 32);
    const map_qy = aggregate.e7_load_i64(probe_ptr + 40);
    const map_qz = aggregate.e7_load_i64(probe_ptr + 48);
    const map_qw = aggregate.e7_load_i64(probe_ptr + 56);
    const m00 = aggregate.e7_load_i64(probe_ptr + 64);
    const m02 = aggregate.e7_load_i64(probe_ptr + 72);
    const m20 = aggregate.e7_load_i64(probe_ptr + 80);
    const m22 = aggregate.e7_load_i64(probe_ptr + 88);
    const rot_x = aggregate.e7_load_i64(probe_ptr + 96);
    const rot_y = aggregate.e7_load_i64(probe_ptr + 104);
    const rot_z = aggregate.e7_load_i64(probe_ptr + 112);
    const low_y = aggregate.e7_load_i64(probe_ptr + 120);
    const up_y = aggregate.e7_load_i64(probe_ptr + 128);

    // Stack stays stacked through 240 contact steps (no tunnelling/explosion)
    // and the upper body keeps its authored Euler mirror untouched.
    try std.testing.expect(low_y > 200 and low_y < 800);
    try std.testing.expect(up_y > 1000 and up_y < 2000);
    try std.testing.expectEqual(@as(i64, 40000), rot_x);
    try std.testing.expectEqual(@as(i64, 0), rot_y);
    try std.testing.expectEqual(@as(i64, 30), @divTrunc(rot_z, 1000));
    // Collision response publishes the same normalised quaternion to the
    // render component that the solver integrated.
    try std.testing.expect(@abs(up_qx - map_qx) <= 1);
    try std.testing.expect(@abs(up_qy - map_qy) <= 1);
    try std.testing.expect(@abs(up_qz - map_qz) <= 1);
    try std.testing.expect(@abs(up_qw - map_qw) <= 1);
    const norm = @sqrt(@as(f64, @floatFromInt(up_qx * up_qx + up_qy * up_qy + up_qz * up_qz + up_qw * up_qw)) / 1000000000000.0);
    try std.testing.expect(@abs(norm - 1.0) < 0.001);
    // The rendered model matrix is derived directly from that quaternion.
    const qx: f64 = @as(f64, @floatFromInt(up_qx)) / 1000000.0;
    const qy: f64 = @as(f64, @floatFromInt(up_qy)) / 1000000.0;
    const qz: f64 = @as(f64, @floatFromInt(up_qz)) / 1000000.0;
    const qw: f64 = @as(f64, @floatFromInt(up_qw)) / 1000000.0;
    try expectMilliNear(1.0 - 2.0 * (qy * qy + qz * qz), m00, 4);
    // Column-major slots: +8 holds R20, +32 holds R02.
    try expectMilliNear(2.0 * (qx * qz - qw * qy), m02, 4);
    try expectMilliNear(2.0 * (qx * qz + qw * qy), m20, 4);
    try expectMilliNear(1.0 - 2.0 * (qx * qx + qy * qy), m22, 4);
}
