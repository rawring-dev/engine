# engine7 engine scaffold

This directory is the e7-side of the engine. The goal is that almost all
engine policy and scene code lives here, while `runtime/` only owns the native
platform boundary (SDL3 and Vulkan) and the JIT/ecs machinery needed to run
the scripts.

```
engine/
├── main.e7        resources, components, systems, frame loop
├── ui.e7          trait-dependency/UI ECS sample
└── shaders/       Slang sources compiled to SPIR-V
```

## Architecture

- **Resources** (`@resource`) are long-lived singletons: `Window`, `Input`,
  `Time`, `Camera`, `Gpu`, `World`.
- **Components** are structs marked `@Components`. They carry an `entity_id`
  column and are stored in the `Components` table.
- **Queries** are declared in systems with `select &[mut] Component from
  Components` (and resource parameters with `res &[mut] Resource`).
- **Systems** are `sys` functions attached to trigger phases with
  `@trigger(...)`.
- **Frame phases** are `FrameInit`, `PreUpdate`, `Update`, `PostUpdate`, and
  `Render`. `main` runs them in order until `Window.quit_requested` is set by
  the SDL close request; the final `QuitRequested` trigger is the shutdown
  signal.
- **GPU resources** wrap the runtime's Vulkan scene ABI:
  - `ShaderDeploy` describes Slang-produced vertex/fragment SPIR-V modules.
  - `RasterPipeline`/`Mesh` are e7 resources over native Vulkan handles.
  - `gpu_deploy_shader`, `gpu_begin_frame`, `gpu_draw_mesh`, and
    `gpu_end_frame` are the extension points for shader deployment and draw
    submission.

## Shaders

`shaders/*.slang` are Slang sources. At build time they are compiled to
SPIR-V and embedded/loaded by the native scene renderer. `slangc` is preferred;
an HLSL-compatible fallback through `glslangValidator` is used when `slangc`
is not installed.

## Current compiler/runtime boundary

The language surface needed by this scaffold is:

- trait dependencies (`Trait <- trait : Parent`) and trait method
  requirements, including `&self`/`&mut self`;
- `res &mut T` and `select &mut Trait from Components` system parameters;
- `@Components` component structs and `Components <- table` storage;
- `@resource` resource structs.

The native scene renderer and camera/cube demo are under
`runtime/src/ffi/renderer.zig` and `runtime/src/scene_demo.zig`; that demo is
the current executable proof of the Vulkan pipeline while the e7-side systems
are wired up incrementally. Codegen for mutable query projection and
resource-parameter bodies is the remaining gap for running `main.e7` directly.
