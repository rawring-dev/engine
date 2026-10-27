# engine/shaders

Scene shaders for the e7 engine, written in **e7s** (the e7 shading subset).
They are transpiled to Khronos Slang with the repo's `transpiler/` package,
then compiled to SPIR-V with `slangc`.

| Source | Generated Slang | Output | Stage |
| --- | --- | --- | --- |
| `cube.vert.e7` | `cube_vert.slang` | `cube.vert.spv` | vertex |
| `cube.frag.e7` | `cube_frag.slang` | `cube.frag.spv` | fragment |
| `ui.vert.e7` | `ui_vert.slang` | `ui.vert.spv` | vertex |
| `ui.frag.e7` | `ui_frag.slang` | `ui.frag.spv` | fragment |

The generated Slang intermediate is not checked in: `build.sh` produces
it in a temporary directory so the e7s file is the single source of truth.
The generated SPIR-V **is** checked in next to the e7s sources; the e7 engine
loads it from disk through `e7_engine_read_shader`, so builds and the engine
run work on machines without the e7s transpiler or `slangc`.

## Building

```sh
zig build shaders          # from the repository root (builds the e7s CLI too)
# or
sh engine/shaders/build.sh
# inspect the generated Slang for one shader:
./transpiler/zig-out/bin/e7s transpile engine/shaders/cube.vert.e7 -o -
```

`build.sh` resolves the e7s binary from (in order) its first argument, `$E7S`,
`transpiler/zig-out/bin/e7s`, or `PATH`.  `slangc` is resolved from `$SLANGC`,
`.tooling/slang/bin/slangc`, or `PATH`; without `slangc` the e7s sources are
still transpiled (so errors surface) and the checked-in SPIR-V is kept.  The
generated SPIR-V targets `spirv_1_3`, the SPIR-V baseline for the Vulkan 1.1
device the e7 platform module creates.

The workspace `zig build shaders` step is the canonical rebuild entry point and
also compiles `engine/platform/shaders/*.e7`.

## Uniform layout

`SceneUniform` is 272 bytes, std140-compatible, and matches the
`SceneUniform` struct declared by `cube.vert.e7`/`cube.frag.e7`:

| Offset | Field | Meaning |
| --- | --- | --- |
| 0 | `model: [f32; 4, 4]` | column-major model matrix |
| 64 | `view: [f32; 4, 4]` | column-major view matrix |
| 128 | `proj: [f32; 4, 4]` | column-major projection matrix |
| 192 | `camera_pos` | world-space eye position |
| 208 | `light_pos` | world-space point light position |
| 224 | `light_color` | rgb = colour, w = intensity |
| 240 | `params` | rgb = ambient colour, w = ambient scale |
| 256 | `tint` | rgb = per-object tint (multiplies the vertex colour); a unused |

The fragment shader multiplies each mesh's base (vertex) colour by
`scene.tint.rgb`, so procedural shapes share one pipeline while each object can
have its own colour.

## UI pass

`ui.vert.e7`/`ui.frag.e7` are used by a second graphics pipeline created by the
renderer: positions arrive already converted to Vulkan clip space from pixel
coordinates (top-left origin), each vertex carries a UV and straight-alpha RGBA
tint, and the fragment shader outputs `texture * tint`.  The UI pipeline has
depth test/write disabled and SrcAlpha/OneMinusSrcAlpha blending, and is
recorded after the 3D draws in the same render pass/frame.  It reuses the
material texture descriptor sets (set 1); texture 0 is the built-in white
texture, so a UI quad with no texture draws a solid tinted rectangle.

## Material textures

Descriptor set 0 is the per-object uniform buffer (dynamic offset).  Descriptor
set 1 holds the material: binding 1 is a `Texture2D<[f32; 4]>` sampled image and
binding 2 is a `SamplerState`.  The fragment shader samples it with the vertex
UV (`@location(3)` in/out) and multiplies `vertex_colour * tint * texture`.

Texture id 0 is a built-in white 1x1 texture created by the renderer, so an
untextured draw is exactly `vertex_colour * tint`.  The vertex format is
position(3) + normal(3) + colour(3) + uv(2) = 11 floats; uploaded OBJ meshes
are converted to that layout at upload time.

The e7s source declares regular matrix fields (`model: [f32; 4, 4]`) and
uses matrix products (`scene.model * position`).  The transpiler emits
`column_major` matrix fields and lowers the products to Slang `mul(...)`:

```slang
struct SceneUniform {
    column_major float4x4 model;
    column_major float4x4 view;
    column_major float4x4 proj;
    ...
};
[[vk::binding(0, 0)]] ConstantBuffer<SceneUniform> scene;
```

Host code uploads the matrices column-major (`Mat4 = [4][4]f32`, columns
contiguous), which is exactly the `column_major` layout.  There is no need to
split matrices into separate `float4` column fields.  `@row_major` and
`@column_major` on an e7s matrix field override the default; see
[`transpiler/docs/e7s.md`](../../transpiler/docs/e7s.md#storage-layout).
