# engine7 engine scaffold

This directory is the e7-side of the engine. The goal is that almost all
engine policy and scene code lives here, while `runtime/` owns the native
platform boundary (SDL3 and Vulkan) and the machinery needed to run scripts.

```
engine/
├── main.e7        resources, components, systems, plugins, frame loop
├── ui.e7          Ui plugin, trait dependencies, UI ECS sample
├── shaders/       e7s shader sources and checked-in SPIR-V
└── scene-preview.png
```

## Developer-facing model

- `mod ui` declares an external module. Plugins are top-level items:

  ```e7
  Ui <- plugin
      init <- sys (commands: &mut Commands):
          commands.insert_resource(UINode { ... })
  ```

- `@plugin(Ui)` gates a system/resource behind that plugin.

- Resources are long-lived singleton structs tagged `@resource`.

- Components are ordinary structs tagged `@Components`; they do **not** carry an
  entity id field. The `Components` table is the ECS storage:

  ```e7
  @Components
  Camera <- struct
      yaw: f32
      pitch: f32
      fov_y: f32
      near: f32
      far: f32

  Components <- table
      entity_id: usize,
      ... # auto-collected from @Components types
  ```

- Systems use `res &[mut] Resource` and `select &[mut] Component ... from
  Components`, including trait projections and `where has Component` filters.
  Parameters may be separated by commas or newlines.

- `Commands` is the deferred world-mutation handle:
  `commands := await query &mut Commands`, then `insert_resource`, `add_row`,
  `add_plugin`, etc. `disown commands` releases the handle before the frame
  loop.

- Frame phases are `Init`, `FrameInit`, `PreUpdate`, `Update`, `PostUpdate`,
  `Render`, and `DeInit`. `main` runs them until `Window.quit_requested` is set
  by the SDL close request.

- GPU wrappers are resources over the runtime ABI: `Gpu`, `ShaderModule`,
  `RasterPipeline`, `ComputePipeline`, `Mesh`, `ShaderDeploy`, and
  `PipelineOptions`. The `gpu_*` functions are the intended async methods for
  shader/pipeline deployment and draw submission.

## Shaders

`shaders/*.e7` are e7s shader sources.  `shaders/build.sh` transpiles them to
Khronos Slang with [`transpiler/`](../transpiler/README.md), compiles the
generated Slang to SPIR-V with `slangc`, and publishes the checked-in `.spv`
files used by the runtime renderer.  Without `slangc`, the e7s sources are
still transpiled (so source errors surface) and the checked-in SPIR-V is kept.

```sh
zig build shaders          # from the repository root (also builds the e7s CLI)
sh engine/shaders/build.sh
```

See [`engine/shaders/README.md`](shaders/README.md) for the source table,
toolchain resolution, and the 256-byte uniform layout.

## Native scene demo

```sh
zig build run-scene
zig build run-scene -- --frames 120
zig build run-scene -- --headless --capture /tmp/scene.ppm
```

The native demo is the executable proof of the Vulkan raster pipeline
(camera, spinning cube, point light). `engine/main.e7` is the target e7-side
frame loop and resource/ECS layout.

## Compiler boundary

The front end now parses the DX surface above: modules, plugins, `@plugin`,
`Commands` queries, `disown`, `select ... where has`, row literals, unit
structs, `@Components`, auto-collected table columns, and newline-separated sys
parameters.

Full execution still needs ECS/plugin/Commands runtime semantics and codegen
for mutable query/resource projection. Until then, the native renderer remains
the executable scene path and `engine/main.e7` is the scaffold for that next
step.
