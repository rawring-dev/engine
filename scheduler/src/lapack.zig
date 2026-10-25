//! Minimal, explicit Fortran-ABI bindings to the parts of LAPACK/BLAS used by
//! the scheduler.
//!
//! The declarations use the reference implementation's symbol names
//! (`dgesv_`, `dsyev_`, ...) and the column-major convention shared by
//! LAPACK, BLAS, and Fortran.  All matrices crossing this boundary are
//! column-major even though the rest of the project is row-major; conversion
//! happens in the small helpers below.
//!
//! References:
//!   [anderson1999] LAPACK Users' Guide (3rd ed.), SIAM, 1999.
//!   [blackford2002] "An Updated Set of Basic Linear Algebra Subprograms
//!                    (BLAS)", ACM TOMS 28(2), 2002.

const std = @import("std");

pub const lapack_int = i32;

// ---------------------------------------------------------------------------
// Raw Fortran ABI
// ---------------------------------------------------------------------------

/// Solves `A * X = B` for a general square matrix using LU with partial
/// pivoting.  `A` (lda x n) and `B` (ldb x nrhs) are overwritten; `ipiv`
/// receives the pivot indices.
pub extern "c" fn dgesv_(
    n: *const lapack_int,
    nrhs: *const lapack_int,
    a: [*]f64,
    lda: *const lapack_int,
    ipiv: [*]lapack_int,
    b: [*]f64,
    ldb: *const lapack_int,
    info: *lapack_int,
) void;

/// Computes all eigenvalues and (optionally) eigenvectors of a real symmetric
/// matrix.  `a` is column-major and is overwritten by the eigenvectors when
/// `jobz = 'V'`; `w` receives eigenvalues in ascending order.
pub extern "c" fn dsyev_(
    jobz: [*]const u8,
    uplo: [*]const u8,
    n: *const lapack_int,
    a: [*]f64,
    lda: *const lapack_int,
    w: [*]f64,
    work: [*]f64,
    lwork: *const lapack_int,
    info: *const lapack_int,
) void;

/// General matrix-matrix multiply: `C := alpha * op(A) * op(B) + beta * C`.
/// Included for callers that need to keep dense linear algebra on the BLAS
/// side of the boundary.
pub extern "c" fn dgemm_(
    transa: [*]const u8,
    transb: [*]const u8,
    m: *const lapack_int,
    n: *const lapack_int,
    k: *const lapack_int,
    alpha: *const f64,
    a: [*]const f64,
    lda: *const lapack_int,
    b: [*]const f64,
    ldb: *const lapack_int,
    beta: *const f64,
    c: [*]f64,
    ldc: *const lapack_int,
) void;

// ---------------------------------------------------------------------------
// Safe-ish helpers
// ---------------------------------------------------------------------------

pub const LapackError = error{
    SingularMatrix,
    InvalidArgument,
    EigenDecompositionFailed,
    OutOfMemory,
};

pub const Eigen = struct {
    /// Eigenvalues in ascending order.
    values: []f64,
    /// Column-major `n x n` matrix.  Eigenvector `j` is
    /// `vectors[0..n]` at column offset `j * n`.
    vectors: []f64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Eigen) void {
        self.allocator.free(self.values);
        self.allocator.free(self.vectors);
        self.* = undefined;
    }

    pub fn eigenvector(self: *const Eigen, n: usize, j: usize) []const f64 {
        return self.vectors[j * n ..][0..n];
    }
};

/// Solve `A X = B` with dense row-major inputs.  The returned matrix is
/// row-major `n x nrhs` and owned by `allocator`.
pub fn solve(
    allocator: std.mem.Allocator,
    a_row_major: []const f64,
    b_row_major: []const f64,
    n: usize,
    nrhs: usize,
) LapackError![]f64 {
    if (n == 0 or nrhs == 0) return error.InvalidArgument;
    if (a_row_major.len != n * n or b_row_major.len != n * nrhs) {
        return error.InvalidArgument;
    }

    const a = try allocator.alloc(f64, n * n);
    defer allocator.free(a);
    const b = try allocator.alloc(f64, n * nrhs);
    defer allocator.free(b);
    const ipiv = try allocator.alloc(lapack_int, n);
    defer allocator.free(ipiv);

    // Row-major -> column-major.
    for (0..n) |r| {
        for (0..n) |c| a[c * n + r] = a_row_major[r * n + c];
    }
    for (0..n) |r| {
        for (0..nrhs) |c| b[c * n + r] = b_row_major[r * nrhs + c];
    }

    var nn: lapack_int = @intCast(n);
    var nnrhs: lapack_int = @intCast(nrhs);
    var lda: lapack_int = nn;
    var ldb: lapack_int = nn;
    var info: lapack_int = 0;
    dgesv_(&nn, &nnrhs, a.ptr, &lda, ipiv.ptr, b.ptr, &ldb, &info);

    if (info < 0) return error.InvalidArgument;
    if (info > 0) return error.SingularMatrix;

    const out = try allocator.alloc(f64, n * nrhs);
    errdefer allocator.free(out);
    for (0..n) |r| {
        for (0..nrhs) |c| out[r * nrhs + c] = b[c * n + r];
    }
    return out;
}

/// Full eigendecomposition of a real symmetric row-major matrix.
pub fn symmetricEigen(
    allocator: std.mem.Allocator,
    a_row_major: []const f64,
    n: usize,
) LapackError!Eigen {
    if (n == 0 or a_row_major.len != n * n) return error.InvalidArgument;

    var a = try allocator.alloc(f64, n * n);
    defer allocator.free(a);
    for (0..n) |r| {
        for (0..n) |c| a[c * n + r] = a_row_major[r * n + c];
    }

    const values = try allocator.alloc(f64, n);
    errdefer allocator.free(values);

    var jobz = [_]u8{'V'};
    var uplo = [_]u8{'U'};
    var nn: lapack_int = @intCast(n);
    var lda: lapack_int = nn;
    var info: lapack_int = 0;

    // Workspace query.
    var query: [1]f64 = undefined;
    var lwork: lapack_int = -1;
    dsyev_(&jobz, &uplo, &nn, a.ptr, &lda, values.ptr, &query, &lwork, &info);
    if (info != 0 or query[0] < 1) return error.EigenDecompositionFailed;

    const work_len: lapack_int = @intFromFloat(query[0]);
    const work = try allocator.alloc(f64, @intCast(work_len));
    defer allocator.free(work);
    lwork = work_len;
    dsyev_(&jobz, &uplo, &nn, a.ptr, &lda, values.ptr, work.ptr, &lwork, &info);
    if (info != 0) return error.EigenDecompositionFailed;

    // `a` is now column-major eigenvectors; move it into an owned slice.
    const vectors = try allocator.dupe(f64, a);
    return .{ .values = values, .vectors = vectors, .allocator = allocator };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "dgesv solves a 2x2 system" {
    const a = [_]f64{
        3, 1,
        1, 2,
    };
    const b = [_]f64{
        9,
        8,
    };
    const x = try solve(std.testing.allocator, &a, &b, 2, 1);
    defer std.testing.allocator.free(x);

    try std.testing.expectApproxEqAbs(@as(f64, 2.0), x[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), x[1], 1e-12);
}

test "dsyev returns ascending eigenvalues and orthonormal vectors" {
    const a = [_]f64{
        2, 1,
        1, 2,
    };
    var eig = try symmetricEigen(std.testing.allocator, &a, 2);
    defer eig.deinit();

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), eig.values[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), eig.values[1], 1e-12);

    const v0 = eig.eigenvector(2, 0);
    const v1 = eig.eigenvector(2, 1);
    const dot = v0[0] * v1[0] + v0[1] * v1[1];
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), dot, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), @sqrt(v0[0] * v0[0] + v0[1] * v0[1]), 1e-12);
}
