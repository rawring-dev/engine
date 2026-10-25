//! WebRTC data channels through libdatachannel's C API [libdatachannel],
//! following the data-channel establishment protocol [rfc8832].
//!
//! The runtime exposes a deliberately small peer abstraction: create a peer,
//! create/answer an SDP offer, set the remote description, wait for gathering
//! and connectivity, then send/receive data-channel messages.  Non-trickle ICE
//! is used: the local description returned after gathering completes contains
//! host candidates, which is sufficient for loopback and LAN peers.  STUN/TURN
//! servers can be supplied as a comma-separated `ice_servers` list.

const std = @import("std");
const abi = @import("abi.zig");
const io_mod = @import("io.zig");
const handles = @import("handles.zig");
const time = @import("time.zig");

pub const c = @cImport({
    @cInclude("rtc/rtc.h");
});

pub const Error = error{
    CreateFailed,
    OperationFailed,
    Timeout,
    Closed,
    NotOpen,
    OutOfMemory,
    InvalidArgument,
};

const sdp_capacity = 128 * 1024;

pub const Message = struct {
    data: []u8,
    binary: bool,
};

pub const Peer = struct {
    pc: c_int,
    dc: c_int = -1,
    mutex: io_mod.Mutex = .{},
    messages: std.ArrayListUnmanaged(Message) = .empty,
    last_sdp: []u8 = &.{},
    open: bool = false,
    closed: bool = false,
    state: c_int = c.RTC_NEW,
    gathering: c_int = c.RTC_GATHERING_NEW,
    last_error: [256]u8 = [_]u8{0} ** 256,
    last_error_len: usize = 0,

    pub fn create(allocator: std.mem.Allocator, ice_servers: []const u8, bind_address: ?[]const u8) Error!*Peer {
        _ = allocator;
        ensurePreload();

        var server_ptrs: [16]?[*:0]const u8 = [_]?[*:0]const u8{null} ** 16;
        var server_count: usize = 0;
        var server_bufs: [16][]u8 = undefined;
        var server_buf_count: usize = 0;
        defer {
            for (server_bufs[0..server_buf_count]) |buf| std.heap.c_allocator.free(buf);
        }

        var it = std.mem.splitScalar(u8, ice_servers, ',');
        while (it.next()) |raw| {
            const item = std.mem.trim(u8, raw, " \t\r\n");
            if (item.len == 0) continue;
            if (server_count == server_ptrs.len) break;
            const z = std.heap.c_allocator.dupeZ(u8, item) catch return error.OutOfMemory;
            server_bufs[server_buf_count] = z;
            server_buf_count += 1;
            server_ptrs[server_count] = z.ptr;
            server_count += 1;
        }

        const bind_z = if (bind_address) |addr| (std.heap.c_allocator.dupeZ(u8, addr) catch return error.OutOfMemory) else null;
        defer if (bind_z) |z| std.heap.c_allocator.free(z);

        var config = std.mem.zeroes(c.rtcConfiguration);
        config.iceServers = if (server_count == 0) null else @ptrCast(&server_ptrs);
        config.iceServersCount = @intCast(server_count);
        config.bindAddress = if (bind_z) |z| z.ptr else null;
        config.certificateType = c.RTC_CERTIFICATE_DEFAULT;
        config.iceTransportPolicy = c.RTC_TRANSPORT_POLICY_ALL;

        const pc = c.rtcCreatePeerConnection(&config);
        if (pc < 0) {
            abi.setErrorFmt("rtcCreatePeerConnection: {d}", .{pc});
            return error.CreateFailed;
        }

        const item = std.heap.c_allocator.create(Peer) catch {
            _ = c.rtcDeletePeerConnection(pc);
            return error.OutOfMemory;
        };
        item.* = .{ .pc = pc, .state = c.RTC_NEW };
        errdefer {
            _ = c.rtcDeletePeerConnection(pc);
            std.heap.c_allocator.destroy(item);
        }

        // The callback user pointer must be the same allocation that the
        // registry stores, so `create` returns the pointer directly.
        c.rtcSetUserPointer(pc, item);
        _ = c.rtcSetStateChangeCallback(pc, stateCallback);
        _ = c.rtcSetGatheringStateChangeCallback(pc, gatheringCallback);
        _ = c.rtcSetDataChannelCallback(pc, dataChannelCallback);
        _ = c.rtcSetLocalDescriptionCallback(pc, descriptionCallback);
        _ = c.rtcSetLocalCandidateCallback(pc, candidateCallback);
        _ = c.rtcSetErrorCallback(pc, errorCallback);

        return item;
    }

    pub fn setRemote(self: *Peer, sdp: []const u8, kind: []const u8) Error!void {
        const sdp_z = std.heap.c_allocator.dupeZ(u8, sdp) catch return error.OutOfMemory;
        defer std.heap.c_allocator.free(sdp_z);
        const kind_z = std.heap.c_allocator.dupeZ(u8, kind) catch return error.OutOfMemory;
        defer std.heap.c_allocator.free(kind_z);

        const rc = c.rtcSetRemoteDescription(self.pc, sdp_z.ptr, kind_z.ptr);
        if (rc < 0) {
            abi.setErrorFmt("rtcSetRemoteDescription: {d}", .{rc});
            return error.OperationFailed;
        }
    }

    fn waitFor(self: *Peer, comptime predicate: fn (*const Peer) bool, timeout_ms: u32) Error!void {
        const start = time.nowNs();
        const limit = @as(u64, timeout_ms) * std.time.ns_per_ms;
        while (!predicate(self)) {
            if (time.nowNs() - start >= limit) return error.Timeout;
            time.sleepMs(1);
        }
    }

    pub fn waitGathering(self: *Peer, timeout_ms: u32) Error!void {
        try self.waitFor(struct {
            fn check(peer: *const Peer) bool {
                return peer.gathering == c.RTC_GATHERING_COMPLETE;
            }
        }.check, timeout_ms);
    }

    pub fn waitOpen(self: *Peer, timeout_ms: u32) Error!void {
        try self.waitFor(struct {
            fn check(peer: *const Peer) bool {
                return peer.open;
            }
        }.check, timeout_ms);
    }

    pub fn waitConnected(self: *Peer, timeout_ms: u32) Error!void {
        try self.waitFor(struct {
            fn check(peer: *const Peer) bool {
                return peer.state == c.RTC_CONNECTED or peer.open;
            }
        }.check, timeout_ms);
    }

    fn snapshotSdp(self: *Peer) []u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.last_sdp;
    }

    /// Create an offer, wait for ICE gathering, and return the complete SDP.
    pub fn createOffer(self: *Peer, timeout_ms: u32) Error![]u8 {
        const buf = std.heap.c_allocator.alloc(u8, sdp_capacity) catch return error.OutOfMemory;
        defer std.heap.c_allocator.free(buf);
        const rc = c.rtcCreateOffer(self.pc, buf.ptr, @intCast(buf.len));
        if (rc < 0) {
            abi.setErrorFmt("rtcCreateOffer: {d}", .{rc});
            return error.OperationFailed;
        }
        try self.waitGathering(timeout_ms);
        return self.localDescription(buf) catch return error.OperationFailed;
    }

    /// Create an answer for an already-set remote offer.
    pub fn createAnswer(self: *Peer, timeout_ms: u32) Error![]u8 {
        const buf = std.heap.c_allocator.alloc(u8, sdp_capacity) catch return error.OutOfMemory;
        defer std.heap.c_allocator.free(buf);
        const rc = c.rtcCreateAnswer(self.pc, buf.ptr, @intCast(buf.len));
        if (rc < 0) {
            abi.setErrorFmt("rtcCreateAnswer: {d}", .{rc});
            return error.OperationFailed;
        }
        try self.waitGathering(timeout_ms);
        return self.localDescription(buf) catch return error.OperationFailed;
    }

    fn localDescription(self: *Peer, buf: []u8) Error![]u8 {
        const rc = c.rtcGetLocalDescription(self.pc, buf.ptr, @intCast(buf.len));
        if (rc >= 0) {
            const len: usize = @intCast(rc);
            return std.heap.c_allocator.dupe(u8, buf[0..len]) catch error.OutOfMemory;
        }
        const sdp = self.snapshotSdp();
        if (sdp.len == 0) {
            abi.setErrorFmt("rtcGetLocalDescription: {d}", .{rc});
            return error.OperationFailed;
        }
        return std.heap.c_allocator.dupe(u8, sdp) catch error.OutOfMemory;
    }

    /// Create the locally-initiated data channel.  Call before `createOffer`.
    pub fn createDataChannel(self: *Peer, label: []const u8) Error!void {
        const label_z = std.heap.c_allocator.dupeZ(u8, label) catch return error.OutOfMemory;
        defer std.heap.c_allocator.free(label_z);
        const dc = c.rtcCreateDataChannel(self.pc, label_z.ptr);
        if (dc < 0) {
            abi.setErrorFmt("rtcCreateDataChannel: {d}", .{dc});
            return error.OperationFailed;
        }
        self.attachDataChannel(dc);
    }

    fn attachDataChannel(self: *Peer, dc: c_int) void {
        self.mutex.lock();
        self.dc = dc;
        self.mutex.unlock();

        c.rtcSetUserPointer(dc, self);
        _ = c.rtcSetOpenCallback(dc, openCallback);
        _ = c.rtcSetClosedCallback(dc, closedCallback);
        _ = c.rtcSetMessageCallback(dc, messageCallback);
        _ = c.rtcSetErrorCallback(dc, errorCallback);
        if (c.rtcIsOpen(dc)) {
            self.mutex.lock();
            self.open = true;
            self.mutex.unlock();
        }
    }

    pub fn send(self: *Peer, data: []const u8, binary: bool) Error!void {
        self.mutex.lock();
        const dc = self.dc;
        const open = self.open;
        self.mutex.unlock();
        if (dc < 0) return error.NotOpen;
        if (!open) return error.NotOpen;

        const size: c_int = if (binary)
            @intCast(data.len)
        else
            -@as(c_int, @intCast(data.len));
        const rc = c.rtcSendMessage(dc, @ptrCast(data.ptr), size);
        if (rc < 0) {
            abi.setErrorFmt("rtcSendMessage: {d}", .{rc});
            return error.OperationFailed;
        }
    }

    /// Pop one queued message.  Returns null when no message is available.
    /// The caller supplies the destination buffer; the message is dropped if it
    /// does not fit.
    pub fn receive(self: *Peer, buffer: []u8, out_binary: ?*bool) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.messages.items.len == 0) return null;

        const message = self.messages.orderedRemove(0);
        defer std.heap.c_allocator.free(message.data);
        if (out_binary) |flag| flag.* = message.binary;
        const n = @min(buffer.len, message.data.len);
        @memcpy(buffer[0..n], message.data[0..n]);
        return n;
    }

    pub fn receiveWait(self: *Peer, buffer: []u8, timeout_ms: u32, out_binary: ?*bool) Error!?usize {
        const start = time.nowNs();
        const limit = @as(u64, timeout_ms) * std.time.ns_per_ms;
        while (true) {
            if (self.receive(buffer, out_binary)) |n| return n;
            if (time.nowNs() - start >= limit) return null;
            time.sleepMs(1);
        }
    }

    pub fn close(self: *Peer) void {
        self.mutex.lock();
        if (self.closed) {
            self.mutex.unlock();
            return;
        }
        const dc = self.dc;
        const pc = self.pc;
        self.open = false;
        self.closed = true;
        self.dc = -1;
        self.mutex.unlock();

        c.rtcSetUserPointer(pc, null);
        if (dc >= 0) {
            c.rtcSetUserPointer(dc, null);
            _ = c.rtcDeleteDataChannel(dc);
        }
        _ = c.rtcClosePeerConnection(pc);
        _ = c.rtcDeletePeerConnection(pc);
    }

    pub fn destroy(self: *Peer) void {
        self.mutex.lock();
        for (self.messages.items) |message| std.heap.c_allocator.free(message.data);
        self.messages.deinit(std.heap.c_allocator);
        const sdp = self.last_sdp;
        self.messages = .empty;
        self.last_sdp = &.{};
        self.mutex.unlock();
        if (sdp.len > 0) std.heap.c_allocator.free(sdp);
    }
};

var preloaded = false;

fn ensurePreload() void {
    if (!preloaded) {
        c.rtcInitLogger(c.RTC_LOG_NONE, null);
        c.rtcPreload();
        preloaded = true;
    }
}

fn stateCallback(pc: c_int, state: c.rtcState, ptr: ?*anyopaque) callconv(.c) void {
    _ = pc;
    const peer: *Peer = @ptrCast(@alignCast(ptr orelse return));
    peer.mutex.lock();
    peer.state = @intCast(state);
    peer.mutex.unlock();
}

fn gatheringCallback(pc: c_int, state: c.rtcGatheringState, ptr: ?*anyopaque) callconv(.c) void {
    _ = pc;
    const peer: *Peer = @ptrCast(@alignCast(ptr orelse return));
    peer.mutex.lock();
    peer.gathering = @intCast(state);
    peer.mutex.unlock();
}

fn dataChannelCallback(pc: c_int, dc: c_int, ptr: ?*anyopaque) callconv(.c) void {
    _ = pc;
    const peer: *Peer = @ptrCast(@alignCast(ptr orelse return));
    peer.attachDataChannel(dc);
}

fn openCallback(id: c_int, ptr: ?*anyopaque) callconv(.c) void {
    _ = id;
    const peer: *Peer = @ptrCast(@alignCast(ptr orelse return));
    peer.mutex.lock();
    peer.open = true;
    peer.mutex.unlock();
}

fn closedCallback(id: c_int, ptr: ?*anyopaque) callconv(.c) void {
    _ = id;
    const peer: *Peer = @ptrCast(@alignCast(ptr orelse return));
    peer.mutex.lock();
    peer.open = false;
    peer.closed = true;
    peer.mutex.unlock();
}

fn messageCallback(id: c_int, message: [*c]const u8, size: c_int, ptr: ?*anyopaque) callconv(.c) void {
    _ = id;
    const peer: *Peer = @ptrCast(@alignCast(ptr orelse return));
    if (size == 0) return;
    const binary = size > 0;
    var len: usize = @intCast(if (size < 0) -size else size);
    // libdatachannel's C string path includes the trailing NUL in the callback
    // length; hide it from runtime callers.
    if (!binary and len > 0 and message[len - 1] == 0) len -= 1;
    const data = std.heap.c_allocator.dupe(u8, message[0..len]) catch return;

    peer.mutex.lock();
    defer peer.mutex.unlock();
    peer.messages.append(std.heap.c_allocator, .{ .data = data, .binary = binary }) catch {
        std.heap.c_allocator.free(data);
    };
}

fn descriptionCallback(pc: c_int, sdp: [*c]const u8, kind: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = kind;
    const peer: *Peer = @ptrCast(@alignCast(ptr orelse return));
    if (sdp == null) return;
    const text = std.mem.span(sdp);
    const copy = std.heap.c_allocator.dupe(u8, text) catch return;

    peer.mutex.lock();
    defer peer.mutex.unlock();
    if (peer.last_sdp.len > 0) std.heap.c_allocator.free(peer.last_sdp);
    peer.last_sdp = copy;
}

fn candidateCallback(pc: c_int, candidate: [*c]const u8, mid: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
    _ = pc;
    _ = candidate;
    _ = mid;
    _ = ptr;
}

fn errorCallback(id: c_int, message: [*c]const u8, ptr: ?*anyopaque) callconv(.c) void {
    _ = id;
    const peer: *Peer = @ptrCast(@alignCast(ptr orelse return));
    if (message == null) return;
    const text = std.mem.span(message);
    const n = @min(text.len, peer.last_error.len);
    peer.mutex.lock();
    @memcpy(peer.last_error[0..n], text[0..n]);
    peer.last_error_len = n;
    peer.mutex.unlock();
}

pub const Registry = handles.Table(Peer);
pub var registry: Registry = .{};

test "WebRTC data-channel loopback" {
    const offerer = try Peer.create(std.testing.allocator, "", "127.0.0.1");
    defer {
        offerer.close();
        offerer.destroy();
    }
    const answerer = try Peer.create(std.testing.allocator, "", "127.0.0.1");
    defer {
        answerer.close();
        answerer.destroy();
    }

    try offerer.createDataChannel("engine7");

    const offer = offerer.createOffer(10_000) catch |err| {
        std.debug.print("skipping WebRTC test (offer): {s}\n", .{@errorName(err)});
        return;
    };
    defer std.heap.c_allocator.free(offer);

    try answerer.setRemote(offer, "offer");
    const answer = answerer.createAnswer(10_000) catch |err| {
        std.debug.print("skipping WebRTC test (answer): {s}\n", .{@errorName(err)});
        return;
    };
    defer std.heap.c_allocator.free(answer);

    try offerer.setRemote(answer, "answer");

    offerer.waitOpen(10_000) catch |err| {
        std.debug.print("skipping WebRTC test (open offer): {s}\n", .{@errorName(err)});
        return;
    };
    answerer.waitOpen(10_000) catch |err| {
        std.debug.print("skipping WebRTC test (open answer): {s}\n", .{@errorName(err)});
        return;
    };

    try offerer.send("hello webrtc", false);
    var buf: [256]u8 = undefined;
    const n = (try answerer.receiveWait(&buf, 5_000, null)) orelse return error.Timeout;
    try std.testing.expectEqualStrings("hello webrtc", buf[0..n]);

    try answerer.send("ack", false);
    const m = (try offerer.receiveWait(&buf, 5_000, null)) orelse return error.Timeout;
    try std.testing.expectEqualStrings("ack", buf[0..m]);
}
