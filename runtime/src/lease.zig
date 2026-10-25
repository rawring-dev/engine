//! Runtime lease table for external borrows held across `await`.
//!
//! A lease is a numeric id (`i64`) owned by exactly one task or thread at a
//! time.  The table is a fixed-size slot array; ids are table keys, so any
//! non-negative `i64` is a valid lease id, and at most `max_leases` distinct
//! ids may be live at once.  The table itself never allocates or fails, which
//! keeps the JIT ABI total: every entry point returns an integer status.
//!
//! ## Await boundaries
//!
//! `task.zig` installs a holder provider and calls [`suspendHolder`] right
//! before a task blocks in `await`, and [`resumeHolder`] as soon as it is
//! scheduled again.  Suspension *releases* the leases for external observers
//! (so another waiter can acquire them) while remembering the original holder
//! as a suspended claim.  Resumption reacquires free claims; a claim taken by
//! another holder in the meantime is lost, which matches the "fresh
//! acquisition after await" model of the language.
//!
//! `task.zig` also calls [`endHolder`] when a task body returns, so a task
//! cannot leak an active lease by forgetting an explicit release.
//!
//! ## Exported ABI
//!
//! `e7_lease_acquire(id) -> i64` returns 1 on success, 0 when the lease is held
//! by somebody else (or the table is full).  `e7_lease_release(id) -> i64`
//! returns 1 only when this call actually released the lease, so a double
//! release returns 0 and cannot free another holder's lease.
//! `e7_lease_reacquire(id) -> i64` re-takes a suspended claim (or confirms an
//! already-active lease) and returns 1 on success.
//! `e7_lease_active(id) -> i64` reports whether any holder currently owns the
//! lease.

const std = @import("std");
const Symbol = @import("intrinsics.zig").Symbol;

const c = @cImport({
    @cInclude("pthread.h");
});

/// Maximum number of distinct live lease ids.
pub const max_leases: usize = 256;

/// Set by the task runtime so the exported ABI can attribute acquisitions to
/// the running task.  When unset (no task runtime, or a plain host thread) the
/// calling thread acts as its own holder via a thread-local fallback token.
pub var holder_provider: ?*const fn () callconv(.c) u64 = null;

pub fn setHolderProvider(provider: *const fn () callconv(.c) u64) void {
    holder_provider = provider;
}

pub fn clearHolderProvider() void {
    holder_provider = null;
}

threadlocal var fallback_holder: u64 = 0;

fn currentHolder() u64 {
    if (holder_provider) |provider| return provider();
    // No task runtime installed: the calling thread is its own holder.  Tokens
    // use a bit namespace disjoint from the task runtime's pointer tokens and
    // from `task.currentHolderToken`'s standalone tokens.
    if (fallback_holder == 0) {
        const thread_id: u64 = @intCast(std.Thread.getCurrentId());
        fallback_holder = (@as(u64, 1) << 62) | (thread_id & ((@as(u64, 1) << 61) - 1)) | 1;
    }
    return fallback_holder;
}

const Slot = struct {
    /// Lease id, or `-1` for a free slot.
    id: i64 = -1,
    /// Token of the task/thread that currently owns the lease; 0 means free.
    holder: u64 = 0,
    /// Token of the holder that released the lease on suspension and may
    /// reacquire it on resume.
    suspended: u64 = 0,
    acquires: u64 = 0,
    releases: u64 = 0,
    suspended_releases: u64 = 0,
    reacquires: u64 = 0,
};

var table: [max_leases]Slot = [_]Slot{.{}} ** max_leases;

var table_mutex: c.pthread_mutex_t = undefined;
var table_state = std.atomic.Value(u8).init(0); // 0 = uninit, 1 = initing, 2 = ready

fn ensureTable() void {
    if (table_state.load(.acquire) == 2) return;
    if (table_state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
        _ = c.pthread_mutex_init(&table_mutex, null);
        table_state.store(2, .release);
        return;
    }
    while (table_state.load(.acquire) != 2) std.atomic.spinLoopHint();
}

fn lockTable() void {
    ensureTable();
    _ = c.pthread_mutex_lock(&table_mutex);
}

fn unlockTable() void {
    _ = c.pthread_mutex_unlock(&table_mutex);
}

fn findSlotLocked(id: i64) ?usize {
    for (&table, 0..) |*slot, index| {
        if (slot.id == id) return index;
    }
    return null;
}

fn ensureSlotLocked(id: i64) ?usize {
    if (findSlotLocked(id)) |index| return index;
    for (&table, 0..) |*slot, index| {
        if (slot.id == -1) {
            slot.* = .{ .id = id };
            return index;
        }
    }
    return null;
}

fn acquireLocked(id: i64, holder: u64) bool {
    if (holder == 0) return false;
    const index = ensureSlotLocked(id) orelse return false;
    const slot = &table[index];
    if (slot.holder != 0) return slot.holder == holder;
    // Free.  A suspended claim by another holder is forfeited: the lease was
    // released while that holder slept, so it no longer owns anything.
    slot.suspended = 0;
    slot.holder = holder;
    slot.acquires += 1;
    return true;
}

fn releaseLocked(id: i64, holder: u64) bool {
    if (holder == 0) return false;
    const index = findSlotLocked(id) orelse return false;
    const slot = &table[index];
    if (slot.holder != holder) return false;
    slot.holder = 0;
    slot.releases += 1;
    return true;
}

fn reacquireLocked(id: i64, holder: u64) bool {
    if (holder == 0) return false;
    const index = findSlotLocked(id) orelse return false;
    const slot = &table[index];
    if (slot.holder == holder) return true;
    if (slot.holder != 0 or slot.suspended != holder) return false;
    slot.holder = holder;
    slot.suspended = 0;
    slot.reacquires += 1;
    return true;
}

fn activeLocked(id: i64) bool {
    const index = findSlotLocked(id) orelse return false;
    return table[index].holder != 0;
}

/// Release every lease actively held by `holder`, parking a suspended claim.
/// Returns the number of leases released.
pub fn suspendHolder(holder: u64) usize {
    if (holder == 0) return 0;
    lockTable();
    defer unlockTable();
    var count: usize = 0;
    for (&table) |*slot| {
        if (slot.holder != holder) continue;
        slot.holder = 0;
        slot.suspended = holder;
        slot.suspended_releases += 1;
        count += 1;
    }
    return count;
}

/// Reacquire suspended claims for `holder`.  Claims taken by another holder in
/// the meantime are dropped.  Returns the number of leases reacquired.
pub fn resumeHolder(holder: u64) usize {
    if (holder == 0) return 0;
    lockTable();
    defer unlockTable();
    var count: usize = 0;
    for (&table) |*slot| {
        if (slot.suspended != holder) continue;
        if (slot.holder == 0) {
            slot.holder = holder;
            slot.reacquires += 1;
            count += 1;
        }
        slot.suspended = 0;
    }
    return count;
}

/// Permanently drop every active or suspended claim for `holder`.  Called when
/// a task body returns or is destroyed.  Returns the number of active leases
/// released.
pub fn endHolder(holder: u64) usize {
    if (holder == 0) return 0;
    lockTable();
    defer unlockTable();
    var count: usize = 0;
    for (&table) |*slot| {
        if (slot.holder == holder) {
            slot.holder = 0;
            slot.releases += 1;
            count += 1;
        }
        if (slot.suspended == holder) slot.suspended = 0;
    }
    return count;
}

/// Explicit acquire for an addressing test (no holder provider required).
pub fn acquireFor(id: i64, holder: u64) bool {
    lockTable();
    defer unlockTable();
    return acquireLocked(id, holder);
}

/// Explicit release for an addressing test (no holder provider required).
pub fn releaseFor(id: i64, holder: u64) bool {
    lockTable();
    defer unlockTable();
    return releaseLocked(id, holder);
}

/// Explicit reacquire for an addressing test (no holder provider required).
pub fn reacquireFor(id: i64, holder: u64) bool {
    lockTable();
    defer unlockTable();
    return reacquireLocked(id, holder);
}

/// Active-state query for an addressing test (no holder provider required).
pub fn activeFor(id: i64) bool {
    lockTable();
    defer unlockTable();
    return activeLocked(id);
}

/// Number of live lease ids currently owned by `holder` (diagnostics/tests).
pub fn heldCount(holder: u64) usize {
    lockTable();
    defer unlockTable();
    var count: usize = 0;
    for (&table) |*slot| {
        if (slot.holder == holder) count += 1;
    }
    return count;
}

/// Drop all leases and return the table to its initial state.  Only safe when
/// no task is running; `task.shutdownGlobal` calls it after the worker pool is
/// joined, and runtime tests use it for isolation.
pub fn reset() void {
    lockTable();
    defer unlockTable();
    for (&table) |*slot| slot.* = .{};
}

// ---------------------------------------------------------------------------
// JIT ABI
// ---------------------------------------------------------------------------

pub export fn e7_lease_acquire(id: i64) callconv(.c) i64 {
    if (id < 0) return 0;
    const holder = currentHolder();
    lockTable();
    defer unlockTable();
    return if (acquireLocked(id, holder)) 1 else 0;
}

pub export fn e7_lease_release(id: i64) callconv(.c) i64 {
    if (id < 0) return 0;
    const holder = currentHolder();
    lockTable();
    defer unlockTable();
    return if (releaseLocked(id, holder)) 1 else 0;
}

pub export fn e7_lease_reacquire(id: i64) callconv(.c) i64 {
    if (id < 0) return 0;
    const holder = currentHolder();
    lockTable();
    defer unlockTable();
    return if (reacquireLocked(id, holder)) 1 else 0;
}

pub export fn e7_lease_active(id: i64) callconv(.c) i64 {
    if (id < 0) return 0;
    lockTable();
    defer unlockTable();
    return if (activeLocked(id)) 1 else 0;
}

pub fn symbols() [4]Symbol {
    return .{
        .{ .name = "e7_lease_acquire", .address = @intFromPtr(&e7_lease_acquire), .callable = true },
        .{ .name = "e7_lease_release", .address = @intFromPtr(&e7_lease_release), .callable = true },
        .{ .name = "e7_lease_reacquire", .address = @intFromPtr(&e7_lease_reacquire), .callable = true },
        .{ .name = "e7_lease_active", .address = @intFromPtr(&e7_lease_active), .callable = true },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "leases acquire exclusively and do not double release" {
    reset();
    const alice: u64 = 0x1000;
    const bob: u64 = 0x2000;

    try std.testing.expect(acquireFor(7, alice));
    try std.testing.expect(activeFor(7));
    try std.testing.expectEqual(@as(usize, 1), heldCount(alice));

    // Same holder re-acquiring is idempotent; another holder is refused.
    try std.testing.expect(acquireFor(7, alice));
    try std.testing.expect(!acquireFor(7, bob));
    try std.testing.expect(!releaseFor(7, bob));
    try std.testing.expect(activeFor(7));

    try std.testing.expect(releaseFor(7, alice));
    try std.testing.expect(!activeFor(7));
    try std.testing.expectEqual(@as(usize, 0), heldCount(alice));

    // Double release is a no-op, not an error that frees another holder.
    try std.testing.expect(!releaseFor(7, alice));
    try std.testing.expect(acquireFor(7, bob));
    try std.testing.expect(!releaseFor(7, alice));
    try std.testing.expect(activeFor(7));
    try std.testing.expect(releaseFor(7, bob));
    try std.testing.expect(!activeFor(7));
}

test "suspension releases leases and resumption reacquires them" {
    reset();
    const alice: u64 = 0x1000;
    const bob: u64 = 0x2000;

    try std.testing.expect(acquireFor(11, alice));
    try std.testing.expect(acquireFor(12, alice));
    try std.testing.expectEqual(@as(usize, 2), suspendHolder(alice));

    // While suspended the leases are externally free.
    try std.testing.expect(!activeFor(11));
    try std.testing.expect(!activeFor(12));
    try std.testing.expect(!releaseFor(11, alice)); // already released by suspend

    // No contention: resuming reacquires both claims.
    try std.testing.expectEqual(@as(usize, 2), resumeHolder(alice));
    try std.testing.expect(activeFor(11));
    try std.testing.expect(activeFor(12));
    try std.testing.expect(releaseFor(11, alice));
    try std.testing.expect(releaseFor(12, alice));

    // Contention: if another holder takes the lease while suspended, the
    // original holder's claim is lost rather than stolen back.
    try std.testing.expect(acquireFor(13, alice));
    try std.testing.expectEqual(@as(usize, 1), suspendHolder(alice));
    try std.testing.expect(acquireFor(13, bob));
    try std.testing.expectEqual(@as(usize, 0), resumeHolder(alice));
    try std.testing.expect(activeFor(13));
    try std.testing.expect(!reacquireFor(13, alice));
    try std.testing.expect(releaseFor(13, bob));
    try std.testing.expectEqual(@as(usize, 0), resumeHolder(alice));
}

test "explicit reacquire and task end release suspended claims" {
    reset();
    const alice: u64 = 0x1000;

    try std.testing.expect(acquireFor(21, alice));
    try std.testing.expectEqual(@as(usize, 1), suspendHolder(alice));
    try std.testing.expect(reacquireFor(21, alice));
    try std.testing.expect(activeFor(21));
    try std.testing.expect(reacquireFor(21, alice)); // already held: idempotent
    try std.testing.expectEqual(@as(usize, 0), resumeHolder(alice));

    // End-of-task cleanup releases active leases and drops suspended claims.
    try std.testing.expectEqual(@as(usize, 1), endHolder(alice));
    try std.testing.expect(!activeFor(21));
    try std.testing.expect(acquireFor(22, alice));
    _ = suspendHolder(alice);
    try std.testing.expectEqual(@as(usize, 0), endHolder(alice));
    try std.testing.expect(!activeFor(22));
    try std.testing.expectEqual(@as(usize, 0), resumeHolder(alice));
}

test "exported ABI tracks the active holder" {
    reset();
    const TestHolder = struct {
        var token: u64 = 0x9000;
        fn provide() callconv(.c) u64 {
            return token;
        }
    };
    setHolderProvider(&TestHolder.provide);
    defer clearHolderProvider();

    try std.testing.expectEqual(@as(i64, 1), e7_lease_acquire(31));
    try std.testing.expectEqual(@as(i64, 1), e7_lease_active(31));
    try std.testing.expectEqual(@as(usize, 1), suspendHolder(TestHolder.token));
    try std.testing.expectEqual(@as(i64, 0), e7_lease_active(31));
    try std.testing.expectEqual(@as(i64, 1), e7_lease_reacquire(31));
    try std.testing.expectEqual(@as(i64, 1), e7_lease_active(31));
    try std.testing.expectEqual(@as(i64, 1), e7_lease_release(31));
    try std.testing.expectEqual(@as(i64, 0), e7_lease_release(31));
    try std.testing.expectEqual(@as(i64, 0), e7_lease_acquire(-1));
    try std.testing.expectEqual(@as(i64, 0), e7_lease_active(-1));
}

test "lease table is bounded" {
    reset();
    defer reset();
    const holder: u64 = 0x1000;
    var acquired: usize = 0;
    for (0..max_leases) |id| {
        if (acquireFor(@intCast(id), holder)) acquired += 1;
    }
    try std.testing.expectEqual(max_leases, acquired);
    // A full table refuses new ids but still reports existing leases.
    try std.testing.expect(!acquireFor(@intCast(max_leases), holder));
    try std.testing.expect(activeFor(0));
    try std.testing.expectEqual(max_leases, endHolder(holder));
    try std.testing.expect(!activeFor(0));
}
