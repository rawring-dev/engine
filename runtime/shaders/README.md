# runtime/shaders

Compiled SPIR-V shader assets embedded by the runtime, plus the compatibility
entry point for rebuilding them.

| Asset | Stage | Canonical source |
| --- | --- | --- |
| `cube.vert.spv` | vertex | [`engine/shaders/cube.vert.e7`](../../engine/shaders/cube.vert.e7) |
| `cube.frag.spv` | fragment | [`engine/shaders/cube.frag.e7`](../../engine/shaders/cube.frag.e7) |

The canonical shader sources are e7s files in `engine/shaders/`; they are
transpiled to Slang by `transpiler/` and compiled with `slangc`.  This
directory only keeps the generated SPIR-V (`assets.zig` embeds it) and
`build.sh` as a compatibility wrapper:

```sh
zig build shaders              # workspace root: e7s -> Slang -> SPIR-V
cd runtime && zig build shaders
sh runtime/shaders/build.sh    # delegates to engine/shaders/build.sh
```

The checked-in `.spv` files let `zig build run-scene` and the runtime tests
compile without any shader toolchain.  See
[`engine/shaders/README.md`](../../engine/shaders/README.md) for the uniform
layout and toolchain resolution.
