# runtime/shaders

SPIR-V shaders for the engine7 native scene renderer.

| Source | Output | Stage |
| --- | --- | --- |
| `cube.vert.slang` | `cube.vert.spv` | vertex |
| `cube.frag.slang` | `cube.frag.spv` | fragment |

The `.slang` sources are HLSL-compatible Slang (explicit `[[vk::location]]`
inputs, a single `[[vk::binding(0, 0)]]` constant buffer, `SV_Position` /
`SV_Target` outputs) so both Slang and the HLSL front ends accept them.

## Building

```sh
zig build shaders          # from the repository root
# or
./runtime/shaders/build.sh
```

`build.sh` tries `slangc` first, then `glslangValidator -D` (HLSL), then
`glslc -x hlsl`, and finally falls back to the checked-in `.spv` files with a
warning.  Setting `SLANGC=/path/to/slangc` forces a particular Slang binary.
The script also verifies the SPIR-V magic number, so a failed compile cannot
silently leave a stale/garbage binary behind.

The generated SPIR-V is checked in, which keeps `zig build run-scene` and
`zig build test` working on machines without a shader compiler.

## Uniform layout

`SceneUniform` is 256 bytes, std140-compatible, and matches
`renderer.Uniforms`:

| Offset | Field | Meaning |
| --- | --- | --- |
| 0 | `model_c0..c3` | model matrix columns (column-major) |
| 64 | `view_c0..c3` | view matrix columns |
| 128 | `proj_c0..c3` | projection matrix columns |
| 192 | `camera_pos` | world-space eye position |
| 208 | `light_pos` | world-space point light position |
| 224 | `light_color` | rgb = colour, w = intensity |
| 240 | `params` | rgb = ambient colour, w = ambient scale |

Matrices are passed as explicit `float4` columns instead of a `float4x4`
because the HLSL/Slang constant-buffer matrix packing rules differ between
front ends; explicit columns are unambiguous.
