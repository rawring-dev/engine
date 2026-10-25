//! TCP and UDP networking over Zig's cross-platform `std.Io.net`.
//!
//! Host names are resolved through the platform resolver (`getaddrinfo`) and
//! converted back to a numeric address so all socket operations share
//! `std.Io.net.IpAddress`.  TCP accepts and reads take a millisecond timeout on
//! POSIX systems by polling the descriptor; on Windows those paths fall back to
//! blocking behaviour.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const io_mod = @import("io.zig");
const handles = @import("handles.zig");

pub const Error = error{
    InvalidAddress,
    ResolveFailed,
    ConnectFailed,
    ListenFailed,
    AcceptFailed,
    SendFailed,
    ReceiveFailed,
    Timeout,
    Closed,
    OutOfMemory,
};

pub const IpAddress = std.Io.net.IpAddress;

/// Resolve `host` (literal or name) and `port` to an address usable by
/// `std.Io.net`.
pub fn resolve(host: []const u8, port: u16) Error!IpAddress {
    if (host.len == 0) return error.InvalidAddress;

    // Fast path for numeric literals.
    var literal_buf: [128]u8 = undefined;
    if (std.mem.indexOfScalar(u8, host, ':') != null and host[0] != '[') {
        if (std.fmt.bufPrint(&literal_buf, "[{s}]:{d}", .{ host, port })) |text| {
            if (IpAddress.parseLiteral(text) catch null) |addr| return addr;
        } else |_| {}
    } else if (std.fmt.bufPrint(&literal_buf, "{s}:{d}", .{ host, port })) |text| {
        if (IpAddress.parseLiteral(text) catch null) |addr| return addr;
    } else |_| {}

    const allocator = std.heap.c_allocator;
    const host_z = allocator.dupeZ(u8, host) catch return error.OutOfMemory;
    defer allocator.free(host_z);
    var port_buf: [8]u8 = undefined;
    const port_z = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch return error.InvalidAddress;

    var result: ?*std.c.addrinfo = null;
    const rc = std.c.getaddrinfo(host_z.ptr, port_z.ptr, null, &result);
    if (@intFromEnum(rc) != 0) {
        abi.setErrorFmt("getaddrinfo({s}): {s}", .{ host, std.mem.span(std.c.gai_strerror(rc)) });
        return error.ResolveFailed;
    }
    defer if (result) |res| std.c.freeaddrinfo(res);

    var current = result;
    while (current) |ai| : (current = ai.next) {
        const sockaddr = ai.addr orelse continue;
        var numeric: [128]u8 = undefined;
        const ni = std.c.getnameinfo(
            sockaddr,
            ai.addrlen,
            &numeric,
            numeric.len,
            null,
            0,
            std.c.NI{ .NUMERICHOST = true },
        );
        if (@intFromEnum(ni) != 0) continue;

        const text = std.mem.sliceTo(&numeric, 0);
        var buf: [160]u8 = undefined;
        const formatted = if (std.mem.indexOfScalar(u8, text, ':') != null)
            std.fmt.bufPrint(&buf, "[{s}]:{d}", .{ text, port }) catch continue
        else
            std.fmt.bufPrint(&buf, "{s}:{d}", .{ text, port }) catch continue;

        if (IpAddress.parseLiteral(formatted) catch null) |addr| return addr;
    }
    return error.ResolveFailed;
}

fn timeoutOf(ms: u32) std.Io.Timeout {
    if (ms == 0) return .none;
    return .{ .duration = .{
        .raw = .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms },
        .clock = .awake,
    } };
}

fn waitReadable(handle: std.Io.net.Socket.Handle, timeout_ms: u32) Error!bool {
    if (comptime builtin.os.tag == .windows) return true;

    var pfd = std.c.pollfd{
        .fd = handle,
        .events = std.c.POLL.IN,
        .revents = 0,
    };
    const timeout: c_int = if (timeout_ms == 0) -1 else @intCast(@min(timeout_ms, std.math.maxInt(c_int)));
    const rc = std.c.poll(@ptrCast(&pfd), 1, timeout);
    if (rc < 0) return error.AcceptFailed;
    if (rc == 0) return false;
    return (pfd.revents & (std.c.POLL.IN | std.c.POLL.ERR | std.c.POLL.HUP)) != 0;
}

pub const Listener = struct {
    server: std.Io.net.Server,
    port: u16,

    pub fn listen(host: []const u8, port: u16, backlog: u31) Error!Listener {
        const addr = try resolve(host, port);
        const server = addr.listen(io_mod.io(), .{
            .reuse_address = true,
            .mode = .stream,
            .protocol = .tcp,
            .kernel_backlog = backlog,
        }) catch |err| {
            abi.setErrorFmt("tcp listen {s}:{d}: {s}", .{ host, port, @errorName(err) });
            return error.ListenFailed;
        };
        return .{ .server = server, .port = server.socket.address.getPort() };
    }

    pub fn accept(self: *Listener, timeout_ms: u32) Error!Connection {
        const io = io_mod.io();
        if (timeout_ms != 0) {
            if (!try waitReadable(self.server.socket.handle, timeout_ms)) return error.Timeout;
        }
        const stream = self.server.accept(io) catch |err| {
            abi.setErrorFmt("tcp accept: {s}", .{@errorName(err)});
            return error.AcceptFailed;
        };
        return .{ .stream = stream, .peer = stream.socket.address };
    }

    pub fn close(self: *Listener) void {
        self.server.deinit(io_mod.io());
    }
};

pub const Connection = struct {
    stream: std.Io.net.Stream,
    peer: IpAddress,

    pub fn connect(host: []const u8, port: u16, timeout_ms: u32) Error!Connection {
        const addr = try resolve(host, port);
        // std.Io's POSIX backend currently panics for connect deadlines, so the
        // connect itself is blocking; `timeout_ms` is honoured by accept/read.
        _ = timeout_ms;
        const stream = addr.connect(io_mod.io(), .{
            .mode = .stream,
            .protocol = .tcp,
        }) catch |err| {
            abi.setErrorFmt("tcp connect {s}:{d}: {s}", .{ host, port, @errorName(err) });
            return error.ConnectFailed;
        };
        return .{ .stream = stream, .peer = addr };
    }

    /// Send every byte, returning the number accepted.
    pub fn send(self: *Connection, data: []const u8) Error!usize {
        const io = io_mod.io();
        var sent: usize = 0;
        while (sent < data.len) {
            const chunk = data[sent..];
            const n = io.vtable.netWrite(io.userdata, self.stream.socket.handle, "", &.{chunk}, 1) catch |err| {
                abi.setErrorFmt("tcp send: {s}", .{@errorName(err)});
                return error.SendFailed;
            };
            if (n == 0) return error.Closed;
            sent += n;
        }
        return sent;
    }

    /// Receive up to `buffer.len` bytes.  A return value of zero means EOF.
    pub fn receive(self: *Connection, buffer: []u8, timeout_ms: u32) Error!usize {
        if (timeout_ms != 0) {
            if (!try waitReadable(self.stream.socket.handle, timeout_ms)) return error.Timeout;
        }
        const io = io_mod.io();
        var bufs = [_][]u8{buffer};
        const n = io.vtable.netRead(io.userdata, self.stream.socket.handle, &bufs) catch |err| {
            abi.setErrorFmt("tcp receive: {s}", .{@errorName(err)});
            return error.ReceiveFailed;
        };
        return n;
    }

    pub fn shutdown(self: *Connection) void {
        self.stream.shutdown(io_mod.io(), .both) catch {};
    }

    pub fn close(self: *Connection) void {
        self.stream.close(io_mod.io());
    }
};

pub const DatagramSocket = struct {
    socket: std.Io.net.Socket,
    port: u16,

    pub fn bind(host: []const u8, port: u16) Error!DatagramSocket {
        const addr = try resolve(host, port);
        const socket = addr.bind(io_mod.io(), .{
            .mode = .dgram,
            .protocol = .udp,
            .allow_broadcast = false,
        }) catch |err| {
            abi.setErrorFmt("udp bind {s}:{d}: {s}", .{ host, port, @errorName(err) });
            return error.ListenFailed;
        };
        return .{ .socket = socket, .port = socket.address.getPort() };
    }

    pub fn sendTo(self: *DatagramSocket, host: []const u8, port: u16, data: []const u8) Error!void {
        const addr = try resolve(host, port);
        self.socket.send(io_mod.io(), &addr, data) catch |err| {
            abi.setErrorFmt("udp send: {s}", .{@errorName(err)});
            return error.SendFailed;
        };
    }

    pub fn receiveFrom(self: *DatagramSocket, buffer: []u8, timeout_ms: u32) Error!struct { from: IpAddress, len: usize } {
        const io = io_mod.io();
        const msg = self.socket.receiveTimeout(io, buffer, timeoutOf(timeout_ms)) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => {
                abi.setErrorFmt("udp receive: {s}", .{@errorName(err)});
                return error.ReceiveFailed;
            },
        };
        return .{ .from = msg.from, .len = msg.data.len };
    }

    pub fn close(self: *DatagramSocket) void {
        const io = io_mod.io();
        self.socket.close(io);
    }
};

pub fn formatAddress(addr: IpAddress, out: []u8) []const u8 {
    return switch (addr) {
        .ip4 => |a| std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}:{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3], a.port }) catch "",
        .ip6 => |a| std.fmt.bufPrint(out, "[{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}]:{d}", .{
            a.bytes[0],  a.bytes[1],  a.bytes[2],  a.bytes[3],
            a.bytes[4],  a.bytes[5],  a.bytes[6],  a.bytes[7],
            a.bytes[8],  a.bytes[9],  a.bytes[10], a.bytes[11],
            a.bytes[12], a.bytes[13], a.bytes[14], a.bytes[15],
            a.port,
        }) catch "",
    };
}

pub const ListenerRegistry = handles.Table(Listener);
pub const ConnectionRegistry = handles.Table(Connection);
pub const DatagramRegistry = handles.Table(DatagramSocket);
pub var listeners: ListenerRegistry = .{};
pub var connections: ConnectionRegistry = .{};
pub var datagrams: DatagramRegistry = .{};

fn echoServer(listener: *Listener, ready: *std.Io.Event) void {
    defer listener.close();
    ready.set(io_mod.io());
    var conn = listener.accept(0) catch return;
    defer conn.close();
    var buf: [64]u8 = undefined;
    const n = conn.receive(&buf, 5_000) catch return;
    _ = conn.send(buf[0..n]) catch return;
    _ = conn.send("!") catch return;
}

test "TCP loopback echo" {
    var listener = try Listener.listen("127.0.0.1", 0, 16);
    var ready: std.Io.Event = .unset;
    const thread = try std.Thread.spawn(.{}, echoServer, .{ &listener, &ready });
    ready.waitUncancelable(io_mod.io());

    var conn = try Connection.connect("127.0.0.1", listener.port, 2_000);
    defer conn.close();
    _ = try conn.send("ping");
    var buf: [32]u8 = undefined;
    const n = try conn.receive(&buf, 2_000);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "ping"));

    // Some kernels split the reply; keep reading until the terminator arrives.
    var total = n;
    while (total < 5 and total < buf.len) {
        const more = try conn.receive(buf[total..], 2_000);
        if (more == 0) break;
        total += more;
    }
    try std.testing.expectEqualStrings("ping!", buf[0..total]);
    thread.join();
}

test "UDP loopback datagram" {
    var server = try DatagramSocket.bind("127.0.0.1", 0);
    defer server.close();
    var client = try DatagramSocket.bind("127.0.0.1", 0);
    defer client.close();

    try client.sendTo("127.0.0.1", server.port, "hello");
    var buf: [64]u8 = undefined;
    const msg = try server.receiveFrom(&buf, 2_000);
    try std.testing.expectEqualStrings("hello", buf[0..msg.len]);
    try server.sendTo("127.0.0.1", client.port, "world");
    const reply = try client.receiveFrom(&buf, 2_000);
    try std.testing.expectEqualStrings("world", buf[0..reply.len]);
}

test "resolve localhost and literal" {
    const a = try resolve("127.0.0.1", 80);
    try std.testing.expectEqual(@as(u16, 80), a.getPort());
    const b = try resolve("localhost", 443);
    try std.testing.expectEqual(@as(u16, 443), b.getPort());
}
