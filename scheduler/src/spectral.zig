//! Multi-view spectral partitioning for a two-view bipartite graph.
//!
//! Model
//! -----
//! A BiSBM graph [holland1983] has row nodes `[n1]` and column nodes `[n2]`; an edge
//! `(i, j)` exists with a probability that depends only on the latent row
//! and column communities (Braun, 2023 [braun2023]).  The single-view
//! spectral method in that paper forms the row similarity matrix
//! `S = A A^T`, takes the top-`K` eigenvectors, row-normalizes them, and
//! clusters the resulting points.
//!
//! This module extends that construction to two independent edge views:
//!
//!     S_rows = (1 / V) * sum_v B_v B_v^T
//!     S_cols = (1 / V) * sum_v B_v^T B_v
//!
//! where `B_v` is the degree-normalized adjacency of view `v` (or raw
//! adjacency when `normalize = false`).  Averaging the view-specific
//! similarity matrices is the natural multi-view analogue of the BiSBM
//! similarity matrix; it keeps the problem a single symmetric
//! eigendecomposition per side instead of concatenating independent
//! embeddings.  Eigenvectors are obtained with LAPACK `dsyev` [anderson1999],
//! row-normalized as in Ng-Jordan-Weiss spectral clustering [ng2002],
//! and partitioned with deterministic k-means++ [arthur2007] and Lloyd
//! iterations [lloyd1982].  The broader spectral-clustering background is
//! surveyed in [vonluxburg2007].

const std = @import("std");
const lapack = @import("lapack.zig");

pub const Edge = struct {
    row: usize,
    col: usize,
    weight: f64 = 1.0,
};

pub const BipartiteView = struct {
    rows: usize,
    cols: usize,
    edges: []const Edge,
};

pub const Options = struct {
    row_clusters: usize,
    col_clusters: usize,
    /// Degree-normalize each view's adjacency before forming similarities.
    normalize: bool = true,
    /// Deterministic seed for k-means++ initialization.
    seed: u64 = 0x9e3779b97f4a7c15,
    max_kmeans_iterations: usize = 100,
    kmeans_tolerance: f64 = 1e-12,
};

pub const Partition = struct {
    row_labels: []usize,
    col_labels: []usize,
    /// Row-major `rows x row_clusters` spectral embedding.
    row_embedding: []f64,
    /// Row-major `cols x col_clusters` spectral embedding.
    col_embedding: []f64,
    /// Selected eigenvalues in descending order.
    row_eigenvalues: []f64,
    col_eigenvalues: []f64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Partition) void {
        self.allocator.free(self.row_labels);
        self.allocator.free(self.col_labels);
        self.allocator.free(self.row_embedding);
        self.allocator.free(self.col_embedding);
        self.allocator.free(self.row_eigenvalues);
        self.allocator.free(self.col_eigenvalues);
        self.* = undefined;
    }
};

pub const Error = error{
    EmptyGraph,
    InvalidDimensions,
    InvalidEdge,
    InvalidClusterCount,
    InvalidWeight,
    OutOfMemory,
    EigenDecompositionFailed,
    SingularMatrix,
};

/// Partition both sides of a two-view bipartite graph.
pub fn partition(
    allocator: std.mem.Allocator,
    views: [2]BipartiteView,
    options: Options,
) Error!Partition {
    const n1 = views[0].rows;
    const n2 = views[0].cols;
    if (n1 == 0 or n2 == 0) return error.EmptyGraph;
    if (options.row_clusters == 0 or options.row_clusters > n1) {
        return error.InvalidClusterCount;
    }
    if (options.col_clusters == 0 or options.col_clusters > n2) {
        return error.InvalidClusterCount;
    }
    for (views) |view| {
        if (view.rows != n1 or view.cols != n2) return error.InvalidDimensions;
        for (view.edges) |edge| {
            if (edge.row >= n1 or edge.col >= n2) return error.InvalidEdge;
            if (!std.math.isFinite(edge.weight) or edge.weight < 0) {
                return error.InvalidWeight;
            }
        }
    }

    const row_sim = try allocator.alloc(f64, n1 * n1);
    defer allocator.free(row_sim);
    const col_sim = try allocator.alloc(f64, n2 * n2);
    defer allocator.free(col_sim);
    @memset(row_sim, 0);
    @memset(col_sim, 0);

    for (views) |view| {
        const adjacency = try normalizedAdjacency(allocator, view, options.normalize);
        defer allocator.free(adjacency);
        accumulateRowSimilarity(row_sim, adjacency, n1, n2);
        accumulateColSimilarity(col_sim, adjacency, n1, n2);
    }
    for (row_sim) |*v| v.* /= 2.0;
    for (col_sim) |*v| v.* /= 2.0;

    const rows = try spectralEmbedding(
        allocator,
        row_sim,
        n1,
        options.row_clusters,
    );
    errdefer {
        allocator.free(rows.embedding);
        allocator.free(rows.eigenvalues);
    }
    const cols = try spectralEmbedding(
        allocator,
        col_sim,
        n2,
        options.col_clusters,
    );
    errdefer {
        allocator.free(cols.embedding);
        allocator.free(cols.eigenvalues);
    }

    const row_labels = try kmeans(
        allocator,
        rows.embedding,
        n1,
        options.row_clusters,
        options.row_clusters,
        options.seed,
        options.max_kmeans_iterations,
        options.kmeans_tolerance,
    );
    errdefer allocator.free(row_labels);

    const col_labels = try kmeans(
        allocator,
        cols.embedding,
        n2,
        options.col_clusters,
        options.col_clusters,
        options.seed ^ 0xa5a5a5a5a5a5a5a5,
        options.max_kmeans_iterations,
        options.kmeans_tolerance,
    );

    return .{
        .row_labels = row_labels,
        .col_labels = col_labels,
        .row_embedding = rows.embedding,
        .col_embedding = cols.embedding,
        .row_eigenvalues = rows.eigenvalues,
        .col_eigenvalues = cols.eigenvalues,
        .allocator = allocator,
    };
}

fn normalizedAdjacency(
    allocator: std.mem.Allocator,
    view: BipartiteView,
    normalize: bool,
) Error![]f64 {
    const a = try allocator.alloc(f64, view.rows * view.cols);
    errdefer allocator.free(a);
    @memset(a, 0);
    const row_degree = try allocator.alloc(f64, view.rows);
    defer allocator.free(row_degree);
    const col_degree = try allocator.alloc(f64, view.cols);
    defer allocator.free(col_degree);
    @memset(row_degree, 0);
    @memset(col_degree, 0);

    for (view.edges) |edge| {
        a[edge.row * view.cols + edge.col] += edge.weight;
        row_degree[edge.row] += edge.weight;
        col_degree[edge.col] += edge.weight;
    }

    if (normalize) {
        for (0..view.rows) |i| {
            for (0..view.cols) |j| {
                const idx = i * view.cols + j;
                if (a[idx] == 0) continue;
                const denom = @sqrt(row_degree[i] * col_degree[j]);
                if (denom > 0) a[idx] /= denom;
            }
        }
    }
    return a;
}

fn accumulateRowSimilarity(
    acc: []f64,
    a: []const f64,
    n1: usize,
    n2: usize,
) void {
    for (0..n1) |i| {
        for (i..n1) |j| {
            var sum: f64 = 0;
            for (0..n2) |l| sum += a[i * n2 + l] * a[j * n2 + l];
            acc[i * n1 + j] += sum;
            if (i != j) acc[j * n1 + i] += sum;
        }
    }
}

fn accumulateColSimilarity(
    acc: []f64,
    a: []const f64,
    n1: usize,
    n2: usize,
) void {
    // `n2 x n2` accumulation is symmetric; do it in place without a second
    // dense copy of the adjacency.
    for (0..n2) |i| {
        for (i..n2) |j| {
            var sum: f64 = 0;
            for (0..n1) |l| sum += a[l * n2 + i] * a[l * n2 + j];
            acc[i * n2 + j] += sum;
            if (i != j) acc[j * n2 + i] += sum;
        }
    }
}

const Embedding = struct {
    embedding: []f64,
    eigenvalues: []f64,
};

fn spectralEmbedding(
    allocator: std.mem.Allocator,
    similarity: []const f64,
    n: usize,
    k: usize,
) Error!Embedding {
    var eig = lapack.symmetricEigen(allocator, similarity, n) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.EigenDecompositionFailed,
    };
    defer eig.deinit();

    const embedding = try allocator.alloc(f64, n * k);
    errdefer allocator.free(embedding);
    const eigenvalues = try allocator.alloc(f64, k);
    errdefer allocator.free(eigenvalues);

    // LAPACK returns ascending eigenvalues; take the k largest and normalize
    // each point to the unit sphere (Ng-Jordan-Weiss).
    for (0..k) |j| {
        const src = n - 1 - j;
        eigenvalues[j] = eig.values[src];
        const column = eig.eigenvector(n, src);
        for (0..n) |i| embedding[i * k + j] = column[i];
    }
    for (0..n) |i| {
        const row = embedding[i * k ..][0..k];
        var nn: f64 = 0;
        for (row) |v| nn += v * v;
        nn = @sqrt(nn);
        if (nn > 1e-15) {
            for (row) |*v| v.* /= nn;
        }
    }

    return .{ .embedding = embedding, .eigenvalues = eigenvalues };
}

fn kmeans(
    allocator: std.mem.Allocator,
    points: []const f64,
    n: usize,
    dim: usize,
    k: usize,
    seed: u64,
    max_iterations: usize,
    tolerance: f64,
) Error![]usize {
    if (k == 1) {
        const labels = try allocator.alloc(usize, n);
        @memset(labels, 0);
        return labels;
    }

    const centers = try allocator.alloc(f64, k * dim);
    defer allocator.free(centers);
    const labels = try allocator.alloc(usize, n);
    errdefer allocator.free(labels);
    @memset(labels, std.math.maxInt(usize));

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    // k-means++ seeding.
    const first = rng.uintLessThan(usize, n);
    @memcpy(centers[0..dim], points[first * dim ..][0..dim]);
    const min_dist = try allocator.alloc(f64, n);
    defer allocator.free(min_dist);
    @memset(min_dist, std.math.inf(f64));

    var center_count: usize = 1;
    while (center_count < k) : (center_count += 1) {
        var total: f64 = 0;
        for (0..n) |i| {
            const d = squaredDistance(points[i * dim ..][0..dim], centers[(center_count - 1) * dim ..][0..dim]);
            if (d < min_dist[i]) min_dist[i] = d;
            total += min_dist[i];
        }
        if (!(total > 0) or !std.math.isFinite(total)) {
            // Degenerate/duplicate embedding: fill remaining centers by
            // evenly spaced points.
            for (center_count..k) |c| {
                const idx = (c * n) / k;
                @memcpy(centers[c * dim ..][0..dim], points[idx * dim ..][0..dim]);
            }
            break;
        }
        var target = rng.float(f64) * total;
        var chosen: usize = n - 1;
        for (0..n) |i| {
            target -= min_dist[i];
            if (target <= 0) {
                chosen = i;
                break;
            }
        }
        @memcpy(centers[center_count * dim ..][0..dim], points[chosen * dim ..][0..dim]);
    }

    const sums = try allocator.alloc(f64, k * dim);
    defer allocator.free(sums);
    const counts = try allocator.alloc(usize, k);
    defer allocator.free(counts);

    var iteration: usize = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        var changed = false;
        for (0..n) |i| {
            const p = points[i * dim ..][0..dim];
            var best: usize = 0;
            var best_dist = std.math.inf(f64);
            for (0..k) |c| {
                const d = squaredDistance(p, centers[c * dim ..][0..dim]);
                if (d < best_dist) {
                    best_dist = d;
                    best = c;
                }
            }
            if (labels[i] != best) {
                labels[i] = best;
                changed = true;
            }
        }

        @memset(sums, 0);
        @memset(counts, 0);
        for (0..n) |i| {
            const c = labels[i];
            counts[c] += 1;
            for (0..dim) |d| sums[c * dim + d] += points[i * dim + d];
        }

        var max_movement: f64 = 0;
        for (0..k) |c| {
            if (counts[c] == 0) {
                // Re-seed an empty cluster with the point farthest from its
                // current center.  This is deterministic and keeps Lloyd's
                // algorithm from collapsing.
                var far: usize = 0;
                var far_dist: f64 = -1;
                for (0..n) |i| {
                    const d = squaredDistance(points[i * dim ..][0..dim], centers[labels[i] * dim ..][0..dim]);
                    if (d > far_dist) {
                        far_dist = d;
                        far = i;
                    }
                }
                @memcpy(centers[c * dim ..][0..dim], points[far * dim ..][0..dim]);
                continue;
            }
            const inv = 1.0 / @as(f64, @floatFromInt(counts[c]));
            for (0..dim) |d| {
                const new_value = sums[c * dim + d] * inv;
                const delta = @abs(new_value - centers[c * dim + d]);
                max_movement = @max(max_movement, delta);
                centers[c * dim + d] = new_value;
            }
        }

        if (!changed or max_movement <= tolerance) break;
    }

    return labels;
}

fn squaredDistance(a: []const f64, b: []const f64) f64 {
    var sum: f64 = 0;
    for (a, b) |ai, bi| {
        const d = ai - bi;
        sum += d * d;
    }
    return sum;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn sameLabel(labels: []const usize, a: usize, b: usize) bool {
    return labels[a] == labels[b];
}

test "two-view BiSBM-style partition recovers block structure" {
    var edges_a: [64]Edge = undefined;
    var edges_b: [64]Edge = undefined;
    var count: usize = 0;
    for (0..8) |i| {
        for (0..8) |j| {
            const same_block = (i < 4) == (j < 4);
            edges_a[count] = .{
                .row = i,
                .col = j,
                .weight = if (same_block) 1.0 else 0.01,
            };
            edges_b[count] = .{
                .row = i,
                .col = j,
                .weight = if (same_block) 0.8 else 0.02,
            };
            count += 1;
        }
    }

    const views = [2]BipartiteView{
        .{ .rows = 8, .cols = 8, .edges = &edges_a },
        .{ .rows = 8, .cols = 8, .edges = &edges_b },
    };
    var result = try partition(std.testing.allocator, views, .{
        .row_clusters = 2,
        .col_clusters = 2,
        .seed = 7,
    });
    defer result.deinit();

    try std.testing.expect(sameLabel(result.row_labels, 0, 3));
    try std.testing.expect(sameLabel(result.row_labels, 4, 7));
    try std.testing.expect(!sameLabel(result.row_labels, 0, 4));
    try std.testing.expect(sameLabel(result.col_labels, 0, 3));
    try std.testing.expect(sameLabel(result.col_labels, 4, 7));
    try std.testing.expect(!sameLabel(result.col_labels, 0, 4));

    try std.testing.expect(result.row_eigenvalues[0] >= result.row_eigenvalues[1]);
    try std.testing.expect(result.col_eigenvalues[0] >= result.col_eigenvalues[1]);
}

test "single-cluster partition is total" {
    const edges = [_]Edge{
        .{ .row = 0, .col = 0, .weight = 1 },
        .{ .row = 1, .col = 1, .weight = 1 },
    };
    const views = [2]BipartiteView{
        .{ .rows = 2, .cols = 2, .edges = &edges },
        .{ .rows = 2, .cols = 2, .edges = &edges },
    };
    var result = try partition(std.testing.allocator, views, .{
        .row_clusters = 1,
        .col_clusters = 1,
    });
    defer result.deinit();

    for (result.row_labels) |label| try std.testing.expectEqual(@as(usize, 0), label);
    for (result.col_labels) |label| try std.testing.expectEqual(@as(usize, 0), label);
}

test "mismatched view dimensions are rejected" {
    const views = [2]BipartiteView{
        .{ .rows = 2, .cols = 2, .edges = &.{} },
        .{ .rows = 2, .cols = 3, .edges = &.{} },
    };
    try std.testing.expectError(error.InvalidDimensions, partition(
        std.testing.allocator,
        views,
        .{ .row_clusters = 1, .col_clusters = 1 },
    ));
}
