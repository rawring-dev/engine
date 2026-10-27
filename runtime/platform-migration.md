# SDL/Vulkan runtime migration

Goal: the `runtime` package must not link or implement SDL3/Vulkan. The e7
engine owns the platform intrinsics and reaches SDL/Vulkan through the generic
C FFI, using only `e7_dl_*` / `e7_cffi_bind` / `e7_ffi_call*` and raw memory.

Status: the migration is complete.  The stage notes below are the historical
journal; see [Migration complete](#migration-complete) for the final state.

## Completed foundation

- `runtime/src/ffi/dl.zig`: `dlopen`/`LoadLibrary`, symbol lookup, call
  trampolines 0..16, data access.
- `runtime/src/ffi/cbridge.zig`: cached `e7_cffi_bind(library, symbol)` and
  `e7_ffi_call0..16` callable from e7 source.
- Compiler intrinsic table + bytecode support for `e7_cffi_bind`,
  `e7_ffi_call0..16`, `e7_str_data/len/new`, `e7_alloc_bytes`, `e7_free_ptr`,
  and `e7_load/store_*`.
- End-to-end test: e7 source binds libc `strlen` and calls it.
- ORC tests call library symbols directly; dynamic-library tests cover `cos`,
  `strlen`, `qsort` callbacks, and data symbols.

## Stage progress

- **1a (done):** e7 source initializes SDL video, sets `SDL_VIDEODRIVER`, creates
  a hidden `SDL_Window`, destroys it, and quits the subsystem using only
  `e7_cffi_bind`/`e7_ffi_call*`, `e7_cstr`, and `e7_alloc_bytes`.
- **1b (done):** e7 source builds `VkApplicationInfo`/`VkInstanceCreateInfo` in
  raw memory, creates a Vulkan instance, calls
  `vkEnumeratePhysicalDevices`, and destroys the instance. Device enumeration is
  treated as zero devices when the headless loader reports no GPU.
- **1c (done):** `engine/platform/sdl.e7` is a real e7 module that initializes
  SDL video, creates/destroys/sizes windows, polls events into a raw state block,
  tracks close/quit and mouse motion, and exposes keyboard/mouse queries.  The
  runtime test reads this module from disk, compiles it through the e7 pipeline,
  JITs it, and runs it.
- **2a (done):** `engine/platform/vulkan.e7` creates a Vulkan instance with
  the platform extensions reported by `SDL_Vulkan_GetInstanceExtensions`, then
  creates and destroys a window surface with `SDL_Vulkan_CreateSurface` and
  `vkDestroySurfaceKHR`.  A combined SDL+Vulkan e7 self-test exercises the full
  path on a hidden Vulkan window.
- **2b (done):** `engine/platform/vulkan.e7` creates a logical Vulkan device
  and graphics/present queue with the `VK_KHR_swapchain` extension.  Verified
  against a workspace-local Mesa lavapipe ICD (CPU Vulkan):
  `VK_ICD_FILENAMES=.local-vulkan/usr/share/vulkan/icd.d/lvp_icd.json`
  `LD_LIBRARY_PATH=.local-vulkan/usr/lib`; all 134 runtime tests pass.
  Queue-family selection now queries
  `vkGetPhysicalDeviceQueueFamilyProperties` and
  `vkGetPhysicalDeviceSurfaceSupportKHR` and picks a family that supports both
  graphics and presentation (the earlier crash was a missing third argument to
  the properties query).
- **2c (done):** `engine/platform/vulkan.e7` creates a `VkSwapchainKHR` with
  surface capabilities/formats, image usage, FIFO present mode, and returns the
  swapchain images.  Verified with lavapipe (extent > 0, image count > 0) and
  destroyed cleanly.
- **2d (done):** `vulkan_present_clear` acquires a swapchain image, records a
  UNDEFINED→TRANSFER_DST→PRESENT_SRC barrier chain, clears the image to red,
  submits it with image-available/render-finished semaphores and a fence, then
  calls `vkQueuePresentKHR`.  Verified with lavapipe.  The submit path exposed
  an argument-order bug: `vkQueueSubmit(queue, submitCount, pSubmits, fence)`
  needs the count before the pointer.
- **2e (done):** `vulkan_capture_clear` creates a host-visible/coherent buffer,
  copies the cleared swapchain image into it with `vkCmdCopyImageToBuffer`, maps
  it, copies the pixels into an e7 allocation with the new `e7_memcpy`
  intrinsic, and verifies the readback color.  Verified with lavapipe.
- **3a (done):** `vulkan_render_targets` creates a single-color-attachment
  render pass, one image view per swapchain image, and matching framebuffers;
  `vulkan_render_targets_destroy` tears them down.  Verified with lavapipe.
- **3b (done):** `vulkan_graphics_pipeline` creates shader modules from e7
  `str` SPIR-V data, an empty pipeline layout, and a full graphics pipeline
  (dynamic viewport/scissor, triangle list, no vertex input).  Added
  `engine/platform/shaders/triangle.{vert,frag}.spv` and the `e7_handle`
  intrinsic for passing typed string handles through raw FFI slots.  Verified
  with lavapipe.
- **3c (done):** `vulkan_draw_triangle_capture` begins the render pass, binds
  the pipeline, sets dynamic viewport/scissor, issues `vkCmdDraw(3)`, copies the
  rendered image back, and verifies the center pixel is the shader's green.
  Added `e7_store_f32` for viewport/scissor state.  Verified with lavapipe:
  the e7-built pipeline rasterizes the triangle, not just clears the frame.
- **4a (done):** `engine/platform/input.e7` provides explicit-handle input
  (action-key scancode mapping, mouse position/motion/buttons, relative capture,
  text placeholder) over the e7 SDL module.  The old zero-argument intrinsics
  cannot be reimplemented safely without moving scene state, because e7 has no
  mutable globals; the engine port will pass `window.handle` explicitly.
  Verified with lavapipe/SDL: **135/135** runtime tests.
- **3d (done):** `vulkan_uniform_resources` creates a host-visible 256-byte
  uniform buffer, a descriptor set layout/pool/set, binds the buffer, and
  updates the descriptor.  This is the per-frame `SceneUniform` path used by the
  engine shaders.  Verified with lavapipe: **135/135** runtime tests.
- **5a (done):** `engine/platform/scene.e7` composes the platform into a
  reusable scene lifecycle (create, draw, capture, destroy) with a compact
  raw-memory state block.  The test creates a hidden Vulkan window, builds the
  scene, draws the triangle, and verifies the center pixel is the shader green.
  Runtime: **136/136** with lavapipe.
- **5b (assets):** added validated `mesh.vert.spv`/`mesh.frag.spv` shaders with
  a vertex buffer (position/color) and `Scene` UBO.  Pipeline integration is
  pending; the first attempt crashed inside `vkCreateGraphicsPipelines` and was
  reverted rather than committed unverified.
- **5c (done):** added a host-visible vertex buffer, a vertex-input pipeline
  with empty layout, and vertex-buffer binding in the draw path.  The e7 test
  now draws from the vertex buffer and verifies the captured center is the
  vertex shader's green.  Runtime: **136/136** with lavapipe.  The earlier
  crash was caused by stale/incorrect cleanup and the UBO descriptor path; the
  empty-layout mesh path is stable.
- **5d (done):** added a standalone UBO descriptor-set layout and made the
  vertex-input pipeline accept an optional set layout.  The UBO mesh pipeline
  now creates successfully with lavapipe; the earlier crash was caused by
  cleanup code inserted into the wrong e7 function, not by the pipeline state.
  The verified vertex-buffer draw remains green. Runtime: **136/136**.
- **5e (fix):** corrected `VkBufferCreateInfo` offsets (`size` at 24,
  `usage` at 32) and `VkMemoryRequirements.memoryTypeBits` (offset 16) in all
  e7 buffer/readback/uniform paths.  Buffers were previously tiny/invalid, which
  explained the capture crashes.  Runtime: **136/136**.
- **5f (done):** the e7 scene now creates a UBO + descriptor set, writes
  identity model/view/projection matrices, builds the UBO mesh pipeline, binds
  the descriptor set and vertex buffer, draws, and captures.  Verified with
  lavapipe: **136/136** runtime tests.  Fence waits now use a 1-second timeout
  and return an error instead of hanging.
- **6a (done):** added a cube vertex buffer (8 vertices), a 16-bit index buffer
  (36 indices), `vkCmdBindIndexBuffer`/`vkCmdDrawIndexed`, and switched the e7
  scene to render the indexed cube through the UBO pipeline.  The scene test
  verifies the captured center is a colored cube pixel, not the cleared
  background.  Runtime: **136/136** with lavapipe.
- **6b (resource):** `vulkan_depth_target` creates a `D32_SFLOAT` depth image,
  device memory, and depth image view; the e7 scene creates/destroys it.
  Render-pass/pipeline depth integration is next. Runtime: **136/136**.
- **6c (done):** depth is wired into the scene: render pass depth attachment
  (CLEAR/STORE, D32_SFLOAT), framebuffers with color+depth views, two clear
  values, and depth test/write/LESS_OR_EQUAL in the mesh pipeline.  The indexed
  cube still renders and captures correctly.  Runtime: **136/136**.
- **7a (done):** `scene_set_camera` converts milli-unit eye/yaw/pitch into the
  FPS view matrix and Vulkan Y-flipped perspective projection, writes the full
  engine `SceneUniform` (UBO expanded to 320 bytes), and the scene test draws a
  camera-transformed indexed cube. Runtime: **136/136**.
- **7b (done):** `scene_set_light` writes point-light position/color/intensity,
  ambient parameters, and white tint into the SceneUniform. Camera+light frame
  setup now matches the engine contract. Runtime: **136/136**.
- **7c (done):** `scene_set_cube_angle` writes the engine's `RY(angle) * RX(0.35)`
  model matrix; the scene test rotates the cube before capture. Runtime:
  **136/136**.
- **7d (done):** the scene UBO is now a dynamic uniform buffer with per-draw
  dynamic offsets; buffer/descriptor slot count is configurable and the draw
  path binds a dynamic offset. This is the foundation for per-object model/tint
  slots. Runtime: **136/136**.
- **7e (done):** the frame recorder can bind dynamic uniform slots and issue
  multiple indexed draws before submit; the scene fills a second object slot
  (translated/red-tinted cube) and records two objects in one captured frame.
  Runtime: **136/136**.
- **7f (done):** added the e7 object draw API: `scene_begin_frame`,
  `scene_draw_box` (position/scale/color), per-object model/tint UBO slots, and
  up to four indexed draw calls per frame with dynamic offsets. Scene test now
  records four colored cubes and captures the frame. Runtime: **136/136**.
- **8a (done):** e7 text/font port over SDL_ttf 3:
  `engine/platform/text.e7` loads fonts, measures UTF-8 text, rasterizes blended
  text to a surface, and registers it as an RGBA image through
  `e7_image_from_argb`. Added an f32 second-argument FFI trampoline for
  `TTF_OpenFont`, switched to `TTF_GetStringSize`/`TTF_RenderText_Blended`, and
  taught the IR translator to skip runtime declarations shadowed by e7
  definitions. Runtime: **137/137**.
- **8b (done):** engine integration: `engine/main.e7` imports `platform`,
  `engine/ui/main.e7` uses `platform::text::*`, and the e7 text module now
  defines the original intrinsic names. Removed the compiler text intrinsics,
  `runtime/src/text.zig`, its symbol manifest, SDL3_ttf link directives, and the
  old text-dependent runtime tests. `zig build run-engine -- --frames 1
  --headless` passes. Runtime: **134/134**.
- **7g (done):** object draw API extended to eight per-object UBO slots and
  eight indexed draw calls per frame; the scene test records eight colored cubes
  and captures the frame. Runtime: **134/134**.
- **7h (done):** e7 texture resources: sampled `R8G8B8A8_UNORM` image,
  image view, linear sampler, staging-buffer upload with barriers/copy/submit,
  and clean teardown. The scene creates/uploads a 4x4 texture at startup.
  Runtime: **134/134**.
- **7i (done):** single combined-image-sampler descriptor set (set 1,
  binding 1) for the uploaded texture; the scene creates/updates/destroys it
  without validation errors. The two-binding sampler path was the earlier crash
  source and is not used. Runtime: **134/134**.
- **7j (done):** object capacity extended to sixteen dynamic UBO slots and
  sixteen indexed draws per frame; scene state/object/texture regions no longer
  overlap. Scene test records sixteen cubes. Runtime: **134/134**.
- **7k (done):** static combined texture descriptor bound through a mesh
  pipeline and a static draw path; scene renders and captures a static-
  descriptor frame, proving the static binding/layout path independently of the
  textured shader. Runtime: **134/134**.
- **7l (done):** textured shader pipeline: single-set combined sampler bound
  statically through the mesh pipeline helper; `scene_draw_textured` samples the
  uploaded 4x4 white texture and the captured center is exactly white. Runtime:
  **134/134**.
- **7m (done):** UI quad pipeline: position/UV/color vertex buffer, combined
  texture descriptor, SrcAlpha/OneMinusSrcAlpha blending, indexed 6-vertex quad;
  `scene_draw_ui` captures a white textured quad. Runtime: **134/134**.
- **7n (done):** two-set pipeline and draw path: mesh pipeline layout with
  set0 dynamic UBO + set1 combined texture; draw binds both sets, renders and
  captures a two-set cube frame. This matches the engine shader descriptor
  layout closely. Runtime: **134/134**.
- **7o (done):** engine-style lit shader: SceneUniform UBO (camera/light/tint)
  + combined albedo texture, point-light attenuation/diffuse, drawn through the
  two-set pipeline. `scene_draw_lit` captures a lit textured cube frame.
  Runtime: **134/134**.
- **9a (done):** SDL/Vulkan-free host module: headless flag, deterministic
  frame limit, frame counter, and RGBA capture. e7 intrinsics
  (`e7_host_headless`, `e7_host_should_close`, `e7_host_note_frame`,
  `e7_host_capture`) are JIT-tested end-to-end; this is the capture/frame-control
  foundation for removing the runtime renderer from `engine-run`. Runtime:
  **135/135**.
- **9b (done):** native-window bridge: `e7_engine_native_window(handle)` exposes
  the runtime SDL window pointer to e7, so the e7 Vulkan scene can create its
  own surface while the runtime still owns event/window plumbing. Verified
  stable across repeated queries. Runtime: **136/136**.
- **9c (done):** borrowed-window scene: `scene_create_borrowed(native_window,
  w, h)` creates the e7 Vulkan surface/swapchain on a runtime-owned SDL window
  and `scene_destroy` no longer destroys that window. Borrowed create/destroy is
  JIT-verified on a runtime-created window. Runtime: **136/136**.
- **7p (done):** dynamic UI texture replacement: upload arbitrary RGBA8
  pixels (e.g. text/image raster output), repoint the static UI descriptor, and
  sample them through the UI quad. The scene test swaps in a green 8x8 texture
  and captures the exact green center pixel. Runtime: **136/136**.
- **7q (done):** e7 text raster output now feeds the UI texture upload path:
  font load -> `text_image` -> image pixels -> `scene_set_ui_texture` is
  JIT-verified on a real font. Drawing the text texture is still isolated (the
  upload succeeds but a captured text-texture frame currently crashes
  lavapipe). Runtime: **137/137**.
- **9d (done):** e7 engine window module (`engine/platform/engine_window.e7`):
  explicit-handle SDL create/pump/should-close/destroy plus key/mouse queries,
  implemented through the generic C FFI. JIT-verified create/pump/query/destroy.
  Functions currently use `ew_*` names to avoid colliding with the still-live
  runtime engine symbol manifest; they will take the `e7_engine_*` names when
  that manifest is removed. Runtime: **138/138**.
- **9e (done):** e7 engine scene module (`engine/platform/engine_scene.e7`):
  create/destroy/resize, camera/light/cube state, begin frame, box/shape/custom
  draws, and end-frame capture into the host module + frame counter. Temporary
  `es_*` names. JIT-verified full frame on an e7 window: capture is 64x48 RGBA
  and the host frame counter advances. Runtime: **139/139**.
- **9f (done):** engine runs on the e7 platform layers. `engine/main.e7`
  imports `platform`; window/input use `engine_window`; `gpu` uses
  `engine_scene`; `engine_run` uses the SDL/Vulkan-free host module for frame
  limit and capture. The runtime engine's window/input/scene JIT symbol manifest
  was removed; only `e7_engine_read_shader` and `e7_engine_time_now_ms` remain
  host symbols. `zig build run-engine -- --frames 2 --headless --capture`
  writes a 960x540 frame and exits. Remaining visual issue: the captured engine
  frame is empty (geometry/camera path), and ten engine-subset/legacy tests are
  temporarily skipped while their module lists are migrated to include
  `platform`. Runtime: **128 passed, 10 skipped**; compiler 207.
- **9g (done):** `engine_scene` now sizes the scene from the actual window
  (`window_size`) instead of hardcoding 960x540. Empty-frame debugging shows the
  engine scene module itself draws objects (count/UBO non-zero) but captures an
  empty frame in its direct JIT test too, so the issue is inside the engine_scene
  module path rather than the async engine-task context. Temporary probes were
  reverted; suite remains green (128 pass, 10 skipped; compiler 207).
- **9h (done):** fixed the e7 SDL initialization contract: `SDL_InitSubSystem`
  returns true on success, but the e7 wrapper treated true as failure and
  reported success as failure (or vice versa), so several probes/window paths
  were effectively skipped. `video_init` now initializes with `SDL_Init`
  fallback and returns non-zero on success; test probes were aligned.
  `engine-run` also initializes SDL video on the host main thread before the e7
  task runs. e7 platform tests now execute for real; suite: **128 pass,
  10 skipped**; compiler 207. Engine project still captures an empty frame,
  which is now reproducible with genuinely initialized SDL.
- **9i (done):** added opt-in inline task execution (`e7_task_set_inline`), used
  by `engine-run` so the engine task runs synchronously on the host main thread.
  Async i64 return propagation and inline mode are JIT-tested. Inline mode alone
  does not fix the empty engine frame. Suite: **129 pass, 10 skipped**;
  compiler 207.
- **9j (done):** added a regression test compiling the scene as *separate
  modules* (sdl/vulkan/scene + root) and rendering a cube frame. It passes,
  proving module-call lowering and scene rendering work; the empty engine frame
  is therefore specific to the engine project lifecycle/resources, not module
  ABI. Suite: **130 pass, 10 skipped**; compiler 207.
- **9k (done):** removed compiler-known window/input/scene engine intrinsics.
  e7 now owns those calls directly (`e7_engine_window_*`, `e7_engine_scene_*`,
  input) with correct e7 function ABIs; only `e7_engine_time_now_ms` and
  `e7_engine_read_shader` remain host intrinsics. Obsolete semantic/pipeline
  intrinsic tests were updated/removed. Suite: **130 pass, 10 skipped**;
  compiler **206**. The engine frame is still empty.
- **9l (done):** found that a window created in a nested e7 helper must be
  pumped before Vulkan scene creation; without it the scene renders empty.
  `e7_engine_window_create` now pumps the new window, `gpu.create_scene` pumps
  around scene creation, and regression tests cover helper-returned window
  validity, helper-local scene rendering, and helper-window scene rendering
  after pumping. Suite: **133 pass, 10 skipped**; compiler 206. The full engine
  frame is still empty for a further reason.
- **9m (done):** restored the lost inline-task wiring in `engine-run` and
  registered `e7_task_set_inline` in the task symbol manifest, so the engine
  task now executes on the host main thread (verified by matching thread IDs at
  scene create/end/draw). This addresses C FFI/Vulkan thread affinity. The
  engine frame is still empty, so thread affinity was not the remaining sole
  cause. Suite: **133 pass, 10 skipped**; compiler 206.
- **9n (done):** readback now invalidates non-coherent mapped memory
  (`vkInvalidateMappedMemoryRanges`) after the fence wait. Engine scene handles
  were verified valid at draw time (pipeline/render pass/framebuffers non-zero,
  4 swapchain images, 960x540). The engine frame remains empty, with successful
  acquire/submit/wait but zero readback even for the clear color. Suite:
  **133 pass, 10 skipped**; compiler 206.
- **9o (done):** regression test now covers the real e7 engine window wrapper
  plus a raw 960x540 scene (photo capture content) — it renders correctly. GPU
  bypassing `engine_scene` and calling raw scene functions still yields an empty
  engine frame, so the remaining difference is in the engine system/render
  lifecycle, not the window or scene wrappers. Suite: **133 pass, 10 skipped**.
- **9p (done):** added regression for the engine's exact split pattern:
  create/camera/begin/draw in one function, `scene_draw` in another function. It
  renders correctly, so the remaining engine-only failure is inside the
  project/system lifecycle rather than function-boundary behavior. Suite:
  **134 pass, 10 skipped**; compiler 206.
- **9q (done):** added passing regressions for every engine call shape:
  cross-module `scene_draw`, `&receiver` method draw, and inline async-task scene
  draw. All render correctly, leaving the engine project's resource/plugin
  lifecycle as the only remaining difference behind the all-zero engine
  readback. Suite: **137 pass, 10 skipped**; compiler 206.
- Remaining: engine project resource/plugin lifecycle (zero clear/readback only
  there), restore skipped tests, draw text textures, borrowed-window rendering,
  image port, and removing remaining runtime SDL/Vulkan wrappers.

## Migration stages

1. **Raw platform bindings in e7**
   - SDL: `SDL_InitSubSystem`, `SDL_CreateWindow`, `SDL_PollEvent`,
     `SDL_DestroyWindow`, keyboard/mouse/text state, relative mouse mode.
   - Vulkan: instance + physical/logical device + surface + swapchain creation,
     render pass, command buffers, clear/present, readback capture.
   - State is stored in raw allocations (`e7_alloc_bytes`) owned by opaque
     handles; e7 has no mutable globals, so the handle carries the state.

2. **Intrinsic parity**
   - Reimplement `e7_engine_window_*`, input, `e7_engine_scene_*`,
     `e7_font_*`/`e7_text_*`, and `e7_image_*` as e7 functions with the existing
     signatures. Import them into the engine modules so they shadow the
     compiler-known intrinsics.
   - `e7_engine_read_shader` and `e7_engine_time_now_ms` remain generic runtime
     helpers (filesystem/clock, not SDL/Vulkan).

3. **Renderer port**
   - Port the SPIR-V pipeline, vertex/index buffers, uniform slots, descriptor
     sets, texture upload, depth target, and draw paths from
     `runtime/src/ffi/renderer.zig` into e7 using raw-memory Vulkan calls.
   - Keep the shader SPIR-V assets as data consumed by e7.

4. **Remove Zig platform layer**
   - Delete `runtime/src/ffi/{sdl,window,vulkan,renderer}.zig`, `engine.zig`,
     `text.zig`, `image.zig`, the SDL/Vulkan link directives, and the old
     engine/image/text symbol manifests.
   - Move/retire the runtime engine/scene tests with the implementation.

5. **Build/runtime packaging**
   - `engine-run` links only the runtime; e7 loads SDL/Vulkan libraries from
     the platform loader. No SDL/Vulkan headers or libraries in
     `runtime/build.zig`.

## Current blocker

The existing Zig platform layer is ~180 KB of renderer/engine code and is
exercised by 128 runtime tests. Stage 3 must reach visual parity before stage 4
deletes it; otherwise window/scene/UI behavior and capture tests regress.

## Status at round 60

Verified working:

- generic C FFI (`e7_cffi_bind`, `e7_ffi_call0..16`, f32 trampoline)
- e7 SDL window/input module, e7 Vulkan instance/surface/device/queue/
  swapchain/render-pass/depth/pipelines/descriptors/readback
- dynamic per-object UBO slots (16 objects), camera/light/spin
- texture upload + sampled texture frames, blending UI quad, dynamic UI texture
- engine-style lit UBO + texture shader
- e7 SDL_ttf text/font module integrated into the engine
- SDL/Vulkan-free host module (headless flag, frame limit, RGBA capture)
- engine project compiles and runs on e7 window/scene modules; `engine-run`
  writes PPM frames and frame limits via the host module
- runtime engine window/input/scene JIT symbols removed; only
  `e7_engine_read_shader`/`e7_engine_time_now_ms` remain host intrinsics

Known blocker:

- Creating the SDL window/Vulkan scene through an **extra e7 user-function
  boundary** (the shape used by engine systems → gpu methods → platform modules)
  produces a valid scene handle but an empty captured frame. Creation directly
  from the probe function renders correctly. This is isolated to nested e7
  function-call/FFI behavior and is the remaining blocker for engine visual
  parity. Ten engine-subset/legacy tests are skipped while this is resolved.

Not yet done:

- engine visual parity and restoration of the skipped tests
- drawing text-raster textures through the UI quad
- borrowed-window rendering
- image module port
- removal of the remaining runtime SDL/Vulkan/png/turbojpeg links and the
  runtime `engine/window/renderer/vulkan/image` wrapper modules

## Final verified state (round 79)

Verified working:

- generic C FFI, e7 SDL window/input, e7 Vulkan renderer, text/font, host
  frame limit/capture
- engine runs on e7 window/scene modules with inline main-thread execution
- runtime engine window/input/scene JIT symbols removed
- isolated engine call shapes all render: cross-module draw, method receiver,
  inline async task, split begin/draw, 960x540 engine window wrapper
- suite: 137 runtime pass / 10 migration skips / 0 fail, 206 compiler pass

Remaining blocker:

- the full engine project captures an all-zero frame, including clear color.
  Window/scene/depth/pipeline/render-pass/framebuffer handles are non-zero,
  acquire/submit/wait succeed, and the same calls render correctly outside the
  project. Readback pixels are zero inside `scene_draw`, so the project-only
  lifecycle changes render-pass execution or the image being copied.

Unfinished migration items:

- restore the ten skipped engine-subset/legacy tests
- draw text-raster textures through the UI quad
- borrowed-window rendering
- image module port
- remove runtime SDL/Vulkan/png/turbojpeg links and remaining Zig wrappers

## Migration complete

Final state (supersedes the round-79 notes above):

- The runtime links and implements neither SDL3 nor Vulkan: there is no
  `runtime/src/engine.zig`, `src/scene_demo.zig`, or
  `src/ffi/{sdl,window,vulkan,renderer}.zig`, and no vendored Khronos headers.
  `runtime/build.zig` has no SDL/Vulkan link directives or include paths.
- Only the SDL/Vulkan-free host helpers remain in `runtime/src/host_engine.zig`
  (`e7_engine_read_shader`, `e7_engine_time_now_ms`); `runtime/src/host.zig`
  keeps the frame limiter and capture bookkeeping.
- Windows, input, and the Vulkan scene pipeline are `engine/platform/*.e7`
  modules bound dynamically through the generic C FFI.
- The dead runtime shader-asset module and its `runtime/shaders/` SPIR-V copies
  (`assets.zig`, `build.sh`, `run-scene` build graph) are gone.  Shader assets
  live in `engine/shaders/` and `engine/platform/shaders/` and are loaded from
  disk through `e7_engine_read_shader`; `zig build shaders` rebuilds them.
- Dead compiler/bytecode legacy engine window/input/scene runtime-call variants
  were removed from `compiler/src/bytecode.zig`; only `engine_time_now_ms`,
  `engine_read_shader`, and the `host_*` frame/capture entries remain.
- The runtime still links libpng/libjpeg-turbo for image decoding and the
  net/FFI backends (curl, OpenSSL, ngtcp2, libdatachannel); these are unrelated
  to SDL/Vulkan.


## Final parity state

- Engine capture is non-empty and includes the 3D scene, lit materials, uploaded
  meshes, textured UI panels/buttons/labels, and SDL_ttf text glyphs.
- Runtime SDL/Vulkan wrappers, vendored headers, link directives, dead
  compiler/bytecode engine variants, and runtime shader copies are removed.
- Engine window creation is headless-aware (dummy hidden in headless runs,
  visible real-driver window otherwise), mouse capture/buttons and SDL text
  input events are implemented, and non-headless frames present to the
  swapchain.
- All platform shaders use e7s -> Slang -> SPIR-V; e7s supports combined image
  samplers (`Sampler2D<[f32;4]>`) for the textured/UI/lit fragment stages.
- Host PPM capture writes RGB from BGRA swapchain bytes.
- Full suite: scheduler 8, compiler 206, runtime 130, transpiler 26; all pass
  with zero skipped tests (capture assertions now require actual frame content).
- Procedural sphere (UV 16x24), capsule (24 slices, closed band, 8 cap stacks),
  and plane meshes render through the lit pipeline; box keeps the cube. Full
  XYZ Euler transforms, tint, textures, and dynamic UBO slots are preserved.
  Capsule caps are ellipsoidal when Y scale differs from radius (static
  per-kind mesh scaled per axis); this is the only documented visual
  approximation.
