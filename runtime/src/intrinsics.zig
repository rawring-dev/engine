//! Runtime intrinsics: the stable C ABI callable from LLVM ORC-JITed code.
//!
//! Every entry point takes plain integers, floats, pointers, and lengths.  It
//! never exposes Zig slices, error unions, allocators, or opaque Zig types.
//! Strings are `(pointer, length)` pairs; byte results are malloc-owned and
//! released with `e7_free`.  Handles are `u64` ids validated by the owning
//! subsystem.
//!
//! `symbols()` is the complete manifest registered with `Jit.defineSymbols`.
//! `declarations` is the matching LLVM IR declaration block; prepend or append
//! it to generated IR so calls are typed before ORC resolves them.

const std = @import("std");
const abi = @import("ffi/abi.zig");
const time = @import("ffi/time.zig");
const fs = @import("ffi/fs.zig");
const net = @import("ffi/net.zig");
const http = @import("ffi/http.zig");
const quic = @import("ffi/quic.zig");
const webrtc = @import("ffi/webrtc.zig");
const stdio = @import("ffi/stdio.zig");
const dl = @import("ffi/dl.zig");

pub const Symbol = abi.Symbol;

fn begin() void {
    abi.clearError();
}

fn ok() i32 {
    return abi.code(.ok);
}

fn invalid() i32 {
    abi.setError("invalid argument");
    return abi.code(.invalid_argument);
}

fn fail(err: anyerror) i32 {
    return abi.fail(err);
}

fn input(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return &.{};
    const p = ptr orelse return null;
    return p[0..len];
}

fn mutable(ptr: ?[*]u8, len: usize) ?[]u8 {
    if (len == 0) return null;
    const p = ptr orelse return null;
    return p[0..len];
}

fn output(data: []const u8, out_ptr: ?*?[*]u8, out_len: ?*usize) i32 {
    const op = out_ptr orelse return invalid();
    const ol = out_len orelse return invalid();
    if (data.len == 0) {
        op.* = null;
        ol.* = 0;
        return ok();
    }
    const copy = std.heap.c_allocator.dupe(u8, data) catch return fail(error.OutOfMemory);
    op.* = copy.ptr;
    ol.* = copy.len;
    return ok();
}

fn transfer(allocated: []u8, out_ptr: ?*?[*]u8, out_len: ?*usize) i32 {
    const op = out_ptr orelse {
        std.heap.c_allocator.free(allocated);
        return invalid();
    };
    const ol = out_len orelse {
        std.heap.c_allocator.free(allocated);
        return invalid();
    };
    if (allocated.len == 0) {
        std.heap.c_allocator.free(allocated);
        op.* = null;
        ol.* = 0;
        return ok();
    }
    op.* = allocated.ptr;
    ol.* = allocated.len;
    return ok();
}

// ---------------------------------------------------------------- core -------

pub export fn e7_clock_ns() callconv(.c) u64 {
    return time.nowNs();
}

pub export fn e7_sleep_ms(milliseconds: u64) callconv(.c) void {
    time.sleepMs(milliseconds);
}

pub export fn e7_log(level: i32, text: ?[*]const u8, len: usize) callconv(.c) void {
    const message = input(text, len) orelse return;
    const prefix = switch (level) {
        0 => "debug",
        1 => "info",
        2 => "warn",
        else => "error",
    };
    std.debug.print("[{s}] {s}\n", .{ prefix, message });
}

// ---------------------------------------------------------------- STDIO ------

pub export fn e7_stdio_write(
    stream_id: i32,
    data: ?[*]const u8,
    data_len: usize,
    out_written: ?*usize,
) callconv(.c) i32 {
    begin();
    const stream = stdio.fromInt(stream_id) catch {
        abi.setError("invalid stdio stream (0=stdin, 1=stdout, 2=stderr)");
        return invalid();
    };
    const bytes = input(data, data_len) orelse return invalid();
    stdio.write(stream, bytes) catch |err| return fail(err);
    if (out_written) |value| value.* = bytes.len;
    return ok();
}

pub export fn e7_stdio_read(
    stream_id: i32,
    buffer: ?[*]u8,
    capacity: usize,
    out_read: ?*usize,
) callconv(.c) i32 {
    begin();
    const stream = stdio.fromInt(stream_id) catch {
        abi.setError("invalid stdio stream (0=stdin, 1=stdout, 2=stderr)");
        return invalid();
    };
    if (capacity == 0) {
        if (out_read) |value| value.* = 0;
        return ok();
    }
    const dest = mutable(buffer, capacity) orelse return invalid();
    const n = stdio.read(stream, dest) catch |err| return fail(err);
    if (out_read) |value| value.* = n;
    return ok();
}

pub export fn e7_stdio_read_line(
    stream_id: i32,
    buffer: ?[*]u8,
    capacity: usize,
    out_read: ?*usize,
    out_eof: ?*i32,
) callconv(.c) i32 {
    begin();
    const stream = stdio.fromInt(stream_id) catch {
        abi.setError("invalid stdio stream (0=stdin, 1=stdout, 2=stderr)");
        return invalid();
    };
    const dest = mutable(buffer, capacity) orelse return invalid();
    const result = stdio.readLine(stream, dest) catch |err| return fail(err);
    if (result) |n| {
        if (out_read) |value| value.* = n;
        if (out_eof) |value| value.* = 0;
    } else {
        if (out_read) |value| value.* = 0;
        if (out_eof) |value| value.* = 1;
    }
    return ok();
}

pub export fn e7_stdio_is_tty(stream_id: i32) callconv(.c) i32 {
    begin();
    const stream = stdio.fromInt(stream_id) catch {
        abi.setError("invalid stdio stream (0=stdin, 1=stdout, 2=stderr)");
        return -1;
    };
    return if (stdio.isTty(stream)) 1 else 0;
}

pub export fn e7_stdio_flush(stream_id: i32) callconv(.c) i32 {
    begin();
    const stream = stdio.fromInt(stream_id) catch {
        abi.setError("invalid stdio stream (0=stdin, 1=stdout, 2=stderr)");
        return invalid();
    };
    stdio.flush(stream) catch |err| return fail(err);
    return ok();
}

// ------------------------------------------------------------------- fs ------

pub export fn e7_fs_root(out_ptr: ?*?[*]u8, out_len: ?*usize) callconv(.c) i32 {
    begin();
    const sandbox = fs.global() orelse return fail(error.SandboxUnavailable);
    return output(sandbox.rootPath(), out_ptr, out_len);
}

pub export fn e7_fs_read(path: ?[*]const u8, path_len: usize, out_ptr: ?*?[*]u8, out_len: ?*usize) callconv(.c) i32 {
    begin();
    const sandbox = fs.global() orelse return fail(error.SandboxUnavailable);
    const name = input(path, path_len) orelse return invalid();
    const data = sandbox.read(name) catch |err| return fail(err);
    return transfer(data, out_ptr, out_len);
}

pub export fn e7_fs_write(
    path: ?[*]const u8,
    path_len: usize,
    data: ?[*]const u8,
    data_len: usize,
    append: i32,
) callconv(.c) i32 {
    begin();
    const sandbox = fs.global() orelse return fail(error.SandboxUnavailable);
    const name = input(path, path_len) orelse return invalid();
    const bytes = input(data, data_len) orelse return invalid();
    sandbox.write(name, bytes, append != 0) catch |err| return fail(err);
    return ok();
}

pub export fn e7_fs_exists(path: ?[*]const u8, path_len: usize) callconv(.c) i32 {
    begin();
    const sandbox = fs.global() orelse return -1;
    const name = input(path, path_len) orelse return -1;
    return if (sandbox.exists(name)) 1 else 0;
}

pub export fn e7_fs_stat(
    path: ?[*]const u8,
    path_len: usize,
    out_size: ?*u64,
    out_kind: ?*i32,
    out_mtime_ns: ?*i64,
) callconv(.c) i32 {
    begin();
    const sandbox = fs.global() orelse return fail(error.SandboxUnavailable);
    const name = input(path, path_len) orelse return invalid();
    const st = sandbox.stat(name) catch |err| return fail(err);
    if (out_size) |size| size.* = st.size;
    if (out_kind) |kind| kind.* = @intFromEnum(st.kind);
    if (out_mtime_ns) |mtime| mtime.* = @intCast(std.math.clamp(st.mtime_ns, std.math.minInt(i64), std.math.maxInt(i64)));
    return ok();
}

pub export fn e7_fs_list(path: ?[*]const u8, path_len: usize, out_ptr: ?*?[*]u8, out_len: ?*usize) callconv(.c) i32 {
    begin();
    const sandbox = fs.global() orelse return fail(error.SandboxUnavailable);
    const name = input(path, path_len) orelse return invalid();
    const listing = sandbox.list(name) catch |err| return fail(err);
    return transfer(listing, out_ptr, out_len);
}

pub export fn e7_fs_mkdir(path: ?[*]const u8, path_len: usize) callconv(.c) i32 {
    begin();
    const sandbox = fs.global() orelse return fail(error.SandboxUnavailable);
    const name = input(path, path_len) orelse return invalid();
    sandbox.mkdir(name) catch |err| return fail(err);
    return ok();
}

pub export fn e7_fs_remove(path: ?[*]const u8, path_len: usize) callconv(.c) i32 {
    begin();
    const sandbox = fs.global() orelse return fail(error.SandboxUnavailable);
    const name = input(path, path_len) orelse return invalid();
    sandbox.removeFile(name) catch |err| return fail(err);
    return ok();
}

pub export fn e7_fs_remove_tree(path: ?[*]const u8, path_len: usize) callconv(.c) i32 {
    begin();
    const sandbox = fs.global() orelse return fail(error.SandboxUnavailable);
    const name = input(path, path_len) orelse return invalid();
    sandbox.removeTree(name) catch |err| return fail(err);
    return ok();
}

pub export fn e7_fs_rename(
    from: ?[*]const u8,
    from_len: usize,
    to: ?[*]const u8,
    to_len: usize,
) callconv(.c) i32 {
    begin();
    const sandbox = fs.global() orelse return fail(error.SandboxUnavailable);
    const src = input(from, from_len) orelse return invalid();
    const dst = input(to, to_len) orelse return invalid();
    sandbox.rename(src, dst) catch |err| return fail(err);
    return ok();
}

// ------------------------------------------------------------------ TCP ------

pub export fn e7_tcp_listen(host: ?[*]const u8, host_len: usize, port: u16) callconv(.c) u64 {
    begin();
    const name = input(host, host_len) orelse return 0;
    const listener = net.Listener.listen(name, port, 128) catch |err| {
        _ = fail(err);
        return 0;
    };
    return net.listeners.create(listener) catch |err| {
        var copy = listener;
        copy.close();
        _ = fail(err);
        return 0;
    };
}

pub export fn e7_tcp_accept(listener_handle: u64, timeout_ms: u32) callconv(.c) u64 {
    begin();
    const listener = net.listeners.get(listener_handle) orelse {
        _ = fail(error.InvalidHandle);
        return 0;
    };
    const conn = listener.accept(timeout_ms) catch |err| {
        _ = fail(err);
        return 0;
    };
    return net.connections.create(conn) catch |err| {
        var copy = conn;
        copy.close();
        _ = fail(err);
        return 0;
    };
}

pub export fn e7_tcp_connect(host: ?[*]const u8, host_len: usize, port: u16, timeout_ms: u32) callconv(.c) u64 {
    begin();
    const name = input(host, host_len) orelse return 0;
    const conn = net.Connection.connect(name, port, timeout_ms) catch |err| {
        _ = fail(err);
        return 0;
    };
    return net.connections.create(conn) catch |err| {
        var copy = conn;
        copy.close();
        _ = fail(err);
        return 0;
    };
}

pub export fn e7_tcp_send(conn_handle: u64, data: ?[*]const u8, data_len: usize, out_sent: ?*usize) callconv(.c) i32 {
    begin();
    const conn = net.connections.get(conn_handle) orelse return fail(error.InvalidHandle);
    const bytes = input(data, data_len) orelse return invalid();
    const sent = conn.send(bytes) catch |err| return fail(err);
    if (out_sent) |value| value.* = sent;
    return ok();
}

pub export fn e7_tcp_recv(
    conn_handle: u64,
    buffer: ?[*]u8,
    capacity: usize,
    timeout_ms: u32,
    out_read: ?*usize,
) callconv(.c) i32 {
    begin();
    const conn = net.connections.get(conn_handle) orelse return fail(error.InvalidHandle);
    const dest = mutable(buffer, capacity) orelse return invalid();
    const n = conn.receive(dest, timeout_ms) catch |err| return fail(err);
    if (out_read) |value| value.* = n;
    return ok();
}

pub export fn e7_tcp_shutdown(conn_handle: u64) callconv(.c) i32 {
    begin();
    const conn = net.connections.get(conn_handle) orelse return fail(error.InvalidHandle);
    conn.shutdown();
    return ok();
}

pub export fn e7_tcp_close(conn_handle: u64) callconv(.c) i32 {
    begin();
    const value = net.connections.remove(conn_handle) orelse return fail(error.InvalidHandle);
    var conn = value;
    conn.close();
    return ok();
}

pub export fn e7_tcp_local_port(conn_handle: u64) callconv(.c) i32 {
    begin();
    const conn = net.connections.get(conn_handle) orelse return -1;
    return conn.stream.socket.address.getPort();
}

pub export fn e7_tcp_listener_close(listener_handle: u64) callconv(.c) i32 {
    begin();
    const value = net.listeners.remove(listener_handle) orelse return fail(error.InvalidHandle);
    var listener = value;
    listener.close();
    return ok();
}

// ------------------------------------------------------------------ UDP ------

pub export fn e7_udp_bind(host: ?[*]const u8, host_len: usize, port: u16) callconv(.c) u64 {
    begin();
    const name = input(host, host_len) orelse return 0;
    const socket = net.DatagramSocket.bind(name, port) catch |err| {
        _ = fail(err);
        return 0;
    };
    return net.datagrams.create(socket) catch |err| {
        var copy = socket;
        copy.close();
        _ = fail(err);
        return 0;
    };
}

pub export fn e7_udp_send_to(
    socket_handle: u64,
    host: ?[*]const u8,
    host_len: usize,
    port: u16,
    data: ?[*]const u8,
    data_len: usize,
) callconv(.c) i32 {
    begin();
    const socket = net.datagrams.get(socket_handle) orelse return fail(error.InvalidHandle);
    const name = input(host, host_len) orelse return invalid();
    const bytes = input(data, data_len) orelse return invalid();
    socket.sendTo(name, port, bytes) catch |err| return fail(err);
    return ok();
}

pub export fn e7_udp_recv_from(
    socket_handle: u64,
    buffer: ?[*]u8,
    capacity: usize,
    timeout_ms: u32,
    out_read: ?*usize,
    out_addr: ?[*]u8,
    addr_capacity: usize,
    out_addr_len: ?*usize,
) callconv(.c) i32 {
    begin();
    const socket = net.datagrams.get(socket_handle) orelse return fail(error.InvalidHandle);
    const dest = mutable(buffer, capacity) orelse return invalid();
    const msg = socket.receiveFrom(dest, timeout_ms) catch |err| return fail(err);
    if (out_read) |value| value.* = msg.len;

    var addr_buf: [160]u8 = undefined;
    const text = net.formatAddress(msg.from, &addr_buf);
    if (out_addr_len) |value| value.* = text.len;
    if (out_addr) |dest_addr| {
        const n = @min(addr_capacity, text.len);
        if (n > 0) @memcpy(dest_addr[0..n], text[0..n]);
    }
    return ok();
}

pub export fn e7_udp_local_port(socket_handle: u64) callconv(.c) i32 {
    begin();
    const socket = net.datagrams.get(socket_handle) orelse return -1;
    return socket.port;
}

pub export fn e7_udp_close(socket_handle: u64) callconv(.c) i32 {
    begin();
    const value = net.datagrams.remove(socket_handle) orelse return fail(error.InvalidHandle);
    var socket = value;
    socket.close();
    return ok();
}

// ----------------------------------------------------------------- HTTP ------

pub export fn e7_http_request(
    method: ?[*]const u8,
    method_len: usize,
    url: ?[*]const u8,
    url_len: usize,
    headers: ?[*]const u8,
    headers_len: usize,
    body: ?[*]const u8,
    body_len: usize,
    timeout_ms: u32,
    out_body: ?*?[*]u8,
    out_len: ?*usize,
    out_status: ?*u32,
) callconv(.c) i32 {
    begin();
    const method_bytes = input(method, method_len) orelse return invalid();
    const url_bytes = input(url, url_len) orelse return invalid();
    const header_bytes = input(headers, headers_len) orelse return invalid();
    const body_bytes: ?[]const u8 = if (body_len == 0) null else (input(body, body_len) orelse return invalid());

    const response = http.request(std.heap.c_allocator, method_bytes, url_bytes, header_bytes, body_bytes, timeout_ms) catch |err| return fail(err);
    if (out_status) |status| status.* = response.status;
    return transfer(response.body, out_body, out_len);
}

pub export fn e7_http_get(
    url: ?[*]const u8,
    url_len: usize,
    timeout_ms: u32,
    out_body: ?*?[*]u8,
    out_len: ?*usize,
    out_status: ?*u32,
) callconv(.c) i32 {
    return e7_http_request("GET".ptr, 3, url, url_len, "".ptr, 0, null, 0, timeout_ms, out_body, out_len, out_status);
}

pub export fn e7_http_post(
    url: ?[*]const u8,
    url_len: usize,
    headers: ?[*]const u8,
    headers_len: usize,
    body: ?[*]const u8,
    body_len: usize,
    timeout_ms: u32,
    out_body: ?*?[*]u8,
    out_len: ?*usize,
    out_status: ?*u32,
) callconv(.c) i32 {
    return e7_http_request("POST".ptr, 4, url, url_len, headers, headers_len, body, body_len, timeout_ms, out_body, out_len, out_status);
}

// ----------------------------------------------------------------- QUIC ------

pub export fn e7_quic_connect(
    host: ?[*]const u8,
    host_len: usize,
    port: u16,
    alpn: ?[*]const u8,
    alpn_len: usize,
    insecure: i32,
    timeout_ms: u32,
) callconv(.c) u64 {
    begin();
    const host_bytes = input(host, host_len) orelse return 0;
    const alpn_bytes = input(alpn, alpn_len) orelse return 0;
    const conn = quic.Conn.connect(std.heap.c_allocator, host_bytes, port, .{
        .alpn = alpn_bytes,
        .insecure = insecure != 0,
        .idle_timeout_ms = if (timeout_ms == 0) 30_000 else timeout_ms,
    }) catch |err| {
        _ = fail(err);
        return 0;
    };
    return quic.registry.adopt(conn) catch |err| {
        conn.deinit();
        _ = fail(err);
        return 0;
    };
}

pub export fn e7_quic_listen(
    host: ?[*]const u8,
    host_len: usize,
    port: u16,
    alpn: ?[*]const u8,
    alpn_len: usize,
    cert: ?[*]const u8,
    cert_len: usize,
    key: ?[*]const u8,
    key_len: usize,
) callconv(.c) u64 {
    begin();
    const host_bytes = input(host, host_len) orelse return 0;
    const alpn_bytes = input(alpn, alpn_len) orelse return 0;
    const cert_bytes = input(cert, cert_len) orelse return 0;
    const key_bytes = input(key, key_len) orelse return 0;
    const listener = quic.Listener.listen(std.heap.c_allocator, host_bytes, port, .{
        .alpn = alpn_bytes,
        .cert_pem = cert_bytes,
        .key_pem = key_bytes,
    }) catch |err| {
        _ = fail(err);
        return 0;
    };
    return quic.listeners.adopt(listener) catch |err| {
        listener.deinit();
        _ = fail(err);
        return 0;
    };
}

pub export fn e7_quic_accept(listener_handle: u64, timeout_ms: u32) callconv(.c) u64 {
    begin();
    const listener = quic.listeners.get(listener_handle) orelse {
        _ = fail(error.InvalidHandle);
        return 0;
    };
    const conn = listener.accept(timeout_ms) catch |err| {
        _ = fail(err);
        return 0;
    };
    return quic.registry.adopt(conn) catch |err| {
        conn.deinit();
        _ = fail(err);
        return 0;
    };
}

pub export fn e7_quic_send(
    conn_handle: u64,
    data: ?[*]const u8,
    data_len: usize,
    fin: i32,
) callconv(.c) i32 {
    begin();
    const conn = quic.registry.get(conn_handle) orelse return fail(error.InvalidHandle);
    const bytes = input(data, data_len) orelse return invalid();
    conn.send(bytes, fin != 0) catch |err| return fail(err);
    return ok();
}

pub export fn e7_quic_recv(
    conn_handle: u64,
    buffer: ?[*]u8,
    capacity: usize,
    timeout_ms: u32,
    out_read: ?*usize,
) callconv(.c) i32 {
    begin();
    const conn = quic.registry.get(conn_handle) orelse return fail(error.InvalidHandle);
    const dest = mutable(buffer, capacity) orelse return invalid();
    const n = conn.receive(dest, timeout_ms) catch |err| return fail(err);
    if (out_read) |value| value.* = n;
    return ok();
}

pub export fn e7_quic_shutdown(conn_handle: u64, error_code: u64) callconv(.c) i32 {
    begin();
    const conn = quic.registry.get(conn_handle) orelse return fail(error.InvalidHandle);
    conn.shutdown(error_code);
    return ok();
}

pub export fn e7_quic_close(conn_handle: u64) callconv(.c) i32 {
    begin();
    const conn = quic.registry.detach(conn_handle) orelse return fail(error.InvalidHandle);
    conn.deinit();
    return ok();
}

pub export fn e7_quic_listener_close(listener_handle: u64) callconv(.c) i32 {
    begin();
    const listener = quic.listeners.detach(listener_handle) orelse return fail(error.InvalidHandle);
    listener.deinit();
    return ok();
}

// ---------------------------------------------------------------- WebRTC -----

pub export fn e7_rtc_create(
    ice_servers: ?[*]const u8,
    ice_len: usize,
    bind_address: ?[*]const u8,
    bind_len: usize,
) callconv(.c) u64 {
    begin();
    const servers = input(ice_servers, ice_len) orelse return 0;
    const bind: ?[]const u8 = if (bind_len == 0) null else (input(bind_address, bind_len) orelse return 0);
    const peer = webrtc.Peer.create(std.heap.c_allocator, servers, bind) catch |err| {
        _ = fail(err);
        return 0;
    };
    return webrtc.registry.adopt(peer) catch |err| {
        peer.close();
        peer.destroy();
        _ = fail(err);
        return 0;
    };
}

pub export fn e7_rtc_create_data_channel(peer_handle: u64, label: ?[*]const u8, label_len: usize) callconv(.c) i32 {
    begin();
    const peer = webrtc.registry.get(peer_handle) orelse return fail(error.InvalidHandle);
    const name = input(label, label_len) orelse return invalid();
    peer.createDataChannel(name) catch |err| return fail(err);
    return ok();
}

pub export fn e7_rtc_create_offer(
    peer_handle: u64,
    timeout_ms: u32,
    out_sdp: ?*?[*]u8,
    out_len: ?*usize,
) callconv(.c) i32 {
    begin();
    const peer = webrtc.registry.get(peer_handle) orelse return fail(error.InvalidHandle);
    const sdp = peer.createOffer(timeout_ms) catch |err| return fail(err);
    return transfer(sdp, out_sdp, out_len);
}

pub export fn e7_rtc_create_answer(
    peer_handle: u64,
    timeout_ms: u32,
    out_sdp: ?*?[*]u8,
    out_len: ?*usize,
) callconv(.c) i32 {
    begin();
    const peer = webrtc.registry.get(peer_handle) orelse return fail(error.InvalidHandle);
    const sdp = peer.createAnswer(timeout_ms) catch |err| return fail(err);
    return transfer(sdp, out_sdp, out_len);
}

pub export fn e7_rtc_set_remote(
    peer_handle: u64,
    sdp: ?[*]const u8,
    sdp_len: usize,
    kind: ?[*]const u8,
    kind_len: usize,
) callconv(.c) i32 {
    begin();
    const peer = webrtc.registry.get(peer_handle) orelse return fail(error.InvalidHandle);
    const description = input(sdp, sdp_len) orelse return invalid();
    const description_kind = input(kind, kind_len) orelse return invalid();
    peer.setRemote(description, description_kind) catch |err| return fail(err);
    return ok();
}

pub export fn e7_rtc_wait_open(peer_handle: u64, timeout_ms: u32) callconv(.c) i32 {
    begin();
    const peer = webrtc.registry.get(peer_handle) orelse return fail(error.InvalidHandle);
    peer.waitOpen(timeout_ms) catch |err| return fail(err);
    return ok();
}

pub export fn e7_rtc_send(peer_handle: u64, data: ?[*]const u8, data_len: usize, binary: i32) callconv(.c) i32 {
    begin();
    const peer = webrtc.registry.get(peer_handle) orelse return fail(error.InvalidHandle);
    const bytes = input(data, data_len) orelse return invalid();
    peer.send(bytes, binary != 0) catch |err| return fail(err);
    return ok();
}

pub export fn e7_rtc_recv(
    peer_handle: u64,
    buffer: ?[*]u8,
    capacity: usize,
    timeout_ms: u32,
    out_read: ?*usize,
    out_binary: ?*i32,
) callconv(.c) i32 {
    begin();
    const peer = webrtc.registry.get(peer_handle) orelse return fail(error.InvalidHandle);
    const dest = mutable(buffer, capacity) orelse return invalid();
    var binary = false;
    const n = (peer.receiveWait(dest, timeout_ms, &binary) catch |err| return fail(err)) orelse {
        abi.setError("WebRTC receive timed out");
        return abi.code(.timeout);
    };
    if (out_read) |value| value.* = n;
    if (out_binary) |value| value.* = if (binary) 1 else 0;
    return ok();
}

pub export fn e7_rtc_state(peer_handle: u64) callconv(.c) i32 {
    begin();
    const peer = webrtc.registry.get(peer_handle) orelse return -1;
    return peer.state;
}

pub export fn e7_rtc_close(peer_handle: u64) callconv(.c) i32 {
    begin();
    const peer = webrtc.registry.detach(peer_handle) orelse return fail(error.InvalidHandle);
    peer.close();
    peer.destroy();
    return ok();
}

// ------------------------------------------------------- dynamic FFI --------

pub export fn e7_dl_open(path: ?[*]const u8, path_len: usize, flags_bits: u32) callconv(.c) u64 {
    begin();
    const name = input(path, path_len) orelse return 0;
    var flags = dl.OpenFlags{
        .lazy = (flags_bits & 1) != 0,
        .global = (flags_bits & 2) != 0,
        .now = (flags_bits & 4) != 0,
    };
    if (!flags.lazy and !flags.now) flags.lazy = true;

    const library = dl.Library.open(name, flags) catch |err| {
        _ = fail(err);
        return 0;
    };
    return dl.registry.create(library) catch |err| {
        var copy = library;
        copy.close();
        _ = fail(err);
        return 0;
    };
}

pub export fn e7_dl_open_self(flags_bits: u32) callconv(.c) u64 {
    return e7_dl_open("".ptr, 0, flags_bits);
}

pub export fn e7_dl_symbol(handle: u64, name: ?[*]const u8, name_len: usize) callconv(.c) u64 {
    begin();
    const library = dl.registry.get(handle) orelse {
        _ = fail(error.InvalidHandle);
        return 0;
    };
    const symbol_name = input(name, name_len) orelse return 0;
    const address = library.symbol(symbol_name) catch |err| {
        _ = fail(err);
        return 0;
    };
    return address;
}

pub export fn e7_dl_has_symbol(handle: u64, name: ?[*]const u8, name_len: usize) callconv(.c) i32 {
    begin();
    const library = dl.registry.get(handle) orelse return -1;
    const symbol_name = input(name, name_len) orelse return -1;
    const address = library.symbol(symbol_name) catch return 0;
    return if (address != 0) 1 else 0;
}

pub export fn e7_dl_close(handle: u64) callconv(.c) i32 {
    begin();
    const value = dl.registry.remove(handle) orelse return fail(error.InvalidHandle);
    var library = value;
    library.close();
    return ok();
}

pub export fn e7_dl_path(handle: u64, out_ptr: ?*?[*]u8, out_len: ?*usize) callconv(.c) i32 {
    begin();
    const library = dl.registry.get(handle) orelse return fail(error.InvalidHandle);
    return output(library.path, out_ptr, out_len);
}

pub export fn e7_ffi_call0(address: u64) callconv(.c) u64 {
    begin();
    return dl.call0(@intCast(address));
}

pub export fn e7_ffi_call1(address: u64, a0: u64) callconv(.c) u64 {
    begin();
    return dl.call1(@intCast(address), @intCast(a0));
}

pub export fn e7_ffi_call2(address: u64, a0: u64, a1: u64) callconv(.c) u64 {
    begin();
    return dl.call2(@intCast(address), @intCast(a0), @intCast(a1));
}

pub export fn e7_ffi_call3(address: u64, a0: u64, a1: u64, a2: u64) callconv(.c) u64 {
    begin();
    return dl.call3(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2));
}

pub export fn e7_ffi_call4(address: u64, a0: u64, a1: u64, a2: u64, a3: u64) callconv(.c) u64 {
    begin();
    return dl.call4(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3));
}

pub export fn e7_ffi_call5(address: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64) callconv(.c) u64 {
    begin();
    return dl.call5(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3), @intCast(a4));
}

pub export fn e7_ffi_call6(address: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) callconv(.c) u64 {
    begin();
    return dl.call6(@intCast(address), @intCast(a0), @intCast(a1), @intCast(a2), @intCast(a3), @intCast(a4), @intCast(a5));
}

pub export fn e7_ffi_call_f64_0(address: u64) callconv(.c) f64 {
    begin();
    return dl.callF64_0(@intCast(address));
}

pub export fn e7_ffi_call_f64_1(address: u64, a0: f64) callconv(.c) f64 {
    begin();
    return dl.callF64_1(@intCast(address), a0);
}

pub export fn e7_ffi_call_f64_2(address: u64, a0: f64, a1: f64) callconv(.c) f64 {
    begin();
    return dl.callF64_2(@intCast(address), a0, a1);
}

pub export fn e7_ffi_call_f64_3(address: u64, a0: f64, a1: f64, a2: f64) callconv(.c) f64 {
    begin();
    return dl.callF64_3(@intCast(address), a0, a1, a2);
}

pub export fn e7_ffi_call_f64_4(address: u64, a0: f64, a1: f64, a2: f64, a3: f64) callconv(.c) f64 {
    begin();
    return dl.callF64_4(@intCast(address), a0, a1, a2, a3);
}

pub export fn e7_ffi_read(address: u64, buffer: ?[*]u8, len: usize) callconv(.c) i32 {
    begin();
    if (len == 0) return ok();
    const dest = mutable(buffer, len) orelse return invalid();
    dl.readBytes(@intCast(address), dest) catch |err| return fail(err);
    return ok();
}

pub export fn e7_ffi_write(address: u64, data: ?[*]const u8, len: usize) callconv(.c) i32 {
    begin();
    const source = input(data, len) orelse return invalid();
    dl.writeBytes(@intCast(address), source) catch |err| return fail(err);
    return ok();
}

// ------------------------------------------------------------- manifest ------

var symbol_table: [70]Symbol = undefined;
var symbol_state = std.atomic.Value(u8).init(0);

pub fn symbols() []const Symbol {
    if (symbol_state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
        const built = [_]Symbol{
            .{ .name = "e7_version", .address = @intFromPtr(&abi.e7_version) },
            .{ .name = "e7_alloc", .address = @intFromPtr(&abi.e7_alloc) },
            .{ .name = "e7_free", .address = @intFromPtr(&abi.e7_free) },
            .{ .name = "e7_last_error", .address = @intFromPtr(&abi.e7_last_error) },
            .{ .name = "e7_clock_ns", .address = @intFromPtr(&e7_clock_ns) },
            .{ .name = "e7_sleep_ms", .address = @intFromPtr(&e7_sleep_ms) },
            .{ .name = "e7_log", .address = @intFromPtr(&e7_log) },
            .{ .name = "e7_stdio_write", .address = @intFromPtr(&e7_stdio_write) },
            .{ .name = "e7_stdio_read", .address = @intFromPtr(&e7_stdio_read) },
            .{ .name = "e7_stdio_read_line", .address = @intFromPtr(&e7_stdio_read_line) },
            .{ .name = "e7_stdio_is_tty", .address = @intFromPtr(&e7_stdio_is_tty) },
            .{ .name = "e7_stdio_flush", .address = @intFromPtr(&e7_stdio_flush) },
            .{ .name = "e7_dl_open", .address = @intFromPtr(&e7_dl_open) },
            .{ .name = "e7_dl_open_self", .address = @intFromPtr(&e7_dl_open_self) },
            .{ .name = "e7_dl_symbol", .address = @intFromPtr(&e7_dl_symbol) },
            .{ .name = "e7_dl_has_symbol", .address = @intFromPtr(&e7_dl_has_symbol) },
            .{ .name = "e7_dl_close", .address = @intFromPtr(&e7_dl_close) },
            .{ .name = "e7_dl_path", .address = @intFromPtr(&e7_dl_path) },
            .{ .name = "e7_ffi_call_f64_0", .address = @intFromPtr(&e7_ffi_call_f64_0) },
            .{ .name = "e7_ffi_call_f64_1", .address = @intFromPtr(&e7_ffi_call_f64_1) },
            .{ .name = "e7_ffi_call_f64_2", .address = @intFromPtr(&e7_ffi_call_f64_2) },
            .{ .name = "e7_ffi_call_f64_3", .address = @intFromPtr(&e7_ffi_call_f64_3) },
            .{ .name = "e7_ffi_call_f64_4", .address = @intFromPtr(&e7_ffi_call_f64_4) },
            .{ .name = "e7_ffi_read", .address = @intFromPtr(&e7_ffi_read) },
            .{ .name = "e7_ffi_write", .address = @intFromPtr(&e7_ffi_write) },
            .{ .name = "e7_fs_root", .address = @intFromPtr(&e7_fs_root) },
            .{ .name = "e7_fs_read", .address = @intFromPtr(&e7_fs_read) },
            .{ .name = "e7_fs_write", .address = @intFromPtr(&e7_fs_write) },
            .{ .name = "e7_fs_exists", .address = @intFromPtr(&e7_fs_exists) },
            .{ .name = "e7_fs_stat", .address = @intFromPtr(&e7_fs_stat) },
            .{ .name = "e7_fs_list", .address = @intFromPtr(&e7_fs_list) },
            .{ .name = "e7_fs_mkdir", .address = @intFromPtr(&e7_fs_mkdir) },
            .{ .name = "e7_fs_remove", .address = @intFromPtr(&e7_fs_remove) },
            .{ .name = "e7_fs_remove_tree", .address = @intFromPtr(&e7_fs_remove_tree) },
            .{ .name = "e7_fs_rename", .address = @intFromPtr(&e7_fs_rename) },
            .{ .name = "e7_tcp_listen", .address = @intFromPtr(&e7_tcp_listen) },
            .{ .name = "e7_tcp_accept", .address = @intFromPtr(&e7_tcp_accept) },
            .{ .name = "e7_tcp_connect", .address = @intFromPtr(&e7_tcp_connect) },
            .{ .name = "e7_tcp_send", .address = @intFromPtr(&e7_tcp_send) },
            .{ .name = "e7_tcp_recv", .address = @intFromPtr(&e7_tcp_recv) },
            .{ .name = "e7_tcp_shutdown", .address = @intFromPtr(&e7_tcp_shutdown) },
            .{ .name = "e7_tcp_close", .address = @intFromPtr(&e7_tcp_close) },
            .{ .name = "e7_tcp_local_port", .address = @intFromPtr(&e7_tcp_local_port) },
            .{ .name = "e7_tcp_listener_close", .address = @intFromPtr(&e7_tcp_listener_close) },
            .{ .name = "e7_udp_bind", .address = @intFromPtr(&e7_udp_bind) },
            .{ .name = "e7_udp_send_to", .address = @intFromPtr(&e7_udp_send_to) },
            .{ .name = "e7_udp_recv_from", .address = @intFromPtr(&e7_udp_recv_from) },
            .{ .name = "e7_udp_local_port", .address = @intFromPtr(&e7_udp_local_port) },
            .{ .name = "e7_udp_close", .address = @intFromPtr(&e7_udp_close) },
            .{ .name = "e7_http_request", .address = @intFromPtr(&e7_http_request) },
            .{ .name = "e7_http_get", .address = @intFromPtr(&e7_http_get) },
            .{ .name = "e7_http_post", .address = @intFromPtr(&e7_http_post) },
            .{ .name = "e7_quic_connect", .address = @intFromPtr(&e7_quic_connect) },
            .{ .name = "e7_quic_listen", .address = @intFromPtr(&e7_quic_listen) },
            .{ .name = "e7_quic_accept", .address = @intFromPtr(&e7_quic_accept) },
            .{ .name = "e7_quic_send", .address = @intFromPtr(&e7_quic_send) },
            .{ .name = "e7_quic_recv", .address = @intFromPtr(&e7_quic_recv) },
            .{ .name = "e7_quic_shutdown", .address = @intFromPtr(&e7_quic_shutdown) },
            .{ .name = "e7_quic_close", .address = @intFromPtr(&e7_quic_close) },
            .{ .name = "e7_quic_listener_close", .address = @intFromPtr(&e7_quic_listener_close) },
            .{ .name = "e7_rtc_create", .address = @intFromPtr(&e7_rtc_create) },
            .{ .name = "e7_rtc_create_data_channel", .address = @intFromPtr(&e7_rtc_create_data_channel) },
            .{ .name = "e7_rtc_create_offer", .address = @intFromPtr(&e7_rtc_create_offer) },
            .{ .name = "e7_rtc_create_answer", .address = @intFromPtr(&e7_rtc_create_answer) },
            .{ .name = "e7_rtc_set_remote", .address = @intFromPtr(&e7_rtc_set_remote) },
            .{ .name = "e7_rtc_wait_open", .address = @intFromPtr(&e7_rtc_wait_open) },
            .{ .name = "e7_rtc_send", .address = @intFromPtr(&e7_rtc_send) },
            .{ .name = "e7_rtc_recv", .address = @intFromPtr(&e7_rtc_recv) },
            .{ .name = "e7_rtc_state", .address = @intFromPtr(&e7_rtc_state) },
            .{ .name = "e7_rtc_close", .address = @intFromPtr(&e7_rtc_close) },
        };
        symbol_table = built;
        symbol_state.store(2, .release);
    } else {
        while (symbol_state.load(.acquire) != 2) std.atomic.spinLoopHint();
    }
    return &symbol_table;
}

/// LLVM IR declarations matching `symbols()`.  Pointer-sized integers are `i64`.
pub const declarations =
    \\declare i32 @e7_version()
    \\declare ptr @e7_alloc(i64)
    \\declare void @e7_free(ptr)
    \\declare i32 @e7_last_error(ptr, ptr)
    \\declare i32 @e7_memcpy(ptr, ptr, i64)
    \\declare i64 @e7_clock_ns()
    \\declare void @e7_sleep_ms(i64)
    \\declare void @e7_log(i32, ptr, i64)
    \\declare i32 @e7_stdio_write(i32, ptr, i64, ptr)
    \\declare i32 @e7_stdio_read(i32, ptr, i64, ptr)
    \\declare i32 @e7_stdio_read_line(i32, ptr, i64, ptr, ptr)
    \\declare i32 @e7_stdio_is_tty(i32)
    \\declare i32 @e7_stdio_flush(i32)
    \\declare i64 @e7_dl_open(ptr, i64, i32)
    \\declare i64 @e7_dl_open_self(i32)
    \\declare i64 @e7_dl_symbol(i64, ptr, i64)
    \\declare i32 @e7_dl_has_symbol(i64, ptr, i64)
    \\declare i32 @e7_dl_close(i64)
    \\declare i32 @e7_dl_path(i64, ptr, ptr)
    \\declare i64 @e7_ffi_call0(i64)
    \\declare i64 @e7_ffi_call1(i64, i64)
    \\declare i64 @e7_ffi_call2(i64, i64, i64)
    \\declare i64 @e7_ffi_call3(i64, i64, i64, i64)
    \\declare i64 @e7_ffi_call4(i64, i64, i64, i64, i64)
    \\declare i64 @e7_ffi_call5(i64, i64, i64, i64, i64, i64)
    \\declare i64 @e7_ffi_call6(i64, i64, i64, i64, i64, i64, i64)
    \\declare double @e7_ffi_call_f64_0(i64)
    \\declare double @e7_ffi_call_f64_1(i64, double)
    \\declare double @e7_ffi_call_f64_2(i64, double, double)
    \\declare double @e7_ffi_call_f64_3(i64, double, double, double)
    \\declare double @e7_ffi_call_f64_4(i64, double, double, double, double)
    \\declare i32 @e7_ffi_read(i64, ptr, i64)
    \\declare i32 @e7_ffi_write(i64, ptr, i64)
    \\declare i64 @e7_ffi_call7(i64, i64, i64, i64, i64, i64, i64, i64)
    \\declare i64 @e7_ffi_call8(i64, i64, i64, i64, i64, i64, i64, i64, i64)
    \\declare i64 @e7_ffi_call9(i64, i64, i64, i64, i64, i64, i64, i64, i64, i64)
    \\declare i64 @e7_ffi_call10(i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64)
    \\declare i64 @e7_ffi_call11(i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64)
    \\declare i64 @e7_ffi_call12(i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64)
    \\declare i64 @e7_ffi_call13(i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64)
    \\declare i64 @e7_ffi_call14(i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64)
    \\declare i64 @e7_ffi_call15(i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64)
    \\declare i64 @e7_ffi_call16(i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64, i64)
    \\declare i64 @e7_cffi_bind(i64, i64)
    \\declare i64 @e7_str_data(i64)
    \\declare i64 @e7_str_len(i64)
    \\declare i64 @e7_str_new(i64, i64)
    \\declare i64 @e7_alloc_bytes(i64)
    \\declare void @e7_free_ptr(i64)
    \\declare i64 @e7_load_i64(i64)
    \\declare void @e7_store_i64(i64, i64)
    \\declare i64 @e7_load_u8(i64)
    \\declare void @e7_store_u8(i64, i64)
    \\declare i64 @e7_load_u16(i64)
    \\declare void @e7_store_u16(i64, i64)
    \\declare i64 @e7_load_u32(i64)
    \\declare i64 @e7_load_f32(i64)
    \\declare void @e7_store_u32(i64, i64)
    \\declare i64 @e7_load_u64(i64)
    \\declare void @e7_store_u64(i64, i64)
    \\declare i32 @e7_fs_root(ptr, ptr)
    \\declare i32 @e7_fs_read(ptr, i64, ptr, ptr)
    \\declare i32 @e7_fs_write(ptr, i64, ptr, i64, i32)
    \\declare i32 @e7_fs_exists(ptr, i64)
    \\declare i32 @e7_fs_stat(ptr, i64, ptr, ptr, ptr)
    \\declare i32 @e7_fs_list(ptr, i64, ptr, ptr)
    \\declare i32 @e7_fs_mkdir(ptr, i64)
    \\declare i32 @e7_fs_remove(ptr, i64)
    \\declare i32 @e7_fs_remove_tree(ptr, i64)
    \\declare i32 @e7_fs_rename(ptr, i64, ptr, i64)
    \\declare i64 @e7_tcp_listen(ptr, i64, i16)
    \\declare i64 @e7_tcp_accept(i64, i32)
    \\declare i64 @e7_tcp_connect(ptr, i64, i16, i32)
    \\declare i32 @e7_tcp_send(i64, ptr, i64, ptr)
    \\declare i32 @e7_tcp_recv(i64, ptr, i64, i32, ptr)
    \\declare i32 @e7_tcp_shutdown(i64)
    \\declare i32 @e7_tcp_close(i64)
    \\declare i32 @e7_tcp_local_port(i64)
    \\declare i32 @e7_tcp_listener_close(i64)
    \\declare i64 @e7_udp_bind(ptr, i64, i16)
    \\declare i32 @e7_udp_send_to(i64, ptr, i64, i16, ptr, i64)
    \\declare i32 @e7_udp_recv_from(i64, ptr, i64, i32, ptr, ptr, i64, ptr)
    \\declare i32 @e7_udp_local_port(i64)
    \\declare i32 @e7_udp_close(i64)
    \\declare i32 @e7_http_request(ptr, i64, ptr, i64, ptr, i64, ptr, i64, i32, ptr, ptr, ptr)
    \\declare i32 @e7_http_get(ptr, i64, i32, ptr, ptr, ptr)
    \\declare i32 @e7_http_post(ptr, i64, ptr, i64, ptr, i64, i32, ptr, ptr, ptr)
    \\declare i64 @e7_quic_connect(ptr, i64, i16, ptr, i64, i32, i32)
    \\declare i64 @e7_quic_listen(ptr, i64, i16, ptr, i64, ptr, i64, ptr, i64)
    \\declare i64 @e7_quic_accept(i64, i32)
    \\declare i32 @e7_quic_send(i64, ptr, i64, i32)
    \\declare i32 @e7_quic_recv(i64, ptr, i64, i32, ptr)
    \\declare i32 @e7_quic_shutdown(i64, i64)
    \\declare i32 @e7_quic_close(i64)
    \\declare i32 @e7_quic_listener_close(i64)
    \\declare i64 @e7_rtc_create(ptr, i64, ptr, i64)
    \\declare i32 @e7_rtc_create_data_channel(i64, ptr, i64)
    \\declare i32 @e7_rtc_create_offer(i64, i32, ptr, ptr)
    \\declare i32 @e7_rtc_create_answer(i64, i32, ptr, ptr)
    \\declare i32 @e7_rtc_set_remote(i64, ptr, i64, ptr, i64)
    \\declare i32 @e7_rtc_wait_open(i64, i32)
    \\declare i32 @e7_rtc_send(i64, ptr, i64, i32)
    \\declare i32 @e7_rtc_recv(i64, ptr, i64, i32, ptr, ptr)
    \\declare i32 @e7_rtc_state(i64)
    \\declare i32 @e7_rtc_close(i64)
;

test "intrinsic manifest is non-empty and unique" {
    try std.testing.expect(symbols().len > 50);
    for (symbols(), 0..) |symbol, i| {
        try std.testing.expect(symbol.address != 0);
        for (symbols()[0..i]) |previous| {
            if (std.mem.eql(u8, previous.name, symbol.name)) {
                std.debug.print("duplicate intrinsic: {s}\n", .{symbol.name});
                return error.TestUnexpectedResult;
            }
        }
    }
}
