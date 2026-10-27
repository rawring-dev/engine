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
| `textured.vert.e7` | `textured.vert.spv` | vertex | fullscreen textured triangle selected by `vertex_index` |
| — (GLSL-derived) | `textured.frag.spv` | fragment | combined image-sampler at set 0, binding 0 |
| `ui.vert.e7` | `ui.vert.spv` | vertex | screen-space UI quad (position/uv/colour, stride 32) |
| — (GLSL-derived) | `ui.frag.spv` | fragment | combined image-sampler at set 0, binding 0, `texture * colour` |
| `lit.vert.e7` | `lit.vert.spv` | vertex | lit mesh draw with the 320-byte `Scene` UBO (set 0, binding 0) |
| — (GLSL-derived) | `lit.frag.spv` | fragment | point-light/ambient formula, combined albedo sampler at set 1, binding 1 |

The three fragment shaders listed as GLSL-derived are **not** e7s sources: they
sample a combined image-sampler descriptor, which e7s cannot express yet (see
[Combined image samplers](#combined-image-samplers)).  Their checked-in SPIR-V
is kept byte-for-byte; `build.sh` only rebuilds files that have an `.e7` source.

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
  declares the `DrawParameters` capability.  The same applies to
  `textured.vert.e7`.  The SPIR-V therefore requires the Vulkan 1.1
  `shaderDrawParameters` feature before those pipelines can be created.  Note
  that the current `create_logical_device` in `engine/platform/vulkan.e7` does
  not request that feature (the triangle/textured pipeline creation still works
  under lavapipe without validation layers); enabling it is a device-creation
  follow-up outside the shader sources.
- `textured.vert.e7` has no vertex attributes: a fullscreen triangle's three
  corners `(-1,-1)`, `(3,-1)`, `(-1,3)` are selected from
  `@builtin(vertex_index)` (`u32`), the position is `(x, y, 0, 1)` and the uv
  output at location 0 is `p * 0.5 + 0.5`, matching the original GLSL-derived
  SPIR-V.
- `ui.vert.e7` inputs are locations 0 (`position`, `vec2`), 1 (`uv`, `vec2`)
  and 2 (`color`, `vec4`), stride 32; outputs are `@builtin(position)`,
  location 0 (`uv`) and location 1 (`color`), matching `vulkan_ui_pipeline`.
- `lit.vert.e7` declares the 320-byte `Scene` block at descriptor set 0,
  binding 0: `model`/`view`/`proj` as `column_major float4x4` at offsets
  0/64/128, then `camera_pos`, `light_pos`, `light_color`, `params` and `tint`
  as `vec4` at offsets 192/208/224/240/256.  Vertex inputs are location 0
  (`position`, `vec3`) and location 1 (`color`, `vec3`), stride 24; outputs are
  location 0 (`world_pos`, `vec3`), location 1 (`vcolor`, `vec3`) and
  location 2 (`uv`, `vec2`), matching `vulkan_mesh_pipeline_two` and
  `lit.frag.spv`.
- `lit.vert.e7` reproduces the original uv derivation exactly:
  `position.xy + 0.5`.

## Combined image samplers

`textured.frag.spv`, `ui.frag.spv` and `lit.frag.spv` declare a **combined
image-sampler** (`OpTypeSampledImage`): one `VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER`
descriptor at set 0 binding 0 (textured/ui) or set 1 binding 1 (lit), which is
the layout created by `vulkan_texture_descriptor_one` /
`vulkan_texture_descriptor_static` / `vulkan_texture_descriptor_write` in
`engine/platform/vulkan.e7` and `engine/platform/scene.e7`.

e7s cannot currently express that interface:

- `Sampler2D` (the Slang combined texture-sampler type) is rejected as a
  resource type: `resource 'tex' must name a user struct or a Slang resource
  type (Texture2D<f32>, SamplerState, ...)`.
- Declaring `Texture2D<[f32; 4]>` and `SamplerState` on the same
  `@binding(binding, set)` is rejected with
  `duplicate resource binding: binding 0, set 0`, and the supported forms map
  them to two separate descriptors (`VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE` +
  `VK_DESCRIPTOR_TYPE_SAMPLER`), not one combined descriptor.
- e7s has no attribute that lowers to Slang's `[[vk::combinedImageSampler]]`,
  which is the Slang spelling for binding a texture and sampler at the same
  descriptor.

Converting them therefore needs one of:

1. an e7s combined-sampler resource form (e.g. pass `Sampler2D` through as an
   explicit Slang resource type, or a `@combined_image_sampler` attribute that
   emits `[[vk::combinedImageSampler]]` for a `Texture2D` + `SamplerState`
   pair), or
2. a host-side descriptor change to separate `SAMPLED_IMAGE` and `SAMPLER`
   descriptors, which requires editing `engine/platform/vulkan.e7` and
   `engine/platform/scene.e7`.

Until then the GLSL-derived SPIR-V for these three fragment stages stays in
place.  Their descriptor interfaces are unchanged by this work; only the three
vertex stage SPIR-V files were regenerated from e7s.
