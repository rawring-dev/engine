# e7 project editor (scaffold)

The editor is a normal e7 project (`engine/editor_main.e7`) compiled and run by
a Zig host (`runtime/src/editor_run.zig`).  The host owns the compiler/JIT
integration and the code-swap loop; everything user-facing (scene rendering,
selection, property editing UI, document handling) is written in e7 on top of
the engine modules.

```
engine/editor_main.e7        project root: modules + host-facing `main` loop
engine/editor/main.e7        Editor plugin/systems, UI rows, actions, labels
engine/scene/main.e7         scene library module root
engine/scene/document.e7     scene file format, JSON (de)serialization, helpers
engine/editor/scenes/        checked-in sample scene documents
runtime/src/editor_run.zig   compile/JIT/reload host (`zig build run-editor`)
```

The scaffold in action (headless capture from `zig build run-editor -- --frames 3
--headless --reload-test --capture`; scene rendered by the engine renderer, side
panel drawn by the e7 UI library):

![editor scaffold](../editor-preview.png)

## Host bridge (Zig side)

`editor-run` mirrors `engine-run`: it compiles the project with
`compiler.pipeline.compileProject`, registers ECS metadata, encodes bytecode,
creates an ORC JIT, and awaits the compiled async `main`.  It adds the
reload loop and three host capabilities the editor needs:

| e7 native method | runtime symbol | purpose |
| --- | --- | --- |
| `host::read_asset(path)` | `e7_engine_read_shader` | read a cwd-relative file (scene JSON, OBJ, shaders) |
| `host::write_asset(path, text)` | `e7_engine_write_asset` | create/truncate a cwd-relative file (scene saves) |
| `host::list_dir(path)` | `e7_engine_list_dir` | one-level directory listing (fs list format) |
| `host::request_reload()` | `e7_host_request_reload` | request an in-process code swap |
| `host::take_reload_request()` | `e7_host_take_reload_request` | consume the request from the e7 loop |

`e7_engine_write_asset` returns 0 on success / -1 on I/O failure; the scene
library turns that into a status line in the editor.

### Code hot-swap model

The e7 editor `main` loop checks `host::take_reload_request()` after `Render`.
When set, it runs `DeInit` (releasing the window/scene) and returns the reload
marker `42`.  `editor_run` then:

1. drops the current JIT and compiled project,
2. recompiles the project from disk,
3. resets/re-registers ECS metadata for the new generation,
4. creates a fresh JIT and starts the new `main`.

`--reload-test` seeds one request before the first run so the swap path is
exercised in headless verification (`zig build run-editor -- --frames 3
--headless --reload-test`).  The current scaffold restarts the whole editor
loop; scene state survives because the reload action saves the document
first.  Future work: preserve ECS world state and swap only changed systems
(see below).

## Scene file format (version 1)

Scene documents are JSON serialized with the e7 `@derive(Serialize,
Deserialize)` + `json::encode` / `json::decode::<T>` support.  The format is
additive, versioned, and rejects unknown versions.  Every field is required
(no implicit defaults on load); the editor always writes complete documents.

```json
{
  "format": "engine7-scene",
  "version": 1,
  "name": "sample",
  "camera": {
    "position": { "x": 0.0, "y": 1.8, "z": 6.0 },
    "yaw": 0.0, "pitch": -0.15,
    "fov_y": 1.0471975512, "near": 0.1, "far": 100.0
  },
  "light": {
    "position": { "x": 3.0, "y": 4.0, "z": 2.0 },
    "colour": { "x": 1.0, "y": 0.9, "z": 0.8 },
    "intensity": 2.8
  },
  "objects": [
    {
      "name": "cube",
      "kind": "Box",
      "translation": { "x": 0.0, "y": 0.5, "z": 0.0 },
      "rotation": { "x": 0.0, "y": 20.0, "z": 0.0 },
      "half_extents": { "x": 0.5, "y": 0.5, "z": 0.5 },
      "colour": { "r": 1.0, "g": 0.55, "b": 0.22, "a": 1.0 },
      "texture": ""
    }
  ]
}
```

* `format` is always `"engine7-scene"`; `version` is `1`.
* `kind` is a tagged enum: `"Box"`, `"Sphere"`, `"Capsule"`, `"Plane"`.
* `rotation` is Euler degrees (intrinsic X, then Y, then Z), converted on apply
  to the renderer's `BodyOrientation` quaternion.
* `half_extents` is the renderer's half-size (world units); a plane uses a thin
  y extent.
* `texture` is reserved for an AssetServer image key (`"cube/cube.png"`) or
  `""` for the built-in white texture.  The scaffold stores it; wiring it to
  the GPU texture/material is follow-up work.
* Unknown fields are skipped by the decoder; a future format bump adds
  migration rather than silently half-loading.

The checked-in example is `engine/editor/scenes/sample.scene.json`; the
in-code `sample_scene()` mirrors it so a missing/read-only working file still
opens a useful scene.

### ECS mapping

`EditorRefresh` rebuilds the scene rows from the document:

| document | ECS rows |
| --- | --- |
| camera | one `Camera` |
| light | one `PointLight` |
| object | `Transform`, `BodyBounds`, `Material`, `Renderable`, `BodyOrientation`, `EditorObject` |

The scene renderer (`engine/gfx/scene.e7::render_scene`) consumes exactly these
components, so the editor uses the same rendering path as the engine demo
(no editor-only renderer).

## Editing UI (e7)

The side panel uses the engine's retained UI widgets (`engine/ui/main.e7`):
rows of `UIRect`/`UIPanel`/`UILabel`/`UIButton`/`UITextField` plus an
`EditorLabel` role marker for dynamic text.  Buttons write `UIState.action`;
the project `main` loop forwards `clicked_action` to the `UIButtonPressed`
trigger, and `handle_editor_action` mutates the authoritative document:

| action | effect |
| --- | --- |
| 1 / 2 | select next / previous object |
| 3-8 | nudge selected translation by 0.25 on X/Y/Z |
| 9 | cycle selected object colour |
| 10 | save scene JSON |
| 11 | save scene JSON, then request code reload |

`refresh_labels` (Update) recomputes title/selection/transform/status strings.
Label textures are cached per entity by the UI layer, so a changed label
destroys its cached texture and lets the UI system regenerate it next frame.
Editing marks `EditorState.dirty`; the main loop fires `EditorRefresh` after
`Update` to rebuild rows from the mutated document.

## Limitations / next steps

* Reload restarts the whole editor loop (fresh JIT + ECS world); live world
  preservation and per-system swapping are future work.  The scene document
  (saved before reload) is the persistence boundary.
* Scene objects are render-only; physics colliders/triggers are not part of the
  format yet.
* `texture` is serialized but not yet resolved through the AssetServer at
  upload time.
* UI is fixed-layout; no hierarchy view, undo/redo, or text-field property
  editing beyond button nudges.
* No file watcher: reload is explicit (button/`host::request_reload`).
