# engine/platform/shaders

Shaders for the e7 JIT engine's Vulkan platform layer, written in **e7s** (the
e7 shading subset).  They are transpiled to Khronos Slang by `transpiler/` and
compiled to SPIR-V with `slangc`.  `engine/platform/scene.e7` loads the
checked-in `.spv` files by path at runtime.

| Source | SPIR-V | Stage | Used for |
| --- | --- | --- | --- |
| `triangle.vert.e7` | `triangle.vert.spv` | vertex | hard-coded clip-space triangle (`vulkan_graphics_pipeline`) |
| `triangle.frag.e7` | `triangle.frag.spv` | fragment | flat green triangle |
| `mesh.vert.e7` | `mesh.vert.spv` | vertex | mesh draw with the 192-byte `Scene` uniform block |
| `mesh.frag.e7` | `mesh.frag.spv` | fragment | vertex-colour mesh output |
| `mesh_simple.vert.e7` | `mesh_simple.vert.spv` | vertex | mesh draw without uniforms (clip-space positions) |
| `mesh_simple.frag.e7` | `mesh_simple.frag.spv` | fragment | vertex-colour mesh output |

## Building

```sh
zig build shaders                       # from the repo root: both shader sets
sh engine/platform/shaders/build.sh     # just this directory
```

`build.sh` resolves the e7s binary from its first argument, `$E7S`,
`transpiler/zig-out/bin/e7s`, or `PATH`, and `slangc` from `$SLANGC`,
`.tooling/slang/bin/slangc`, or `PATH`.  If `slangc` is not available the e7s
sources are still transpiled (so lowering errors surface) and the checked-in
SPIR-V is kept.  The script targets `spirv_1_3` (Vulkan 1.1).

Generated Slang is not checked in; only the `.spv` artifacts are.

## Interfaces

- `mesh.vert.e7` declares `Scene { model, view, proj }` as `[f32; 4, 4]`
  matrix fields at descriptor set 0, binding 0.  e7s emits them as
  `column_major float4x4` (offsets 0/64/128, stride 16), matching the
  column-major matrices written by `scene_set_camera` / `scene_set_cube_angle`.
- Mesh vertex inputs are locations 0 (`position`, `vec3`) and 1 (`color`,
  `vec3`), stride 24, matching `vulkan_mesh_pipeline_simple`.
- `mesh.frag` / `mesh_simple.frag` read location 0 and write location 0.
- `triangle.vert.e7` uses `@builtin(vertex_index)`; Slang lowers
  `SV_VertexID` to `gl_VertexIndex - gl_BaseVertex`, so the emitted SPIR-V
  declares the `DrawParameters` capability.  Vulkan exposes the required
  `shaderDrawParameters` feature at 1.1, and
  `engine/platform/vulkan.e7` enables it when creating the logical device
  (the SPIR-V targets Vulkan 1.1 / SPIR-V 1.3).
