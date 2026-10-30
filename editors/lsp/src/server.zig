//! LSP server: lifecycle, document store, request dispatch, and diagnostics.
//!
//! The implemented surface is the subset of LSP 3.17 [lsp] that the Neovim
//! client uses; wire format lives in `protocol.zig` and compiler analysis in
//! `analysis.zig`/`project.zig`.  This file owns:
//!
//!   * `initialize` / `initialized` / `shutdown` / `exit`
//!   * `textDocument/didOpen` / `didChange` (full sync) / `didClose` / `didSave`
//!   * `textDocument/publishDiagnostics` notifications
//!   * `textDocument/documentSymbol`, `hover`, `completion`, `definition`
//!   * JSON-RPC error responses for failed requests; unknown requests get a
//!     `null` result, unknown notifications are ignored
//!
//! Transport is a synchronous stdio loop: the server reads one message,
//! handles it, writes one response/notification set, and flushes stdout before
//! blocking on the next read.
//!
//! Every request handler builds its `result` payload (and every notification
//! its `params` payload) with the pure writers near the bottom of this file.
//! They take a `protocol.JsonOut` and touch neither stdio nor the document
//! store, so the wire shapes are unit tested without a transport.

const std = @import("std");
const protocol = @import("protocol");
const analysis = @import("analysis");
const project = @import("project");
const formatter = @import("formatter");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;

pub const name = "e7-lsp";
pub const version = "0.1.0";

/// JSON-RPC 2.0 "Internal error".
const jsonrpc_internal_error: i32 = -32603;

/// One open document.
///
/// `text` is the owned buffer that `analysis.Document` borrows, so `doc` must
/// be deinitialized *before* `text` is freed.  The URI is owned by the
/// `documents` map key; this struct intentionally does not alias it.
const DocumentEntry = struct {
    text: []u8,
    version: ?i64 = null,
    doc: analysis.Document,
};

pub const Server = struct {
    allocator: Allocator,
    stdout: *Io.Writer,
    documents: std.StringHashMap(DocumentEntry),
    /// Workspace project index built on `initialize`, when the client supplied
    /// a usable workspace root.  Lets semantic diagnostics resolve external
    /// `mod` files for multi-file e7 projects.
    project_index: ?project.Index = null,
    shutdown_requested: bool = false,

    pub fn init(allocator: Allocator, stdout: *Io.Writer) Server {
        return .{
            .allocator = allocator,
            .stdout = stdout,
            .documents = std.StringHashMap(DocumentEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        var iterator = self.documents.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.doc.deinit();
            self.allocator.free(entry.value_ptr.text);
            self.allocator.free(entry.key_ptr.*);
        }
        self.documents.deinit();
        if (self.project_index) |*index| index.deinit();
        self.* = undefined;
    }

    /// Runs the blocking read -> handle -> write loop until `exit`/EOF.
    pub fn run(self: *Server, stdin: *Io.Reader) !void {
        while (true) {
            const maybe_message = protocol.readMessage(stdin, self.allocator) catch |err| switch (err) {
                error.OutOfMemory => return err,
                // Framing/JSON errors: drop this message and keep serving.
                else => continue,
            };
            if (maybe_message == null) return; // clean EOF

            var parsed = maybe_message.?;
            defer parsed.deinit();

            try self.dispatch(parsed.value);
            try self.stdout.flush();
        }
    }

    // -----------------------------------------------------------------------
    // Dispatch
    // -----------------------------------------------------------------------

    /// Routes one parsed JSON-RPC message.  Request handlers get their id and
    /// params; notification handlers only params.  Handler failures become a
    /// `-32603` error response for requests and are ignored for notifications.
    fn dispatch(self: *Server, message: Value) !void {
        const object = switch (message) {
            .object => |object| object,
            else => return, // JSON-RPC requires an object; ignore anything else.
        };

        const method = switch (object.get("method") orelse return) {
            .string => |method| method,
            else => return,
        };
        const id = object.get("id");
        const params = object.get("params") orelse .null;

        // `exit` is a notification per spec, but honor it even if mislabelled
        // as a request so a client can always terminate the server.
        if (std.mem.eql(u8, method, "exit")) {
            std.process.exit(if (self.shutdown_requested) 0 else 1);
        }

        if (isNotification(method)) {
            self.handleNotification(method, params) catch {};
            return;
        }

        const request_id = id orelse return; // request without id: ignore.
        self.handleRequest(method, request_id, params) catch |err| {
            protocol.writeError(
                self.stdout,
                request_id,
                jsonrpc_internal_error,
                @errorName(err),
            ) catch {};
        };
    }

    /// True for methods that never receive a response.
    fn isNotification(method: []const u8) bool {
        return std.mem.eql(u8, method, "initialized") or
            std.mem.eql(u8, method, "textDocument/didOpen") or
            std.mem.eql(u8, method, "textDocument/didChange") or
            std.mem.eql(u8, method, "textDocument/didClose") or
            std.mem.eql(u8, method, "textDocument/didSave") or
            std.mem.eql(u8, method, "textDocument/didChangeConfiguration") or
            std.mem.eql(u8, method, "$/cancelRequest") or
            std.mem.eql(u8, method, "$/setTrace");
    }

    fn handleNotification(self: *Server, method: []const u8, params: Value) !void {
        if (std.mem.eql(u8, method, "initialized")) return; // no-op
        if (std.mem.eql(u8, method, "textDocument/didOpen")) return self.handleDidOpen(params);
        if (std.mem.eql(u8, method, "textDocument/didChange")) return self.handleDidChange(params);
        if (std.mem.eql(u8, method, "textDocument/didClose")) return self.handleDidClose(params);
        if (std.mem.eql(u8, method, "textDocument/didSave")) return self.handleDidSave(params);
        // Unknown (or intentionally ignored) notification: silent by design.
    }

    fn handleRequest(self: *Server, method: []const u8, id: Value, params: Value) !void {
        if (std.mem.eql(u8, method, "initialize")) return self.handleInitialize(id, params);
        if (std.mem.eql(u8, method, "shutdown")) {
            self.shutdown_requested = true;
            return self.respondNull(id);
        }
        if (std.mem.eql(u8, method, "textDocument/documentSymbol")) return self.handleDocumentSymbol(id, params);
        if (std.mem.eql(u8, method, "textDocument/hover")) return self.handleHover(id, params);
        if (std.mem.eql(u8, method, "textDocument/completion")) return self.handleCompletion(id, params);
        if (std.mem.eql(u8, method, "textDocument/definition")) return self.handleDefinition(id, params);
        if (std.mem.eql(u8, method, "textDocument/formatting")) return self.handleFormatting(id, params);

        // Unknown request: `result: null` keeps spec-compliant clients quiet.
        return self.respondNull(id);
    }

    fn respondNull(self: *Server, id: Value) !void {
        try protocol.writeResponse(self.stdout, id, "null");
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    fn handleInitialize(self: *Server, id: Value, params: Value) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        const out = protocol.JsonOut.init(&buffer, arena.allocator());

        try writeInitializeResult(out);
        try protocol.writeResponse(self.stdout, id, buffer.items);

        // Build the workspace project index after answering so the handshake
        // stays fast; the client sends `initialized` (and documents) only after
        // it received the response, so the index is ready before the first
        // didOpen on any practical client.
        self.initializeProjectIndex(params);
    }

    /// Builds the multi-file project index from the workspace URI/path the
    /// client supplied in `initialize`.  Failure is not fatal: the server then
    /// falls back to single-document analysis.
    fn initializeProjectIndex(self: *Server, params: Value) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const workspace_uri = initializeWorkspaceUri(params) orelse return;
        const root_path = protocol.uriToPath(arena.allocator(), workspace_uri) catch return;
        self.project_index = project.Index.init(self.allocator, root_path) catch null;
    }

    // -----------------------------------------------------------------------
    // Document synchronization (full sync: change = 1)
    // -----------------------------------------------------------------------

    fn handleDidOpen(self: *Server, params: Value) !void {
        const text_document = jsonGet(params, "textDocument") orelse return;
        const uri = jsonGetString(text_document, "uri") orelse return;
        const text = jsonGetString(text_document, "text") orelse "";
        const document_version = jsonGetInt(text_document, "version");

        try self.openDocument(uri, text, document_version);
        try self.publishDiagnostics(uri);
    }

    fn handleDidChange(self: *Server, params: Value) !void {
        const text_document = jsonGet(params, "textDocument") orelse return;
        const uri = jsonGetString(text_document, "uri") orelse return;
        const document_version = jsonGetInt(text_document, "version");

        const changes = switch (jsonGet(params, "contentChanges") orelse return) {
            .array => |array| array,
            else => return,
        };
        if (changes.items.len == 0) return;
        // Full sync: the last change carries the whole new buffer.
        const text = jsonGetString(changes.items[changes.items.len - 1], "text") orelse return;

        if (!try self.changeDocument(uri, text, document_version)) return;
        try self.publishDiagnostics(uri);
    }

    fn handleDidClose(self: *Server, params: Value) !void {
        const text_document = jsonGet(params, "textDocument") orelse return;
        const uri = jsonGetString(text_document, "uri") orelse return;

        // Clear squiggles in the client before forgetting the document.
        try self.publishEmptyDiagnostics(uri);

        var removed = self.documents.fetchRemove(uri) orelse return;
        removed.value.doc.deinit();
        self.allocator.free(removed.value.text);
        self.allocator.free(removed.key);
    }

    fn handleDidSave(self: *Server, params: Value) !void {
        const text_document = jsonGet(params, "textDocument") orelse return;
        const uri = jsonGetString(text_document, "uri") orelse return;
        // `save.includeText` is false, so diagnostics come from the buffer we
        // already track; any text the client sends is picked up by the next
        // didChange instead.
        const entry = self.documents.getPtr(uri) orelse return;

        // A save may have changed dependency files too: refresh the project
        // index, then re-run the full (semantic) analysis for this buffer.
        if (self.project_index) |*index| {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            if (protocol.uriToPath(arena.allocator(), uri)) |path| {
                index.refresh(path);
            } else |_| {}
        }

        const document = try self.createDocument(uri, entry.text, .full);
        entry.doc.deinit();
        entry.doc = document;
        try self.publishDiagnostics(uri);
    }

    /// Builds an `analysis.Document` for `text` with the workspace project
    /// context.  `text` stays owned by the document store; the document only
    /// borrows it.
    fn createDocument(
        self: *Server,
        uri: []const u8,
        text: []const u8,
        phase: analysis.Phase,
    ) !analysis.Document {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const path = protocol.uriToPath(arena.allocator(), uri) catch null;
        return analysis.Document.initWithOptions(self.allocator, text, .{
            .path = path,
            .project = if (self.project_index) |*index| index else null,
            .phase = phase,
        });
    }

    /// Inserts or replaces one document.  Owns the URI and text copies it
    /// makes; the caller publishes diagnostics afterwards.
    fn openDocument(self: *Server, uri: []const u8, text: []const u8, document_version: ?i64) !void {
        const uri_copy = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(uri_copy);

        const text_copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_copy);

        var document = try self.createDocument(uri, text_copy, .full);
        errdefer document.deinit();

        const gop = try self.documents.getOrPut(uri_copy);
        if (gop.found_existing) {
            // Keep the existing map key stable; the new URI copy is unused.
            gop.value_ptr.doc.deinit();
            self.allocator.free(gop.value_ptr.text);
            self.allocator.free(uri_copy);
        } else {
            gop.key_ptr.* = uri_copy;
        }
        gop.value_ptr.* = .{
            .text = text_copy,
            .version = document_version,
            .doc = document,
        };
        // Ownership transferred to the map; nothing fallible remains.
    }

    /// Replaces an existing document's text.  Returns false when the document
    /// is not open (the client is out of sync; ignoring is the safe move).
    fn changeDocument(self: *Server, uri: []const u8, text: []const u8, document_version: ?i64) !bool {
        const entry = self.documents.getPtr(uri) orelse return false;

        const text_copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_copy);

        // Keystroke path: refresh lexer/parser diagnostics and the symbol
        // index, but defer multi-file semantic analysis to open/save.
        const document = try self.createDocument(uri, text_copy, .change);

        // Commit: no fallible work remains.
        entry.doc.deinit();
        self.allocator.free(entry.text);
        entry.text = text_copy;
        entry.doc = document;
        if (document_version) |new_version| entry.version = new_version;
        return true;
    }

    // -----------------------------------------------------------------------
    // Diagnostics
    // -----------------------------------------------------------------------

    fn publishDiagnostics(self: *Server, uri: []const u8) !void {
        const entry = self.documents.getPtr(uri) orelse return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        const out = protocol.JsonOut.init(&buffer, arena.allocator());

        try writeDiagnosticsParams(out, uri, entry.version, entry.doc.diagnostics);
        try protocol.writeNotification(
            self.stdout,
            "textDocument/publishDiagnostics",
            buffer.items,
        );
    }

    fn publishEmptyDiagnostics(self: *Server, uri: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        const out = protocol.JsonOut.init(&buffer, arena.allocator());

        try writeDiagnosticsParams(out, uri, null, &.{});
        try protocol.writeNotification(
            self.stdout,
            "textDocument/publishDiagnostics",
            buffer.items,
        );
    }

    // -----------------------------------------------------------------------
    // Language features
    // -----------------------------------------------------------------------

    /// `textDocument/formatting`: runs `e7-fmt` over the tracked buffer and
    /// returns one whole-document replacement when it changed.  The editor's
    /// format-on-save hook applies it before writing.
    fn handleFormatting(self: *Server, id: Value, params: Value) !void {
        const uri = documentUri(params) orelse return self.respondNull(id);
        const entry = self.documents.getPtr(uri) orelse return self.respondNull(id);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const path = protocol.uriToPath(arena.allocator(), uri) catch null;
        var result = formatter.format(self.allocator, entry.text, .{
            .path = path,
            .project_index = if (self.project_index) |*index| index else null,
        }) catch |err| {
            if (err == error.OutOfMemory) return err;
            return self.respondNull(id);
        };
        defer result.deinit();

        if (!result.changed) return protocol.writeResponse(self.stdout, id, "[]");

        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        const out = protocol.JsonOut.init(&buffer, arena.allocator());
        try out.writeAll("[{\"range\":");
        const end = protocol.offsetToPosition(entry.text, entry.text.len);
        try writeRange(out, .{
            .start = .{ .line = 0, .character = 0 },
            .end = end,
        });
        try out.writeAll(",\"newText\":");
        try out.writeString(result.text);
        try out.writeAll("}]");
        try protocol.writeResponse(self.stdout, id, buffer.items);
    }

    fn handleDocumentSymbol(self: *Server, id: Value, params: Value) !void {
        const uri = documentUri(params) orelse return self.respondNull(id);
        const entry = self.documents.getPtr(uri) orelse return self.respondNull(id);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        const out = protocol.JsonOut.init(&buffer, arena.allocator());

        try writeSymbolsArray(out, entry.doc.symbols);
        try protocol.writeResponse(self.stdout, id, buffer.items);
    }

    fn handleHover(self: *Server, id: Value, params: Value) !void {
        const uri = documentUri(params) orelse return self.respondNull(id);
        const position = cursorPosition(params) orelse return self.respondNull(id);
        const entry = self.documents.getPtr(uri) orelse return self.respondNull(id);

        const offset = protocol.positionToOffset(entry.text, position);
        const hover = entry.doc.hoverAt(offset) orelse return self.respondNull(id);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        const out = protocol.JsonOut.init(&buffer, arena.allocator());

        try writeHoverResult(out, hover);
        try protocol.writeResponse(self.stdout, id, buffer.items);
    }

    fn handleCompletion(self: *Server, id: Value, params: Value) !void {
        const uri = documentUri(params) orelse return self.respondNull(id);
        const position = cursorPosition(params) orelse return self.respondNull(id);
        const entry = self.documents.getPtr(uri) orelse return self.respondNull(id);

        const offset = protocol.positionToOffset(entry.text, position);
        const items = entry.doc.completionsAt(offset);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        const out = protocol.JsonOut.init(&buffer, arena.allocator());

        try writeCompletionList(out, items);
        try protocol.writeResponse(self.stdout, id, buffer.items);
    }

    fn handleDefinition(self: *Server, id: Value, params: Value) !void {
        const uri = documentUri(params) orelse return self.respondNull(id);
        const position = cursorPosition(params) orelse return self.respondNull(id);
        const entry = self.documents.getPtr(uri) orelse return self.respondNull(id);

        const offset = protocol.positionToOffset(entry.text, position);
        const location = entry.doc.definitionAt(offset) orelse return self.respondNull(id);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        const out = protocol.JsonOut.init(&buffer, arena.allocator());

        try writeDefinitionResult(out, uri, location.range);
        try protocol.writeResponse(self.stdout, id, buffer.items);
    }
};

// ===========================================================================
// JSON building helpers (pure: no transport, no document store)
// ===========================================================================

/// Writes the `initialize` result: capabilities + serverInfo.
fn writeInitializeResult(out: protocol.JsonOut) !void {
    try out.writeAll("{\"capabilities\":{");
    try out.writeAll("\"textDocumentSync\":{");
    try out.writeAll("\"openClose\":true,");
    try out.writeAll("\"change\":1,");
    try out.writeAll("\"save\":{\"includeText\":false}");
    try out.writeAll("},");
    try out.writeAll("\"documentSymbolProvider\":true,");
    try out.writeAll("\"hoverProvider\":true,");
    try out.writeAll("\"completionProvider\":{\"triggerCharacters\":[\".\"]},");
    try out.writeAll("\"definitionProvider\":true,");
    try out.writeAll("\"documentFormattingProvider\":true,");
    try out.writeAll("\"positionEncoding\":\"utf-16\"");
    try out.writeAll("},");
    try out.writeAll("\"serverInfo\":{\"name\":");
    try out.writeString(name);
    try out.writeAll(",\"version\":");
    try out.writeString(version);
    try out.writeAll("}}");
}

/// Writes one LSP `Position` object.
fn writePosition(out: protocol.JsonOut, position: protocol.Position) !void {
    try out.writeAll("{\"line\":");
    try out.writeInt(position.line);
    try out.writeAll(",\"character\":");
    try out.writeInt(position.character);
    try out.writeAll("}");
}

/// Writes one LSP `Range` object.
fn writeRange(out: protocol.JsonOut, range: protocol.Range) !void {
    try out.writeAll("{\"start\":");
    try writePosition(out, range.start);
    try out.writeAll(",\"end\":");
    try writePosition(out, range.end);
    try out.writeAll("}");
}

/// Writes `textDocument/publishDiagnostics` params.
fn writeDiagnosticsParams(
    out: protocol.JsonOut,
    uri: []const u8,
    document_version: ?i64,
    diagnostics: []const analysis.Diagnostic,
) !void {
    try out.writeAll("{\"uri\":");
    try out.writeString(uri);
    if (document_version) |known_version| {
        try out.writeAll(",\"version\":");
        try out.writeInt(known_version);
    }
    try out.writeAll(",\"diagnostics\":[");
    for (diagnostics, 0..) |diagnostic, index| {
        if (index > 0) try out.writeAll(",");
        try out.writeAll("{\"range\":");
        try writeRange(out, diagnostic.range);
        try out.writeAll(",\"severity\":");
        try out.writeInt(@intFromEnum(diagnostic.severity));
        try out.writeAll(",\"source\":\"e7\",\"message\":");
        try out.writeString(diagnostic.message);
        try out.writeAll("}");
    }
    try out.writeAll("]}");
}

/// Writes the hierarchical `DocumentSymbol[]` result.
///
/// Top-level symbols are those whose `parent` is null; a symbol's children are
/// the symbols whose `parent` is its index.  Symbols unreachable from a
/// top-level symbol (inconsistent parent indices) are omitted rather than
/// recursed into, so a malformed index can never loop forever.
fn writeSymbolsArray(out: protocol.JsonOut, symbols: []const analysis.Symbol) !void {
    try out.writeAll("[");
    var first = true;
    for (symbols, 0..) |symbol, index| {
        if (symbol.parent != null) continue;
        if (!first) try out.writeAll(",");
        first = false;
        try writeSymbol(out, symbols, index);
    }
    try out.writeAll("]");
}

/// Writes one `DocumentSymbol`, recursing into its children.
fn writeSymbol(out: protocol.JsonOut, symbols: []const analysis.Symbol, index: usize) !void {
    const symbol = symbols[index];
    const self_index = std.math.cast(u32, index) orelse std.math.maxInt(u32);

    try out.writeAll("{\"name\":");
    try out.writeString(symbol.name);
    try out.writeAll(",\"kind\":");
    try out.writeInt(@intFromEnum(symbol.kind));
    try out.writeAll(",\"range\":");
    try writeRange(out, symbol.range);
    try out.writeAll(",\"selectionRange\":");
    try writeRange(out, symbol.selection);
    if (symbol.detail) |detail| {
        try out.writeAll(",\"detail\":");
        try out.writeString(detail);
    }

    try out.writeAll(",\"children\":[");
    var first = true;
    for (symbols, 0..) |candidate, child_index| {
        if (child_index == index) continue;
        const parent = candidate.parent orelse continue;
        if (parent != self_index) continue;
        if (!first) try out.writeAll(",");
        first = false;
        try writeSymbol(out, symbols, child_index);
    }
    try out.writeAll("]}");
}

/// Writes the `textDocument/hover` result.
fn writeHoverResult(out: protocol.JsonOut, hover: analysis.Hover) !void {
    try out.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":");
    try out.writeString(hover.markdown);
    try out.writeAll("},\"range\":");
    try writeRange(out, hover.range);
    try out.writeAll("}");
}

/// Writes the `textDocument/completion` result (a `CompletionList`).
fn writeCompletionList(out: protocol.JsonOut, items: []const analysis.CompletionItem) !void {
    try out.writeAll("{\"isIncomplete\":false,\"items\":[");
    for (items, 0..) |item, index| {
        if (index > 0) try out.writeAll(",");
        try out.writeAll("{\"label\":");
        try out.writeString(item.label);
        try out.writeAll(",\"kind\":");
        try out.writeInt(@intFromEnum(item.kind));
        if (item.detail) |detail| {
            try out.writeAll(",\"detail\":");
            try out.writeString(detail);
        }
        try out.writeAll("}");
    }
    try out.writeAll("]}");
}

/// Writes the `textDocument/definition` result (a `Location`).
fn writeDefinitionResult(out: protocol.JsonOut, uri: []const u8, range: protocol.Range) !void {
    try out.writeAll("{\"uri\":");
    try out.writeString(uri);
    try out.writeAll(",\"range\":");
    try writeRange(out, range);
    try out.writeAll("}");
}

// ===========================================================================
// std.json helpers
// ===========================================================================

fn jsonGet(value: Value, key: []const u8) ?Value {
    return switch (value) {
        .object => |object| object.get(key),
        else => null,
    };
}

fn jsonGetString(value: Value, key: []const u8) ?[]const u8 {
    const found = jsonGet(value, key) orelse return null;
    return switch (found) {
        .string => |string| string,
        else => null,
    };
}

fn jsonGetInt(value: Value, key: []const u8) ?i64 {
    const found = jsonGet(value, key) orelse return null;
    return switch (found) {
        .integer => |integer| integer,
        else => null,
    };
}

fn jsonGetBool(value: Value, key: []const u8) ?bool {
    const found = jsonGet(value, key) orelse return null;
    return switch (found) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn jsonGetPosition(value: Value) ?protocol.Position {
    const line = jsonGetInt(value, "line") orelse return null;
    const character = jsonGetInt(value, "character") orelse return null;
    if (line < 0 or character < 0) return null;
    return .{
        .line = std.math.cast(u32, line) orelse return null,
        .character = std.math.cast(u32, character) orelse return null,
    };
}

fn documentUri(params: Value) ?[]const u8 {
    const text_document = jsonGet(params, "textDocument") orelse return null;
    return jsonGetString(text_document, "uri");
}

/// Workspace root URI from `initialize` params: current clients send
/// `rootUri`, some send `workspaceFolders`, and older clients send only
/// `rootPath` (a filesystem path, not a URI, so it is not supported here).
fn initializeWorkspaceUri(params: Value) ?[]const u8 {
    if (jsonGetString(params, "rootUri")) |uri| return uri;
    const folders = jsonGet(params, "workspaceFolders") orelse return null;
    switch (folders) {
        .array => |array| {
            if (array.items.len == 0) return null;
            return jsonGetString(array.items[0], "uri");
        },
        else => return null,
    }
}

fn cursorPosition(params: Value) ?protocol.Position {
    const position = jsonGet(params, "position") orelse return null;
    return jsonGetPosition(position);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Parses the JSON that `write` produced into a scratch-buffer arena.
fn parseJson(buffer: *const std.ArrayListUnmanaged(u8)) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, testing.allocator, buffer.items, .{
        .allocate = .alloc_always,
    });
}

test "document store owns and frees uri/text/document memory" {
    var output: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var server = Server.init(testing.allocator, &writer);
    defer server.deinit();

    const uri = "file:///tmp/server-store-test.tri";
    try server.openDocument(uri, "fn main() void {}\n", 1);
    try testing.expect(server.documents.contains(uri));
    try server.publishDiagnostics(uri);

    // Full-sync change replaces the buffer and bumps the version.
    try testing.expect(try server.changeDocument(uri, "fn main() void { let x = 1; }\n", 2));
    try server.publishDiagnostics(uri);

    // didClose clears diagnostics then drops the document.
    try server.publishEmptyDiagnostics(uri);
    var removed = server.documents.fetchRemove(uri) orelse return error.TestUnexpectedResult;
    removed.value.doc.deinit();
    testing.allocator.free(removed.value.text);
    testing.allocator.free(removed.key);
    try testing.expect(!server.documents.contains(uri));

    // Changing an unknown document is a no-op, not an error.
    try testing.expect(!try server.changeDocument("file:///tmp/never-opened.tri", "", null));

    // Re-opening the same URI exercises the replace path without leaking.
    try server.openDocument(uri, "fn a() void {}\n", 3);
    try server.openDocument(uri, "fn b() void {}\n", 4);
    try testing.expectEqual(@as(?i64, 4), server.documents.get(uri).?.version);
}

test "initialize result advertises the expected capabilities" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    const out = protocol.JsonOut.init(&buffer, arena.allocator());
    try writeInitializeResult(out);

    const parsed = try parseJson(&buffer);
    defer parsed.deinit();
    const root = parsed.value;

    const capabilities = jsonGet(root, "capabilities") orelse return error.TestUnexpectedResult;

    const sync = jsonGet(capabilities, "textDocumentSync") orelse return error.TestUnexpectedResult;
    try testing.expect(jsonGetBool(sync, "openClose") orelse false);
    try testing.expectEqual(@as(i64, 1), jsonGetInt(sync, "change") orelse -1);
    const save = jsonGet(sync, "save") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(false, jsonGetBool(save, "includeText") orelse true);

    try testing.expect(jsonGetBool(capabilities, "documentSymbolProvider") orelse false);
    try testing.expect(jsonGetBool(capabilities, "hoverProvider") orelse false);
    try testing.expect(jsonGetBool(capabilities, "definitionProvider") orelse false);
    try testing.expect(jsonGetBool(capabilities, "documentFormattingProvider") orelse false);

    const completion = jsonGet(capabilities, "completionProvider") orelse return error.TestUnexpectedResult;
    const trigger_characters = switch (jsonGet(completion, "triggerCharacters") orelse
        return error.TestUnexpectedResult) {
        .array => |array| array,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 1), trigger_characters.items.len);
    try testing.expectEqualStrings(".", trigger_characters.items[0].string);

    try testing.expectEqualStrings(
        "utf-16",
        jsonGetString(capabilities, "positionEncoding") orelse return error.TestUnexpectedResult,
    );

    const server_info = jsonGet(root, "serverInfo") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(
        "e7-lsp",
        jsonGetString(server_info, "name") orelse return error.TestUnexpectedResult,
    );
    try testing.expectEqualStrings(
        "0.1.0",
        jsonGetString(server_info, "version") orelse return error.TestUnexpectedResult,
    );
}

test "document symbols nest children under their parent" {
    const range: protocol.Range = .{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 3, .character = 0 },
    };
    const name_range: protocol.Range = .{
        .start = .{ .line = 0, .character = 3 },
        .end = .{ .line = 0, .character = 9 },
    };
    const child_range: protocol.Range = .{
        .start = .{ .line = 1, .character = 4 },
        .end = .{ .line = 2, .character = 0 },
    };
    const child_name_range: protocol.Range = .{
        .start = .{ .line = 1, .character = 7 },
        .end = .{ .line = 1, .character = 12 },
    };

    const symbols = [_]analysis.Symbol{
        .{
            .name = "engine",
            .kind = .struct_,
            .range = range,
            .selection = name_range,
            .detail = "struct engine",
        },
        .{
            .name = "run",
            .kind = .function,
            .range = child_range,
            .selection = child_name_range,
            .parent = 0,
        },
        .{
            .name = "update",
            .kind = .function,
            .range = child_range,
            .selection = child_name_range,
            .parent = 0,
        },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    const out = protocol.JsonOut.init(&buffer, arena.allocator());
    try writeSymbolsArray(out, &symbols);

    const parsed = try parseJson(&buffer);
    defer parsed.deinit();

    const top_level = switch (parsed.value) {
        .array => |array| array,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 1), top_level.items.len);

    const engine = top_level.items[0];
    try testing.expectEqualStrings("engine", jsonGetString(engine, "name") orelse "");
    try testing.expectEqual(@as(i64, 23), jsonGetInt(engine, "kind") orelse 0);
    try testing.expectEqualStrings("struct engine", jsonGetString(engine, "detail") orelse "");

    // The full declaration range and the identifier range are distinct.
    const declaration_range = jsonGet(engine, "range") orelse return error.TestUnexpectedResult;
    const declaration_start = jsonGet(declaration_range, "start") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 0), jsonGetInt(declaration_start, "line") orelse -1);
    const selection_range = jsonGet(engine, "selectionRange") orelse return error.TestUnexpectedResult;
    const selection_start = jsonGet(selection_range, "start") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i64, 3), jsonGetInt(selection_start, "character") orelse -1);

    const children = switch (jsonGet(engine, "children") orelse return error.TestUnexpectedResult) {
        .array => |array| array,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 2), children.items.len);
    try testing.expectEqualStrings("run", jsonGetString(children.items[0], "name") orelse "");
    try testing.expectEqualStrings("update", jsonGetString(children.items[1], "name") orelse "");
    const leaf_children = switch (jsonGet(children.items[0], "children") orelse
        return error.TestUnexpectedResult) {
        .array => |array| array,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 0), leaf_children.items.len);
}

test "publishDiagnostics params carry uri, version, severity and source" {
    const diagnostics = [_]analysis.Diagnostic{
        .{
            .range = .{
                .start = .{ .line = 2, .character = 4 },
                .end = .{ .line = 2, .character = 9 },
            },
            .severity = .warning,
            .message = "unused binding \"x\"",
        },
        .{
            .range = .{
                .start = .{ .line = 4, .character = 0 },
                .end = .{ .line = 4, .character = 1 },
            },
            .severity = .err,
            .message = "expected ';'",
        },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    const out = protocol.JsonOut.init(&buffer, arena.allocator());
    try writeDiagnosticsParams(out, "file:///tmp/example.tri", @as(?i64, 7), &diagnostics);

    const parsed = try parseJson(&buffer);
    defer parsed.deinit();

    const root = parsed.value;
    try testing.expectEqualStrings(
        "file:///tmp/example.tri",
        jsonGetString(root, "uri") orelse "",
    );
    try testing.expectEqual(@as(i64, 7), jsonGetInt(root, "version") orelse -1);

    const items = switch (jsonGet(root, "diagnostics") orelse return error.TestUnexpectedResult) {
        .array => |array| array,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 2), items.items.len);

    try testing.expectEqual(@as(i64, 2), jsonGetInt(items.items[0], "severity") orelse 0);
    try testing.expectEqualStrings("e7", jsonGetString(items.items[0], "source") orelse "");
    try testing.expectEqualStrings(
        "unused binding \"x\"",
        jsonGetString(items.items[0], "message") orelse "",
    );

    try testing.expectEqual(@as(i64, 1), jsonGetInt(items.items[1], "severity") orelse 0);
    try testing.expectEqualStrings("expected ';'", jsonGetString(items.items[1], "message") orelse "");
}

test "publishDiagnostics omits version when unknown and allows empty lists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    const out = protocol.JsonOut.init(&buffer, arena.allocator());
    try writeDiagnosticsParams(out, "file:///tmp/empty.e7", null, &.{});

    const parsed = try parseJson(&buffer);
    defer parsed.deinit();

    try testing.expect(jsonGet(parsed.value, "version") == null);
    const items = switch (jsonGet(parsed.value, "diagnostics") orelse
        return error.TestUnexpectedResult) {
        .array => |array| array,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 0), items.items.len);
}

test "hover and completion payloads use the declared LSP shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const hover = analysis.Hover{
        .markdown = "```e7\nfn run() void\n```",
        .range = .{
            .start = .{ .line = 1, .character = 3 },
            .end = .{ .line = 1, .character = 6 },
        },
    };
    var hover_buffer: std.ArrayListUnmanaged(u8) = .empty;
    const hover_out = protocol.JsonOut.init(&hover_buffer, arena.allocator());
    try writeHoverResult(hover_out, hover);

    const parsed_hover = try parseJson(&hover_buffer);
    defer parsed_hover.deinit();

    const contents = jsonGet(parsed_hover.value, "contents") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("markdown", jsonGetString(contents, "kind") orelse "");
    try testing.expectEqualStrings(
        "```e7\nfn run() void\n```",
        jsonGetString(contents, "value") orelse "",
    );

    const items = [_]analysis.CompletionItem{
        .{ .label = "run", .kind = .function, .detail = "fn run() void" },
        .{ .label = "engine", .kind = .struct_ },
    };
    var completion_buffer: std.ArrayListUnmanaged(u8) = .empty;
    const completion_out = protocol.JsonOut.init(&completion_buffer, arena.allocator());
    try writeCompletionList(completion_out, &items);

    const parsed_completion = try parseJson(&completion_buffer);
    defer parsed_completion.deinit();

    try testing.expectEqual(false, jsonGetBool(parsed_completion.value, "isIncomplete") orelse true);
    const completion_items = switch (jsonGet(parsed_completion.value, "items") orelse
        return error.TestUnexpectedResult) {
        .array => |array| array,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 2), completion_items.items.len);
    try testing.expectEqualStrings("run", jsonGetString(completion_items.items[0], "label") orelse "");
    try testing.expectEqual(@as(i64, 3), jsonGetInt(completion_items.items[0], "kind") orelse 0);
    try testing.expectEqualStrings(
        "fn run() void",
        jsonGetString(completion_items.items[0], "detail") orelse "",
    );
    try testing.expect(jsonGet(completion_items.items[1], "detail") == null);
}
