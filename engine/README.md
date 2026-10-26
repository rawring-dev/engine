# engine7 engine scaffold

This directory is the e7-side engine. The project now runs directly through
the JIT host: `zig build run-engine`.

```
engine/
├── main.e7        imports modules, runs the frame loop
├── events.e7      Init/DeInit/FrameInit/PreUpdate/Update/PostUpdate/Render triggers
├── ecs.e7         @Components types and the Components table
├── gfx.e7         Gpu/shader/pipeline/mesh resources and deployment API
├── time.e7        Time resource + tick_time system
├── window.e7      Window resource + event pump system
├── input.e7       Input resource + gather_input/reset_input systems
├── camera.e7      Camera movement/look system
├── scene.e7       cube spin, light animation, render submission
├── physics.e7     colliders, raycasts, gravity/integration plugin
├── bootstrap.e7   Init window/scene/shaders and DeInit teardown
├── ui.e7          Ui plugin, trait dependencies, UI ECS sample
└── shaders/       e7s shader sources + generated SPIR-V
```

## Developer-facing model

- `mod ui` loads sibling `engine/ui.e7`; items are module-qualified (`ui::Ui`).
- Each library exposes its behavior as plugins (`WindowPlugin`,
  `InputPlugin`, `TimePlugin`, `GfxPlugin`, `CameraPlugin`, `PhysicsPlugin`,
  plus the demo `DemoPlugin` in `main.e7` and `ui::Ui`). `main.e7` is the only
  demo-specific file: it adds plugins, describes the cube/light entities, and
  runs the frame loop.
- Plugins are top-level items:
  ```e7
  Ui <- plugin
      init <- sys (commands: &mut Commands):
          commands.insert_resource(UINode { ... })
  ```
  `@plugin(ui::Ui)` gates resources/systems.
- Resources are `@resource` singletons.
- Components are `@Components` structs. They have no entity-id field; the
  `Components` table auto-collects them:
  ```e7
  Components <- table
      entity_id: usize,
      ... # auto-collected
  ```
- Systems declare `res &[mut] Resource`, `select &[mut] Component ... from
  Components [where has Type]`, and `commands: &mut Commands`.
- Commands are deferred and flushed at end of trigger phase and on `disown`.
- Query iteration:
  ```e7
  for (camera, controller) in controllers:
      camera.fov_y
  for transform in transforms:
      transform.rotation
  ```
  Tuple bindings are component references; `&mut` projections are writable.
- Frame phases: `Init`, `FrameInit`, `PreUpdate`, `Update`, `PostUpdate`,
  `Render`, `DeInit`. `main` loops until `Window.quit_requested`.
- Input and camera policy live in e7. `e7_engine_window_pump` only drains SDL
  close/Escape events; `gather_input` reads raw keys and mouse deltas through
  `e7_engine_key_down` / `e7_engine_mouse_dx` / `e7_engine_mouse_dy`; and
  `move_camera` updates the Camera component in a query loop using e7 float
  arithmetic and `e7_f32_sin/cos/clamp`. `render_scene` reads the Camera row,
  issues the split frame intrinsics (`set_camera`, `set_cube_angle`,
  `set_light`, `begin_frame`, `draw_mesh`, `end_frame`). 

## Running

```sh
zig build run-engine                    # interactive
zig build run-engine -- --frames 120
zig build run-engine -- --headless --capture /tmp/engine.ppm
```

Controls: WASD horizontal, Q/E down/up, Shift sprint, mouse/arrows look,
Esc or window close exits.

## Shaders

`engine/shaders/*.e7` are e7s shader sources. `zig build shaders` transpiles
them to Slang with the workspace `e7s` tool and compiles to SPIR-V with
`slangc` (a checked-in SPIR-V fallback keeps builds working without it).

## Runtime boundary

`runtime/src/engine.zig` now exposes only low-level SDL/Vulkan facilities:
window lifecycle/event pumping, scene create/destroy/resize, per-frame scene
state (`set_camera`/`set_cube_angle`/`set_light`/`begin_frame`/`draw_mesh`/
`end_frame`), time, raw key/mouse queries, a raw asset read, and the host frame
limiter/capture. Engine policy — shader asset selection/loading, input
mapping, camera look/movement, time updates, cube spin, light animation, frame
phases, ECS queries, plugins and Commands — lives in `main.e7`.

In particular, `init_window` reads the compiled Slang SPIR-V through
`e7_engine_read_shader` and passes the bytes to the low-level
`e7_engine_scene_create`; the runtime no longer embeds or chooses shaders for
the e7 engine.

## Compiler boundary

Query projection iteration, ECS resources/components/plugins/Commands, project
module loading, float arithmetic/math, and the engine JIT host are implemented.
Remaining work: trigger field binding, trait-object query projections, and
early-break query handle release.
