# engine7 engine scaffold

This directory is the e7-side engine. The project now runs directly through
the JIT host: `zig build run-engine`.

```
engine/
├── main.e7              demo-only: demo plugin/assets/settings, UI handler, frame loop
├── core/
│   ├── main.e7          core prelude (events, ecs, camera, input, time, window, bootstrap)
│   ├── events.e7        Init/FrameInit/PreUpdate/Update/PostUpdate/Render/DeInit triggers
│   ├── ecs.e7           @Components types, Commands, Components table
│   ├── window.e7        Window resource/methods + event pump
│   ├── input.e7         Input resource, key/mouse/text methods, gather/reset systems
│   ├── time.e7          Time resource/methods + tick system
│   ├── camera.e7        Camera resource/plugin
│   └── bootstrap.e7     Init window/scene/shader setup + DeInit teardown
├── gfx/
│   ├── main.e7          rendering prelude
│   ├── gpu.e7           Gpu, Material, renderer methods, GfxPlugin
│   └── scene.e7         world + UI render submission
├── physics/
│   ├── main.e7          PhysicsWorld, fixed-step solver, pickup/camera systems
│   ├── broadphase.e7    spatial grid + aggregated region/ray queries
│   └── narrowphase.e7   quaternion/OBB/capsule/plane collision + raycasts
├── assets/
│   ├── main.e7          Image/Assets resources, AssetsPlugin, GPU upload
│   ├── obj.e7           pure-e7 Wavefront OBJ parser
│   ├── cube.obj         demo mesh asset
│   └── testdata/        PNG/JPEG fixtures
├── ui/
│   └── main.e7          font/text rendering, panels, labels, buttons, text fields,
│                        UIState, UIButtonPressed trigger
├── platform/            e7 Vulkan/SDL platform layer + its shader assets
│   ├── main.e7          platform prelude
│   ├── input.e7         SDL input bindings
│   ├── scene.e7         Vulkan scene/pipeline/uniform setup
│   ├── sdl.e7           SDL bindings
│   ├── text.e7          SDL_ttf bindings
│   ├── vulkan.e7        Vulkan bindings and pipeline helpers
│   └── shaders/         e7s platform shader sources + generated SPIR-V
└── shaders/             e7s runtime-scene shader sources + generated SPIR-V
```

## Developer-facing model

- Modules are nested: `mod ui` loads `engine/ui/main.e7`; nested declarations load
  submodules relative to their file (`core/window.e7`, `physics/broadphase.e7`).
  Items are module-qualified (`ui::Ui`, `core::window::Window`,
  `physics::broadphase::SpatialMap`).  Use the nested preludes (`core`, `gfx`,
  `physics`, `assets`, `ui`) from `main.e7`; reusable libraries never import
  demo-specific code.
- Each library exposes its behavior as plugins (`core::window::WindowPlugin`,
  `core::input::InputPlugin`, `core::time::TimePlugin`, `gfx::gpu::GfxPlugin`,
  `core::camera::CameraPlugin`, `physics::PhysicsPlugin`,
  `physics::broadphase::BroadphasePlugin`,
  `physics::narrowphase::NarrowphasePlugin`, `assets::AssetsPlugin`, `ui::Ui`),
  plus the demo `DemoPlugin` in `main.e7` (`DemoPlugin` also derives a
  `DemoSettings` config serialized through JSON).
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
  `Material` row, one `draw_custom_rot` per uploaded OBJ mesh row, one
  `draw_ui_quad` per widget layer, and `end_frame`.  The draw calls receive the
  full `Transform.rotation` XYZ Euler triple, so physics rotation around any
  axis is rendered.  There is a per-frame recording capacity of 24 3D draws
  (16 procedural + 8 uploaded meshes) and 88 total draws including UI quads;
  object count below those caps is dynamic.
- Frames are recorded, not submitted per draw: `engine/platform/scene.e7`
  writes one 80-byte entry per object into the scene draw list (pipeline,
  buffers, per-object 320-byte `Scene` UBO slot, texture descriptor sets) and
  `scene_draw` captures the whole list in a single command buffer.  The 3D
  entries use the lit pipeline (`lit.vert`/`lit.frag`: 320-byte dynamic
  `Scene` UBO at set 0, combined image-sampler at set 1 binding 1), so the
  material tint and texture are applied per object.  UI entries are appended
  after the 3D entries and use the blended UI pipeline (`ui.vert`/`ui.frag`,
  set 0 binding 0) with a 64-quad dynamic vertex buffer updated at draw time;
  this is the screen-space pass over the 3D scene (pixels from top-left,
  RGBA 0..255, straight alpha).
- Engine textures: `e7_engine_scene_texture_create` uploads an e7 image handle
  (font glyph images and material PNGs) through
  `e7_image_width/height/pixels`; ids are stable (1..24, free-list reuse after
  `e7_engine_scene_texture_destroy`), id 0 is the built-in white texture.
  Each texture owns two combined-sampler descriptor sets (set 0 binding 0 for
  UI, set 1 binding 1 for the lit material path) and is freed with the scene.
- Uploaded meshes: `e7_engine_scene_mesh_upload` converts the e7 OBJ
  interleaved vertex aggregate (position, normal, uv; 8 floats per vertex)
  and 32-bit index aggregate into tightly packed GPU buffers, rendered through
  the 32-byte-stride variant of the lit pipeline.  The normal slot is uploaded
  as neutral vertex colour and the lit vertex stage derives UVs from
  position.xy; material tint/texture still apply.
- Approximation: the procedural shape kinds (sphere, capsule, plane) are all
  rendered with the shared cube geometry; the transform, full XYZ rotation,
  tint and texture id are honored, but the silhouette remains a box.
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
- Engine platform calls are wrapped as e7 inherent methods: `window.create/pump/
  should_close/destroy`, `gpu.create_scene/read_shader/set_camera/set_light/
  begin_frame/draw_renderable/draw_custom/end_frame/destroy_scene/
  upload_texture/upload_mesh`, `image.upload_texture/free`,
  `mesh.upload`, `input.key_down/mouse_dx/mouse_dy/text_input/cursor_x/y/
  mouse_down`, `time.now_ms/start`.
  Call sites use methods; raw calls only appear inside the wrappers.
- `AssetsPlugin` loads the sample PNG/OBJ into CPU resources at plugin init,
  then a `FrameInit` system uploads them once the window/scene exists:
  `e7_engine_scene_texture_create` for the image and
  `e7_engine_scene_mesh_upload` for `cube.obj`.  The demo adds one
  `Transform + MeshRenderer + Material` row that is drawn as a textured custom
  mesh; `render_scene` skips it until the mesh id is assigned.
- Capture limitation: the headless PPM writer copies the swapchain bytes as
  RGB, while the lavapipe surface format is BGRA, so red and blue are swapped
  in captured PPMs (window presentation is unaffected).  Captures also show
  the UI over the lit 3D frame, so text/panel pixels are directly visible.

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

There are two e7s shader sets:

- `engine/shaders/*.e7` — engine scene shaders, loaded from disk by the e7
  engine through `e7_engine_read_shader`.
- `engine/platform/shaders/*.e7` — JIT-engine platform shaders loaded by path
  from `engine/platform/scene.e7` (triangle and mesh pipelines).

`zig build shaders` transpiles both sets to Slang with the workspace `e7s`
tool and compiles them to SPIR-V with `slangc`.  Checked-in SPIR-V keeps
builds and the engine runnable without a shader toolchain.  See
[`engine/shaders/README.md`](shaders/README.md) and
[`engine/platform/shaders/README.md`](platform/shaders/README.md) for
interfaces and the build fallback behavior.

## Runtime boundary

The runtime exposes no SDL/Vulkan API.  `runtime/src/host_engine.zig` keeps
only the SDL/Vulkan-free host helpers `e7_engine_read_shader` and
`e7_engine_time_now_ms`, and `runtime/src/host.zig` keeps the frame limiter and
capture bookkeeping.  Windows, input, and the whole Vulkan scene pipeline live
in `engine/platform/*.e7`, which binds SDL3 and Vulkan dynamically through the
generic C FFI.  Engine policy — shader asset selection/loading, input mapping,
camera look/movement, time updates, physics rotation, light animation, frame
phases, ECS queries, plugins and Commands — lives in `main.e7`.

In particular, `init_window` reads the compiled SPIR-V through
`e7_engine_read_shader` and passes the bytes to `engine_scene_create` in
`engine/platform/engine_scene.e7`; the runtime neither embeds shaders nor owns
the scene.

## Compiler boundary

Query projection iteration, ECS resources/components/plugins/Commands, project
module loading, float arithmetic/math, and the engine JIT host are implemented.
Remaining work: trigger field binding, trait-object query projections, and
early-break query handle release.
