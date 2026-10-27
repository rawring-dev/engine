//! Stackful async task runtime.
//!
//! Async functions are compiled as normal JIT bodies.  A task owns a separate
//! stack and a ucontext; `e7_task_await` suspends the current task and resumes
//! its waiter when the child completes.  The shared queue is serviced by a
//! worker pool, so runnable tasks execute concurrently and a suspended task's
//! stack can be resumed by any worker.  Each worker owns a deque; idle workers
//! steal from other deques, and externally spawned work enters a global
//! injector queue.

const std = @import("std");
const lease = @import("lease.zig");
const c = @cImport({
    @cInclude("ucontext.h");
    @cInclude("pthread.h");
    @cInclude("unistd.h");
});

pub const Error = error{
    OutOfMemory,
    ThreadFailed,
    NotInitialized,
    TooManyArguments,
};

pub const max_args = 8;
pub const cancelled_result: i64 = std.math.minInt(i64);
pub const stack_size = 1 << 20;

const State = enum { lazy, queued, running, waiting, done, canceled };

const Task = struct {
    ctx: c.ucontext_t = undefined,
    stack: []u8,
    entry: usize,
    args: [max_args]i64 = [_]i64{0} ** max_args,
    argc: usize,
    state: State = .lazy,
    result: i64 = 0,
    waiter: ?*Task = null,
    cancel_requested: bool = false,
    manual: bool = false,
    detached: bool = false,
    runtime: *Runtime,
};

const Worker = struct {
    runtime: *Runtime,
    sched: c.ucontext_t = undefined,
    current: ?*Task = null,
    thread: std.Thread = undefined,
    deque: std.ArrayList(*Task) = .empty,
    deque_mutex: c.pthread_mutex_t = undefined,
};

const Injector = struct {
    items: std.ArrayList(*Task) = .empty,
    mutex: c.pthread_mutex_t = undefined,
    available: c.pthread_cond_t = undefined,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    injector: Injector = .{},
    workers: std.ArrayList(*Worker) = .empty,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    completion_mutex: c.pthread_mutex_t = undefined,
    completion: c.pthread_cond_t = undefined,

    pub fn init(allocator: std.mem.Allocator, worker_count: usize) Error!*Runtime {
        const runtime = try allocator.create(Runtime);
        runtime.* = .{ .allocator = allocator };
        _ = c.pthread_mutex_init(&runtime.injector.mutex, null);
        _ = c.pthread_cond_init(&runtime.injector.available, null);
        _ = c.pthread_mutex_init(&runtime.completion_mutex, null);
        _ = c.pthread_cond_init(&runtime.completion, null);
        errdefer allocator.destroy(runtime);
        const count = @max(@as(usize, 1), worker_count);
        try runtime.workers.ensureTotalCapacity(allocator, count);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const worker = try allocator.create(Worker);
            worker.* = .{ .runtime = runtime };
            _ = c.pthread_mutex_init(&worker.deque_mutex, null);
            runtime.workers.appendAssumeCapacity(worker);
            worker.thread = std.Thread.spawn(.{}, workerMain, .{worker}) catch return error.ThreadFailed;
        }
        return runtime;
    }

    pub fn deinit(self: *Runtime) void {
        self.shutdown.store(true, .release);
        _ = c.pthread_mutex_lock(&self.injector.mutex);
        _ = c.pthread_cond_broadcast(&self.injector.available);
        _ = c.pthread_mutex_unlock(&self.injector.mutex);
        for (self.workers.items) |worker| worker.thread.join();
        for (self.workers.items) |worker| {
            worker.deque.deinit(self.allocator);
            _ = c.pthread_mutex_destroy(&worker.deque_mutex);
            self.allocator.destroy(worker);
        }
        self.workers.deinit(self.allocator);
        self.injector.items.deinit(self.allocator);
        _ = c.pthread_cond_destroy(&self.injector.available);
        _ = c.pthread_mutex_destroy(&self.injector.mutex);
        _ = c.pthread_cond_destroy(&self.completion);
        _ = c.pthread_mutex_destroy(&self.completion_mutex);
        self.allocator.destroy(self);
    }

    fn enqueue(self: *Runtime, task: *Task) void {
        if (current_worker) |worker| {
            _ = c.pthread_mutex_lock(&worker.deque_mutex);
            defer _ = c.pthread_mutex_unlock(&worker.deque_mutex);
            if (task.state == .done or task.state == .canceled) return;
            task.state = .queued;
            worker.deque.append(self.allocator, task) catch return;
            _ = c.pthread_mutex_lock(&self.injector.mutex);
            _ = c.pthread_cond_signal(&self.injector.available);
            _ = c.pthread_mutex_unlock(&self.injector.mutex);
            return;
        }
        _ = c.pthread_mutex_lock(&self.injector.mutex);
        defer _ = c.pthread_mutex_unlock(&self.injector.mutex);
        if (task.state == .done or task.state == .canceled) return;
        task.state = .queued;
        self.injector.items.append(self.allocator, task) catch return;
        _ = c.pthread_cond_signal(&self.injector.available);
    }

    fn popLocal(self: *Runtime, worker: *Worker) ?*Task {
        _ = self;
        _ = c.pthread_mutex_lock(&worker.deque_mutex);
        defer _ = c.pthread_mutex_unlock(&worker.deque_mutex);
        return worker.deque.pop();
    }

    fn popInjector(self: *Runtime) ?*Task {
        _ = c.pthread_mutex_lock(&self.injector.mutex);
        defer _ = c.pthread_mutex_unlock(&self.injector.mutex);
        return self.injector.items.pop();
    }

    fn steal(self: *Runtime, thief: *Worker) ?*Task {
        for (self.workers.items) |victim| {
            if (victim == thief) continue;
            _ = c.pthread_mutex_lock(&victim.deque_mutex);
            const stolen = victim.deque.pop();
            _ = c.pthread_mutex_unlock(&victim.deque_mutex);
            if (stolen) |task| return task;
        }
        return null;
    }

    fn next(self: *Runtime, worker: *Worker) ?*Task {
        while (true) {
            if (self.shutdown.load(.acquire)) return null;
            if (self.popLocal(worker)) |task| return task;
            if (self.popInjector()) |task| return task;
            if (self.steal(worker)) |task| return task;

            _ = c.pthread_mutex_lock(&self.injector.mutex);
            while (self.injector.items.items.len == 0 and !self.shutdown.load(.acquire)) {
                _ = c.pthread_cond_wait(&self.injector.available, &self.injector.mutex);
            }
            _ = c.pthread_mutex_unlock(&self.injector.mutex);
        }
    }

    fn complete(self: *Runtime, task: *Task, result: i64) void {
        // Completion and waiter publication are serialized with `awaitTask`
        // through the completion mutex; otherwise a fast child could finish
        // between the parent's state check and its waiter registration.
        _ = c.pthread_mutex_lock(&self.completion_mutex);
        task.result = result;
        task.state = .done;
        const waiter = task.waiter;
        task.waiter = null;
        if (waiter) |parent| self.enqueue(parent);
        _ = c.pthread_cond_broadcast(&self.completion);
        _ = c.pthread_mutex_unlock(&self.completion_mutex);
    }

    fn awaitTask(self: *Runtime, task: *Task) i64 {
        if (current_task) |parent| {
            if (parent == task) return 0;
            const holder = @intFromPtr(parent);
            _ = c.pthread_mutex_lock(&self.completion_mutex);
            if (task.state == .done) {
                const result = task.result;
                _ = c.pthread_mutex_unlock(&self.completion_mutex);
                self.destroyTask(task);
                return result;
            }
            parent.state = .waiting;
            task.waiter = parent;
            // Suspension hands back every external lease the task holds; it is
            // reacquired below once the scheduler resumes this task.
            _ = lease.suspendHolder(holder);
            if (task.state == .lazy and !task.manual) self.enqueue(task);
            _ = c.pthread_mutex_unlock(&self.completion_mutex);
            yieldCurrent();
            _ = lease.resumeHolder(holder);
            const result = task.result;
            self.destroyTask(task);
            return result;
        }
        _ = c.pthread_mutex_lock(&self.completion_mutex);
        if (task.state == .done) {
            const result = task.result;
            _ = c.pthread_mutex_unlock(&self.completion_mutex);
            self.destroyTask(task);
            return result;
        }
        if (task.state == .lazy and !task.manual) self.enqueue(task);
        while (task.state != .done) _ = c.pthread_cond_wait(&self.completion, &self.completion_mutex);
        _ = c.pthread_mutex_unlock(&self.completion_mutex);
        const result = task.result;
        self.destroyTask(task);
        return result;
    }

    pub fn create(self: *Runtime, entry: usize, args: []const i64) Error!*Task {
        if (args.len > max_args) return error.TooManyArguments;
        const task = try self.allocator.create(Task);
        errdefer self.allocator.destroy(task);
        const stack = try std.heap.page_allocator.alloc(u8, stack_size);
        errdefer std.heap.page_allocator.free(stack);
        task.* = .{
            .stack = stack,
            .entry = entry,
            .argc = args.len,
            .runtime = self,
        };
        @memcpy(task.args[0..args.len], args);
        if (c.getcontext(&task.ctx) != 0) return error.ThreadFailed;
        task.ctx.uc_stack.ss_sp = stack.ptr;
        task.ctx.uc_stack.ss_size = stack.len;
        task.ctx.uc_link = null;
        const entry_ptr: *const fn () callconv(.c) void = @ptrCast(&taskEntry);
        c.makecontext(&task.ctx, entry_ptr, 1, task);
        return task;
    }

    pub fn spawn(self: *Runtime, task: *Task) void {
        self.enqueue(task);
    }

    pub fn detach(self: *Runtime, task: *Task) void {
        task.detached = true;
        if (task.state == .lazy) self.enqueue(task);
    }

    pub fn cancel(self: *Runtime, task: *Task) void {
        _ = c.pthread_mutex_lock(&self.completion_mutex);
        task.cancel_requested = true;
        if (task.state == .lazy or task.state == .queued) {
            task.state = .done;
            task.result = cancelled_result;
            const waiter = task.waiter;
            task.waiter = null;
            if (waiter) |parent| self.enqueue(parent);
            _ = c.pthread_cond_broadcast(&self.completion);
        }
        _ = c.pthread_mutex_unlock(&self.completion_mutex);
    }

    fn destroyTask(self: *Runtime, task: *Task) void {
        if (task.stack.len > 0) std.heap.page_allocator.free(task.stack);
        self.allocator.destroy(task);
    }

    pub fn createEvent(self: *Runtime) Error!*Task {
        const task = try self.allocator.create(Task);
        task.* = .{
            .stack = &.{},
            .entry = 0,
            .argc = 0,
            .runtime = self,
            .manual = true,
        };
        return task;
    }

    pub fn completeEvent(self: *Runtime, task: *Task) void {
        _ = c.pthread_mutex_lock(&self.completion_mutex);
        task.result = 0;
        task.state = .done;
        const waiter = task.waiter;
        task.waiter = null;
        if (waiter) |parent| self.enqueue(parent);
        _ = c.pthread_cond_broadcast(&self.completion);
        _ = c.pthread_mutex_unlock(&self.completion_mutex);
    }
};

const TriggerState = struct {
    mutex: c.pthread_mutex_t = undefined,
    active: bool = false,
    pending: bool = false,
    pending_turn: ?*Task = null,
    pending_followers: std.ArrayList(*Task) = .empty,
    active_followers: std.ArrayList(*Task) = .empty,
};

var trigger_table_mutex: c.pthread_mutex_t = undefined;
var trigger_table_initialized: bool = false;
var trigger_states: [256]?*TriggerState = [_]?*TriggerState{null} ** 256;

fn getTrigger(id: usize) ?*TriggerState {
    if (id >= trigger_states.len) return null;
    if (!trigger_table_initialized) {
        _ = c.pthread_mutex_init(&trigger_table_mutex, null);
        trigger_table_initialized = true;
    }
    _ = c.pthread_mutex_lock(&trigger_table_mutex);
    defer _ = c.pthread_mutex_unlock(&trigger_table_mutex);
    if (trigger_states[id]) |state| return state;
    const runtime = global_runtime orelse return null;
    const state = runtime.allocator.create(TriggerState) catch return null;
    state.* = .{};
    _ = c.pthread_mutex_init(&state.mutex, null);
    trigger_states[id] = state;
    return state;
}

fn destroyTriggers() void {
    if (!trigger_table_initialized) return;
    for (trigger_states) |maybe_state| {
        const state = maybe_state orelse continue;
        const runtime = global_runtime orelse continue;
        state.pending_followers.deinit(runtime.allocator);
        state.active_followers.deinit(runtime.allocator);
        _ = c.pthread_mutex_destroy(&state.mutex);
        runtime.allocator.destroy(state);
    }
    @memset(&trigger_states, null);
    _ = c.pthread_mutex_destroy(&trigger_table_mutex);
    trigger_table_initialized = false;
}

fn awaitEvent(event: *Task) void {
    const runtime = global_runtime orelse return;
    _ = runtime.awaitTask(event);
}

fn completeFollowerList(runtime: *Runtime, list: *std.ArrayList(*Task)) void {
    for (list.items) |event| runtime.completeEvent(event);
    list.clearRetainingCapacity();
}

threadlocal var current_task: ?*Task = null;
threadlocal var current_worker: ?*Worker = null;
/// Holder token for threads that are not running a task (e.g. the main thread
/// awaiting a task or calling the lease ABI directly).  Task pointers are
/// user-space addresses with the high bit clear, so high-bit tokens cannot
/// collide with them.
threadlocal var standalone_holder: u64 = 0;

/// Lease-holder token for the code currently running on this thread.  The task
/// runtime installs this as `lease.holder_provider`, so `e7_lease_*` calls made
/// from JITed code are attributed to the running task instead of the thread.
pub fn currentHolderToken() callconv(.c) u64 {
    if (current_task) |task| return @intCast(@intFromPtr(task));
    if (standalone_holder == 0) {
        const thread_id: u64 = @intCast(std.Thread.getCurrentId());
        standalone_holder = (@as(u64, 1) << 63) | (thread_id & ((@as(u64, 1) << 62) - 1)) | 1;
    }
    return standalone_holder;
}

fn taskEntry(task: *Task) callconv(.c) void {
    const result = callEntry(task.entry, @intCast(@intFromPtr(task)), task.args[0..task.argc]);
    // A task owns no external leases after its body returns, whether or not it
    // released them explicitly.
    _ = lease.endHolder(@intCast(@intFromPtr(task)));
    task.runtime.complete(task, result);
    if (current_worker) |worker| {
        task.state = .done;
        _ = c.swapcontext(&task.ctx, &worker.sched);
    }
    unreachable;
}

fn callEntry(entry: usize, task_ptr: i64, args: []const i64) i64 {
    // Async bodies receive the task pointer plus their compiled parameters.
    // Systems with several world parameters (resources + queries + Commands)
    // routinely exceed four, so every arity up to `max_args` is covered.
    const F0 = *const fn (i64) callconv(.c) i64;
    const F1 = *const fn (i64, i64) callconv(.c) i64;
    const F2 = *const fn (i64, i64, i64) callconv(.c) i64;
    const F3 = *const fn (i64, i64, i64, i64) callconv(.c) i64;
    const F4 = *const fn (i64, i64, i64, i64, i64) callconv(.c) i64;
    const F5 = *const fn (i64, i64, i64, i64, i64, i64) callconv(.c) i64;
    const F6 = *const fn (i64, i64, i64, i64, i64, i64, i64) callconv(.c) i64;
    const F7 = *const fn (i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) i64;
    const F8 = *const fn (i64, i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) i64;
    return switch (args.len) {
        0 => @as(F0, @ptrFromInt(entry))(task_ptr),
        1 => @as(F1, @ptrFromInt(entry))(task_ptr, args[0]),
        2 => @as(F2, @ptrFromInt(entry))(task_ptr, args[0], args[1]),
        3 => @as(F3, @ptrFromInt(entry))(task_ptr, args[0], args[1], args[2]),
        4 => @as(F4, @ptrFromInt(entry))(task_ptr, args[0], args[1], args[2], args[3]),
        5 => @as(F5, @ptrFromInt(entry))(task_ptr, args[0], args[1], args[2], args[3], args[4]),
        6 => @as(F6, @ptrFromInt(entry))(task_ptr, args[0], args[1], args[2], args[3], args[4], args[5]),
        7 => @as(F7, @ptrFromInt(entry))(task_ptr, args[0], args[1], args[2], args[3], args[4], args[5], args[6]),
        8 => @as(F8, @ptrFromInt(entry))(task_ptr, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]),
        else => 0,
    };
}

fn workerMain(worker: *Worker) void {
    current_worker = worker;
    while (worker.runtime.next(worker)) |task| {
        if (task.state == .done or task.state == .canceled) continue;
        worker.current = task;
        current_task = task;
        task.state = .running;
        _ = c.swapcontext(&worker.sched, &task.ctx);
        current_task = null;
        worker.current = null;
        if (task.detached and task.state == .done) worker.runtime.destroyTask(task);
    }
}

fn yieldCurrent() void {
    const task = current_task orelse return;
    const worker = current_worker orelse return;
    _ = c.swapcontext(&task.ctx, &worker.sched);
}

// ---------------------------------------------------------------------------
// JIT ABI
// ---------------------------------------------------------------------------

var global_runtime: ?*Runtime = null;
var inline_execution: bool = false;

pub fn ensureGlobal(allocator: std.mem.Allocator) Error!void {
    if (global_runtime != null) return;
    const cpus = std.Thread.getCpuCount() catch 2;
    lease.setHolderProvider(&currentHolderToken);
    global_runtime = try Runtime.init(allocator, @max(@as(usize, 2), @min(cpus, 8)));
}

pub fn shutdownGlobal() void {
    if (global_runtime) |runtime| {
        destroyTriggers();
        runtime.deinit();
        global_runtime = null;
    }
    lease.clearHolderProvider();
    lease.reset();
}

pub export fn e7_task_create(entry: usize, argc: i64, args: [*]const i64) callconv(.c) i64 {
    const runtime = global_runtime orelse return 0;
    if (argc < 0 or argc > max_args) return 0;
    const task = runtime.create(entry, args[0..@intCast(argc)]) catch return 0;
    if (inline_execution) {
        task.result = callEntry(entry, @intCast(@intFromPtr(task)), task.args[0..task.argc]);
        task.state = .done;
    }
    return @intCast(@intFromPtr(task));
}

/// Run newly created tasks synchronously on the creating thread.  The host
/// enables this for `engine-run` so SDL/Vulkan work happens on the main thread.
pub export fn e7_task_set_inline(enabled: i64) callconv(.c) void {
    inline_execution = enabled != 0;
}

pub export fn e7_task_spawn(task_ptr: i64) callconv(.c) i64 {
    const runtime = global_runtime orelse return 0;
    if (task_ptr == 0) return 0;
    const task: *Task = @ptrFromInt(@as(usize, @intCast(task_ptr)));
    if (inline_execution and task.state == .done) return task_ptr;
    runtime.spawn(task);
    return task_ptr;
}

pub export fn e7_task_await(task_ptr: i64) callconv(.c) i64 {
    const runtime = global_runtime orelse return 0;
    if (task_ptr == 0) return 0;
    const task: *Task = @ptrFromInt(@as(usize, @intCast(task_ptr)));
    return runtime.awaitTask(task);
}

pub export fn e7_task_detach(task_ptr: i64) callconv(.c) i64 {
    const runtime = global_runtime orelse return 0;
    if (task_ptr == 0) return 0;
    const task: *Task = @ptrFromInt(@as(usize, @intCast(task_ptr)));
    runtime.detach(task);
    return 0;
}

pub export fn e7_task_cancel(task_ptr: i64) callconv(.c) i64 {
    const runtime = global_runtime orelse return 0;
    if (task_ptr == 0) return 0;
    const task: *Task = @ptrFromInt(@as(usize, @intCast(task_ptr)));
    runtime.cancel(task);
    return 0;
}

pub export fn e7_trigger_enter(trigger_id: i64) callconv(.c) i64 {
    const runtime = global_runtime orelse return 0;
    if (trigger_id < 0) return 0;
    const state = getTrigger(@intCast(trigger_id)) orelse return 0;
    const id: usize = @intCast(trigger_id);

    _ = c.pthread_mutex_lock(&state.mutex);
    if (!state.active) {
        state.active = true;
        _ = c.pthread_mutex_unlock(&state.mutex);
        return 0;
    }
    if (!state.pending) {
        state.pending = true;
        const event = runtime.createEvent() catch {
            _ = c.pthread_mutex_unlock(&state.mutex);
            return 0;
        };
        state.pending_turn = event;
        _ = c.pthread_mutex_unlock(&state.mutex);
        awaitEvent(event);
        return 1;
    }
    const event = runtime.createEvent() catch {
        _ = c.pthread_mutex_unlock(&state.mutex);
        return 2;
    };
    state.pending_followers.append(runtime.allocator, event) catch {
        _ = c.pthread_mutex_unlock(&state.mutex);
        return 2;
    };
    _ = c.pthread_mutex_unlock(&state.mutex);
    awaitEvent(event);
    _ = id;
    return 2;
}

pub export fn e7_trigger_leave(trigger_id: i64) callconv(.c) i64 {
    const runtime = global_runtime orelse return 0;
    if (trigger_id < 0) return 0;
    const state = getTrigger(@intCast(trigger_id)) orelse return 0;

    var followers: std.ArrayList(*Task) = .empty;
    var turn: ?*Task = null;
    _ = c.pthread_mutex_lock(&state.mutex);
    followers = state.active_followers;
    state.active_followers = .empty;
    if (state.pending) {
        state.pending = false;
        state.active = true;
        state.active_followers = state.pending_followers;
        state.pending_followers = .empty;
        turn = state.pending_turn;
        state.pending_turn = null;
    } else {
        state.active = false;
    }
    _ = c.pthread_mutex_unlock(&state.mutex);

    completeFollowerList(runtime, &followers);
    followers.deinit(runtime.allocator);
    if (turn) |event| runtime.completeEvent(event);
    return 0;
}

pub fn symbols() [7]@import("intrinsics.zig").Symbol {
    return .{
        .{ .name = "e7_task_create", .address = @intFromPtr(&e7_task_create), .callable = true },
        .{ .name = "e7_task_spawn", .address = @intFromPtr(&e7_task_spawn), .callable = true },
        .{ .name = "e7_task_await", .address = @intFromPtr(&e7_task_await), .callable = true },
        .{ .name = "e7_task_detach", .address = @intFromPtr(&e7_task_detach), .callable = true },
        .{ .name = "e7_task_cancel", .address = @intFromPtr(&e7_task_cancel), .callable = true },
        .{ .name = "e7_trigger_enter", .address = @intFromPtr(&e7_trigger_enter), .callable = true },
        .{ .name = "e7_trigger_leave", .address = @intFromPtr(&e7_trigger_leave), .callable = true },
    };
}

test "stackful tasks await nested tasks" {
    try ensureGlobal(std.testing.allocator);
    defer shutdownGlobal();

    const Child = struct {
        fn run(task: i64, arg: i64) callconv(.c) i64 {
            _ = task;
            return arg * 2;
        }
    };
    const Parent = struct {
        fn run(task: i64, arg: i64) callconv(.c) i64 {
            _ = task;
            var child_arg = arg + 1;
            const child = e7_task_create(@intFromPtr(&Child.run), 1, @ptrCast(&child_arg));
            return e7_task_await(child) + 1;
        }
    };

    const arg: i64 = 10;
    const task = try global_runtime.?.create(@intFromPtr(&Parent.run), &.{arg});
    global_runtime.?.spawn(task);
    try std.testing.expectEqual(@as(i64, 23), global_runtime.?.awaitTask(task));
}

test "trigger invocations coalesce into one pending invocation" {
    try ensureGlobal(std.testing.allocator);
    defer shutdownGlobal();

    const Counter = struct {
        var runners = std.atomic.Value(usize).init(0);
        fn run(task: i64, arg: i64) callconv(.c) i64 {
            _ = task;
            _ = arg;
            const role = e7_trigger_enter(99);
            if (role != 2) {
                _ = runners.fetchAdd(1, .monotonic);
                _ = c.usleep(50_000);
                _ = e7_trigger_leave(99);
            }
            return role;
        }
    };

    const runtime = global_runtime.?;
    var tasks: [4]*Task = undefined;
    for (&tasks, 0..) |*slot, i| {
        slot.* = try runtime.create(@intFromPtr(&Counter.run), &.{@as(i64, @intCast(i))});
        runtime.spawn(slot.*);
    }
    for (tasks) |task| _ = runtime.awaitTask(task);
    try std.testing.expectEqual(@as(usize, 2), Counter.runners.load(.monotonic));
}

test "task leases release on suspend and reacquire on resume" {
    try ensureGlobal(std.testing.allocator);
    defer shutdownGlobal();

    const Child = struct {
        fn run(task: i64, arg: i64) callconv(.c) i64 {
            _ = task;
            _ = arg;
            // The parent is suspended, so it must not appear to hold its lease.
            const parent_lease = lease.e7_lease_active(41);
            // A lease acquired by a task is released when the task ends.
            _ = lease.e7_lease_acquire(42);
            return parent_lease;
        }
    };
    const Parent = struct {
        fn run(task: i64, arg: i64) callconv(.c) i64 {
            _ = task;
            _ = arg;
            const acquired = lease.e7_lease_acquire(41);
            const before = lease.e7_lease_active(41);
            var child_arg: i64 = 0;
            const child = e7_task_create(@intFromPtr(&Child.run), 1, @ptrCast(&child_arg));
            const child_saw = e7_task_await(child);
            const after = lease.e7_lease_active(41);
            const child_cleared = if (lease.e7_lease_active(42) == 0) @as(i64, 1) else 0;
            const released = lease.e7_lease_release(41);
            return acquired * 100_000 + before * 10_000 + child_saw * 1_000 +
                after * 100 + child_cleared * 10 + released;
        }
    };

    const task_handle = try global_runtime.?.create(@intFromPtr(&Parent.run), &.{0});
    global_runtime.?.spawn(task_handle);
    // acquired=1 before=1 child_saw=0 after=1 child_cleared=1 released=1
    try std.testing.expectEqual(@as(i64, 110_111), global_runtime.?.awaitTask(task_handle));
}
