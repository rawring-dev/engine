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
| `textured.frag.e7` | `textured.frag.spv` | fragment | samples the combined image-sampler at set 0, binding 0 |
| `ui.vert.e7` | `ui.vert.spv` | vertex | screen-space UI quad (position/uv/colour, stride 32) |
| `ui.frag.e7` | `ui.frag.spv` | fragment | combined image-sampler at set 0, binding 0, `texture * colour` |
| `lit.vert.e7` | `lit.vert.spv` | vertex | lit mesh draw with the 320-byte `Scene` UBO (set 0, binding 0) |
| `lit.frag.e7` | `lit.frag.spv` | fragment | point-light/ambient formula, combined albedo sampler at set 1, binding 1 |

Every `.spv` in this directory is generated from a sibling `.e7` source by
`build.sh`; no hand-written or GLSL-derived SPIR-V remains.

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
- `textured.frag.e7` reads location 0 (`uv`, `vec2`), samples the combined
  image-sampler at set 0, binding 0 and writes location 0.  The sampled colour
  is returned unchanged (implicit LOD, matching the original GLSL-derived
  `texture(...)`).
- `ui.vert.e7` inputs are locations 0 (`position`, `vec2`), 1 (`uv`, `vec2`)
  and 2 (`color`, `vec4`), stride 32; outputs are `@builtin(position)`,
  location 0 (`uv`) and location 1 (`color`), matching `vulkan_ui_pipeline`.
- `ui.frag.e7` reads location 0 (`uv`, `vec2`) and location 1 (`color`,
  `vec4`), samples the combined image-sampler at set 0, binding 0 and writes
  `texture * colour` to location 0.
- `lit.vert.e7` declares the 320-byte `Scene` block at descriptor set 0,
  binding 0: `model`/`view`/`proj` as `column_major float4x4` at offsets
  0/64/128, then `camera_pos`, `light_pos`, `light_color`, `params` and `tint`
  as `vec4` at offsets 192/208/224/240/256.  Vertex inputs are location 0
  (`position`, `vec3`) and location 1 (`color`, `vec3`), stride 24; outputs are
  location 0 (`world_pos`, `vec3`), location 1 (`vcolor`, `vec3`) and
  location 2 (`uv`, `vec2`), matching `vulkan_mesh_pipeline_two` and
  `lit.frag.spv`.
- `lit.frag.e7` declares the same 320-byte `Scene` block at set 0, binding 0,
  reads locations 0 (`world_pos`, `vec3`), 1 (`vcolor`, `vec3`) and 2 (`uv`,
  `vec2`), samples the combined albedo image-sampler at set 1, binding 1, and
  writes the lit colour to location 0.  Its formula matches the original
  GLSL-derived `lit.frag.spv`:
  `albedo * tint.xyz * (ambient + light * diffuse)` with the
  `1 / (1 + 0.15*d + 0.02*d*d)` attenuation, `light_color.w` intensity and
  `params.w` ambient strength.
- `lit.vert.e7` reproduces the original uv derivation exactly:
  `position.xy + 0.5`.

## Combined image samplers

`textured.frag.spv`, `ui.frag.spv` and `lit.frag.spv` declare a **combined
image-sampler** (`OpTypeSampledImage`): one `VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER`
descriptor at set 0 binding 0 (textured/ui) or set 1 binding 1 (lit), which is
the layout created by `vulkan_texture_descriptor_one` /
`vulkan_texture_descriptor_static` / `vulkan_texture_descriptor_write` in
`engine/platform/vulkan.e7` and `engine/platform/scene.e7`.

e7s expresses that interface with the combined `Sampler*` resource types
(§3.5.1 of `transpiler/docs/e7s.md`), e.g.:

```e7s
@binding(0, 0)
tex: Sampler2D<[f32; 4]>

@fragment
main <- (input: In) -> [f32; 4]:
    ret tex.Sample(input.uv)
```

`Sampler2D<[f32; 4]>` lowers to Slang's legacy combined texture-sampler
`Sampler2D<float4>`, which slangc emits as a single `OpTypeSampledImage`
variable — one combined descriptor — and `.Sample(coords)` takes no separate
sampler argument.  Omitting the type argument keeps Slang's default `float4`
element type (`tex: Sampler2D`).  The other shapes are `Sampler1D`,
`Sampler1DArray`, `Sampler2DArray`, `Sampler3D`, `SamplerCube` and
`SamplerCubeArray`.

Slang's `[[vk::combinedImageSampler]]` attribute (pairing a `Texture2D` with a
`SamplerState` on one binding) is not recognised by the committed toolchain
(slangc 2026.20: `warning[E31000]: unknown attribute
'vk_combinedImageSampler'`), so the SPIR-V for these three stages uses the
combined `Sampler*` type instead; the resulting descriptor interface is
identical.

This does not remove the separate-resource form: `Texture2D<T>` +
`SamplerState` still lower to two descriptors on two different bindings (as in
`engine/shaders/cube.frag.e7` and `engine/shaders/ui.frag.e7`), and e7s still
diagnoses a duplicate `@binding` for a texture and sampler pair because those
are two resources, not one combined descriptor.

All three regenerated fragment modules were validated with `spirv-val` and keep
their original descriptor sets/bindings, input/output locations and `main`
entry point.
