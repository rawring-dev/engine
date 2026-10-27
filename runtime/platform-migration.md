# SDL/Vulkan runtime migration

Goal: the `runtime` package must not link or implement SDL3/Vulkan. The e7
engine owns the platform intrinsics and reaches SDL/Vulkan through the generic
C FFI, using only `e7_dl_*` / `e7_cffi_bind` / `e7_ffi_call*` and raw memory.

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
- Remaining: engine draw-shape/mesh/texture/UI parity, image port, and deletion
  of the Zig layer.

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
