//! Keep the world and editor main alive while future task calls enter new code.
//! Publication occurs at the editor's frame boundary. Older generations remain
//! resident for active tasks and function values; only session shutdown frees them.
const std = @import("std");
const compiler = @import("compiler");
const orc = @import("orc.zig");
const task = @import("task.zig");
const dispatch = @import("code_dispatch.zig");
const ast = compiler.ast;
const Address = *const fn () callconv(.c) i64;
const Entry = struct { address: usize, params: u16 };
const Signatures = std.StringHashMapUnmanaged([]const u8);

const Manifest = struct {
    layouts: Signatures = .empty,
    functions: Signatures = .empty,

    fn save(map: *Signatures, allocator: std.mem.Allocator, key: []const u8, value: anytype) !void {
        try map.put(allocator, key, try std.json.Stringify.valueAlloc(allocator, value, .{}));
    }

    fn collect(self: *Manifest, allocator: std.mem.Allocator, items: []*ast.Item, prefix: []const u8) !void {
        var use_index: usize = 0;
        for (items) |item| {
            const name: []const u8 = switch (item.kind) {
                .struct_decl => |d| d.name,
                .enum_decl => |d| d.name,
                .table_decl => |d| d.name,
                .trigger_decl => |d| d.name,
                .plugin_decl => |d| d.name,
                .function => |d| d.name,
                .sys => |d| d.name,
                .mod => |d| d.name,
                else => "",
            };
            const key = try std.fmt.allocPrint(allocator, "{s}::{s}", .{ prefix, name });
            switch (item.kind) {
                .mod => |d| if (d.items) |inner| {
                    try self.collect(allocator, inner, key);
                },
                .struct_decl => |d| try save(&self.layouts, allocator, key, .{ .kind = "struct", .fields = d.fields, .generics = d.generics }),
                .enum_decl => |d| try save(&self.layouts, allocator, key, .{ .kind = "enum", .variants = d.variants, .generics = d.generics }),
                .table_decl => |d| try save(&self.layouts, allocator, key, .{ .kind = "table", .fields = d.fields, .generics = d.generics, .ellipsis = d.has_ellipsis }),
                .trigger_decl => |d| try save(&self.layouts, allocator, key, .{ .kind = "trigger", .fields = d.fields, .generics = d.generics }),
                .plugin_decl => |d| {
                    try save(&self.layouts, allocator, key, .{ .kind = "plugin", .generics = d.generics });
                    try self.collect(allocator, d.items, key);
                },
                .function => |d| try self.function(allocator, key, d),
                .sys => |d| try save(&self.functions, allocator, key, .{ .kind = "sys", .generics = d.generics, .params = d.params }),
                .use => |d| {
                    const import_key = try std.fmt.allocPrint(allocator, "{s}::$use{d}", .{ prefix, use_index });
                    use_index += 1;
                    try save(&self.layouts, allocator, import_key, d.tree);
                },
                .trait_decl => |d| {
                    const trait_key = try std.fmt.allocPrint(allocator, "{s}::$trait:{s}", .{ prefix, d.name });
                    try save(&self.layouts, allocator, trait_key, d);
                },
                .impl => |d| {
                    const owner = try std.json.Stringify.valueAlloc(allocator, d.target, .{});
                    for (d.methods) |method| {
                        const method_key = try std.fmt.allocPrint(allocator, "{s}::$impl:{s}::{s}", .{ prefix, owner, method.function.name });
                        try self.function(allocator, method_key, method.function);
                    }
                },
                .binding, .uninitialized => {
                    // Module-level bindings may carry retained function values.
                    const binding_key = try std.fmt.allocPrint(allocator, "{s}::$binding:{s}", .{ prefix, switch (item.kind) {
                        .binding => |d| d.name,
                        .uninitialized => |d| d.name,
                        else => unreachable,
                    } });
                    try save(&self.layouts, allocator, binding_key, item.kind);
                },
            }
        }
    }

    fn function(self: *Manifest, allocator: std.mem.Allocator, key: []const u8, d: ast.FunctionDecl) !void {
        try save(&self.functions, allocator, key, .{ .kind = "function", .is_async = d.is_async, .generics = d.generics, .params = d.params, .result = d.result });
    }
};

const Generation = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    compiled: compiler.pipeline.CompileResult,
    jit: ?orc.Jit = null,
    manifest: Manifest = .{},
    entries: std.StringHashMapUnmanaged(Entry) = .empty,

    /// Always takes ownership of compiled, including on error.
    fn create(allocator: std.mem.Allocator, compiled: compiler.pipeline.CompileResult) !*Generation {
        const self = allocator.create(Generation) catch |err| {
            var owned = compiled;
            owned.deinit();
            return err;
        };
        self.* = .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator), .compiled = compiled };
        errdefer self.destroy();
        try self.manifest.collect(self.arena.allocator(), self.compiled.parsed.module.items, "");
        return self;
    }

    fn load(self: *Generation) !void {
        self.jit = try orc.Jit.init(self.allocator);
        try self.jit.?.addBytecode(&self.compiled.bytecode, "live-generation");
        // Materialize all functions before publication. Named addresses also
        // stabilize higher-order values stored in resources and components.
        var symbols = std.StringHashMapUnmanaged(void).empty;
        for (self.compiled.bytecode.functions) |function| {
            const symbol = try @import("bytecode_ir.zig").symbolNameAlloc(self.arena.allocator(), function.name);
            if (symbols.contains(symbol)) return error.AmbiguousSymbol;
            try symbols.put(self.arena.allocator(), symbol, {});
            const address = try self.jit.?.lookup(symbol);
            try self.entries.put(self.arena.allocator(), function.name, .{ .address = address, .params = function.params });
        }
        _ = try self.jit.?.get(Address, "main");
    }

    fn destroy(self: *Generation) void {
        if (self.jit) |*jit| jit.deinitCode();
        self.compiled.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    generations: std.ArrayList(*Generation) = .empty,
    candidate: ?*Generation = null,
    pending_redirects: dispatch.Table = .empty,
    diagnostic_buffer: [4096]u8 = undefined,
    diagnostic: []const u8 = "",

    /// Owns compiled on success and failure. One live program per task runtime.
    pub fn init(allocator: std.mem.Allocator, compiled: compiler.pipeline.CompileResult) !Program {
        var self = Program{ .allocator = allocator };
        const first = try Generation.create(allocator, compiled);
        errdefer first.destroy();
        try first.load();
        try self.generations.append(allocator, first);
        return self;
    }

    pub fn deinit(self: *Program) void {
        // Stop/join workers while all code and dispatch targets are resident.
        task.shutdownGlobal();
        dispatch.reset();
        self.discardCandidate();
        for (self.generations.items) |generation| generation.destroy();
        self.generations.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn main(self: *Program) !Address {
        return self.generations.items[0].jit.?.get(Address, "main");
    }

    pub fn reloads(self: *const Program) usize {
        return self.generations.items.len - 1;
    }

    fn discardCandidate(self: *Program) void {
        self.pending_redirects.deinit(self.allocator);
        self.pending_redirects = .empty;
        if (self.candidate) |candidate| candidate.destroy();
        self.candidate = null;
    }

    fn fail(self: *Program, comptime format: []const u8, args: anytype) bool {
        self.diagnostic = std.fmt.bufPrint(&self.diagnostic_buffer, format, args) catch "Live reload failed; current code retained";
        return false;
    }

    /// Compile, validate the resident ABI, link, and build the complete redirect
    /// table without changing a single live ECS value or dispatch target.
    pub fn stagePath(self: *Program, path: []const u8) bool {
        self.discardCandidate();
        const compiled = compiler.pipeline.compileProject(self.allocator, path, .{}) catch |err| {
            if (compiler.pipeline.loadProject(self.allocator, path)) |loaded| {
                var project = loaded;
                defer project.deinit();
                if (compiler.semantic.analyze(self.allocator, project.root_ast.module)) |analyzed| {
                    var analysis = analyzed;
                    defer analysis.deinit();
                    if (analysis.diagnostics.len > 0) {
                        const d = analysis.diagnostics[0];
                        return self.fail("{d}:{d}: {s}", .{ d.span.line, d.span.column, d.message });
                    }
                } else |_| {}
            } else |_| {}
            return self.fail("Compile failed: {s}; current editor/game kept running", .{@errorName(err)});
        };
        return self.stage(compiled);
    }

    /// Takes ownership of compiled, including on failure (also used by tests).
    pub fn stage(self: *Program, compiled: compiler.pipeline.CompileResult) bool {
        self.discardCandidate();
        const candidate = Generation.create(self.allocator, compiled) catch |err| return self.fail("Reload failed: {s}", .{@errorName(err)});
        self.candidate = candidate;
        const old = self.generations.items[self.generations.items.len - 1];
        // Retained pointers require stable names, field types/order, imports,
        // function signatures, ECS ids, and plugin ids. No implicit restart.
        if (old.manifest.layouts.count() != candidate.manifest.layouts.count()) {
            self.discardCandidate();
            return self.fail("Type/import layout changed; live reload requires a compatible ABI", .{});
        }
        if (!self.compatible(old, candidate)) {
            self.discardCandidate();
            return false;
        }
        candidate.load() catch |err| {
            self.discardCandidate();
            return self.fail("JIT/link failed: {s}; current code retained", .{@errorName(err)});
        };
        self.generations.ensureUnusedCapacity(self.allocator, 1) catch {
            self.discardCandidate();
            return self.fail("Reload allocation failed; current code retained", .{});
        };
        for (self.generations.items) |generation| {
            var entries = generation.entries.iterator();
            while (entries.next()) |entry| {
                const replacement = candidate.entries.get(entry.key_ptr.*) orelse {
                    self.discardCandidate();
                    return self.fail("Function entry removed; live reload requires stable signatures", .{});
                };
                if (replacement.params != entry.value_ptr.params) {
                    self.discardCandidate();
                    return self.fail("Function signature changed; current code retained", .{});
                }
                self.pending_redirects.put(self.allocator, entry.value_ptr.address, replacement.address) catch {
                    self.discardCandidate();
                    return self.fail("Reload allocation failed; current code retained", .{});
                };
            }
        }
        self.diagnostic = "Compiled and linked; ready to apply at the frame boundary";
        return true;
    }

    fn compatible(self: *Program, old: *const Generation, next: *const Generation) bool {
        var layouts = old.manifest.layouts.iterator();
        while (layouts.next()) |entry| {
            const signature = next.manifest.layouts.get(entry.key_ptr.*) orelse return self.fail("Type removed: {s}; current code retained", .{entry.key_ptr.*});
            if (!std.mem.eql(u8, signature, entry.value_ptr.*)) return self.fail("Type/import layout changed: {s}; restart explicitly to change ABI", .{entry.key_ptr.*});
        }
        var functions = old.manifest.functions.iterator();
        while (functions.next()) |entry| {
            const signature = next.manifest.functions.get(entry.key_ptr.*) orelse return self.fail("Function removed: {s}; current code retained", .{entry.key_ptr.*});
            if (!std.mem.eql(u8, signature, entry.value_ptr.*)) return self.fail("Function signature changed: {s}; current code retained", .{entry.key_ptr.*});
        }
        const a = old.compiled.analysis;
        const b = next.compiled.analysis;
        if (a.resources.len != b.resources.len or a.components.len != b.components.len or a.plugins.len != b.plugins.len) return self.fail("ECS registry changed; current world retained", .{});
        for (a.resources, b.resources) |left, right| {
            if (left.id != right.id or left.slots != right.slots or left.plugin_id != right.plugin_id or !std.mem.eql(u8, left.name, right.name)) return self.fail("Resource registry changed; current world retained", .{});
        }
        for (a.components, b.components) |left, right| {
            if (left.id != right.id or left.slots != right.slots or !std.mem.eql(u8, left.name, right.name)) return self.fail("Component registry changed; current world retained", .{});
        }
        for (a.plugins, b.plugins) |left, right| {
            if (left.id != right.id or !std.mem.eql(u8, left.name, right.name)) return self.fail("Plugin registry changed; current world retained", .{});
        }
        return true;
    }

    /// Frame-boundary transaction: all allocation/linking happened in stage.
    /// The current editor main/task keeps executing; Init/DeInit never run.
    pub fn commit(self: *Program) bool {
        const candidate = self.candidate orelse return self.fail("No staged code to apply", .{});
        dispatch.publish(self.allocator, &self.pending_redirects);
        self.generations.appendAssumeCapacity(candidate);
        self.candidate = null;
        self.diagnostic = "Code applied; editor and live world preserved";
        return true;
    }
};

const reload_fixture =
    \\@resource
    \\State <- struct
    \\    inits: i64
    \\    ticks: i64
    \\    callback: () -> i64
    \\@Components
    \\Counter <- struct
    \\    value: i64
    \\Components <- table
    \\    entity_id: usize,
    \\    ...
    \\Tick <- trigger
    \\increment <- () -> i64 = 1
    \\compute <- async (value: i64) -> i64 = value + increment()
    \\callback_value <- async () -> i64:
    \\    state := await query &State
    \\    ret state.callback()
    \\@trigger(Tick)
    \\update <- sys (state: res &mut State):
    \\    state.ticks = state.ticks + increment()
    \\main <- async () -> i64:
    \\    state := await query &mut State
    \\    state.inits = state.inits + 1
    \\    state.callback = increment
    \\    commands := await query &mut Commands
    \\    commands.add_row(Components, { Counter { value: 77 } })
    \\    disown commands
    \\    await Tick()
    \\    ret 0
;

fn compileTestGeneration(allocator: std.mem.Allocator, increment: []const u8, extra_system: bool) !compiler.pipeline.CompileResult {
    const replacement = try std.fmt.allocPrint(allocator, "{s}increment <- () -> i64 = {s}", .{ if (extra_system) "new_helper <- () -> i64 = 999\n" else "", increment });
    defer allocator.free(replacement);
    const changed = try std.mem.replaceOwned(u8, allocator, reload_fixture, "increment <- () -> i64 = 1", replacement);
    defer allocator.free(changed);
    const source = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{
        changed,
        if (extra_system)
            \\@trigger(Tick)
            \\extra <- sys (state: res &mut State):
            \\    state.ticks = state.ticks + 100
        else
            "",
    });
    defer allocator.free(source);
    return compiler.pipeline.compileProjectFromSources(allocator, source, &.{}, .{}) catch |err| {
        var parsed = switch (try compiler.parser.parse(allocator, source)) {
            .ast => |tree| tree,
            .diagnostic => return err,
        };
        defer parsed.deinit();
        var analysis = try compiler.semantic.analyze(allocator, parsed.module);
        defer analysis.deinit();
        for (analysis.diagnostics) |d| std.debug.print("reload fixture: {s}\n", .{d.message});
        return err;
    };
}

test "live tasks change code across generations without resetting resources or entities" {
    const allocator = std.testing.allocator;
    const ecs = @import("ecs.zig");
    const aggregate = @import("aggregate.zig");
    var program = try Program.init(allocator, try compileTestGeneration(allocator, "1", false));
    defer program.deinit();
    defer ecs.e7_ecs_reset();
    task.e7_task_set_inline(1);
    defer task.e7_task_set_inline(0);
    const main_ctor = try program.main();
    try std.testing.expectEqual(@as(i64, 0), task.e7_task_await(main_ctor()));
    const first = program.generations.items[0];
    const state_id = first.compiled.analysis.resource("State").?.id;
    const state = ecs.e7_ecs_resource(state_id);
    const counter_id = first.compiled.analysis.components[0].id;
    const counter = ecs.e7_ecs_component_get(0, counter_id);
    try std.testing.expect(state != 0 and counter != 0);
    const tick = try first.jit.?.get(Address, "Tick");
    const Compute = *const fn (i64) callconv(.c) i64;
    const compute = try first.jit.?.get(Compute, "compute");
    const callback_value = try first.jit.?.get(Address, "callback_value");
    try std.testing.expectEqual(@as(i64, 6), task.e7_task_await(compute(5)));
    try std.testing.expect(program.stage(try compileTestGeneration(allocator, "10", true)));
    // Staging has no effect on running code/world and never executes main.
    try std.testing.expectEqual(@as(i64, 6), task.e7_task_await(compute(5)));
    try std.testing.expectEqual(@as(i64, 1), aggregate.e7_load_i64(state));
    try std.testing.expect(program.commit());
    try std.testing.expectEqual(@as(i64, 15), task.e7_task_await(compute(5)));
    try std.testing.expectEqual(@as(i64, 10), task.e7_task_await(callback_value()));
    _ = task.e7_task_await(tick());
    try std.testing.expectEqual(@as(i64, 111), aggregate.e7_load_i64(state + 8));
    // A task created before the next publication keeps its original code.
    task.e7_task_set_inline(0);
    const suspended = compute(5);
    try std.testing.expect(program.stage(try compileTestGeneration(allocator, "20", true)));
    try std.testing.expect(program.commit());
    try std.testing.expectEqual(@as(i64, 15), task.e7_task_await(suspended));
    task.e7_task_set_inline(1);
    try std.testing.expectEqual(@as(i64, 25), task.e7_task_await(compute(5)));
    try std.testing.expectEqual(@as(i64, 20), task.e7_task_await(callback_value()));
    _ = task.e7_task_await(tick());
    try std.testing.expectEqual(@as(i64, 231), aggregate.e7_load_i64(state + 8));
    try std.testing.expectEqual(state, ecs.e7_ecs_resource(state_id));
    try std.testing.expectEqual(counter, ecs.e7_ecs_component_get(0, counter_id));
    try std.testing.expectEqual(@as(i64, 77), aggregate.e7_load_i64(counter));
    try std.testing.expectEqual(@as(i64, 1), ecs.e7_ecs_entity_count());
    try std.testing.expectEqual(@as(i64, 1), aggregate.e7_load_i64(state));
    try std.testing.expectEqual(@as(usize, 2), program.reloads());
}

test "layout, signature, compile and link failures leave current dispatch and world intact" {
    const allocator = std.testing.allocator;
    const ecs = @import("ecs.zig");
    var program = try Program.init(allocator, try compileTestGeneration(allocator, "1", false));
    defer program.deinit();
    defer ecs.e7_ecs_reset();
    task.e7_task_set_inline(1);
    defer task.e7_task_set_inline(0);
    const main_ctor = try program.main();
    _ = task.e7_task_await(main_ctor());
    const compute = try program.generations.items[0].jit.?.get(*const fn (i64) callconv(.c) i64, "compute");
    const state = ecs.e7_ecs_resource(program.generations.items[0].compiled.analysis.resource("State").?.id);
    const layout = try std.mem.replaceOwned(u8, allocator, reload_fixture, "    inits: i64\n    ticks: i64", "    ticks: i64\n    inits: i64");
    defer allocator.free(layout);
    try std.testing.expect(!program.stage(try compiler.pipeline.compile(allocator, layout, .{})));
    try std.testing.expect(std.mem.indexOf(u8, program.diagnostic, "layout") != null);
    const signature = try std.mem.replaceOwned(u8, allocator, reload_fixture, "compute <- async (value: i64) -> i64 = value + increment()", "compute <- async (value: f32) -> i64 = increment()");
    defer allocator.free(signature);
    try std.testing.expect(!program.stage(try compiler.pipeline.compile(allocator, signature, .{})));
    try std.testing.expect(std.mem.indexOf(u8, program.diagnostic, "signature") != null);
    var registry = try compileTestGeneration(allocator, "10", false);
    registry.analysis.resources[0].id += 100;
    try std.testing.expect(!program.stage(registry));
    try std.testing.expect(std.mem.indexOf(u8, program.diagnostic, "registry") != null);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.e7", .data = "main <- () -> i64 = missing()\n" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "bad.e7", allocator);
    defer allocator.free(path);
    try std.testing.expect(!program.stagePath(path));
    // A bytecode symbol collision is rejected during candidate loading, not
    // after publication. Candidate disposal must not stop the live scheduler.
    var broken = try compileTestGeneration(allocator, "10", false);
    const old_name = broken.bytecode.functions[1].name;
    broken.bytecode.functions[1].name = try allocator.dupe(u8, broken.bytecode.functions[0].name);
    allocator.free(old_name);
    try std.testing.expect(!program.stage(broken));
    try std.testing.expect(program.candidate == null);
    try std.testing.expectEqual(@as(i64, 6), task.e7_task_await(compute(5)));
    try std.testing.expectEqual(state, ecs.e7_ecs_resource(program.generations.items[0].compiled.analysis.resource("State").?.id));
    try std.testing.expectEqual(@as(usize, 0), program.reloads());
}
