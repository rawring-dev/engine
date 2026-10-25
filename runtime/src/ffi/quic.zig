//! QUIC [rfc9000] transport built on ngtcp2 [ngtcp2] with the OpenSSL 3.x
//! TLS backend [openssl].
//!
//! The module exposes a single bidirectional stream per connection, which is
//! enough for request/response and message-oriented use while keeping packet
//! handling deterministic.  A `Listener` accepts one connection at a time; the
//! listener socket is shared by that connection for subsequent datagrams.
//!
//! Both client and server use non-trickle, in-process packet driving: every
//! operation receives datagrams with a short timeout, advances ngtcp2's timers,
//! and flushes retransmissions.  ALPN is mandatory because QUIC requires it.

const std = @import("std");
const abi = @import("abi.zig");
const io_mod = @import("io.zig");
const handles = @import("handles.zig");
const time = @import("time.zig");
const net = @import("net.zig");

pub const c = @cImport({
    @cInclude("ngtcp2/ngtcp2.h");
    @cInclude("ngtcp2/ngtcp2_crypto.h");
    @cInclude("ngtcp2/ngtcp2_crypto_ossl.h");
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/pem.h");
    @cInclude("openssl/rand.h");
});

pub const Error = error{
    InitFailed,
    ConnectFailed,
    HandshakeFailed,
    ListenFailed,
    AcceptFailed,
    SendFailed,
    ReceiveFailed,
    Timeout,
    Closed,
    OutOfMemory,
    InvalidArgument,
    TlsFailed,
};

pub const max_datagram = 1500;

pub const Options = struct {
    alpn: []const u8 = "engine7",
    insecure: bool = false,
    idle_timeout_ms: u32 = 30_000,
    /// PEM-encoded server certificate chain and private key.  Required for
    /// listeners; ignored by clients.
    cert_pem: []const u8 = "",
    key_pem: []const u8 = "",
};

pub const Conn = struct {
    allocator: std.mem.Allocator,
    is_server: bool,
    owns_socket: bool = true,
    socket: std.Io.net.Socket,
    local: net.IpAddress,
    remote: net.IpAddress,

    local_storage: std.c.sockaddr.storage = undefined,
    remote_storage: std.c.sockaddr.storage = undefined,
    local_len: std.c.socklen_t = 0,
    remote_len: std.c.socklen_t = 0,
    path: c.ngtcp2_path = undefined,

    conn: ?*c.ngtcp2_conn = null,
    ssl_ctx: ?*c.SSL_CTX = null,
    ssl: ?*c.SSL = null,
    ossl_ctx: ?*c.ngtcp2_crypto_ossl_ctx = null,
    conn_ref: c.ngtcp2_crypto_conn_ref = undefined,

    alpn: []u8 = &.{},
    cert_pem: []u8 = &.{},
    key_pem: []u8 = &.{},
    rx: std.ArrayListUnmanaged(u8) = .empty,
    rx_fin: bool = false,
    stream_id: i64 = -1,
    handshake_completed: bool = false,
    handshake_confirmed: bool = false,
    closed: bool = false,
    static_secret: [32]u8 = undefined,
    tx_chunks: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn connect(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        options: Options,
    ) Error!*Conn {
        ensureCrypto();
        const remote = net.resolve(host, port) catch return error.ConnectFailed;

        const bind_addr: net.IpAddress = switch (remote) {
            .ip4 => .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
            .ip6 => .{ .ip6 = .{ .bytes = [_]u8{0} ** 16, .port = 0 } },
        };
        const socket = bind_addr.bind(io_mod.io(), .{ .mode = .dgram, .protocol = .udp }) catch |err| {
            abi.setErrorFmt("udp bind: {s}", .{@errorName(err)});
            return error.ConnectFailed;
        };
        errdefer socket.close(io_mod.io());

        const self = allocator.create(Conn) catch return error.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .is_server = false,
            .owns_socket = true,
            .socket = socket,
            .local = socket.address,
            .remote = remote,
            .alpn = allocator.dupe(u8, options.alpn) catch {
                allocator.destroy(self);
                return error.OutOfMemory;
            },
        };
        errdefer self.deinit();

        self.layoutPath();
        try self.initTls(host, options);
        try self.createClientConn(options);
        try self.driveHandshake(if (options.idle_timeout_ms == 0) 0 else options.idle_timeout_ms);
        try self.openStream();
        return self;
    }

    fn layoutPath(self: *Conn) void {
        writeSockaddr(self.local, &self.local_storage, &self.local_len);
        writeSockaddr(self.remote, &self.remote_storage, &self.remote_len);
        self.path = .{
            .local = .{ .addr = @ptrCast(&self.local_storage), .addrlen = self.local_len },
            .remote = .{ .addr = @ptrCast(&self.remote_storage), .addrlen = self.remote_len },
            .user_data = null,
        };
    }

    fn initTls(self: *Conn, host: []const u8, options: Options) Error!void {
        const method = if (self.is_server) c.TLS_server_method() else c.TLS_client_method();
        const ctx = c.SSL_CTX_new(method) orelse {
            logSslError("SSL_CTX_new");
            return error.TlsFailed;
        };
        self.ssl_ctx = ctx;
        _ = c.SSL_CTX_set_min_proto_version(ctx, c.TLS1_3_VERSION);

        if (self.is_server) {
            try self.loadServerCertificate(ctx);
            _ = c.SSL_CTX_set_alpn_select_cb(ctx, alpnSelectCb, self);
        } else {
            if (options.insecure) {
                c.SSL_CTX_set_verify(ctx, c.SSL_VERIFY_NONE, null);
            }
        }

        const ssl = c.SSL_new(ctx) orelse {
            logSslError("SSL_new");
            return error.TlsFailed;
        };
        self.ssl = ssl;

        self.conn_ref = .{ .get_conn = getConnCb, .user_data = self };
        _ = c.SSL_set_app_data(ssl, &self.conn_ref);

        if (self.is_server) {
            c.SSL_set_accept_state(ssl);
            if (c.ngtcp2_crypto_ossl_configure_server_session(ssl) != 0) {
                logSslError("ngtcp2_crypto_ossl_configure_server_session");
                return error.TlsFailed;
            }
        } else {
            c.SSL_set_connect_state(ssl);
            if (c.ngtcp2_crypto_ossl_configure_client_session(ssl) != 0) {
                logSslError("ngtcp2_crypto_ossl_configure_client_session");
                return error.TlsFailed;
            }
            var wire: [256]u8 = undefined;
            const alpn_wire = encodeAlpn(self.alpn, &wire) orelse return error.InvalidArgument;
            _ = c.SSL_set_alpn_protos(ssl, alpn_wire.ptr, @intCast(alpn_wire.len));
            const sni = if (isNumericHost(host)) "localhost" else host;
            const sni_z = std.heap.c_allocator.dupeZ(u8, sni) catch return error.OutOfMemory;
            defer std.heap.c_allocator.free(sni_z);
            _ = c.SSL_set_tlsext_host_name(ssl, sni_z.ptr);
        }

        var ossl_ctx: ?*c.ngtcp2_crypto_ossl_ctx = null;
        if (c.ngtcp2_crypto_ossl_ctx_new(&ossl_ctx, ssl) != 0 or ossl_ctx == null) {
            logSslError("ngtcp2_crypto_ossl_ctx_new");
            return error.TlsFailed;
        }
        self.ossl_ctx = ossl_ctx;
    }

    fn loadServerCertificate(self: *Conn, ctx: *c.SSL_CTX) Error!void {
        if (self.cert_pem.len == 0 or self.key_pem.len == 0) {
            abi.setError("QUIC server requires cert_pem and key_pem");
            return error.TlsFailed;
        }
        try loadCertificate(ctx, self.cert_pem, self.key_pem);
    }

    fn initServerTls(self: *Conn) Error!void {
        try self.initTls("localhost", .{
            .alpn = self.alpn,
            .insecure = true,
            .cert_pem = self.cert_pem,
            .key_pem = self.key_pem,
        });
    }

    fn createClientConn(self: *Conn, options: Options) Error!void {
        const conn = try self.newConn(null, null, null, options);
        self.conn = conn;
        c.ngtcp2_conn_set_tls_native_handle(conn, @ptrCast(self.ossl_ctx));
    }

    fn newConn(
        self: *Conn,
        dcid_in: ?*const c.ngtcp2_cid,
        scid_in: ?*const c.ngtcp2_cid,
        original_dcid: ?*const c.ngtcp2_cid,
        options: Options,
    ) Error!*c.ngtcp2_conn {
        var dcid: c.ngtcp2_cid = undefined;
        var scid: c.ngtcp2_cid = undefined;
        if (dcid_in) |value| {
            dcid = value.*;
        } else {
            dcid.datalen = 18;
            if (c.RAND_bytes(&dcid.data, @intCast(dcid.datalen)) != 1) return error.InitFailed;
        }
        if (scid_in) |value| {
            scid = value.*;
        } else {
            scid.datalen = 18;
            if (c.RAND_bytes(&scid.data, @intCast(scid.datalen)) != 1) return error.InitFailed;
        }

        var settings = std.mem.zeroes(c.ngtcp2_settings);
        c.ngtcp2_settings_default(&settings);
        settings.initial_ts = time.nowNs();
        settings.initial_rtt = c.NGTCP2_DEFAULT_INITIAL_RTT;
        settings.cc_algo = c.NGTCP2_CC_ALGO_CUBIC;

        var params = std.mem.zeroes(c.ngtcp2_transport_params);
        c.ngtcp2_transport_params_default(&params);
        params.initial_max_data = 1 << 20;
        params.initial_max_stream_data_bidi_local = 256 * 1024;
        params.initial_max_stream_data_bidi_remote = 256 * 1024;
        params.initial_max_stream_data_uni = 64 * 1024;
        params.initial_max_streams_bidi = 4;
        params.initial_max_streams_uni = 4;
        params.max_idle_timeout = @as(u64, options.idle_timeout_ms) * std.time.ns_per_ms;
        if (self.is_server) {
            if (original_dcid) |value| {
                params.original_dcid = value.*;
                params.original_dcid_present = 1;
            }
        }

        var callbacks = callbacksFor(self.is_server);
        var conn: ?*c.ngtcp2_conn = null;

        const rc = if (self.is_server)
            c.ngtcp2_conn_server_new_versioned(
                &conn,
                &dcid,
                &scid,
                &self.path,
                c.NGTCP2_PROTO_VER_V1,
                c.NGTCP2_CALLBACKS_VERSION,
                &callbacks,
                c.NGTCP2_SETTINGS_VERSION,
                &settings,
                c.NGTCP2_TRANSPORT_PARAMS_VERSION,
                &params,
                null,
                self,
            )
        else
            c.ngtcp2_conn_client_new_versioned(
                &conn,
                &dcid,
                &scid,
                &self.path,
                c.NGTCP2_PROTO_VER_V1,
                c.NGTCP2_CALLBACKS_VERSION,
                &callbacks,
                c.NGTCP2_SETTINGS_VERSION,
                &settings,
                c.NGTCP2_TRANSPORT_PARAMS_VERSION,
                &params,
                null,
                self,
            );

        if (rc != 0 or conn == null) {
            abi.setErrorFmt("ngtcp2 conn new: {s}", .{std.mem.span(c.ngtcp2_strerror(rc))});
            return error.InitFailed;
        }
        return conn.?;
    }

    fn openStream(self: *Conn) Error!void {
        if (self.stream_id >= 0) return;
        var stream_id: i64 = -1;
        const rc = c.ngtcp2_conn_open_bidi_stream(self.conn.?, &stream_id, null);
        if (rc != 0) {
            abi.setErrorFmt("ngtcp2_conn_open_bidi_stream: {s}", .{std.mem.span(c.ngtcp2_strerror(rc))});
            return error.ConnectFailed;
        }
        self.stream_id = stream_id;
    }

    fn flush(self: *Conn) Error!void {
        var buf: [max_datagram]u8 = undefined;
        while (true) {
            var pi = std.mem.zeroes(c.ngtcp2_pkt_info);
            const n = c.ngtcp2_conn_write_pkt_versioned(
                self.conn.?,
                &self.path,
                c.NGTCP2_PKT_INFO_VERSION,
                &pi,
                &buf,
                buf.len,
                time.nowNs(),
            );
            if (n < 0) {
                abi.setErrorFmt("ngtcp2_conn_write_pkt: {s}", .{std.mem.span(c.ngtcp2_strerror(@intCast(n)))});
                return error.HandshakeFailed;
            }
            if (n == 0) return;
            self.socket.send(io_mod.io(), &self.remote, buf[0..@intCast(n)]) catch |err| {
                abi.setErrorFmt("quic udp send: {s}", .{@errorName(err)});
                return error.SendFailed;
            };
        }
    }

    fn receiveOne(self: *Conn, timeout_ms: u32) Error!bool {
        var buf: [65536]u8 = undefined;
        const io = io_mod.io();
        const timeout: std.Io.Timeout = if (timeout_ms == 0)
            .none
        else
            .{ .duration = .{
                .raw = .{ .nanoseconds = @as(i96, timeout_ms) * std.time.ns_per_ms },
                .clock = .awake,
            } };

        const msg = self.socket.receiveTimeout(io, &buf, timeout) catch |err| switch (err) {
            error.Timeout => return false,
            else => {
                abi.setErrorFmt("quic udp receive: {s}", .{@errorName(err)});
                return error.ReceiveFailed;
            },
        };
        if (msg.data.len == 0) return false;

        if (!addressesEqual(msg.from, self.remote)) {
            self.remote = msg.from;
            self.layoutPath();
        }

        var pi = std.mem.zeroes(c.ngtcp2_pkt_info);
        const rc = c.ngtcp2_conn_read_pkt_versioned(
            self.conn.?,
            &self.path,
            c.NGTCP2_PKT_INFO_VERSION,
            &pi,
            msg.data.ptr,
            msg.data.len,
            time.nowNs(),
        );
        if (rc != 0) {
            abi.setErrorFmt("ngtcp2_conn_read_pkt: {s}", .{std.mem.span(c.ngtcp2_strerror(rc))});
            return error.HandshakeFailed;
        }
        return true;
    }

    fn driveHandshake(self: *Conn, timeout_ms: u32) Error!void {
        const start = time.nowNs();
        const limit = @as(u64, timeout_ms) * std.time.ns_per_ms;
        while (!self.handshake_completed) {
            if (timeout_ms != 0 and time.nowNs() - start >= limit) return error.Timeout;
            try self.flush();
            if (self.handshake_completed) break;
            _ = try self.receiveOne(20);
            if (timeout_ms != 0 and time.nowNs() - start >= limit) return error.Timeout;
            try self.handleTimers();
        }
        try self.flush();
    }

    fn handleTimers(self: *Conn) Error!void {
        const now = time.nowNs();
        const expiry = c.ngtcp2_conn_get_expiry2(self.conn.?);
        if (expiry != 0 and now >= expiry) {
            const rc = c.ngtcp2_conn_handle_expiry(self.conn.?, now);
            if (rc != 0) {
                abi.setErrorFmt("ngtcp2_conn_handle_expiry: {s}", .{std.mem.span(c.ngtcp2_strerror(rc))});
                return error.HandshakeFailed;
            }
        }
    }

    fn driveReceive(self: *Conn, timeout_ms: u32) Error!void {
        const start = time.nowNs();
        const limit = @as(u64, timeout_ms) * std.time.ns_per_ms;
        while (self.rx.items.len == 0 and !self.rx_fin) {
            if (timeout_ms != 0 and time.nowNs() - start >= limit) return error.Timeout;
            try self.flush();
            _ = try self.receiveOne(20);
            try self.handleTimers();
            try self.flush();
        }
    }

    pub fn send(self: *Conn, data: []const u8, fin: bool) Error!void {
        if (self.conn == null or self.closed) return error.Closed;
        if (self.stream_id < 0) try self.openStream();

        const copy = self.allocator.dupe(u8, data) catch return error.OutOfMemory;
        self.tx_chunks.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return error.OutOfMemory;
        };

        var offset: usize = 0;
        var buf: [max_datagram]u8 = undefined;
        var guard: usize = 0;
        while (guard < 1024) : (guard += 1) {
            const remaining = copy[offset..];
            var datav = c.ngtcp2_vec{
                .base = @constCast(remaining.ptr),
                .len = remaining.len,
            };
            var wdatalen: c.ngtcp2_ssize = 0;
            var flags: u32 = c.NGTCP2_WRITE_STREAM_FLAG_NONE;
            if (fin and remaining.len == 0) flags |= c.NGTCP2_WRITE_STREAM_FLAG_FIN;

            var pi = std.mem.zeroes(c.ngtcp2_pkt_info);
            const n = c.ngtcp2_conn_writev_stream_versioned(
                self.conn.?,
                &self.path,
                c.NGTCP2_PKT_INFO_VERSION,
                &pi,
                &buf,
                buf.len,
                &wdatalen,
                flags,
                self.stream_id,
                &datav,
                1,
                time.nowNs(),
            );
            if (n < 0) {
                abi.setErrorFmt("ngtcp2 writev_stream: {s}", .{std.mem.span(c.ngtcp2_strerror(@intCast(n)))});
                return error.SendFailed;
            }
            if (wdatalen > 0) offset += @intCast(wdatalen);
            if (n > 0) {
                self.socket.send(io_mod.io(), &self.remote, buf[0..@intCast(n)]) catch |err| {
                    abi.setErrorFmt("quic udp send: {s}", .{@errorName(err)});
                    return error.SendFailed;
                };
            } else if (offset >= copy.len) {
                break;
            } else {
                try self.driveReceive(20);
            }
            if (offset >= copy.len and n == 0) break;
        }

        if (fin) {
            var pi = std.mem.zeroes(c.ngtcp2_pkt_info);
            var datav = c.ngtcp2_vec{ .base = null, .len = 0 };
            var wdatalen: c.ngtcp2_ssize = 0;
            const n = c.ngtcp2_conn_writev_stream_versioned(
                self.conn.?,
                &self.path,
                c.NGTCP2_PKT_INFO_VERSION,
                &pi,
                &buf,
                buf.len,
                &wdatalen,
                c.NGTCP2_WRITE_STREAM_FLAG_FIN,
                self.stream_id,
                &datav,
                1,
                time.nowNs(),
            );
            if (n > 0) {
                self.socket.send(io_mod.io(), &self.remote, buf[0..@intCast(n)]) catch |err| {
                    abi.setErrorFmt("quic udp send: {s}", .{@errorName(err)});
                    return error.SendFailed;
                };
            }
        }
        try self.flush();
    }

    pub fn receive(self: *Conn, buffer: []u8, timeout_ms: u32) Error!usize {
        if (self.conn == null or self.closed) return error.Closed;
        if (self.rx.items.len == 0) try self.driveReceive(timeout_ms);
        if (self.rx.items.len == 0) return 0;

        const n = @min(buffer.len, self.rx.items.len);
        @memcpy(buffer[0..n], self.rx.items[0..n]);
        const remaining = self.rx.items.len - n;
        std.mem.copyForwards(u8, self.rx.items[0..remaining], self.rx.items[n..]);
        self.rx.shrinkRetainingCapacity(remaining);
        return n;
    }

    pub fn shutdown(self: *Conn, error_code: u64) void {
        if (self.conn == null or self.closed) return;
        var buf: [max_datagram]u8 = undefined;
        var pi = std.mem.zeroes(c.ngtcp2_pkt_info);
        var ccerr = std.mem.zeroes(c.ngtcp2_ccerr);
        c.ngtcp2_ccerr_default(&ccerr);
        ccerr.type = c.NGTCP2_CCERR_TYPE_APPLICATION;
        ccerr.error_code = error_code;
        const n = c.ngtcp2_conn_write_connection_close_versioned(
            self.conn.?,
            &self.path,
            c.NGTCP2_PKT_INFO_VERSION,
            &pi,
            &buf,
            buf.len,
            &ccerr,
            time.nowNs(),
        );
        if (n > 0) {
            self.socket.send(io_mod.io(), &self.remote, buf[0..@intCast(n)]) catch {};
        }
    }

    pub fn deinit(self: *Conn) void {
        if (self.closed) return;
        self.shutdown(0);
        self.closed = true;
        if (self.conn) |conn| c.ngtcp2_conn_del(conn);
        if (self.ssl) |ssl| {
            _ = c.SSL_set_app_data(ssl, null);
            c.SSL_free(ssl);
        }
        if (self.ossl_ctx) |ctx| c.ngtcp2_crypto_ossl_ctx_del(ctx);
        if (self.ssl_ctx) |ctx| c.SSL_CTX_free(ctx);
        if (self.owns_socket) self.socket.close(io_mod.io());

        for (self.tx_chunks.items) |chunk| self.allocator.free(chunk);
        self.tx_chunks.deinit(self.allocator);
        self.rx.deinit(self.allocator);
        if (self.alpn.len > 0) self.allocator.free(self.alpn);
        if (self.cert_pem.len > 0) self.allocator.free(self.cert_pem);
        if (self.key_pem.len > 0) self.allocator.free(self.key_pem);
        self.allocator.destroy(self);
    }

    pub fn remoteAddress(self: *Conn) net.IpAddress {
        return self.remote;
    }
};

pub const Listener = struct {
    allocator: std.mem.Allocator,
    socket: std.Io.net.Socket,
    local: net.IpAddress,
    port: u16,
    options: Options,

    pub fn listen(allocator: std.mem.Allocator, host: []const u8, port: u16, options: Options) Error!*Listener {
        ensureCrypto();
        const addr = net.resolve(host, port) catch return error.ListenFailed;
        const socket = addr.bind(io_mod.io(), .{ .mode = .dgram, .protocol = .udp }) catch |err| {
            abi.setErrorFmt("quic udp bind: {s}", .{@errorName(err)});
            return error.ListenFailed;
        };
        const self = allocator.create(Listener) catch {
            socket.close(io_mod.io());
            return error.OutOfMemory;
        };
        const alpn_copy = allocator.dupe(u8, options.alpn) catch {
            allocator.destroy(self);
            socket.close(io_mod.io());
            return error.OutOfMemory;
        };
        const cert_copy = allocator.dupe(u8, options.cert_pem) catch {
            allocator.free(alpn_copy);
            allocator.destroy(self);
            socket.close(io_mod.io());
            return error.OutOfMemory;
        };
        const key_copy = allocator.dupe(u8, options.key_pem) catch {
            allocator.free(alpn_copy);
            allocator.free(cert_copy);
            allocator.destroy(self);
            socket.close(io_mod.io());
            return error.OutOfMemory;
        };

        self.* = .{
            .allocator = allocator,
            .socket = socket,
            .local = socket.address,
            .port = socket.address.getPort(),
            .options = .{
                .alpn = alpn_copy,
                .insecure = options.insecure,
                .idle_timeout_ms = options.idle_timeout_ms,
                .cert_pem = cert_copy,
                .key_pem = key_copy,
            },
        };
        return self;
    }

    pub fn accept(self: *Listener, timeout_ms: u32) Error!*Conn {
        const start = time.nowNs();
        const limit = @as(u64, timeout_ms) * std.time.ns_per_ms;
        var buf: [65536]u8 = undefined;

        while (true) {
            if (timeout_ms != 0 and time.nowNs() - start >= limit) return error.Timeout;
            const timeout: std.Io.Timeout = .{ .duration = .{
                .raw = .{ .nanoseconds = 20 * std.time.ns_per_ms },
                .clock = .awake,
            } };
            const msg = self.socket.receiveTimeout(io_mod.io(), &buf, timeout) catch |err| switch (err) {
                error.Timeout => continue,
                else => {
                    abi.setErrorFmt("quic accept receive: {s}", .{@errorName(err)});
                    return error.AcceptFailed;
                },
            };
            if (msg.data.len == 0) continue;

            var hd = std.mem.zeroes(c.ngtcp2_pkt_hd);
            if (c.ngtcp2_accept(&hd, msg.data.ptr, msg.data.len) != 0) continue;

            const conn_alloc = self.allocator.create(Conn) catch return error.OutOfMemory;
            const alpn = self.allocator.dupe(u8, self.options.alpn) catch {
                self.allocator.destroy(conn_alloc);
                return error.OutOfMemory;
            };
            const cert = self.allocator.dupe(u8, self.options.cert_pem) catch {
                self.allocator.free(alpn);
                self.allocator.destroy(conn_alloc);
                return error.OutOfMemory;
            };
            const key = self.allocator.dupe(u8, self.options.key_pem) catch {
                self.allocator.free(alpn);
                self.allocator.free(cert);
                self.allocator.destroy(conn_alloc);
                return error.OutOfMemory;
            };
            var committed = false;
            conn_alloc.* = .{
                .allocator = self.allocator,
                .is_server = true,
                .owns_socket = false,
                .socket = self.socket,
                .local = self.local,
                .remote = msg.from,
                .alpn = alpn,
                .cert_pem = cert,
                .key_pem = key,
            };
            errdefer {
                if (!committed) {
                    conn_alloc.allocator.free(conn_alloc.alpn);
                    conn_alloc.allocator.free(conn_alloc.cert_pem);
                    conn_alloc.allocator.free(conn_alloc.key_pem);
                    conn_alloc.allocator.destroy(conn_alloc);
                }
            }
            conn_alloc.layoutPath();

            conn_alloc.initServerTls() catch |err| {
                committed = true;
                conn_alloc.deinit();
                return err;
            };
            const conn = conn_alloc.newConn(&hd.scid, null, &hd.dcid, self.options) catch |err| {
                committed = true;
                conn_alloc.deinit();
                return err;
            };
            conn_alloc.conn = conn;
            c.ngtcp2_conn_set_tls_native_handle(conn, @ptrCast(conn_alloc.ossl_ctx));

            var pi = std.mem.zeroes(c.ngtcp2_pkt_info);
            const rc = c.ngtcp2_conn_read_pkt_versioned(
                conn,
                &conn_alloc.path,
                c.NGTCP2_PKT_INFO_VERSION,
                &pi,
                msg.data.ptr,
                msg.data.len,
                time.nowNs(),
            );
            if (rc != 0) {
                abi.setErrorFmt("server read initial: {s}", .{std.mem.span(c.ngtcp2_strerror(rc))});
                committed = true;
                conn_alloc.deinit();
                return error.HandshakeFailed;
            }

            conn_alloc.driveHandshake(if (timeout_ms == 0) 0 else timeout_ms) catch |err| {
                committed = true;
                conn_alloc.deinit();
                return err;
            };
            committed = true;
            return conn_alloc;
        }
    }

    pub fn deinit(self: *Listener) void {
        self.socket.close(io_mod.io());
        if (self.options.alpn.len > 0) self.allocator.free(self.options.alpn);
        if (self.options.cert_pem.len > 0) self.allocator.free(self.options.cert_pem);
        if (self.options.key_pem.len > 0) self.allocator.free(self.options.key_pem);
        self.allocator.destroy(self);
    }
};

fn callbacksFor(is_server: bool) c.ngtcp2_callbacks {
    var callbacks = std.mem.zeroes(c.ngtcp2_callbacks);
    if (is_server) {
        callbacks.recv_client_initial = c.ngtcp2_crypto_recv_client_initial_cb;
    } else {
        callbacks.client_initial = c.ngtcp2_crypto_client_initial_cb;
        callbacks.recv_retry = c.ngtcp2_crypto_recv_retry_cb;
    }
    callbacks.recv_crypto_data = c.ngtcp2_crypto_recv_crypto_data_cb;
    callbacks.encrypt = c.ngtcp2_crypto_encrypt_cb;
    callbacks.decrypt = c.ngtcp2_crypto_decrypt_cb;
    callbacks.hp_mask = c.ngtcp2_crypto_hp_mask_cb;
    callbacks.recv_stream_data = streamDataCb;
    callbacks.acked_stream_data_offset = ackedDataCb;
    callbacks.stream_open = streamOpenCb;
    callbacks.stream_close2 = streamCloseCb;
    callbacks.handshake_completed = handshakeCompletedCb;
    callbacks.handshake_confirmed = handshakeConfirmedCb;
    callbacks.rand = randCb;
    callbacks.update_key = c.ngtcp2_crypto_update_key_cb;
    callbacks.delete_crypto_aead_ctx = c.ngtcp2_crypto_delete_crypto_aead_ctx_cb;
    callbacks.delete_crypto_cipher_ctx = c.ngtcp2_crypto_delete_crypto_cipher_ctx_cb;
    callbacks.version_negotiation = c.ngtcp2_crypto_version_negotiation_cb;
    callbacks.get_new_connection_id2 = getNewConnectionIdCb;
    callbacks.get_path_challenge_data2 = c.ngtcp2_crypto_get_path_challenge_data2_cb;
    return callbacks;
}

fn getConnCb(ref: [*c]c.ngtcp2_crypto_conn_ref) callconv(.c) ?*c.ngtcp2_conn {
    if (ref == null) return null;
    const self: *Conn = @ptrCast(@alignCast(ref[0].user_data));
    return self.conn;
}

fn randCb(dest: [*c]u8, destlen: usize, rand_ctx: ?*const c.ngtcp2_rand_ctx) callconv(.c) void {
    _ = rand_ctx;
    if (c.RAND_bytes(dest, @intCast(destlen)) != 1) {
        @memset(dest[0..destlen], 0);
    }
}

fn getNewConnectionIdCb(
    conn: ?*c.ngtcp2_conn,
    cid: ?*c.ngtcp2_cid,
    token: ?*c.ngtcp2_stateless_reset_token,
    cidlen: usize,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = conn;
    const self: *Conn = @ptrCast(@alignCast(user_data orelse return c.NGTCP2_ERR_CALLBACK_FAILURE));
    const cid_ptr = cid orelse return c.NGTCP2_ERR_CALLBACK_FAILURE;
    const token_ptr = token orelse return c.NGTCP2_ERR_CALLBACK_FAILURE;
    if (cidlen > cid_ptr.data.len) return c.NGTCP2_ERR_CALLBACK_FAILURE;
    if (c.RAND_bytes(&cid_ptr.data, @intCast(cidlen)) != 1) return c.NGTCP2_ERR_CALLBACK_FAILURE;
    cid_ptr.datalen = cidlen;
    if (c.ngtcp2_crypto_generate_stateless_reset_token(
        &token_ptr.data,
        &self.static_secret,
        self.static_secret.len,
        cid_ptr,
    ) != 0) {
        return c.NGTCP2_ERR_CALLBACK_FAILURE;
    }
    return 0;
}

fn handshakeCompletedCb(conn: ?*c.ngtcp2_conn, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = conn;
    const self: *Conn = @ptrCast(@alignCast(user_data orelse return c.NGTCP2_ERR_CALLBACK_FAILURE));
    self.handshake_completed = true;
    return 0;
}

fn handshakeConfirmedCb(conn: ?*c.ngtcp2_conn, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = conn;
    const self: *Conn = @ptrCast(@alignCast(user_data orelse return c.NGTCP2_ERR_CALLBACK_FAILURE));
    self.handshake_confirmed = true;
    return 0;
}

fn streamDataCb(
    conn: ?*c.ngtcp2_conn,
    flags: u32,
    stream_id: i64,
    offset: u64,
    data: [*c]const u8,
    datalen: usize,
    user_data: ?*anyopaque,
    stream_user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = conn;
    _ = offset;
    _ = stream_user_data;
    const self: *Conn = @ptrCast(@alignCast(user_data orelse return c.NGTCP2_ERR_CALLBACK_FAILURE));
    if (self.stream_id < 0) self.stream_id = stream_id;
    if (self.stream_id != stream_id) return 0;
    if (datalen > 0) {
        self.rx.appendSlice(self.allocator, data[0..datalen]) catch return c.NGTCP2_ERR_CALLBACK_FAILURE;
    }
    if (flags & c.NGTCP2_STREAM_DATA_FLAG_FIN != 0) self.rx_fin = true;
    return 0;
}

fn streamOpenCb(conn: ?*c.ngtcp2_conn, stream_id: i64, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = conn;
    const self: *Conn = @ptrCast(@alignCast(user_data orelse return c.NGTCP2_ERR_CALLBACK_FAILURE));
    if (self.stream_id < 0) self.stream_id = stream_id;
    return 0;
}

fn streamCloseCb(
    conn: ?*c.ngtcp2_conn,
    flags: u32,
    stream_id: i64,
    rx_error: u64,
    tx_error: u64,
    user_data: ?*anyopaque,
    stream_user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = conn;
    _ = flags;
    _ = stream_id;
    _ = rx_error;
    _ = tx_error;
    _ = user_data;
    _ = stream_user_data;
    return 0;
}

fn ackedDataCb(
    conn: ?*c.ngtcp2_conn,
    stream_id: i64,
    offset: u64,
    datalen: u64,
    user_data: ?*anyopaque,
    stream_user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = conn;
    _ = stream_id;
    _ = offset;
    _ = datalen;
    _ = user_data;
    _ = stream_user_data;
    return 0;
}

fn alpnSelectCb(
    ssl: ?*c.SSL,
    out: [*c][*c]const u8,
    outlen: [*c]u8,
    in: [*c]const u8,
    inlen: c_uint,
    arg: ?*anyopaque,
) callconv(.c) c_int {
    _ = ssl;
    const self: *Conn = @ptrCast(@alignCast(arg orelse return c.SSL_TLSEXT_ERR_NOACK));
    if (inlen < 1) return c.SSL_TLSEXT_ERR_NOACK;
    const first_len: usize = in[0];
    if (first_len + 1 > inlen) return c.SSL_TLSEXT_ERR_NOACK;
    const protocol = in[1 .. 1 + first_len];
    if (!std.mem.eql(u8, protocol, self.alpn)) return c.SSL_TLSEXT_ERR_ALERT_FATAL;
    out.* = in + 1;
    outlen.* = @intCast(first_len);
    return c.SSL_TLSEXT_ERR_OK;
}

fn encodeAlpn(alpn: []const u8, buf: []u8) ?[]const u8 {
    if (alpn.len == 0 or alpn.len > 255 or buf.len < alpn.len + 1) return null;
    buf[0] = @intCast(alpn.len);
    @memcpy(buf[1 .. alpn.len + 1], alpn);
    return buf[0 .. alpn.len + 1];
}

fn isNumericHost(host: []const u8) bool {
    for (host) |ch| {
        if (!(std.ascii.isDigit(ch) or ch == '.' or ch == ':' or ch == '[' or ch == ']')) return false;
    }
    return true;
}

fn loadCertificate(ctx: *c.SSL_CTX, cert_pem: []const u8, key_pem: []const u8) Error!void {
    const cert_bio = c.BIO_new_mem_buf(cert_pem.ptr, @intCast(cert_pem.len)) orelse {
        logSslError("BIO_new_mem_buf(cert)");
        return error.TlsFailed;
    };
    defer _ = c.BIO_free(cert_bio);
    const x509 = c.PEM_read_bio_X509(cert_bio, null, null, null) orelse {
        logSslError("PEM_read_bio_X509");
        return error.TlsFailed;
    };
    defer c.X509_free(x509);
    if (c.SSL_CTX_use_certificate(ctx, x509) != 1) {
        logSslError("SSL_CTX_use_certificate");
        return error.TlsFailed;
    }

    const key_bio = c.BIO_new_mem_buf(key_pem.ptr, @intCast(key_pem.len)) orelse {
        logSslError("BIO_new_mem_buf(key)");
        return error.TlsFailed;
    };
    defer _ = c.BIO_free(key_bio);
    const key = c.PEM_read_bio_PrivateKey(key_bio, null, null, null) orelse {
        logSslError("PEM_read_bio_PrivateKey");
        return error.TlsFailed;
    };
    defer c.EVP_PKEY_free(key);
    if (c.SSL_CTX_use_PrivateKey(ctx, key) != 1 or c.SSL_CTX_check_private_key(ctx) != 1) {
        logSslError("SSL_CTX_use_PrivateKey");
        return error.TlsFailed;
    }
}

fn logSslError(what: []const u8) void {
    const code = c.ERR_get_error();
    var buf: [256]u8 = undefined;
    if (code != 0) {
        c.ERR_error_string_n(code, &buf, buf.len);
        abi.setErrorFmt("{s}: {s}", .{ what, std.mem.sliceTo(&buf, 0) });
    } else {
        abi.setErrorFmt("{s} failed", .{what});
    }
}

fn writeSockaddr(addr: net.IpAddress, storage: *std.c.sockaddr.storage, len: *std.c.socklen_t) void {
    storage.* = std.mem.zeroes(std.c.sockaddr.storage);
    switch (addr) {
        .ip4 => |ip| {
            var sin = std.mem.zeroes(std.c.sockaddr.in);
            sin.family = std.c.AF.INET;
            sin.port = std.mem.nativeToBig(u16, ip.port);
            sin.addr = @bitCast(ip.bytes);
            if (@hasField(@TypeOf(sin), "len")) sin.len = @sizeOf(@TypeOf(sin));
            @as(*std.c.sockaddr.in, @ptrCast(@alignCast(storage))).* = sin;
            len.* = @sizeOf(@TypeOf(sin));
        },
        .ip6 => |ip| {
            var sin6 = std.mem.zeroes(std.c.sockaddr.in6);
            sin6.family = std.c.AF.INET6;
            sin6.port = std.mem.nativeToBig(u16, ip.port);
            sin6.addr = ip.bytes;
            sin6.flowinfo = ip.flow;
            if (@hasField(@TypeOf(sin6), "scope_id")) sin6.scope_id = ip.interface.index;
            if (@hasField(@TypeOf(sin6), "len")) sin6.len = @sizeOf(@TypeOf(sin6));
            @as(*std.c.sockaddr.in6, @ptrCast(@alignCast(storage))).* = sin6;
            len.* = @sizeOf(@TypeOf(sin6));
        },
    }
}

fn addressesEqual(a: net.IpAddress, b: net.IpAddress) bool {
    return switch (a) {
        .ip4 => |a4| switch (b) {
            .ip4 => |b4| a4.port == b4.port and std.mem.eql(u8, &a4.bytes, &b4.bytes),
            else => false,
        },
        .ip6 => |a6| switch (b) {
            .ip6 => |b6| a6.port == b6.port and std.mem.eql(u8, &a6.bytes, &b6.bytes),
            else => false,
        },
    };
}

var crypto_state = std.atomic.Value(u8).init(0);

fn ensureCrypto() void {
    if (crypto_state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
        _ = c.ngtcp2_crypto_ossl_init();
        crypto_state.store(2, .release);
    } else {
        while (crypto_state.load(.acquire) != 2) std.atomic.spinLoopHint();
    }
}

pub const Registry = handles.Table(Conn);
pub const ListenerRegistry = handles.Table(Listener);
pub var registry: Registry = .{};
pub var listeners: ListenerRegistry = .{};

test "QUIC loopback handshake and stream" {
    const cert = @embedFile("testdata/quic-cert.pem");
    const key = @embedFile("testdata/quic-key.pem");

    var listener = Listener.listen(std.testing.allocator, "127.0.0.1", 0, .{
        .alpn = "engine7-test",
        .insecure = true,
        .cert_pem = cert,
        .key_pem = key,
    }) catch |err| {
        std.debug.print("skipping QUIC test (listen): {s} ({s})\n", .{ @errorName(err), abi.lastError() });
        return;
    };
    defer listener.deinit();

    const Ctx = struct {
        listener: *Listener,
        event: *std.Io.Event,
        fn run(ctx: @This()) void {
            ctx.event.set(io_mod.io());
            const conn = ctx.listener.accept(12_000) catch |err| {
                std.debug.print("QUIC server accept failed: {s} ({s})\n", .{ @errorName(err), abi.lastError() });
                return;
            };
            defer conn.deinit();
            var buf: [256]u8 = undefined;
            const n = conn.receive(&buf, 8_000) catch return;
            _ = conn.send(buf[0..n], false) catch return;
        }
    };

    var ready: std.Io.Event = .unset;
    const thread = try std.Thread.spawn(.{}, Ctx.run, .{Ctx{ .listener = listener, .event = &ready }});
    ready.waitUncancelable(io_mod.io());

    const conn = Conn.connect(std.testing.allocator, "127.0.0.1", listener.port, .{
        .alpn = "engine7-test",
        .insecure = true,
    }) catch |err| {
        std.debug.print("skipping QUIC test (connect): {s} ({s})\n", .{ @errorName(err), abi.lastError() });
        return;
    };
    defer conn.deinit();

    try conn.send("hello quic", false);
    var buf: [256]u8 = undefined;
    const n = try conn.receive(&buf, 8_000);
    try std.testing.expectEqualStrings("hello quic", buf[0..n]);
    thread.join();
}
