//! Scheduler: numerical building blocks for execution planning.
//!
//! The module is intentionally dependency-light: dense linear algebra goes
//! through the system LAPACK/BLAS, while optimization and graph partitioning
//! are implemented in Zig.

pub const lapack = @import("lapack.zig");
pub const lbfgs = @import("lbfgs.zig");
pub const spectral = @import("spectral.zig");

pub const Vec = struct {
    pub fn dot(a: []const f64, b: []const f64) f64 {
        var sum: f64 = 0;
        for (a, b) |ai, bi| sum += ai * bi;
        return sum;
    }

    pub fn norm(a: []const f64) f64 {
        return @sqrt(dot(a, a));
    }
};

test {
    _ = lapack;
    _ = lbfgs;
    _ = spectral;
}
