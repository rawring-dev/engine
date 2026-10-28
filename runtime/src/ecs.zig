//! Runtime ECS world: columnar component storage, resources, deferred
//! commands, plugins, and snapshot queries.
//!
//! The compiler lowers engine source to calls against this ABI; the engine
//! loop drives it once per trigger phase.  There is exactly one world per
//! process, guarded by a `pthread_mutex_t`.  Systems run on task threads, so
//! every entry point serializes on the world lock; a whole trigger phase can
//! therefore run single-threaded through the same ABI.
//!
//! ## Storage model
//!
//! * Values are `slots` 64-bit words.  The compiler knows each component /
//!   resource layout and passes the slot count at registration time.
//! * A **resource** is one heap block of `slots` words.  `e7_ecs_resource`
//!   returns its address; the block is stable until the resource is replaced
//!   by a flush or the world is reset.
//! * A **component column** is keyed by a numeric `type_id`.  A column stores
//!   the entity ids that own the component (kept sorted ascending) and one heap
//!   copy of the value per entity.  Presence is represented by membership in
//!   the column: removing a component deletes its entry, so there are no
//!   tombstones and re-adding the component re-inserts the entity.
//! * **Entities** are zero-based row indices assigned at flush time.  The id
//!   space is monotonic (`0 .. e7_ecs_entity_count() - 1`), but an entity can be
//!   despawned: its alive flag is cleared, every component entry is removed, and
//!   `e7_ecs_entity_alive` reports `0`.  Despawned ids are not reused.  A query's
//!   *row handle* is `entity_id + 1`, reserving `0` as the "end of iteration".
//!
//! ## Commands
//!
//! Mutations are deferred through a single shared command buffer:
//! `e7_ecs_commands()` returns its handle (always `1`).  Queuing a resource or
//! row component **copies the value immediately**, so caller locals may die
//! before the flush.  Nothing is visible to readers until
//! `e7_ecs_commands_flush`.  A flush bumps the world generation, which
//! invalidates every query handle created before it; callers regenerate their
//! queries after a flush.  Flushing pre-reserves all column/map capacity, so
//! an out-of-memory failure leaves the pending commands untouched for retry.
//!
//! ## Ownership and lifetime
//!
//! All storage is allocated with the C allocator and freed by
//! `e7_ecs_reset` (or when a query/row handle is retired).  Component and
//! resource pointers returned to JITed code remain valid until the next reset;
//! they are never moved by a flush.  Query handles are freed automatically when
//! iteration reaches the end, when a stale handle is observed after a flush, or
//! by `e7_ecs_reset`.  Handles are monotonically increasing ids and are
//! validated on every call.
//!
//! ## Status codes
//!
//! `i32`-returning entry points use `0` for success and the same small codes as
//! the rest of the runtime ABI: `1` invalid argument, `2` out of memory,
//! `3` not found (unregistered component/resource id).
//!
//! ## Exported ABI
//!
//! ```text
//! e7_ecs_reset()                                         -> void
//! e7_ecs_register_resource(id, slots)                    -> i32
//! e7_ecs_register_component(id, slots)                   -> i32
//! e7_ecs_resource(id)                                    -> i64  (ptr or 0)
//! e7_ecs_has_resource(id)                                -> i64  (1/0)
//! e7_ecs_entity_count()                                  -> i64
//! e7_ecs_component_get(entity, type_id)                  -> i64  (ptr or 0)
//! e7_ecs_commands()                                      -> i64  (shared handle)
//! e7_ecs_commands_insert_resource(cmd, type_id, value)   -> i32
//! e7_ecs_commands_row_begin(cmd)                         -> i64  (row handle)
//! e7_ecs_commands_row_add(row, type_id, value)           -> i32
//! e7_ecs_commands_row_finish(row)                        -> i32
//! e7_ecs_commands_add_plugin(cmd, plugin_id)             -> i32
//! e7_ecs_commands_flush(cmd)                             -> i32
//! e7_ecs_plugin_active(plugin_id)                        -> i64  (1/0)
//! e7_ecs_query_begin(count, ids_ptr, mut_ptr, has_id)    -> i64  (query or 0)
//! e7_ecs_query_next(query)                               -> i64  (1+entity or 0)
//! e7_ecs_query_component(query, type_index)              -> i64  (ptr or 0)
//! ```
//!
//! `ids_ptr` points at `count` i64 component type ids; `mut_ptr` points at
//! `count` i64 mutation flags (`0` shared, non-zero mutable).  `has_id < 0`
//! means "no presence filter".  `count == 0` with a `has_id` queries every
//! entity owning that component; with no `has_id` it queries every entity.

const std = @import("std");
const Symbol = @import("intrinsics.zig").Symbol;

const c = @cImport({
    @cInclude("pthread.h");
});

const allocator = std.heap.c_allocator;

pub const status_ok: i32 = 0;
pub const status_invalid_argument: i32 = 1;
pub const status_out_of_memory: i32 = 2;
pub const status_not_found: i32 = 3;

/// The one shared deferred command buffer.
const command_handle: i64 = 1;

// ---------------------------------------------------------------------------
// Allocations
// ---------------------------------------------------------------------------

/// Number of heap blocks currently owned by the world (value blocks, row
/// structs, query structs).  Used by tests to prove `reset` releases
/// everything it acquired.
var live_blocks: usize = 0;

fn rawAlloc(size: usize) ?*anyopaque {
    const memory = std.c.malloc(size) orelse return null;
    live_blocks += 1;
    return memory;
}

fn rawFree(memory: ?*anyopaque) void {
    const ptr = memory orelse return;
    std.c.free(ptr);
    if (live_blocks > 0) live_blocks -= 1;
}

fn allocValueSlots(count: usize) ?[*]i64 {
    if (count == 0) return null;
    const bytes = std.math.mul(usize, count, @sizeOf(i64)) catch return null;
    const memory = rawAlloc(bytes) orelse return null;
    const bytes_ptr: [*]u8 = @ptrCast(memory);
    @memset(bytes_ptr[0..bytes], 0);
    return @ptrCast(@alignCast(memory));
}

fn freeValueSlots(ptr: ?[*]i64) void {
    rawFree(@ptrCast(ptr));
}

/// Copy a component/resource value.  Zero-slot values (marker components) still
/// receive one presence word so every returned pointer is distinguishable from
/// the "absent" `0` result.
fn copyValueBlock(value_ptr: i64, slot_count: usize) ?[*]i64 {
    const destination = allocValueSlots(@max(slot_count, 1)) orelse return null;
    if (value_ptr != 0 and slot_count > 0) {
        const source: [*]const i64 = @ptrFromInt(@as(usize, @intCast(value_ptr)));
        @memcpy(destination[0..slot_count], source[0..slot_count]);
    }
    return destination;
}

fn allocI64Slice(count: usize) ?[]const i64 {
    if (count == 0) return &.{};
    const ptr = allocValueSlots(count) orelse return null;
    return ptr[0..count];
}

fn freeI64Slice(slice: []const i64) void {
    if (slice.len == 0) return;
    freeValueSlots(@constCast(slice.ptr));
}

fn createRow() ?*Row {
    const memory = rawAlloc(@sizeOf(Row)) orelse return null;
    const row: *Row = @ptrCast(@alignCast(memory));
    row.* = .{};
    return row;
}

fn destroyRow(row: *Row) void {
    rawFree(row);
}

fn createQuery() ?*Query {
    const memory = rawAlloc(@sizeOf(Query)) orelse return null;
    const query: *Query = @ptrCast(@alignCast(memory));
    query.* = .{};
    return query;
}

fn destroyQuery(query: *Query) void {
    if (query.rows) |rows| freeValueSlots(rows);
    freeI64Slice(query.type_ids);
    freeI64Slice(query.mut_flags);
    rawFree(query);
}

// ---------------------------------------------------------------------------
// World data
// ---------------------------------------------------------------------------

const ComponentEntry = struct {
    type_id: i64,
    ptr: [*]i64,
};

const Column = struct {
    slots: usize,
    /// Entity ids owning this component, in ascending append order.
    entity_ids: std.ArrayListUnmanaged(i64) = .empty,
    /// Parallel heap copies of the component value, one per entity id.
    values: std.ArrayListUnmanaged([*]i64) = .empty,
};

const Resource = struct {
    slots: usize,
    ptr: [*]i64,
};

const Row = struct {
    entries: std.ArrayListUnmanaged(ComponentEntry) = .empty,
};

const PendingRow = struct {
    entries: std.ArrayListUnmanaged(ComponentEntry) = .empty,
};

const PendingResource = struct {
    id: i64,
    ptr: [*]i64,
};

const PendingComponentAdd = struct {
    entity: i64,
    type_id: i64,
    ptr: [*]i64,
};

const PendingComponentRemove = struct {
    entity: i64,
    type_id: i64,
};

/// A materialized query snapshot.  Entity ids are captured at `begin`; component
/// pointers are looked up live.  `generation` identifies the world structure the
/// snapshot was taken against.
const Query = struct {
    rows: ?[*]i64 = null,
    row_count: usize = 0,
    type_ids: []const i64 = &.{},
    mut_flags: []const i64 = &.{},
    has_id: i64 = -1,
    generation: u64 = 0,
    cursor: usize = 0,
    current_entity: i64 = -1,
};

const World = struct {
    resources: std.AutoHashMapUnmanaged(i64, Resource) = .empty,
    columns: std.AutoHashMapUnmanaged(i64, Column) = .empty,
    plugins: std.AutoHashMapUnmanaged(i64, void) = .empty,
    /// Open rows (`row_begin` without `row_finish` yet), keyed by row handle.
    rows: std.AutoHashMapUnmanaged(i64, *Row) = .empty,
    /// Live query handles, keyed by query handle.
    queries: std.AutoHashMapUnmanaged(i64, *Query) = .empty,

    pending_resources: std.ArrayListUnmanaged(PendingResource) = .empty,
    pending_rows: std.ArrayListUnmanaged(PendingRow) = .empty,
    pending_component_adds: std.ArrayListUnmanaged(PendingComponentAdd) = .empty,
    pending_component_removes: std.ArrayListUnmanaged(PendingComponentRemove) = .empty,
    pending_despawns: std.ArrayListUnmanaged(i64) = .empty,
    pending_plugins: std.ArrayListUnmanaged(i64) = .empty,

    /// One alive flag per allocated entity id (high-water `entity_count`).
    alive: std.ArrayListUnmanaged(bool) = .empty,
    entity_count: i64 = 0,
    /// Incremented by every successful flush.  Queries from an older
    /// generation are stale and are discarded on their next use.
    generation: u64 = 0,
};

var world: World = .{};

/// Row/query handles are unique for the lifetime of the process and are not
/// reused across `reset`, so a stale handle can never alias a new object.
var next_row_handle: i64 = 1;
var next_query_handle: i64 = 1;

var world_mutex: c.pthread_mutex_t = undefined;
var world_state = std.atomic.Value(u8).init(0); // 0 = uninit, 1 = initing, 2 = ready

fn ensureWorld() void {
    if (world_state.load(.acquire) == 2) return;
    if (world_state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
        _ = c.pthread_mutex_init(&world_mutex, null);
        world_state.store(2, .release);
        return;
    }
    while (world_state.load(.acquire) != 2) std.atomic.spinLoopHint();
}

fn beginCall() void {
    ensureWorld();
    _ = c.pthread_mutex_lock(&world_mutex);
}

fn endCall() void {
    _ = c.pthread_mutex_unlock(&world_mutex);
}

fn nextHandle(counter: *i64) ?i64 {
    if (counter.* <= 0 or counter.* == std.math.maxInt(i64)) return null;
    const handle = counter.*;
    counter.* += 1;
    return handle;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn columnIndexForEntity(column: *const Column, entity: i64) ?usize {
    // Columns are append-only, so entity ids are sorted ascending.
    var low: usize = 0;
    var high: usize = column.entity_ids.items.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const candidate = column.entity_ids.items[middle];
        if (candidate < entity) {
            low = middle + 1;
        } else if (candidate > entity) {
            high = middle;
        } else {
            return middle;
        }
    }
    return null;
}

fn entityHasColumn(type_id: i64, entity: i64) bool {
    const column = world.columns.getPtr(type_id) orelse return false;
    return columnIndexForEntity(column, entity) != null;
}

fn entityAliveLocked(entity: i64) bool {
    if (entity < 0) return false;
    const index: usize = @intCast(entity);
    if (index >= world.alive.items.len) return false;
    return world.alive.items[index];
}

/// Insert or replace `entity`'s value in a column, keeping entity ids sorted.
/// The value block is copied from `value_ptr` (zero-filled when 0).
fn columnSetLocked(type_id: i64, entity: i64, value_ptr: i64) !void {
    const column = world.columns.getPtr(type_id) orelse return error.NotFound;
    const copy = copyValueBlock(value_ptr, column.slots) orelse return error.OutOfMemory;
    errdefer freeValueSlots(copy);
    var low: usize = 0;
    var high: usize = column.entity_ids.items.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (column.entity_ids.items[middle] < entity) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    if (low < column.entity_ids.items.len and column.entity_ids.items[low] == entity) {
        // Re-add/update: replace the existing value block in place.
        freeValueSlots(column.values.items[low]);
        column.values.items[low] = copy;
        return;
    }
    try column.entity_ids.ensureUnusedCapacity(allocator, 1);
    try column.values.ensureUnusedCapacity(allocator, 1);
    column.entity_ids.insertAssumeCapacity(low, entity);
    column.values.insertAssumeCapacity(low, copy);
}

fn columnRemoveLocked(type_id: i64, entity: i64) bool {
    const column = world.columns.getPtr(type_id) orelse return false;
    const index = columnIndexForEntity(column, entity) orelse return false;
    freeValueSlots(column.values.items[index]);
    _ = column.entity_ids.orderedRemove(index);
    _ = column.values.orderedRemove(index);
    return true;
}

/// Clear every component presence for `entity` and mark it dead.  Resources,
/// other entities, and pending commands are untouched.
fn despawnLocked(entity: i64) bool {
    if (!entityAliveLocked(entity)) return false;
    world.alive.items[@intCast(entity)] = false;
    var column_it = world.columns.valueIterator();
    while (column_it.next()) |column| {
        if (columnIndexForEntity(column, entity)) |index| {
            freeValueSlots(column.values.items[index]);
            _ = column.entity_ids.orderedRemove(index);
            _ = column.values.orderedRemove(index);
        }
    }
    return true;
}

fn componentPtr(entity: i64, type_id: i64) i64 {
    const column = world.columns.getPtr(type_id) orelse return 0;
    const index = columnIndexForEntity(column, entity) orelse return 0;
    return @intCast(@intFromPtr(column.values.items[index]));
}

fn rowHandleOwner(handle: i64) ?*Row {
    return world.rows.get(handle);
}

fn queryHandleOwner(handle: i64) ?*Query {
    return world.queries.get(handle);
}

fn retireQuery(handle: i64) void {
    if (world.queries.fetchRemove(handle)) |entry| destroyQuery(entry.value);
}

fn freeColumn(column: *Column) void {
    for (column.values.items) |ptr| freeValueSlots(ptr);
    column.entity_ids.deinit(allocator);
    column.values.deinit(allocator);
}

fn freePendingRow(row: *PendingRow) void {
    for (row.entries.items) |entry| freeValueSlots(entry.ptr);
    row.entries.deinit(allocator);
}

fn resetLocked() void {
    var resource_it = world.resources.valueIterator();
    while (resource_it.next()) |resource| freeValueSlots(resource.ptr);
    world.resources.deinit(allocator);

    var column_it = world.columns.valueIterator();
    while (column_it.next()) |column| freeColumn(column);
    world.columns.deinit(allocator);

    world.plugins.deinit(allocator);

    var row_it = world.rows.valueIterator();
    while (row_it.next()) |row| destroyRow(row.*);
    world.rows.deinit(allocator);

    var query_it = world.queries.valueIterator();
    while (query_it.next()) |query| destroyQuery(query.*);
    world.queries.deinit(allocator);

    for (world.pending_resources.items) |pending| freeValueSlots(pending.ptr);
    world.pending_resources.deinit(allocator);

    for (world.pending_rows.items) |*pending| freePendingRow(pending);
    world.pending_rows.deinit(allocator);

    for (world.pending_component_adds.items) |pending| freeValueSlots(pending.ptr);
    world.pending_component_adds.deinit(allocator);
    world.pending_component_removes.deinit(allocator);
    world.pending_despawns.deinit(allocator);

    world.alive.deinit(allocator);
    world.pending_plugins.deinit(allocator);

    world = .{};
}

// ---------------------------------------------------------------------------
// World lifecycle and registration
// ---------------------------------------------------------------------------

/// Release every resource, component column, pending command, plugin, and
/// query handle.  The world is left empty and immediately reusable.
pub export fn e7_ecs_reset() callconv(.c) void {
    beginCall();
    defer endCall();
    resetLocked();
}

/// Register a resource `id` with `slots` 64-bit words (`0` is allowed for a
/// value-free marker resource).  Registration allocates a zeroed value block
/// immediately, so `e7_ecs_resource` is valid before the first flush.
/// Re-registering with the same slot count is idempotent; a different count is
/// rejected.
pub export fn e7_ecs_register_resource(id: i64, slots: i64) callconv(.c) i32 {
    beginCall();
    defer endCall();

    if (id < 0 or slots < 0) return status_invalid_argument;
    const slot_count: usize = @intCast(slots);
    if (world.resources.getPtr(id)) |existing| {
        return if (existing.slots == slot_count) status_ok else status_invalid_argument;
    }
    const ptr = allocValueSlots(@max(slot_count, 1)) orelse return status_out_of_memory;
    world.resources.put(allocator, id, .{ .slots = slot_count, .ptr = ptr }) catch {
        freeValueSlots(ptr);
        return status_out_of_memory;
    };
    return status_ok;
}

/// Register a component `type_id` whose values occupy `slots` words (`0` is
/// allowed for marker components such as `CubeMesh`).  Columns start empty;
/// entities are appended by flushing a command row.  Re-registering with the
/// same slot count is idempotent; a different count is rejected.  Zero-slot
/// values still get a one-word presence block, so `component_get` and
/// `query_component` return a non-zero pointer for entities that own them.
pub export fn e7_ecs_register_component(type_id: i64, slots: i64) callconv(.c) i32 {
    beginCall();
    defer endCall();

    if (type_id < 0 or slots < 0) return status_invalid_argument;
    const slot_count: usize = @intCast(slots);
    if (world.columns.getPtr(type_id)) |existing| {
        return if (existing.slots == slot_count) status_ok else status_invalid_argument;
    }
    world.columns.put(allocator, type_id, .{ .slots = slot_count }) catch return status_out_of_memory;
    return status_ok;
}

/// Address of the resource value block, or `0` when `id` is not registered.
/// The block is stable until the resource is replaced by a flush or the world
/// is reset.
pub export fn e7_ecs_resource(id: i64) callconv(.c) i64 {
    beginCall();
    defer endCall();
    const resource = world.resources.get(id) orelse return 0;
    return @intCast(@intFromPtr(resource.ptr));
}

pub export fn e7_ecs_has_resource(id: i64) callconv(.c) i64 {
    beginCall();
    defer endCall();
    return if (world.resources.contains(id)) 1 else 0;
}

/// Number of entities appended so far.  Entities are zero-based; a valid
/// entity id is `0 .. e7_ecs_entity_count() - 1`.
pub export fn e7_ecs_entity_count() callconv(.c) i64 {
    beginCall();
    defer endCall();
    return world.entity_count;
}

/// Address of `entity`'s component value, or `0` when the entity does not have
/// that component (or either id is invalid).
pub export fn e7_ecs_component_get(entity: i64, type_id: i64) callconv(.c) i64 {
    beginCall();
    defer endCall();
    if (!entityAliveLocked(entity)) return 0;
    return componentPtr(entity, type_id);
}

/// Whether `entity` is a live (non-despawned) allocated row.
pub export fn e7_ecs_entity_alive(entity: i64) callconv(.c) i64 {
    beginCall();
    defer endCall();
    return if (entityAliveLocked(entity)) 1 else 0;
}

/// Immediately remove `entity`'s component `type_id`.
///
/// Returns `0` on success (including when the component was already absent),
/// `-1` for an invalid/despawned entity, and `-2` for an unregistered component.
/// This is the synchronous counterpart to the deferred
/// `e7_ecs_commands_remove_component`; live queries created before the removal
/// may still iterate the entity but `e7_ecs_query_component` returns `0` for the
/// removed projection.
pub export fn e7_ecs_component_remove(entity: i64, type_id: i64) callconv(.c) i64 {
    beginCall();
    defer endCall();
    if (!entityAliveLocked(entity)) return -1;
    if (!world.columns.contains(type_id)) return -2;
    _ = columnRemoveLocked(type_id, entity);
    return 0;
}

/// Immediately despawn `entity`: clear all component presences and mark the id
/// dead.  Returns `0` on success or `-1` if the entity is already dead/invalid.
pub export fn e7_ecs_entity_despawn(entity: i64) callconv(.c) i64 {
    beginCall();
    defer endCall();
    return if (despawnLocked(entity)) 0 else -1;
}

pub export fn e7_ecs_plugin_active(plugin_id: i64) callconv(.c) i64 {
    beginCall();
    defer endCall();
    return if (world.plugins.contains(plugin_id)) 1 else 0;
}

/// Handle of the process-wide deferred command buffer.  Always non-zero while
/// the runtime is initialized.
pub export fn e7_ecs_commands() callconv(.c) i64 {
    beginCall();
    defer endCall();
    return command_handle;
}

// ---------------------------------------------------------------------------
// Deferred commands
// ---------------------------------------------------------------------------

fn validCommand(cmd: i64) bool {
    return cmd == command_handle;
}

/// Queue a resource replacement.  The value block is copied **now**, so the
/// caller's pointer may be released before the flush.  The resource must have
/// been registered with `e7_ecs_register_resource`; a `value_ptr` of `0` queues
/// a zero-filled value block.
pub export fn e7_ecs_commands_insert_resource(
    cmd: i64,
    type_id: i64,
    value_ptr: i64,
) callconv(.c) i32 {
    beginCall();
    defer endCall();

    if (!validCommand(cmd)) return status_invalid_argument;
    const resource = world.resources.get(type_id) orelse return status_not_found;
    const copy = copyValueBlock(value_ptr, resource.slots) orelse return status_out_of_memory;
    world.pending_resources.append(allocator, .{ .id = type_id, .ptr = copy }) catch {
        freeValueSlots(copy);
        return status_out_of_memory;
    };
    return status_ok;
}

/// Begin a deferred table row.  Returns a non-zero row handle used by
/// `row_add`/`row_finish`; `0` means the command handle was invalid or the
/// allocation failed.
pub export fn e7_ecs_commands_row_begin(cmd: i64) callconv(.c) i64 {
    beginCall();
    defer endCall();

    if (!validCommand(cmd)) return 0;
    const row = createRow() orelse return 0;
    const handle = nextHandle(&next_row_handle) orelse {
        destroyRow(row);
        return 0;
    };
    world.rows.put(allocator, handle, row) catch {
        destroyRow(row);
        return 0;
    };
    return handle;
}

/// Add one component to an open row.  The component type must be registered and
/// the value is copied immediately; `slots` words are read from `value_ptr`
/// (or zero-filled when `value_ptr == 0`).  Adding the same type twice to one
/// row is rejected.
pub export fn e7_ecs_commands_row_add(
    row_handle: i64,
    type_id: i64,
    value_ptr: i64,
) callconv(.c) i32 {
    beginCall();
    defer endCall();

    const row = rowHandleOwner(row_handle) orelse return status_invalid_argument;
    const column = world.columns.get(type_id) orelse return status_not_found;
    for (row.entries.items) |entry| {
        if (entry.type_id == type_id) return status_invalid_argument;
    }
    const copy = copyValueBlock(value_ptr, column.slots) orelse return status_out_of_memory;
    row.entries.append(allocator, .{ .type_id = type_id, .ptr = copy }) catch {
        freeValueSlots(copy);
        return status_out_of_memory;
    };
    return status_ok;
}

/// Finish a row and move it into the pending command list.  The entity becomes
/// visible after the next successful flush.  A row with no components is a
/// valid entity.
pub export fn e7_ecs_commands_row_finish(row_handle: i64) callconv(.c) i32 {
    beginCall();
    defer endCall();

    const row = rowHandleOwner(row_handle) orelse return status_invalid_argument;
    _ = world.rows.remove(row_handle);
    var entries = row.entries;
    world.pending_rows.append(allocator, .{ .entries = entries }) catch {
        for (entries.items) |entry| freeValueSlots(entry.ptr);
        entries.deinit(allocator);
        destroyRow(row);
        return status_out_of_memory;
    };
    // The pending row now owns the entry list and value blocks.
    destroyRow(row);
    return status_ok;
}

/// Queue a plugin activation.  Plugin init execution is compiler-side; the
/// runtime only tracks the active set.  Repeated activation is idempotent.
pub export fn e7_ecs_commands_add_plugin(cmd: i64, plugin_id: i64) callconv(.c) i32 {
    beginCall();
    defer endCall();

    if (!validCommand(cmd)) return status_invalid_argument;
    if (plugin_id < 0) return status_invalid_argument;
    world.pending_plugins.append(allocator, plugin_id) catch return status_out_of_memory;
    return status_ok;
}

/// Queue removal of `type_id` from a live entity.  Applied at the next flush
/// (after pending rows, before pending component additions); queuing validates
/// the entity and registration immediately.  Duplicate removals are harmless.
pub export fn e7_ecs_commands_remove_component(
    cmd: i64,
    entity: i64,
    type_id: i64,
) callconv(.c) i32 {
    beginCall();
    defer endCall();

    if (!validCommand(cmd)) return status_invalid_argument;
    if (!entityAliveLocked(entity)) return status_invalid_argument;
    if (!world.columns.contains(type_id)) return status_not_found;
    world.pending_component_removes.append(allocator, .{ .entity = entity, .type_id = type_id }) catch
        return status_out_of_memory;
    return status_ok;
}

/// Queue adding (or replacing) `type_id` on a live entity.  The value block is
/// copied immediately.  Applied at the next flush after removals/despawns.
pub export fn e7_ecs_commands_add_component(
    cmd: i64,
    entity: i64,
    type_id: i64,
    value_ptr: i64,
) callconv(.c) i32 {
    beginCall();
    defer endCall();

    if (!validCommand(cmd)) return status_invalid_argument;
    if (!entityAliveLocked(entity)) return status_invalid_argument;
    const column = world.columns.get(type_id) orelse return status_not_found;
    const copy = copyValueBlock(value_ptr, column.slots) orelse return status_out_of_memory;
    world.pending_component_adds.append(allocator, .{
        .entity = entity,
        .type_id = type_id,
        .ptr = copy,
    }) catch {
        freeValueSlots(copy);
        return status_out_of_memory;
    };
    return status_ok;
}

/// Queue a despawn.  Applied at the next flush after row/component removals and
/// before component additions (so a queued add for a despawned entity is
/// skipped).  Despawned ids are never reused.
pub export fn e7_ecs_commands_despawn(cmd: i64, entity: i64) callconv(.c) i32 {
    beginCall();
    defer endCall();

    if (!validCommand(cmd)) return status_invalid_argument;
    if (!entityAliveLocked(entity)) return status_invalid_argument;
    world.pending_despawns.append(allocator, entity) catch return status_out_of_memory;
    return status_ok;
}

/// Apply all pending resource insertions, rows, and plugin activations.
///
/// The flush is all-or-nothing with respect to allocation failure: column and
/// plugin capacity is reserved first, and an `out_of_memory` result leaves the
/// pending command list untouched for a retry.  A successful flush increments
/// the world generation, invalidating query handles created before it.
pub export fn e7_ecs_commands_flush(cmd: i64) callconv(.c) i32 {
    beginCall();
    defer endCall();

    if (!validCommand(cmd)) return status_invalid_argument;
    if (world.pending_resources.items.len == 0 and
        world.pending_rows.items.len == 0 and
        world.pending_component_adds.items.len == 0 and
        world.pending_component_removes.items.len == 0 and
        world.pending_despawns.items.len == 0 and
        world.pending_plugins.items.len == 0)
    {
        return status_ok;
    }

    // Reserve everything that can fail before mutating the world.  Row entries
    // are grouped per column first: calling ensureUnusedCapacity(1) once per
    // pending row entry does not accumulate capacity for columns that receive
    // several rows in the same flush (e.g. plugin init spawning a large list).
    var row_capacity: std.AutoHashMapUnmanaged(i64, usize) = .empty;
    defer row_capacity.deinit(allocator);
    for (world.pending_rows.items) |pending| {
        for (pending.entries.items) |entry| {
            const slot = row_capacity.getPtr(entry.type_id) orelse blk: {
                row_capacity.put(allocator, entry.type_id, 0) catch return status_out_of_memory;
                break :blk row_capacity.getPtr(entry.type_id).?;
            };
            slot.* += 1;
        }
    }
    var row_columns = row_capacity.iterator();
    while (row_columns.next()) |entry| {
        const column = world.columns.getPtr(entry.key_ptr.*) orelse continue;
        column.entity_ids.ensureUnusedCapacity(allocator, entry.value_ptr.*) catch return status_out_of_memory;
        column.values.ensureUnusedCapacity(allocator, entry.value_ptr.*) catch return status_out_of_memory;
    }
    for (world.pending_component_adds.items) |pending| {
        const column = world.columns.getPtr(pending.type_id) orelse continue;
        column.entity_ids.ensureUnusedCapacity(allocator, 1) catch return status_out_of_memory;
        column.values.ensureUnusedCapacity(allocator, 1) catch return status_out_of_memory;
    }
    if (world.pending_rows.items.len > 0) {
        world.alive.ensureUnusedCapacity(allocator, @intCast(world.pending_rows.items.len)) catch
            return status_out_of_memory;
    }
    const pending_plugin_count = std.math.cast(u32, world.pending_plugins.items.len) orelse
        return status_out_of_memory;
    world.plugins.ensureUnusedCapacity(allocator, pending_plugin_count) catch
        return status_out_of_memory;
    if (world.pending_rows.items.len > 0 and
        world.entity_count > std.math.maxInt(i64) - @as(i64, @intCast(world.pending_rows.items.len)))
    {
        return status_out_of_memory;
    }

    for (world.pending_resources.items) |pending| {
        const resource = world.resources.getPtr(pending.id) orelse continue;
        freeValueSlots(resource.ptr);
        resource.ptr = pending.ptr;
    }
    world.pending_resources.clearRetainingCapacity();

    for (world.pending_rows.items) |*pending| {
        const entity = world.entity_count;
        world.entity_count += 1;
        world.alive.appendAssumeCapacity(true);
        for (pending.entries.items) |entry| {
            const column = world.columns.getPtr(entry.type_id) orelse continue;
            column.entity_ids.appendAssumeCapacity(entity);
            column.values.appendAssumeCapacity(entry.ptr);
        }
    }
    for (world.pending_rows.items) |*pending| {
        pending.entries.deinit(allocator);
    }
    world.pending_rows.clearRetainingCapacity();

    // Removals first, then despawns, then additions.  This makes a flush that
    // removes and re-adds the same component deterministic, and a despawn wins
    // over any queued add for that entity.
    for (world.pending_component_removes.items) |pending| {
        _ = columnRemoveLocked(pending.type_id, pending.entity);
    }
    world.pending_component_removes.clearRetainingCapacity();

    for (world.pending_despawns.items) |entity| {
        _ = despawnLocked(entity);
    }
    world.pending_despawns.clearRetainingCapacity();

    for (world.pending_component_adds.items) |pending| {
        if (entityAliveLocked(pending.entity)) {
            columnSetLocked(pending.type_id, pending.entity, @intCast(@intFromPtr(pending.ptr))) catch {};
        }
        freeValueSlots(pending.ptr);
    }
    world.pending_component_adds.clearRetainingCapacity();

    for (world.pending_plugins.items) |plugin_id| {
        world.plugins.putAssumeCapacity(plugin_id, {});
    }
    world.pending_plugins.clearRetainingCapacity();

    world.generation +%= 1;
    return status_ok;
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

/// Materialize a snapshot of entities owning every projected component
/// (`ids_ptr`) and, when `has_id >= 0`, the presence component `has_id`.
/// `mut_ptr` carries one i64 mutation flag per projection; it is retained with
/// the query so the compiler can distinguish shared from mutable access.
///
/// Returns a query handle, or `0` for invalid arguments or allocation failure.
/// The handle is invalidated by the next successful flush; `query_next` then
/// returns `0` and releases it.
pub export fn e7_ecs_query_begin(
    count: i64,
    ids_ptr: i64,
    mut_ptr: i64,
    has_id: i64,
) callconv(.c) i64 {
    beginCall();
    defer endCall();

    if (count < 0) return 0;
    const projection_count: usize = @intCast(count);
    if (projection_count > 0 and (ids_ptr == 0 or mut_ptr == 0)) return 0;

    var type_ids: []const i64 = &.{};
    var mut_flags: []const i64 = &.{};
    if (projection_count > 0) {
        type_ids = allocI64Slice(projection_count) orelse return 0;
        mut_flags = allocI64Slice(projection_count) orelse {
            freeI64Slice(type_ids);
            return 0;
        };
        const ids: [*]const i64 = @ptrFromInt(@as(usize, @intCast(ids_ptr)));
        const muts: [*]const i64 = @ptrFromInt(@as(usize, @intCast(mut_ptr)));
        @memcpy(@constCast(type_ids.ptr)[0..projection_count], ids[0..projection_count]);
        @memcpy(@constCast(mut_flags.ptr)[0..projection_count], muts[0..projection_count]);
    }

    const entity_total: usize = @intCast(world.entity_count);
    var match_count: usize = 0;
    for (0..entity_total) |index| {
        const entity: i64 = @intCast(index);
        if (!entityAliveLocked(entity)) continue;
        if (has_id >= 0 and !entityHasColumn(has_id, entity)) continue;
        var matches = true;
        for (type_ids) |type_id| {
            if (!entityHasColumn(type_id, entity)) {
                matches = false;
                break;
            }
        }
        if (matches) match_count += 1;
    }

    const rows = allocValueSlots(match_count);
    if (rows == null and match_count > 0) {
        freeI64Slice(type_ids);
        freeI64Slice(mut_flags);
        return 0;
    }
    if (rows) |rows_ptr| {
        var cursor: usize = 0;
        for (0..entity_total) |index| {
            const entity: i64 = @intCast(index);
            if (!entityAliveLocked(entity)) continue;
            if (has_id >= 0 and !entityHasColumn(has_id, entity)) continue;
            var matches = true;
            for (type_ids) |type_id| {
                if (!entityHasColumn(type_id, entity)) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                rows_ptr[cursor] = entity;
                cursor += 1;
            }
        }
    }

    const query = createQuery() orelse {
        freeValueSlots(rows);
        freeI64Slice(type_ids);
        freeI64Slice(mut_flags);
        return 0;
    };
    query.* = .{
        .rows = rows,
        .row_count = match_count,
        .type_ids = type_ids,
        .mut_flags = mut_flags,
        .has_id = has_id,
        .generation = world.generation,
    };
    const handle = nextHandle(&next_query_handle) orelse {
        destroyQuery(query);
        return 0;
    };
    world.queries.put(allocator, handle, query) catch {
        destroyQuery(query);
        return 0;
    };
    return handle;
}

/// Advance to the next matching row.  Returns `entity_id + 1` (non-zero), or
/// `0` at the end, for a stale handle, or for an invalid handle.  Reaching the
/// end or observing a stale generation releases the query handle.
pub export fn e7_ecs_query_next(query_handle: i64) callconv(.c) i64 {
    beginCall();
    defer endCall();

    const query = queryHandleOwner(query_handle) orelse return 0;
    if (query.generation != world.generation) {
        retireQuery(query_handle);
        return 0;
    }
    if (query.cursor >= query.row_count) {
        retireQuery(query_handle);
        return 0;
    }
    const rows = query.rows orelse {
        retireQuery(query_handle);
        return 0;
    };
    const entity = rows[query.cursor];
    query.cursor += 1;
    query.current_entity = entity;
    return entity + 1;
}

/// Component pointer for the row most recently returned by `query_next`.
/// `type_index` indexes the projection list passed to `query_begin`.  Returns
/// `0` before the first successful `query_next`, for an out-of-range index, or
/// for a stale/invalid handle.
pub export fn e7_ecs_query_component(query_handle: i64, type_index: i64) callconv(.c) i64 {
    beginCall();
    defer endCall();

    const query = queryHandleOwner(query_handle) orelse return 0;
    if (query.generation != world.generation) {
        retireQuery(query_handle);
        return 0;
    }
    if (query.current_entity < 0) return 0;
    if (type_index < 0 or type_index >= @as(i64, @intCast(query.type_ids.len))) return 0;
    return componentPtr(query.current_entity, query.type_ids[@intCast(type_index)]);
}

/// Entity id for the row most recently returned by `e7_ecs_query_next`, or `-1`
/// before the first row / for a stale handle.  This is the value e7 passes to
/// `Commands.remove_component::<T>` / `Commands.despawn`.
pub export fn e7_ecs_query_entity(query_handle: i64) callconv(.c) i64 {
    beginCall();
    defer endCall();

    const query = queryHandleOwner(query_handle) orelse return -1;
    if (query.generation != world.generation) {
        retireQuery(query_handle);
        return -1;
    }
    return query.current_entity;
}

// ---------------------------------------------------------------------------
// Symbol manifest and test diagnostics
// ---------------------------------------------------------------------------

/// Host symbols to register with the JIT (`Jit.defineSymbols`).
pub fn symbols() [25]Symbol {
    return .{
        .{ .name = "e7_ecs_reset", .address = @intFromPtr(&e7_ecs_reset) },
        .{ .name = "e7_ecs_register_resource", .address = @intFromPtr(&e7_ecs_register_resource) },
        .{ .name = "e7_ecs_register_component", .address = @intFromPtr(&e7_ecs_register_component) },
        .{ .name = "e7_ecs_resource", .address = @intFromPtr(&e7_ecs_resource) },
        .{ .name = "e7_ecs_has_resource", .address = @intFromPtr(&e7_ecs_has_resource) },
        .{ .name = "e7_ecs_entity_count", .address = @intFromPtr(&e7_ecs_entity_count) },
        .{ .name = "e7_ecs_component_get", .address = @intFromPtr(&e7_ecs_component_get) },
        .{ .name = "e7_ecs_commands", .address = @intFromPtr(&e7_ecs_commands) },
        .{ .name = "e7_ecs_commands_insert_resource", .address = @intFromPtr(&e7_ecs_commands_insert_resource) },
        .{ .name = "e7_ecs_commands_row_begin", .address = @intFromPtr(&e7_ecs_commands_row_begin) },
        .{ .name = "e7_ecs_commands_row_add", .address = @intFromPtr(&e7_ecs_commands_row_add) },
        .{ .name = "e7_ecs_commands_row_finish", .address = @intFromPtr(&e7_ecs_commands_row_finish) },
        .{ .name = "e7_ecs_commands_add_plugin", .address = @intFromPtr(&e7_ecs_commands_add_plugin) },
        .{ .name = "e7_ecs_commands_flush", .address = @intFromPtr(&e7_ecs_commands_flush) },
        .{ .name = "e7_ecs_plugin_active", .address = @intFromPtr(&e7_ecs_plugin_active) },
        .{ .name = "e7_ecs_query_begin", .address = @intFromPtr(&e7_ecs_query_begin) },
        .{ .name = "e7_ecs_query_next", .address = @intFromPtr(&e7_ecs_query_next) },
        .{ .name = "e7_ecs_query_component", .address = @intFromPtr(&e7_ecs_query_component) },
        .{ .name = "e7_ecs_query_entity", .address = @intFromPtr(&e7_ecs_query_entity) },
        .{ .name = "e7_ecs_component_remove", .address = @intFromPtr(&e7_ecs_component_remove) },
        .{ .name = "e7_ecs_entity_despawn", .address = @intFromPtr(&e7_ecs_entity_despawn) },
        .{ .name = "e7_ecs_entity_alive", .address = @intFromPtr(&e7_ecs_entity_alive) },
        .{ .name = "e7_ecs_commands_remove_component", .address = @intFromPtr(&e7_ecs_commands_remove_component) },
        .{ .name = "e7_ecs_commands_add_component", .address = @intFromPtr(&e7_ecs_commands_add_component) },
        .{ .name = "e7_ecs_commands_despawn", .address = @intFromPtr(&e7_ecs_commands_despawn) },
    };
}

/// Number of live heap blocks owned by the world.  Tests use this to prove a
/// reset has released every resource, column value, row, and query it owns.
pub fn debugLiveBlocks() usize {
    beginCall();
    defer endCall();
    return live_blocks;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sourcePtr(values: []const i64) i64 {
    return @intCast(@intFromPtr(values.ptr));
}

fn block(ptr: i64) [*]i64 {
    return @ptrFromInt(@as(usize, @intCast(ptr)));
}

fn addRow(cmd: i64, components: []const struct { type_id: i64, values: []const i64 }) !void {
    const row = e7_ecs_commands_row_begin(cmd);
    try testing.expect(row != 0);
    for (components) |component| {
        try testing.expectEqual(
            status_ok,
            e7_ecs_commands_row_add(row, component.type_id, sourcePtr(component.values)),
        );
    }
    try testing.expectEqual(status_ok, e7_ecs_commands_row_finish(row));
}

test "resources register, queue a copy, and become visible on flush" {
    e7_ecs_reset();
    defer e7_ecs_reset();

    try testing.expectEqual(status_ok, e7_ecs_register_resource(1, 3));
    try testing.expectEqual(@as(i64, 1), e7_ecs_has_resource(1));
    try testing.expectEqual(@as(i64, 0), e7_ecs_has_resource(2));

    const initial = e7_ecs_resource(1);
    try testing.expect(initial != 0);
    try testing.expectEqual(@as(i64, 0), block(initial)[0]);
    try testing.expectEqual(@as(i64, 0), e7_ecs_resource(2));

    var values = [_]i64{ 10, 20, 30 };
    const cmd = e7_ecs_commands();
    try testing.expect(cmd != 0);
    try testing.expectEqual(status_ok, e7_ecs_commands_insert_resource(cmd, 1, sourcePtr(&values)));

    // Deferred: the old zeroed block is still what readers see.
    try testing.expectEqual(@as(i64, 0), block(e7_ecs_resource(1))[0]);

    // Queue-time copy: mutating the source before the flush must not matter.
    values[0] = 99;
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));
    const resource = e7_ecs_resource(1);
    try testing.expect(resource != 0);
    try testing.expectEqual(@as(i64, 10), block(resource)[0]);
    try testing.expectEqual(@as(i64, 20), block(resource)[1]);
    try testing.expectEqual(@as(i64, 30), block(resource)[2]);
}

test "columnar rows are deferred, append entities, and keep per-entity values" {
    e7_ecs_reset();
    defer e7_ecs_reset();

    try testing.expectEqual(status_ok, e7_ecs_register_component(10, 2));
    try testing.expectEqual(status_ok, e7_ecs_register_component(11, 1));
    const cmd = e7_ecs_commands();

    var first_position = [_]i64{ 1, 2 };
    var first_scale = [_]i64{7};
    try addRow(cmd, &.{
        .{ .type_id = 10, .values = &first_position },
        .{ .type_id = 11, .values = &first_scale },
    });

    var second_position = [_]i64{ 3, 4 };
    try addRow(cmd, &.{.{ .type_id = 10, .values = &second_position }});

    // Nothing is visible before the flush.
    try testing.expectEqual(@as(i64, 0), e7_ecs_entity_count());
    try testing.expectEqual(@as(i64, 0), e7_ecs_component_get(0, 10));

    // Values are copied when queued.
    first_position[0] = 100;
    second_position[1] = 400;
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));

    try testing.expectEqual(@as(i64, 2), e7_ecs_entity_count());
    const position0 = e7_ecs_component_get(0, 10);
    try testing.expect(position0 != 0);
    try testing.expectEqual(@as(i64, 1), block(position0)[0]);
    try testing.expectEqual(@as(i64, 2), block(position0)[1]);
    const scale0 = e7_ecs_component_get(0, 11);
    try testing.expect(scale0 != 0);
    try testing.expectEqual(@as(i64, 7), block(scale0)[0]);

    const position1 = e7_ecs_component_get(1, 10);
    try testing.expectEqual(@as(i64, 3), block(position1)[0]);
    try testing.expectEqual(@as(i64, 4), block(position1)[1]);
    try testing.expectEqual(@as(i64, 0), e7_ecs_component_get(1, 11));
    try testing.expectEqual(@as(i64, 0), e7_ecs_component_get(2, 10));
    try testing.expectEqual(@as(i64, 0), e7_ecs_component_get(-1, 10));
}

test "queries filter by projections and has with mutable flags" {
    e7_ecs_reset();
    defer e7_ecs_reset();

    try testing.expectEqual(status_ok, e7_ecs_register_component(10, 1));
    try testing.expectEqual(status_ok, e7_ecs_register_component(11, 1));
    try testing.expectEqual(status_ok, e7_ecs_register_component(12, 1));
    const cmd = e7_ecs_commands();

    // e0: 10 + 11, e1: 10 + 12, e2: 10, e3: 11 + 12.
    var a10 = [_]i64{100};
    var a11 = [_]i64{200};
    var b10 = [_]i64{101};
    var b12 = [_]i64{300};
    var c10 = [_]i64{102};
    var d11 = [_]i64{201};
    var d12 = [_]i64{301};
    try addRow(cmd, &.{
        .{ .type_id = 10, .values = &a10 },
        .{ .type_id = 11, .values = &a11 },
    });
    try addRow(cmd, &.{
        .{ .type_id = 10, .values = &b10 },
        .{ .type_id = 12, .values = &b12 },
    });
    try addRow(cmd, &.{.{ .type_id = 10, .values = &c10 }});
    try addRow(cmd, &.{
        .{ .type_id = 11, .values = &d11 },
        .{ .type_id = 12, .values = &d12 },
    });
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));
    try testing.expectEqual(@as(i64, 4), e7_ecs_entity_count());

    // Projections 10 and 11, mutable flags mixed, no presence filter: only e0.
    var ids_a = [_]i64{ 10, 11 };
    var muts_a = [_]i64{ 0, 1 };
    const query_a = e7_ecs_query_begin(2, sourcePtr(&ids_a), sourcePtr(&muts_a), -1);
    try testing.expect(query_a != 0);
    try testing.expectEqual(@as(i64, 1), e7_ecs_query_next(query_a)); // entity 0
    const q10 = e7_ecs_query_component(query_a, 0);
    const q11 = e7_ecs_query_component(query_a, 1);
    try testing.expectEqual(@as(i64, 100), block(q10)[0]);
    try testing.expectEqual(@as(i64, 200), block(q11)[0]);
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(query_a));

    // Projection 10 with `has 12`: only e1.  Mutable projection flag accepted.
    var ids_b = [_]i64{10};
    var muts_b = [_]i64{1};
    const query_b = e7_ecs_query_begin(1, sourcePtr(&ids_b), sourcePtr(&muts_b), 12);
    try testing.expectEqual(@as(i64, 2), e7_ecs_query_next(query_b)); // entity 1
    try testing.expectEqual(@as(i64, 101), block(e7_ecs_query_component(query_b, 0))[0]);
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_component(query_b, 1));
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(query_b));

    // Zero projections with `has 12`: e1 and e3.
    const query_c = e7_ecs_query_begin(0, 0, 0, 12);
    try testing.expect(query_c != 0);
    try testing.expectEqual(@as(i64, 2), e7_ecs_query_next(query_c));
    try testing.expectEqual(@as(i64, 4), e7_ecs_query_next(query_c));
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(query_c));

    // Zero projections, no presence filter: every entity.
    const query_d = e7_ecs_query_begin(0, 0, 0, -1);
    try testing.expectEqual(@as(i64, 1), e7_ecs_query_next(query_d)); // entity 0
    try testing.expectEqual(@as(i64, 2), e7_ecs_query_next(query_d));
    try testing.expectEqual(@as(i64, 3), e7_ecs_query_next(query_d));
    try testing.expectEqual(@as(i64, 4), e7_ecs_query_next(query_d));
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(query_d));

    // Unregistered projection: an empty snapshot, not an error.
    var ids_missing = [_]i64{77};
    var muts_missing = [_]i64{0};
    const query_e = e7_ecs_query_begin(1, sourcePtr(&ids_missing), sourcePtr(&muts_missing), -1);
    try testing.expect(query_e != 0);
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(query_e));

    // A flush invalidates existing query handles; regenerate after.
    var ids_f = [_]i64{10};
    var muts_f = [_]i64{0};
    const stale = e7_ecs_query_begin(1, sourcePtr(&ids_f), sourcePtr(&muts_f), -1);
    try testing.expect(stale != 0);
    var extra = [_]i64{103};
    try addRow(cmd, &.{.{ .type_id = 10, .values = &extra }});
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(stale));
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_component(stale, 0));

    const fresh = e7_ecs_query_begin(1, sourcePtr(&ids_f), sourcePtr(&muts_f), -1);
    try testing.expectEqual(@as(i64, 1), e7_ecs_query_next(fresh)); // e0
    try testing.expectEqual(@as(i64, 2), e7_ecs_query_next(fresh)); // e1
    try testing.expectEqual(@as(i64, 3), e7_ecs_query_next(fresh)); // e2
    try testing.expectEqual(@as(i64, 5), e7_ecs_query_next(fresh)); // e4
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(fresh));
}

test "many rows for one column flush without capacity corruption" {
    e7_ecs_reset();
    defer e7_ecs_reset();

    try testing.expectEqual(status_ok, e7_ecs_register_component(20, 1));
    try testing.expectEqual(status_ok, e7_ecs_register_component(21, 1));
    const cmd = e7_ecs_commands();

    // Regression: the flush pre-reservation used to call ensureUnusedCapacity(1)
    // once per pending row entry without accumulating, so a single flush adding
    // more rows than the column's existing spare capacity panicked in
    // appendAssumeCapacity.  Large plugin-init row sets hit this.
    var bulk = [_]i64{0};
    for (0..40) |index| {
        bulk[0] = @intCast(index);
        try addRow(cmd, &.{.{ .type_id = 20, .values = &bulk }});
    }
    var bulk_a = [_]i64{0};
    var bulk_b = [_]i64{0};
    for (0..20) |index| {
        bulk_a[0] = @intCast(1000 + index);
        bulk_b[0] = @intCast(2000 + index);
        try addRow(cmd, &.{
            .{ .type_id = 20, .values = &bulk_a },
            .{ .type_id = 21, .values = &bulk_b },
        });
    }
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));
    try testing.expectEqual(@as(i64, 60), e7_ecs_entity_count());

    var ids = [_]i64{21};
    var muts = [_]i64{0};
    const query = e7_ecs_query_begin(1, sourcePtr(&ids), sourcePtr(&muts), -1);
    var seen: i64 = 0;
    while (e7_ecs_query_next(query) != 0) seen += 1;
    try testing.expectEqual(@as(i64, 20), seen);

    const all = e7_ecs_query_begin(0, 0, 0, -1);
    var total: i64 = 0;
    while (e7_ecs_query_next(all) != 0) total += 1;
    try testing.expectEqual(@as(i64, 60), total);
}

test "plugins activate only when the command buffer is flushed" {
    e7_ecs_reset();
    defer e7_ecs_reset();

    const cmd = e7_ecs_commands();
    try testing.expectEqual(@as(i64, 0), e7_ecs_plugin_active(5));
    try testing.expectEqual(status_ok, e7_ecs_commands_add_plugin(cmd, 5));
    try testing.expectEqual(@as(i64, 0), e7_ecs_plugin_active(5));
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));
    try testing.expectEqual(@as(i64, 1), e7_ecs_plugin_active(5));
    try testing.expectEqual(@as(i64, 0), e7_ecs_plugin_active(6));

    // Activation is idempotent.
    try testing.expectEqual(status_ok, e7_ecs_commands_add_plugin(cmd, 5));
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));
    try testing.expectEqual(@as(i64, 1), e7_ecs_plugin_active(5));

    e7_ecs_reset();
    try testing.expectEqual(@as(i64, 0), e7_ecs_plugin_active(5));
}

test "zero-slot marker components and resources are presence records" {
    e7_ecs_reset();
    defer e7_ecs_reset();

    // Marker resources still expose a non-zero (presence) block.
    try testing.expectEqual(status_ok, e7_ecs_register_resource(2, 0));
    try testing.expect(e7_ecs_resource(2) != 0);
    const cmd = e7_ecs_commands();
    try testing.expectEqual(status_ok, e7_ecs_commands_insert_resource(cmd, 2, 0));
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));
    try testing.expect(e7_ecs_resource(2) != 0);

    // Marker components (e.g. CubeMesh) can be added, queried, and `has`-filtered.
    try testing.expectEqual(status_ok, e7_ecs_register_component(30, 0));
    const row = e7_ecs_commands_row_begin(cmd);
    try testing.expect(row != 0);
    try testing.expectEqual(status_ok, e7_ecs_commands_row_add(row, 30, 0));
    try testing.expectEqual(status_invalid_argument, e7_ecs_commands_row_add(row, 30, 0));
    try testing.expectEqual(status_ok, e7_ecs_commands_row_finish(row));
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));

    try testing.expectEqual(@as(i64, 1), e7_ecs_entity_count());
    try testing.expect(e7_ecs_component_get(0, 30) != 0);

    var ids = [_]i64{30};
    var muts = [_]i64{0};
    const query = e7_ecs_query_begin(1, sourcePtr(&ids), sourcePtr(&muts), -1);
    try testing.expectEqual(@as(i64, 1), e7_ecs_query_next(query));
    try testing.expect(e7_ecs_query_component(query, 0) != 0);
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(query));

    const presence = e7_ecs_query_begin(0, 0, 0, 30);
    try testing.expectEqual(@as(i64, 1), e7_ecs_query_next(presence));
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(presence));
}

test "invalid registrations and handles are rejected" {
    e7_ecs_reset();
    defer e7_ecs_reset();

    try testing.expectEqual(status_invalid_argument, e7_ecs_register_resource(-1, 1));
    try testing.expectEqual(status_invalid_argument, e7_ecs_register_resource(1, -1));
    try testing.expectEqual(status_ok, e7_ecs_register_resource(1, 2));
    try testing.expectEqual(status_ok, e7_ecs_register_resource(1, 2));
    try testing.expectEqual(status_invalid_argument, e7_ecs_register_resource(1, 3));

    try testing.expectEqual(status_invalid_argument, e7_ecs_register_component(-1, 1));
    try testing.expectEqual(status_ok, e7_ecs_register_component(10, 1));
    try testing.expectEqual(status_ok, e7_ecs_register_component(10, 1));
    try testing.expectEqual(status_invalid_argument, e7_ecs_register_component(10, 2));

    const cmd = e7_ecs_commands();
    try testing.expectEqual(status_invalid_argument, e7_ecs_commands_insert_resource(cmd + 1, 1, 0));
    try testing.expectEqual(status_not_found, e7_ecs_commands_insert_resource(cmd, 77, 0));
    try testing.expectEqual(@as(i64, 0), e7_ecs_commands_row_begin(cmd + 1));

    const row = e7_ecs_commands_row_begin(cmd);
    try testing.expect(row != 0);
    try testing.expectEqual(status_not_found, e7_ecs_commands_row_add(row, 77, 0));
    var value = [_]i64{1};
    try testing.expectEqual(status_ok, e7_ecs_commands_row_add(row, 10, sourcePtr(&value)));
    try testing.expectEqual(status_invalid_argument, e7_ecs_commands_row_add(row, 10, sourcePtr(&value)));
    try testing.expectEqual(status_invalid_argument, e7_ecs_commands_row_finish(row + 1));
    try testing.expectEqual(status_ok, e7_ecs_commands_row_finish(row));
    try testing.expectEqual(status_invalid_argument, e7_ecs_commands_row_finish(row));

    try testing.expectEqual(status_invalid_argument, e7_ecs_commands_add_plugin(cmd + 1, 1));
    try testing.expectEqual(status_invalid_argument, e7_ecs_commands_add_plugin(cmd, -1));
    try testing.expectEqual(status_invalid_argument, e7_ecs_commands_flush(cmd + 1));

    try testing.expectEqual(@as(i64, 0), e7_ecs_query_begin(-1, 0, 0, -1));
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_begin(1, 0, 0, -1));
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(0));
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(9999));
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_component(9999, 0));
}

test "reset releases every owned block and leaves a reusable world" {
    e7_ecs_reset();
    defer e7_ecs_reset();

    try testing.expectEqual(@as(usize, 0), debugLiveBlocks());
    try testing.expectEqual(status_ok, e7_ecs_register_resource(1, 2));
    try testing.expectEqual(status_ok, e7_ecs_register_component(10, 1));
    const cmd = e7_ecs_commands();

    var value = [_]i64{5};
    try testing.expectEqual(status_ok, e7_ecs_commands_insert_resource(cmd, 1, sourcePtr(&value)));
    try addRow(cmd, &.{.{ .type_id = 10, .values = &value }});

    // Leave an open row and an uniterated query behind on purpose.
    const open_row = e7_ecs_commands_row_begin(cmd);
    try testing.expect(open_row != 0);
    var ids = [_]i64{10};
    var muts = [_]i64{0};
    const abandoned_query = e7_ecs_query_begin(1, sourcePtr(&ids), sourcePtr(&muts), -1);
    try testing.expect(abandoned_query != 0);
    // Flush the row that was finished; the open row and query stay pending/live.
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));
    try testing.expectEqual(@as(i64, 1), e7_ecs_entity_count());

    try testing.expect(debugLiveBlocks() > 0);
    e7_ecs_reset();

    try testing.expectEqual(@as(usize, 0), debugLiveBlocks());
    try testing.expectEqual(@as(i64, 0), e7_ecs_entity_count());
    try testing.expectEqual(@as(i64, 0), e7_ecs_has_resource(1));
    try testing.expectEqual(@as(i64, 0), e7_ecs_component_get(0, 10));

    // The world is immediately reusable after reset.
    try testing.expectEqual(status_ok, e7_ecs_register_component(20, 1));
    var again = [_]i64{8};
    try addRow(e7_ecs_commands(), &.{.{ .type_id = 20, .values = &again }});
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(e7_ecs_commands()));
    try testing.expectEqual(@as(i64, 1), e7_ecs_entity_count());
    try testing.expectEqual(@as(i64, 8), block(e7_ecs_component_get(0, 20))[0]);

    e7_ecs_reset();
    try testing.expectEqual(@as(usize, 0), debugLiveBlocks());
}

test "component removal, re-add, and despawn presence semantics" {
    e7_ecs_reset();
    defer e7_ecs_reset();

    try testing.expectEqual(status_ok, e7_ecs_register_resource(7, 1));
    const resource_ptr = e7_ecs_resource(7);
    try testing.expect(resource_ptr != 0);
    try testing.expectEqual(0, e7_ecs_register_component(10, 1));
    try testing.expectEqual(0, e7_ecs_register_component(11, 0));

    const cmd = e7_ecs_commands();
    const row = e7_ecs_commands_row_begin(cmd);
    var value: i64 = 42;
    try testing.expectEqual(status_ok, e7_ecs_commands_row_add(row, 10, @intCast(@intFromPtr(&value))));
    try testing.expectEqual(status_ok, e7_ecs_commands_row_add(row, 11, 0));
    try testing.expectEqual(status_ok, e7_ecs_commands_row_finish(row));
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));
    try testing.expectEqual(@as(i64, 1), e7_ecs_entity_count());
    try testing.expectEqual(@as(i64, 1), e7_ecs_entity_alive(0));
    try testing.expect(e7_ecs_component_get(0, 10) != 0);
    try testing.expect(e7_ecs_component_get(0, 11) != 0);

    // A query over the component sees the row until it is removed.
    var ids = [_]i64{10};
    var muts = [_]i64{1};
    var query = e7_ecs_query_begin(1, @intCast(@intFromPtr(&ids)), @intCast(@intFromPtr(&muts)), -1);
    try testing.expectEqual(@as(i64, 1), e7_ecs_query_next(query));
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_entity(query));
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(query));

    try testing.expectEqual(@as(i64, 0), e7_ecs_component_remove(0, 10));
    try testing.expectEqual(@as(i64, 0), e7_ecs_component_get(0, 10));
    try testing.expect(e7_ecs_component_get(0, 11) != 0);
    query = e7_ecs_query_begin(1, @intCast(@intFromPtr(&ids)), @intCast(@intFromPtr(&muts)), -1);
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(query));
    // The marker query still sees the live entity.
    var marker_ids = [_]i64{11};
    query = e7_ecs_query_begin(1, @intCast(@intFromPtr(&marker_ids)), @intCast(@intFromPtr(&muts)), -1);
    try testing.expectEqual(@as(i64, 1), e7_ecs_query_next(query));
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(query));

    // Removal is idempotent; unregistered ids and dead entities are errors.
    try testing.expectEqual(@as(i64, 0), e7_ecs_component_remove(0, 10));
    try testing.expectEqual(@as(i64, -1), e7_ecs_component_remove(99, 10));
    try testing.expectEqual(@as(i64, -2), e7_ecs_component_remove(0, 99));

    // Re-add through deferred commands and observe the value.
    var restored: i64 = 77;
    try testing.expectEqual(status_ok, e7_ecs_commands_add_component(cmd, 0, 10, @intCast(@intFromPtr(&restored))));
    try testing.expectEqual(@as(i64, 0), e7_ecs_component_get(0, 10)); // deferred
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));
    const readded = e7_ecs_component_get(0, 10);
    try testing.expect(readded != 0);
    const readded_values: [*]const i64 = @ptrFromInt(@as(usize, @intCast(readded)));
    try testing.expectEqual(@as(i64, 77), readded_values[0]);

    // Despawn clears every presence, keeps resources, and invalidates the id.
    try testing.expectEqual(@as(i64, 0), e7_ecs_entity_despawn(0));
    try testing.expectEqual(@as(i64, 0), e7_ecs_entity_alive(0));
    try testing.expectEqual(@as(i64, 0), e7_ecs_component_get(0, 10));
    try testing.expectEqual(@as(i64, 0), e7_ecs_component_get(0, 11));
    try testing.expect(e7_ecs_resource(7) != 0);
    try testing.expectEqual(@as(i64, -1), e7_ecs_entity_despawn(0));
    try testing.expectEqual(@as(i64, 1), e7_ecs_entity_count());
    query = e7_ecs_query_begin(1, @intCast(@intFromPtr(&marker_ids)), @intCast(@intFromPtr(&muts)), -1);
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(query));
    // Zero-projection queries also skip despawned entities.
    query = e7_ecs_query_begin(0, 0, 0, -1);
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(query));
}

test "deferred component removal and despawn are visible only after flush" {
    e7_ecs_reset();
    defer e7_ecs_reset();

    try testing.expectEqual(0, e7_ecs_register_component(20, 0));
    try testing.expectEqual(0, e7_ecs_register_component(21, 1));
    const cmd = e7_ecs_commands();
    var row = e7_ecs_commands_row_begin(cmd);
    try testing.expectEqual(status_ok, e7_ecs_commands_row_add(row, 20, 0));
    try testing.expectEqual(status_ok, e7_ecs_commands_row_add(row, 21, 0));
    try testing.expectEqual(status_ok, e7_ecs_commands_row_finish(row));
    row = e7_ecs_commands_row_begin(cmd);
    try testing.expectEqual(status_ok, e7_ecs_commands_row_add(row, 20, 0));
    try testing.expectEqual(status_ok, e7_ecs_commands_row_finish(row));
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));
    try testing.expectEqual(@as(i64, 2), e7_ecs_entity_count());

    try testing.expectEqual(status_ok, e7_ecs_commands_remove_component(cmd, 0, 21));
    try testing.expect(e7_ecs_component_get(0, 21) != 0); // still live before flush
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));
    try testing.expectEqual(@as(i64, 0), e7_ecs_component_get(0, 21));
    try testing.expectEqual(@as(i64, 1), e7_ecs_entity_alive(0));

    var marker_ids = [_]i64{20};
    var muts = [_]i64{0};
    var query = e7_ecs_query_begin(1, @intCast(@intFromPtr(&marker_ids)), @intCast(@intFromPtr(&muts)), -1);
    try testing.expectEqual(@as(i64, 1), e7_ecs_query_next(query));
    try testing.expectEqual(@as(i64, 2), e7_ecs_query_next(query));
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(query));

    // Despawn wins over a queued add for the same entity; other entities stay.
    try testing.expectEqual(status_ok, e7_ecs_commands_add_component(cmd, 1, 21, 0));
    try testing.expectEqual(status_ok, e7_ecs_commands_despawn(cmd, 1));
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));
    try testing.expectEqual(@as(i64, 0), e7_ecs_entity_alive(1));
    try testing.expectEqual(@as(i64, 0), e7_ecs_component_get(1, 21));
    query = e7_ecs_query_begin(1, @intCast(@intFromPtr(&marker_ids)), @intCast(@intFromPtr(&muts)), -1);
    try testing.expectEqual(@as(i64, 1), e7_ecs_query_next(query));
    try testing.expectEqual(@as(i64, 0), e7_ecs_query_next(query));

    // Adding a component back to a live entity reuses its slot.
    try testing.expectEqual(status_ok, e7_ecs_commands_remove_component(cmd, 0, 21));
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));
    try testing.expectEqual(@as(i64, 0), e7_ecs_component_get(0, 21));
    var replacement: i64 = 9;
    try testing.expectEqual(status_ok, e7_ecs_commands_add_component(cmd, 0, 21, @intCast(@intFromPtr(&replacement))));
    try testing.expectEqual(status_ok, e7_ecs_commands_flush(cmd));
    const ptr = e7_ecs_component_get(0, 21);
    try testing.expect(ptr != 0);
    const replacement_values: [*]const i64 = @ptrFromInt(@as(usize, @intCast(ptr)));
    try testing.expectEqual(@as(i64, 9), replacement_values[0]);
}
