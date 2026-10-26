# engine7 — Next Steps

This is the working roadmap for turning engine7 from a functional e7 demo engine
into a reusable, production-shaped game engine. Priorities are relative, not
promises: **P0** blocks serious engine use, **P1** unlocks real games, **P2**
polish/scale.

Current state:
- e7 compilation, ECS, triggers, async systems, Commands, plugins, borrow checking, derives/JSON.
- SDL3 window/input, Vulkan 3D renderer, procedural shapes, textured/custom OBJ meshes, alpha UI quads.
- Fixed-step physics with broadphase/narrowphase, quaternion/OBB/capsule collision, friction, sleeping, pickup.
- SDL3_ttf text + UI widgets: panels, labels, buttons with `UIButtonPressed`, editable text fields.
- Nested engine modules; demo-only `engine/main.e7`.

---

## P0 — Engine foundations

### 1. Asset pipeline and hot reload
- Content-addressed asset database with UUIDs and dependency graphs.
- Async/cancellable loading (textures, meshes, fonts, audio, scenes).
- Hot reload for shaders, textures, meshes, UI, scripts, and e7 modules.
- Asset importers with source → runtime artifact caching and version stamps.
- Failure policy: fallback assets, clear diagnostics, no partial state leaks.
- Acceptance: edit a shader/texture while running and see it update without restart.

### 2. Scene serialization and prefabs
- Serialize/deserialize the whole ECS world (entities, components, resources, plugins, parent/child).
- Prefab format on top of `@derive(Serialize, Deserialize)` and JSON.
- Stable component IDs, versioned migration, missing-component policy.
- Scene loading/unloading and additive scenes.
- Acceptance: save/load a scene round-trip, spawn prefabs by asset id.

### 3. Debug/profiling/logging tooling
- `log` levels, structured fields, categories, in-game console.
- CPU/GPU profiler markers and a frame timeline.
- Debug draw: lines, boxes, spheres, capsules, rays, text.
- Runtime entity/component/plugin inspector.
- Panic/assert policy with actionable e7 diagnostics.
- Acceptance: profile a frame, inspect ECS rows, toggle debug collision shapes.

### 4. Deterministic scheduler & parallel ECS execution
- Explicit system ordering/conflict graph instead of relying on trigger phase concurrency.
- Job system for parallel system execution with deterministic results.
- Change detection (added/changed/removed) and deferred command phases.
- Snapshot/rollback support for tests and networking.
- Acceptance: deterministic replay across runs and thread counts.

### 5. Math library consolidation
- Move Vec2/Vec3/Vec4/Quat/Mat3/Mat4/AABB/ray into `core::math` (currently split between physics/renderer).
- Matrix/vector methods, inverse/transpose, projection helpers, transform composition.
- Constexpr-ish functions and stable naming.
- Acceptance: one shared math module; physics and rendering use the same types.

---

## P1 — Rendering

### 6. Materials and shaders
- Material assets: base color, metallic/roughness, normal, emissive, alpha mode, texture slots.
- Shader asset pipeline with variant/preprocessor support and uniform reflection.
- Material instances, per-object overrides, alpha modes (opaque/cutout/blend).
- Acceptance: author and swap a material asset without recompiling engine code.

### 7. Lighting
- Directional + multiple point/spot lights, per-light shadows, cascaded shadow maps.
- Ambient/IBL/skybox, exposure/tonemapping, gamma-correct workflow.
- Light culling and clustering.
- Acceptance: a scene with sun, point light, sky, and shadows.

### 8. Post-processing
- Bloom, tonemap, FXAA/TAA, SSAO, depth-of-field, vignette.
- Render graph with named passes and automatic resource barriers.
- Acceptance: toggle each effect at runtime with no pipeline rebuild stalls.

### 9. Mesh/animation pipeline
- Mesh asset import (glTF/OBJ), vertex dedup, tangents, LODs, submeshes.
- Skinned meshes, skeletons, animation clips/blending/state machines.
- GPU instancing and batching; frustum culling and occlusion queries.
- Acceptance: load an animated glTF character and play clips.

### 10. Renderer scalability
- Dynamic descriptor/heap allocation, bindless textures where supported.
- GPU-driven culling, indirect draws, multi-threaded command recording.
- Render targets, offscreen cameras, viewports, split-screen.
- Acceptance: hundreds of textured meshes with stable frame time.

---

## P1 — UI and text

### 11. Layout system
- Flex/row/column/absolute layout, margins/padding, anchors, min/max sizes.
- Nested hierarchy and clipping/scissor stack (current renderer lacks per-quad clip).
- Scroll views, lists/virtualization, responsive layout.
- Acceptance: resizable UI that reflows without manual pixel coordinates.

### 12. Widget library
- Buttons, toggles, sliders, checkboxes, radio groups, dropdowns, tabs, tooltips.
- Text fields with caret, selection, clipboard, IME composition, password mode.
- Menus, dialogs, notifications, drag/drop.
- Keyboard/gamepad focus traversal and accessibility metadata.
- Acceptance: a settings menu built entirely from stock widgets.

### 13. Text and font system
- Font assets, multiple faces/sizes/bold/italic, fallback chains.
- Glyph atlas caching, kerning/line wrapping/alignment, rich text spans.
- Localization and RTL/bidi support.
- Acceptance: a localization file switches all UI text without code changes.

### 14. UI styling/theming
- Theme assets (colors, fonts, spacing, icon sets), style states (normal/hover/pressed/disabled/focus).
- Nine-slice panels, rounded corners, borders, shadows, gradients, icons.
- Acceptance: swap themes at runtime.

---

## P1 — Gameplay systems

### 15. Physics completion
- Iterative contact solver with warm starting; full manifold clipping and edge-edge contacts.
- Full 3D inertia tensor and quaternion constraints; articulated joints/hinges/sliders/springs.
- CCD, collision layers/masks, trigger volumes.
- Character controller (slopes, steps, slopes, ground snapping, moving platforms).
- Per-material friction/restitution; raycasts against all shape types.
- Acceptance: a character walks stairs/slopes and stacked objects are stable.

### 16. Input actions and devices
- Action mapping asset (move/jump/interact/look), keyboard/mouse/gamepad/touch.
- Rebinding, dead zones, sensitivity, input contexts (game/UI/menu).
- UI modal input capture so gameplay doesn't react under menus.
- Acceptance: swap keyboard/gamepad and remap at runtime.

### 17. Audio
- Audio assets, mixer buses, volume groups, spatial 3D audio, streaming.
- Music crossfades, one-shots, looping, ducking.
- Acceptance: positional sound follows a moving object.

### 18. Animation and gameplay
- Animation state machines, blend trees, root motion.
- Timers, tweens/easing, camera shake, sequences.
- Acceptance: state-driven character animation.

### 19. Navigation/AI
- Navmesh generation, pathfinding, steering, behavior trees/utility AI.
- Acceptance: an agent paths around obstacles.

### 20. Scripting/game flow
- Scene/state machine, level transitions, game mode lifecycle.
- e7 module hot reload for gameplay code.
- Acceptance: edit a gameplay script and hot reload it.

---

## P1 — Assets and content

### 21. Asset types
- Texture settings (sRGB, compression, mips, wrap/filter).
- Mesh import settings, font assets, audio assets, material/scene/prefab assets.
- Asset references with ref-counting and async handles.
- Acceptance: change import settings and rebuild only affected assets.

### 22. Content build
- Offline asset cook (compression, atlasing, shader variants) and manifest.
- Deterministic, incremental, parallel builds.
- Acceptance: a cooked build loads only runtime artifacts.

---

## P1 — Editor and tooling

### 23. Editor
- Scene view/game view, hierarchy, inspector, asset browser, console.
- Gizmos (translate/rotate/scale), undo/redo, play-in-editor.
- Prefab editing and UI designer.
- Acceptance: build a small scene without hand-editing e7.

### 24. Debuggability for e7
- e7 source maps/line info in profiler/stack traces.
- Breakpoints/step debugging for JIT code.
- Hot reload of e7 systems preserving state.
- Acceptance: pause and inspect an e7 system mid-frame.

---

## P2 — Platform and scale

### 25. Windowing/platform
- Multiple windows, DPI scaling, fullscreen/borderless toggles, display selection.
- Resize/minimize/focus lifecycle events exposed to e7.
- Acceptance: multi-monitor and DPI-safe UI.

### 26. Networking
- Transport abstraction (TCP/UDP/QUIC/WebRTC already partially available).
- Snapshot replication, interpolation, client prediction/rollback.
- Matchmaking/session APIs.
- Acceptance: two clients share a synchronized scene.

### 27. Persistence
- Save games, settings, keybinds, cloud-save hooks.
- Versioned save migrations.
- Acceptance: settings and save survive reload.

### 28. Build/distribution
- Platform builds (Linux first, then Windows/macOS), packaging, runtime shader assets.
- Content signing/versioning, crash reports.
- Acceptance: one-command distributable build.

---

## P2 — Quality and developer experience

### 29. Testing and CI
- Headless golden-image tests, physics determinism tests, scene tests.
- Fuzzing for parsers/assets, JIT/bytecode verifier tests.
- CI matrix Debug/ReleaseSafe/ReleaseFast with benchmarks.
- Acceptance: regressions caught automatically before merge.

### 30. Documentation and examples
- API reference generated from e7 docs, tutorials, sample games.
- Template projects (`empty`, `3d`, `ui`, `physics-playground`).
- Performance and architecture guides.
- Acceptance: a new user can build and run a small game from a template.

### 31. Error handling/observability
- Structured e7 errors/results instead of sentinel handles where feasible.
- Error boundaries per plugin/system with quarantine.
- Runtime metrics/log export.
- Acceptance: a failing system reports a useful diagnostic and does not kill the frame.

### 32. Security/sandbox
- Expand/verify filesystem and network sandboxing for JIT code.
- Asset path validation, plugin trust model.
- Acceptance: sandbox escape tests and fuzzed asset parsers pass.

---

## Known gaps to fold into the above

- Renderer: no per-quad scissor/nested clipping, one draw per UI quad, no texture batching, straight-alpha UNORM only, no mips/sRGB/compressed textures.
- Text/UI: one font size in the demo, byte-wise backspace (can split UTF-8), no caret/selection/clipboard/IME, no layout engine, no keyboard focus traversal.
- Physics: one-sided positional correction, contact solver not fully iterative/warm-started, approximate box-box manifolds, no joint/CCD/character controller, physics types split from math module.
- ECS: no change detection/hierarchy/prefabs/scene save, entity IDs never reused, queries are snapshots.
- Assets: synchronous texture/font/mesh uploads, no hot reload, no cooked asset manifest.
- Tooling: no profiler, debug draw, console, editor, or source-level e7 debugger.
- Platform: Linux-only demo path, HiDPI mouse scaling is caller responsibility.
- Language/runtime: getters/setters, richer generics/inference, stronger compile-time validation remain opportunities.

## Suggested milestone order

1. Math consolidation + scene serialization + asset pipeline.
2. Renderer materials/lights/post + UI layout/widgets.
3. Physics solver/character + input actions + audio.
4. Editor + hot reload + profiling/debug draw.
5. Animation/nav/network/editor polish, then distribution.
