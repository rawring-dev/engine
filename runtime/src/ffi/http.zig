//! HTTP and HTTPS through libcurl's easy interface [libcurl], following the
//! semantics of RFC 9110 [rfc9110].
//!
//! TLS verification uses libcurl's default trust store; callers that need a
//! private CA can install one in the process environment/trust store.  Requests
//! are synchronous and support arbitrary methods, newline-separated headers,
//! request bodies, redirects, and millisecond timeouts.

const std = @import("std");
const abi = @import("abi.zig");
const io_mod = @import("io.zig");
const net = @import("net.zig");

pub const c = @cImport({
    @cInclude("curl/curl.h");
});

pub const Error = error{
    InitFailed,
    RequestFailed,
    OutOfMemory,
    InvalidArgument,
};

pub const Response = struct {
    status: u32,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

var init_state = std.atomic.Value(u8).init(0);

fn ensureGlobal() Error!void {
    if (init_state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
        if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != c.CURLE_OK) {
            init_state.store(3, .release);
            abi.setError("curl_global_init failed");
            return error.InitFailed;
        }
        init_state.store(2, .release);
    } else {
        while (true) {
            switch (init_state.load(.acquire)) {
                2 => break,
                3 => {
                    abi.setError("curl_global_init failed");
                    return error.InitFailed;
                },
                else => std.atomic.spinLoopHint(),
            }
        }
    }
}

const WriteState = struct {
    list: std.ArrayList(u8) = .empty,
    failed: bool = false,
};

fn writeCallback(ptr: [*c]u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const state: *WriteState = @ptrCast(@alignCast(userdata.?));
    const total = size *| nmemb;
    if (total == 0) return 0;
    state.list.appendSlice(std.heap.c_allocator, ptr[0..total]) catch {
        state.failed = true;
        return 0;
    };
    return total;
}

/// Perform one HTTP(S) request.  `headers` is a newline-separated list such as
/// `"Accept: application/json\nX-Trace: 1"`; pass an empty slice for none.
pub fn request(
    allocator: std.mem.Allocator,
    method: []const u8,
    url: []const u8,
    headers: []const u8,
    body: ?[]const u8,
    timeout_ms: u32,
) Error!Response {
    try ensureGlobal();

    const url_z = allocator.dupeZ(u8, url) catch return error.OutOfMemory;
    defer allocator.free(url_z);
    const method_z = allocator.dupeZ(u8, method) catch return error.OutOfMemory;
    defer allocator.free(method_z);
    const user_agent_z = allocator.dupeZ(u8, "engine7-runtime/1") catch return error.OutOfMemory;
    defer allocator.free(user_agent_z);

    const handle = c.curl_easy_init() orelse {
        abi.setError("curl_easy_init failed");
        return error.InitFailed;
    };
    defer c.curl_easy_cleanup(handle);

    var header_list: ?*c.curl_slist = null;
    defer if (header_list) |list| c.curl_slist_free_all(list);
    {
        var it = std.mem.splitScalar(u8, headers, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r\t");
            if (line.len == 0) continue;
            const line_z = allocator.dupeZ(u8, line) catch return error.OutOfMemory;
            defer allocator.free(line_z);
            header_list = c.curl_slist_append(header_list, line_z.ptr) orelse return error.OutOfMemory;
        }
    }

    var state = WriteState{};
    defer state.list.deinit(std.heap.c_allocator);

    try tryOption(handle, c.CURLOPT_URL, url_z.ptr);
    try tryOption(handle, c.CURLOPT_CUSTOMREQUEST, method_z.ptr);
    try tryOption(handle, c.CURLOPT_USERAGENT, user_agent_z.ptr);
    try tryOption(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    try tryOption(handle, c.CURLOPT_MAXREDIRS, @as(c_long, 10));
    try tryOption(handle, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
    try tryOption(handle, c.CURLOPT_ACCEPT_ENCODING, "");
    try tryOption(handle, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, @intCast(@min(timeout_ms, std.math.maxInt(c_long)))));
    try tryOption(handle, c.CURLOPT_TIMEOUT_MS, @as(c_long, @intCast(@min(timeout_ms, std.math.maxInt(c_long)))));
    try tryOption(handle, c.CURLOPT_WRITEFUNCTION, @as(?*const anyopaque, @ptrCast(&writeCallback)));
    try tryOption(handle, c.CURLOPT_WRITEDATA, @as(?*anyopaque, @ptrCast(&state)));
    if (header_list) |list| try tryOption(handle, c.CURLOPT_HTTPHEADER, list);
    if (body) |bytes| {
        try tryOption(handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(bytes.len)));
        try tryOption(handle, c.CURLOPT_POSTFIELDS, bytes.ptr);
    }

    const result = c.curl_easy_perform(handle);
    if (result != c.CURLE_OK) {
        abi.setErrorFmt("curl: {s}", .{std.mem.span(c.curl_easy_strerror(result))});
        return error.RequestFailed;
    }
    if (state.failed) return error.OutOfMemory;

    var status: c_long = 0;
    _ = c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status);

    const bytes = state.list.toOwnedSlice(std.heap.c_allocator) catch return error.OutOfMemory;
    return .{
        .status = @intCast(@max(status, 0)),
        .body = bytes,
        .allocator = std.heap.c_allocator,
    };
}

fn tryOption(handle: *c.CURL, option: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(handle, option, value) != c.CURLE_OK) {
        abi.setErrorFmt("curl_easy_setopt({d}) failed", .{option});
        return error.InvalidArgument;
    }
}

test "HTTP GET against an in-process server" {
    var listener = try net.Listener.listen("127.0.0.1", 0, 8);
    defer listener.close();

    const ServerCtx = struct {
        listener: *net.Listener,
        port: u16,
        event: *std.Io.Event,

        fn run(ctx: @This()) void {
            ctx.event.set(io_mod.io());
            var conn = ctx.listener.accept(0) catch return;
            defer conn.close();
            var buf: [4096]u8 = undefined;
            _ = conn.receive(&buf, 2_000) catch return;
            _ = conn.send("HTTP/1.1 200 OK\r\nContent-Length: 11\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nhello world") catch return;
        }
    };

    var ready: std.Io.Event = .unset;
    const thread = try std.Thread.spawn(.{}, ServerCtx.run, .{ServerCtx{
        .listener = &listener,
        .port = listener.port,
        .event = &ready,
    }});
    ready.waitUncancelable(io_mod.io());

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{listener.port});
    var response = try request(std.testing.allocator, "GET", url, "", null, 5_000);
    defer response.deinit();

    try std.testing.expectEqual(@as(u32, 200), response.status);
    try std.testing.expectEqualStrings("hello world", response.body);
    thread.join();
}

test "HTTP POST sends a body" {
    var listener = try net.Listener.listen("127.0.0.1", 0, 8);
    defer listener.close();

    const ServerCtx = struct {
        listener: *net.Listener,
        event: *std.Io.Event,

        fn run(ctx: @This()) void {
            ctx.event.set(io_mod.io());
            var conn = ctx.listener.accept(0) catch return;
            defer conn.close();
            var buf: [4096]u8 = undefined;
            _ = conn.receive(&buf, 2_000) catch return;
            _ = conn.send("HTTP/1.1 201 Created\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok") catch return;
        }
    };

    var ready: std.Io.Event = .unset;
    const thread = try std.Thread.spawn(.{}, ServerCtx.run, .{ServerCtx{
        .listener = &listener,
        .event = &ready,
    }});
    ready.waitUncancelable(io_mod.io());

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/submit", .{listener.port});
    var response = try request(std.testing.allocator, "POST", url, "Content-Type: text/plain", "payload", 5_000);
    defer response.deinit();
    try std.testing.expectEqual(@as(u32, 201), response.status);
    try std.testing.expectEqualStrings("ok", response.body);
    thread.join();
}
