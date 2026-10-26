//! Embedded SPIR-V shader assets for the native scene renderer and demo.
//!
//! This file lives in `runtime/shaders/` so `@embedFile` resolves inside this
//! module's own package root.  The `.spv` files are generated from the e7s
//! sources in `engine/shaders/` by `engine/shaders/build.sh` (or `zig build
//! shaders`) and checked in so builds work without the transpiler or slangc.

pub const cube_vert_spv = @embedFile("cube.vert.spv");
pub const cube_frag_spv = @embedFile("cube.frag.spv");
pub const ui_vert_spv = @embedFile("ui.vert.spv");
pub const ui_frag_spv = @embedFile("ui.frag.spv");
