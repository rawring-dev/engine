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
├── scene.e7       light animation, render submission (rotation is physics-driven)
├── physics.e7     physics plugin + fixed-step integration/pickup/camera follow
├── physics_broadphase.e7  spatial grid and aggregated region/ray queries
├── physics_narrowphase.e7 box/sphere/capsule/plane tests and resolution
├── obj.e7         pure-e7 Wavefront OBJ parser
├── assets.e7      PNG/JPEG image + OBJ asset resources/plugin
├── assets/        cube.obj and image test fixtures
├── bootstrap.e7   Init window/scene/shaders and DeInit teardown
├── ui.e7          UI font/text, panels, labels, buttons, text fields, triggers
└── shaders/       e7s shader sources + generated SPIR-V
```

## Developer-facing model

- `mod ui` loads sibling `engine/ui.e7`; items are module-qualified (`ui::Ui`).
- Each library exposes its behavior as plugins (`WindowPlugin`,
  `InputPlugin`, `TimePlugin`, `GfxPlugin`, `CameraPlugin`, `PhysicsPlugin`,
  `AssetsPlugin`), plus the demo `DemoPlugin` in `main.e7` and `ui::Ui`
  (`DemoPlugin` also derives a `DemoSettings` config serialized through JSON).
  `main.e7` is the only
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
  `move_camera` only updates look orientation; player movement/jump is handled by
  `physics.e7` from the player capsule; the fixed step integrates quaternion
  orientation with rotated world inverse inertia, uses OBB SAT/oriented-capsule
  manifolds and corner contact points, and applies high Coulomb friction
  (μ=0.9/1.15) so boxes tip and stop sliding. Supported bodies sleep after
  0.35 s below velocity thresholds with resting-contact damping, so the starting
  stack stays upright. It then follows the player with
  the first-person Camera eye. Pickup picks the nearest body (deterministic
  body-id tie-break). Rendering uses full X/Y/Z Euler orientation, so contact
  torques are visible. `render_scene` reads the Camera row, then submits
  a frame with the split intrinsics: `set_camera`, `set_light`, `begin_frame`,
  one `draw_shape_rot` per `Renderable` + `Transform` + `BodyBounds` +
  `Material` row (object count is dynamic; there is no fixed per-frame limit),
  one `draw_custom_rot` per uploaded OBJ mesh row, calls the `ui_render`
  hook, and `end_frame`.  The draw calls receive the full `Transform.rotation`
  XYZ Euler triple, so physics rotation around any axis is rendered.
- `ui_render(gpu)` in `engine/scene.e7` calls `ui::draw_widget(...)` after the
  3D draws while the frame is still open. UI panels/buttons/text use
  `Gpu.draw_ui_quad(texture, x, y, w, h, r, g, b, a)` (pixels from top-left,
  RGBA 0..255, straight alpha over the 3D scene).
- UI widgets (each row carries all five component slots; zero/empty selects
  the role): `UIRect`, `UIPanel`, `UILabel`, `UIButton { label, action }`,
  `UITextField { text, max_len, focused, revision, texture, ... }`.
  `UIState` tracks cursor/hover/focus/clicked action/font/text texture cache.
  Mouse hit-testing and typing run in `@trigger(PreUpdate) ui_interact`;
  `UIButtonPressed` is invoked from `main` when `clicked_action` is set.
  Buttons currently reset the cube stack (action 1) and toggle the light
  (action 2); the text field supports typing, Backspace, and Enter-to-blur.
- `Renderable { kind, colour }` marks drawable rows and selects a procedural
  mesh: 0 box, 1 sphere, 2 capsule, 3 plane.  `Material { texture, tint }`
  provides the per-object GPU texture and RGB tint (texture * tint * vertex
  colour); the ball and stacked cubes receive the sample PNG through their
  Material. Object count is dynamic (no fixed 64-object cap).  The player capsule is deliberately not renderable in the
  first-person demo.  Rotation comes from the physics step; there is no forced
  animation spin, so boxes tumble from gravity, contacts, and angular impulses.
- Engine intrinsics are wrapped as e7 inherent methods: `window.create/pump/
  should_close/destroy`, `gpu.create_scene/read_shader/set_camera/set_light/
  begin_frame/draw_renderable/draw_custom/end_frame/destroy_scene/
  upload_texture/upload_mesh`, `image.upload_texture/free`,
  `mesh.upload`, `input.key_down/mouse_dx/mouse_dy/text_input/cursor_x/y/
  mouse_down`, `time.now_ms/start`.
  Call sites use methods; raw intrinsics only appear inside the wrappers.
- `AssetsPlugin` loads the sample PNG/OBJ into CPU resources at plugin init,
  then a `FrameInit` system uploads them once the window/scene exists:
  `e7_engine_scene_texture_create` for the image and
  `e7_engine_scene_mesh_upload` for `cube.obj`.  The demo adds one
  `Transform + MeshRenderer + Material` row that is drawn as a textured custom
  mesh; `render_scene` skips it until the mesh id is assigned.

## Running

```sh
zig build run-engine                    # interactive
zig build run-engine -- --frames 120
zig build run-engine -- --headless --capture /tmp/engine.ppm
```

Controls: WASD moves the player capsule horizontally, Space jumps, Shift
sprints, mouse/arrows look, E picks up/drops the nearest body; Esc frees the
mouse; camera look and WASD movement only run while captured; clicking the 3D world (outside UI widgets) recaptures, window close exits.

## Shaders

`engine/shaders/*.e7` are e7s shader sources. `zig build shaders` transpiles
them to Slang with the workspace `e7s` tool and compiles to SPIR-V with
`slangc` (a checked-in SPIR-V fallback keeps builds working without it).

## Runtime boundary

`runtime/src/engine.zig` now exposes only low-level SDL/Vulkan facilities:
window lifecycle/event pumping, scene create/destroy/resize, per-frame scene
state (`set_camera`/`set_cube_angle`/`set_light`/`begin_frame`/`draw_mesh`/
`draw_box`/`draw_shape`/`draw_shape_tex`/`draw_custom`/`texture_create`/
`texture_destroy`/`mesh_upload`/`end_frame`), time, raw key/mouse queries, a raw asset
read, and the host frame limiter/capture. Engine policy — shader asset selection/loading, input
mapping, camera look/movement, time updates, physics rotation, light animation, frame
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
