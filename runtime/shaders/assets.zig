//! Embedded SPIR-V shader assets for the native scene renderer and demo.
//!
//! This file lives in `runtime/shaders/` so `@embedFile` resolves inside this
//! module's own package root.  The `.spv` files are produced by `build.sh`
//! (checked in so builds work without slangc/glslangValidator).

pub const cube_vert_spv = @embedFile("cube.vert.spv");
pub const cube_frag_spv = @embedFile("cube.frag.spv");
