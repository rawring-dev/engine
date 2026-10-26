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
- Remaining: e7 intrinsic wrappers, image/text, and deletion of the Zig layer.

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
