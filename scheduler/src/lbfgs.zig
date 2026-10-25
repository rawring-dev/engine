//! Limited-memory BFGS with a backtracking Armijo line search.
//!
//! This is the standard two-loop recursion described by Liu & Nocedal
//! [liu1989] and Nocedal & Wright [nocedal2006].  It stores the last `m`
//! correction pairs `(s_k, y_k)` and never forms the inverse Hessian.
//!
//! The line search deliberately favours a small, dependency-free
//! implementation: Armijo backtracking with a curvature guard on history
//! updates.  Callers that need strong-Wolfe guarantees can replace the inline
//! search loop without touching the quasi-Newton update.

const std = @import("std");

pub const EvalError = anyerror;

/// A caller-owned objective.  `eval` writes the gradient into `grad` and
/// returns the scalar objective value.
pub const Objective = struct {
    context: *anyopaque,
    eval: *const fn (context: *anyopaque, x: []const f64, grad: []f64) EvalError!f64,
};

pub const Options = struct {
    /// Number of correction pairs retained.  Typical values are 5-20.
    history: usize = 10,
    max_iterations: usize = 200,
    /// Stop when the Euclidean gradient norm falls below this value.
    gradient_tolerance: f64 = 1e-7,
    /// Stop when the accepted step is tiny relative to `|x|`.
    step_tolerance: f64 = 1e-12,
    /// Armijo sufficient-decrease constant.
    armijo_c1: f64 = 1e-4,
    /// Backtracking contraction factor.
    line_search_shrink: f64 = 0.5,
    max_line_search_steps: usize = 64,
    initial_step: f64 = 1.0,
};

pub const Status = enum {
    gradient_converged,
    step_converged,
    max_iterations,
};

pub const Result = struct {
    /// Owned by the result, length `x0.len`.
    x: []f64,
    f: f64,
    gradient_norm: f64,
    iterations: usize,
    status: Status,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.x);
        self.* = undefined;
    }
};

pub const Error = error{
    InvalidOptions,
    EmptyDomain,
    NonFiniteObjective,
    NonFiniteGradient,
    LineSearchFailed,
    ObjectiveFailed,
    OutOfMemory,
};

/// Minimize `objective` starting from `x0`.
pub fn minimize(
    allocator: std.mem.Allocator,
    objective: Objective,
    x0: []const f64,
    options: Options,
) Error!Result {
    if (x0.len == 0) return error.EmptyDomain;
    if (options.history == 0 or options.max_iterations == 0) return error.InvalidOptions;

    const n = x0.len;
    const m = options.history;

    var x = try allocator.dupe(f64, x0);
    errdefer allocator.free(x);
    var grad = try allocator.alloc(f64, n);
    defer allocator.free(grad);

    var f = objective.eval(objective.context, x, grad) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ObjectiveFailed,
    };
    if (!std.math.isFinite(f)) return error.NonFiniteObjective;
    if (!allFinite(grad)) return error.NonFiniteGradient;

    const direction = try allocator.alloc(f64, n);
    defer allocator.free(direction);
    var candidate_x = try allocator.alloc(f64, n);
    defer allocator.free(candidate_x);
    var candidate_grad = try allocator.alloc(f64, n);
    defer allocator.free(candidate_grad);

    var s_history = try allocator.alloc(f64, m * n);
    defer allocator.free(s_history);
    var y_history = try allocator.alloc(f64, m * n);
    defer allocator.free(y_history);
    var rho = try allocator.alloc(f64, m);
    defer allocator.free(rho);
    const alpha = try allocator.alloc(f64, m);
    defer allocator.free(alpha);

    var history_count: usize = 0;
    var gradient_norm = norm(grad);
    var iteration: usize = 0;

    while (iteration < options.max_iterations) : (iteration += 1) {
        if (gradient_norm <= options.gradient_tolerance) {
            return .{
                .x = x,
                .f = f,
                .gradient_norm = gradient_norm,
                .iterations = iteration,
                .status = .gradient_converged,
                .allocator = allocator,
            };
        }

        twoLoopRecursion(
            n,
            history_count,
            s_history,
            y_history,
            rho,
            alpha,
            grad,
            direction,
        );

        var directional_derivative = dot(grad, direction);
        if (!(directional_derivative < 0)) {
            // Lost positive definiteness (or a bad correction pair).  Reset
            // to steepest descent.
            history_count = 0;
            for (direction, grad) |*d, g| d.* = -g;
            directional_derivative = -dot(grad, grad);
        }

        var step = if (iteration == 0)
            @min(options.initial_step, 1.0 / @max(gradient_norm, 1e-12))
        else
            options.initial_step;

        var accepted = false;
        var candidate_f: f64 = undefined;
        var ls: usize = 0;
        while (ls < options.max_line_search_steps) : (ls += 1) {
            for (x, direction, 0..) |xi, di, i| candidate_x[i] = xi + step * di;
            candidate_f = objective.eval(objective.context, candidate_x, candidate_grad) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                step *= options.line_search_shrink;
                continue;
            };
            if (!std.math.isFinite(candidate_f)) {
                step *= options.line_search_shrink;
                continue;
            }
            if (candidate_f <= f + options.armijo_c1 * step * directional_derivative) {
                accepted = true;
                break;
            }
            step *= options.line_search_shrink;
        }
        if (!accepted) return error.LineSearchFailed;

        // s = x_new - x, y = g_new - g.  Keep the newest correction at the
        // end of the history arrays (shift on overflow).
        if (history_count == m) {
            std.mem.copyForwards(f64, s_history[0 .. (m - 1) * n], s_history[n..]);
            std.mem.copyForwards(f64, y_history[0 .. (m - 1) * n], y_history[n..]);
            std.mem.copyForwards(f64, rho[0 .. m - 1], rho[1..m]);
            history_count -= 1;
        }
        const s = s_history[history_count * n ..][0..n];
        const y = y_history[history_count * n ..][0..n];
        for (0..n) |i| {
            s[i] = candidate_x[i] - x[i];
            y[i] = candidate_grad[i] - grad[i];
        }
        const sy = dot(s, y);
        const curvature_threshold = 1e-12 * @max(1.0, norm(s) * norm(y));
        if (sy > curvature_threshold) {
            rho[history_count] = 1.0 / sy;
            history_count += 1;
        } else {
            // Curvature condition failed: discard history rather than
            // injecting an indefinite pair.
            history_count = 0;
        }

        const step_norm = norm(s);
        std.mem.swap([]f64, &x, &candidate_x);
        std.mem.swap([]f64, &grad, &candidate_grad);
        f = candidate_f;
        gradient_norm = norm(grad);

        if (step_norm <= options.step_tolerance * (1.0 + norm(x))) {
            return .{
                .x = x,
                .f = f,
                .gradient_norm = gradient_norm,
                .iterations = iteration + 1,
                .status = .step_converged,
                .allocator = allocator,
            };
        }
    }

    return .{
        .x = x,
        .f = f,
        .gradient_norm = gradient_norm,
        .iterations = options.max_iterations,
        .status = .max_iterations,
        .allocator = allocator,
    };
}

fn twoLoopRecursion(
    n: usize,
    history_count: usize,
    s_history: []const f64,
    y_history: []const f64,
    rho: []const f64,
    alpha: []f64,
    grad: []const f64,
    out: []f64,
) void {
    @memcpy(out, grad);

    // First loop, newest to oldest.
    var i = history_count;
    while (i > 0) {
        i -= 1;
        const s = s_history[i * n ..][0..n];
        const y = y_history[i * n ..][0..n];
        alpha[i] = rho[i] * dot(s, out);
        axpy(-alpha[i], y, out);
    }

    if (history_count > 0) {
        const s = s_history[(history_count - 1) * n ..][0..n];
        const y = y_history[(history_count - 1) * n ..][0..n];
        const yy = dot(y, y);
        const gamma = if (yy > 1e-30) dot(s, y) / yy else 1.0;
        scale(gamma, out);
    }

    // Second loop, oldest to newest.
    for (0..history_count) |j| {
        const s = s_history[j * n ..][0..n];
        const y = y_history[j * n ..][0..n];
        const beta = rho[j] * dot(y, out);
        axpy(alpha[j] - beta, s, out);
    }

    for (out) |*v| v.* = -v.*;
}

fn dot(a: []const f64, b: []const f64) f64 {
    var sum: f64 = 0;
    for (a, b) |ai, bi| sum += ai * bi;
    return sum;
}

fn norm(a: []const f64) f64 {
    return @sqrt(dot(a, a));
}

fn scale(alpha: f64, a: []f64) void {
    for (a) |*v| v.* *= alpha;
}

fn axpy(alpha: f64, x: []const f64, y: []f64) void {
    for (y, x) |*yi, xi| yi.* += alpha * xi;
}

fn allFinite(xs: []const f64) bool {
    for (xs) |v| if (!std.math.isFinite(v)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Quadratic = struct {
    target: [3]f64,
    /// Diagonal curvature; allows mildly ill-conditioned tests.
    curvature: [3]f64 = .{ 1, 1, 1 },
};

fn quadraticEval(context: *anyopaque, x: []const f64, grad: []f64) EvalError!f64 {
    const q: *Quadratic = @ptrCast(@alignCast(context));
    var f: f64 = 0;
    for (0..x.len) |i| {
        const d = x[i] - q.target[i];
        f += 0.5 * q.curvature[i] * d * d;
        grad[i] = q.curvature[i] * d;
    }
    return f;
}

test "L-BFGS minimizes a shifted anisotropic quadratic" {
    var problem = Quadratic{
        .target = .{ 1.5, -2.0, 0.25 },
        .curvature = .{ 1.0, 10.0, 100.0 },
    };
    const x0 = [_]f64{ 0, 0, 0 };

    var result = try minimize(std.testing.allocator, .{
        .context = &problem,
        .eval = quadraticEval,
    }, &x0, .{ .history = 5, .max_iterations = 500 });
    defer result.deinit();

    try std.testing.expect(result.status == .gradient_converged);
    for (0..3) |i| {
        try std.testing.expectApproxEqAbs(problem.target[i], result.x[i], 1e-6);
    }
}

test "L-BFGS reaches the Rosenbrock valley" {
    const Rosenbrock = struct {
        fn eval(_: *anyopaque, x: []const f64, grad: []f64) EvalError!f64 {
            const a: f64 = x[0];
            const b: f64 = x[1];
            const t1 = b - a * a;
            const t2 = 1.0 - a;
            grad[0] = -400.0 * a * t1 - 2.0 * t2;
            grad[1] = 200.0 * t1;
            return 100.0 * t1 * t1 + t2 * t2;
        }
    };

    const x0 = [_]f64{ -1.2, 1.0 };
    var result = try minimize(std.testing.allocator, .{
        .context = undefined,
        .eval = Rosenbrock.eval,
    }, &x0, .{ .history = 10, .max_iterations = 1000, .gradient_tolerance = 1e-6 });
    defer result.deinit();

    try std.testing.expect(result.f < 1e-8);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.x[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.x[1], 1e-3);
}
