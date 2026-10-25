# engine7 engine scaffold

This directory is the e7-side engine. The project now runs directly through
the JIT host: `zig build run-engine`.

```
engine/
├── main.e7        resources, components, systems, plugins, frame loop
├── ui.e7          Ui plugin, trait dependencies, UI ECS sample
├── shaders/       e7s shader sources + generated SPIR-V
└── scene-preview.png
```

## Developer-facing model

- `mod ui` loads sibling `engine/ui.e7`; items are module-qualified (`ui::Ui`).
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
- Native input/camera: `e7_engine_window_pump` drains SDL keyboard/mouse, and
  `e7_engine_camera_update` applies WASD, Q/E, Shift, and mouse look. This is
  temporary until f32 arithmetic lands and e7 can update the Camera component
  itself; query iteration already reads the component fields.

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

## Compiler boundary

Query projection iteration, ECS resources/components/plugins/Commands, project
module loading, and the engine JIT host are implemented. Remaining work:
f32 arithmetic for component-driven camera/rotation/light animation, trigger
field binding, trait-object query projections, and early-break query handle
release.
