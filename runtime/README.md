# engine7 runtime

The runtime is the bridge between generated code and the host. It provides:

- the LLVM ORC `LLJIT` wrapper (`src/orc.zig`);
- bytecode-to-IR translation for the compiler pipeline (`src/bytecode_ir.zig`);
- a stable `e7_*` C ABI (`src/intrinsics.zig`) for windows, Vulkan, the
  filesystem, standard I/O, TCP/UDP, HTTP/HTTPS, QUIC, and WebRTC;
- the host-side FFI implementations under `src/ffi/`;
- a basic Vulkan 3D scene renderer (`src/ffi/renderer.zig`) with e7s shader
  sources (`../engine/shaders/`) compiled to embedded SPIR-V (`shaders/`) and a
  native demo (`src/scene_demo.zig`);
- low-level UI input and text rasterization: absolute mouse position/buttons,
  per-frame SDL text input, Backspace/Enter key codes, and SDL3_ttf fonts whose
  rendered text becomes a normal RGBA8 image handle (`src/text.zig`).

## Intrinsic ABI

Every entry point is callable from JITed IR and follows the same conventions:

- Strings are `(pointer, length)` pairs. They are not NUL-terminated.
- Byte results are allocated with `malloc` and released with `e7_free`.
- Handles are opaque `u64` ids. `0` is never a valid handle, except where a
  function returns a plain count or boolean.
- Status returns are `i32` values from `ffi/abi.zig` (`0` = success).
- Out-parameters are pointers to caller-owned slots.
- `e7_last_error` exposes a per-thread diagnostic for the most recent failure.
- Pointer-sized values are `i64` in IR on the 64-bit targets the JIT supports.

Window flags for `e7_window_create` are bit values:
`1` resizable, `2` hidden, `4` high-DPI, `8` Vulkan, `16` borderless, `32`
fullscreen. A window must pass the Vulkan bit before `e7_vk_attach`. Destroy the
Vulkan surface before its window; the surface borrows the window handle.

The manifest is `intrinsics.symbols()`; the matching IR declarations are
`intrinsics.declarations`. Register the manifest once per `Jit`:

```zig
const runtime = @import("runtime");
const orc = runtime.orc;

var jit = try orc.Jit.init(allocator);
defer jit.deinit();
try jit.defineSymbols(runtime.intrinsics.symbols());

// declarations + generated IR (or add them as separate modules)
const ir = runtime.intrinsics.declarations ++
    \\define i32 @entry() {
    \\  ret i32 7
    \\}
;
try jit.addIr(ir, "generated");
```

`defineSymbols` uses `LLVMOrcAbsoluteSymbols` and defines the addresses in the
main `JITDylib`, so the host executable does not need `-rdynamic`.

Example: a JITed function that writes a file through the sandbox:

```llvm
declare i32 @e7_fs_write(ptr, i64, ptr, i64, i32)
declare i64 @e7_clock_ns()

define i64 @append_log(ptr %path, i64 %path_len, ptr %line, i64 %line_len) {
entry:
  %status = call i32 @e7_fs_write(ptr %path, i64 %path_len, ptr %line,
                                  i64 %line_len, i32 1)
  %now = call i64 @e7_clock_ns()
  ret i64 %now
}
```

## Module map

| File | Responsibility |
| --- | --- |
| `src/ffi/abi.zig` | status codes, thread-local error buffer, malloc bridge, `e7_memcpy` |
| `src/ffi/io.zig` | one process-wide `std.Io.Threaded`, `std.Io.Mutex` wrapper |
| `src/ffi/handles.zig` | `u64` -> pointer tables with `create`/`adopt`/`detach` |
| `src/ffi/time.zig` | monotonic and wall clocks, sleep |
| `src/ffi/sdl.zig` | single shared SDL3 + Vulkan `@cImport` |
| `src/ffi/window.zig` | create/destroy/show/hide/title/size, event pump |
| `src/ffi/vulkan.zig` | instance, device, swapchain, colour+depth offscreen target, capture, scene frame hooks |
| `src/ffi/renderer.zig` | SPIR-V pipeline, cube buffers, camera/light uniforms, indexed draw, present/capture |
| `src/scene_demo.zig` | native SDL3 + Vulkan demo executable (`zig build run-scene`) |
| `src/text.zig` | SDL3_ttf font handles, text measurement, text -> RGBA8 image handle |
| `src/image.zig` | PNG/JPEG decoding + text output registry (`e7_image_*`) |
| `src/engine.zig` | e7 engine host ABI: window, scene, camera/light, input, frame limiter |
| `src/ffi/fs.zig` | executable-directory sandbox |
| `src/ffi/stdio.zig` | stdin/stdout/stderr byte and line I/O |
| `src/ffi/dl.zig` | `dlopen`/`LoadLibrary`, symbol lookup, call trampolines, data access |
| `src/ffi/net.zig` | host resolution, TCP listener/stream, UDP socket |
| `src/ffi/http.zig` | libcurl easy interface |
| `src/ffi/quic.zig` | ngtcp2 client/server with OpenSSL TLS 1.3 |
| `src/ffi/webrtc.zig` | libdatachannel peer, SDP, data channels |
| `src/intrinsics.zig` | `e7_*` exports, manifest, declarations |
| `src/jit_tests.zig` | IR-driven tests for every intrinsic family |

### STDIO

`e7_stdio_write`, `e7_stdio_read`, and `e7_stdio_read_line` use stream ids
`0` = stdin, `1` = stdout, `2` = stderr. They are byte-oriented and do not
perform text encoding. Writes go straight to the OS handle, so there is no
userspace buffer to flush; `e7_stdio_flush` exists for API symmetry. Line input
strips `\n` and a trailing `\r`, returns a partial line when the buffer fills,
and reports end-of-stream through the `out_eof` flag. Reads block until data or
EOF arrives; there is no timeout parameter. `e7_stdio_is_tty` reports whether a
stream is a terminal, which is useful for deciding whether to emit ANSI escapes
or interactive prompts.

## Dynamic C libraries

There are two ways for JITed code to reach an arbitrary shared object.

### Typed IR + ORC library generators (recommended)

`Jit.addLibrary(path)` installs LLVM's dynamic-library search generator for one
`.so`, `.dylib`, or `.dll`. Undefined C symbols in subsequently added IR are
resolved from that library at materialization time:

```zig
try jit.addLibrary("libm.so.6");
try jit.addIr(
    \\declare double @cos(double)
    \\define double @my_cos(double %x) {
    \\  %r = call double @cos(double %x)
    \\  ret double %r
    \\}
, "math");
```

`Jit.addProcessSymbols()` additionally reflects symbols already loaded into the
process (the LLVM equivalent of `dlsym(RTLD_DEFAULT, ...)`). This path supports
any C signature that can be written in LLVM IR, including structs by value,
varargs, mixed integer/float arguments, and vector types; the generated IR is
responsible for matching the platform C ABI.

### Runtime loader intrinsics

For runtime-discovered libraries and symbols:

| Intrinsic | Purpose |
| --- | --- |
| `e7_dl_open(path, len, flags)` | Load a library; empty path = current process |
| `e7_dl_open_self(flags)` | Load/reflect the current process |
| `e7_dl_symbol(handle, name, len)` | Resolve a function or data symbol to an address |
| `e7_dl_has_symbol` | Non-destructive existence check |
| `e7_dl_path` | Return the path recorded for the handle |
| `e7_dl_close` | Unload a library (process handles are not unloaded) |

Open flags are bits: `1` lazy, `2` global, `4` now. Zero or no lazy/now bit is
treated as lazy. Windows ignores POSIX visibility flags.

Once an address is known, generated IR can turn it into a typed function
pointer and call it:

```llvm
declare i64 @e7_dl_open(ptr, i64, i32)
declare i64 @e7_dl_symbol(i64, ptr, i64)
declare double @e7_ffi_call_f64_1(i64, double)
declare i32 @e7_dl_close(i64)
```

The trampolines `e7_ffi_call0` through `e7_ffi_call6` cover all-integer /
pointer signatures, and `e7_ffi_call_f64_0` through `_4` cover all-`double`
signatures. They return a 64-bit integer or `double` respectively; a `void`
result may be ignored. Mixed integer/float signatures, aggregate returns,
varargs, and 128-bit values must use typed IR declarations instead, because the
generic trampoline cannot know the ABI classification.

A JIT function can be passed to a C callback by converting its address with
`ptrtoint` and forwarding it through an integer trampoline:

```llvm
%callback = ptrtoint ptr @compare_ints to i64
%ignored = call i64 @e7_ffi_call4(i64 %qsort, i64 %base, i64 %count,
                                  i64 %element_size, i64 %callback)
```

Data symbols are just addresses. `e7_ffi_read(address, buffer, len)` and
`e7_ffi_write(address, data, len)` copy bytes to/from them, or IR can
`inttoptr` and load/store directly.

Loading a shared object executes native code with the full privileges of the
process; there is no library sandbox. Unloading a library invalidates every
address resolved from it, so keep the handle alive while any JITed code may
still call those pointers.

## Filesystem sandbox

The sandbox root is the canonical directory containing the running executable.
`fs.Sandbox` rejects:

- empty paths, NUL bytes, and paths longer than the platform limit;
- absolute paths and paths beginning with a separator;
- any `..` component;
- existing paths whose realpath escapes the root;
- new paths whose nearest existing ancestor's realpath escapes the root;
- removing the root itself.

On platforms/kernels that support it, file creation also sets
`resolve_beneath`. The canonical check is the primary boundary. Like any
in-process path check it is subject to a TOCTOU race if an attacker can mutate
the directory tree concurrently; do not run untrusted native code in the same
process as data you cannot afford to expose.

## 3D scene renderer and demo

`src/ffi/renderer.zig` implements a small forward renderer on top of
`vulkan.Surface`: a SPIR-V vertex/fragment graphics pipeline, a fixed
position/normal/colour vertex format, an indexed unit cube, a host-visible
uniform buffer with one aligned slot per object (model/view/projection columns,
camera position, point-light position/colour/intensity, ambient), a depth-tested
colour+depth offscreen target, dynamic viewport/scissor, and RGBA8 readback.
The per-frame object count is dynamic (initial capacity 64, doubles on demand
as a frame records more objects) — a few hundred objects/frame are routine and
only allocator/descriptor limits return an error.  Each object writes its own
model matrix/tint into a dynamic uniform-buffer slot, so all objects share the
frame's camera/light while having independent transform, shape, material, and
colour.  When the uniform buffer grows mid-frame the old buffer/descriptor
generation stays alive until the next frame boundary.

Objects select geometry per draw: the built-in procedural meshes (box, UV
sphere, capsule, plane) or a custom mesh uploaded from OBJ-style interleaved
arrays.  Materials sample a GPU texture (set 1, bindings 1/2) multiplied by the
per-object RGB tint and the mesh vertex colour; texture id 0 is a built-in
white 1x1 texture, so untextured draws behave exactly like tint-only draws.
Up to `renderer.max_textures` (512) textures can be created per scene.
`drawMesh` (legacy single cube), `captureFrame` (single cube) and
`captureRecordedFrame` (replays the last frame's objects for headless capture)
remain available. The `Surface` owns the
render pass and depth image so its clear/present/capture paths and the scene
renderer share one target; `beginScene`/`endScenePresent` and
`beginSceneCapture`/`endSceneCapture` are the recording hooks.

The canonical shader sources are e7s files in `../engine/shaders`; `zig build
shaders` (or `shaders/build.sh`, which delegates to the engine build) runs the
e7s transpiler to produce Slang and compiles it with `slangc`.  This directory
keeps only the generated SPIR-V (embedded by `assets.zig`) and falls back to
the checked-in `.spv` files when no shader compiler is installed (verified for
the SPIR-V magic number).  Its 272-byte uniform block stores matrices as
column-major `[f32; 4, 4]` fields (e7s emits `column_major float4x4`), so host
`Mat4[col][row]` data uploads directly; the trailing `tint` field multiplies
the mesh's vertex colour so every object can have its own colour.  See
`shaders/README.md` and `../engine/shaders/README.md` for the layout.

The scene ABI is:

| Function | Notes |
| --- | --- |
| `e7_scene_create(window, vert_spv, vert_len, frag_spv, frag_len) -> u64` | `0` on failure; window must have the Vulkan flag and outlive the scene |
| `e7_scene_destroy(handle) -> i32` | destroys the scene and its Vulkan surface |
| `e7_scene_resize(handle, width, height) -> i32` | `0`/negative sizes just sync to the current window size |
| `e7_scene_set_camera(handle, eye_x, eye_y, eye_z, yaw, pitch) -> i32` | f32 values as IEEE-754 bit patterns in `i64` (`@bitCast` of the low 32 bits) |
| `e7_scene_draw(handle, delta_s, cube_angle, light_x, light_y, light_z) -> i32` | same i64 float convention; renders and presents |
| `e7_scene_capture(handle, out_ptr, out_len, out_w, out_h) -> i32` | malloc-owned RGBA8 pixels for headless checks; release with `e7_free` |

The e7 engine host uses a higher-level per-object ABI in
`runtime/src/engine.zig` between `e7_engine_scene_begin_frame` and
`e7_engine_scene_end_frame`:

| Function | Notes |
| --- | --- |
| `e7_engine_scene_draw_box(handle, x, y, z, sx, sy, sz, angle_milli_radians) -> i64` | legacy box draw; white tint |
| `e7_engine_scene_draw_shape(handle, kind, x, y, z, sx, sy, sz, angle_milli_radians, r, g, b) -> i64` | `kind` 0 box / 1 sphere / 2 capsule / 3 plane; position/scale in milli-units, Y rotation in milli-radians, RGB tint in milli (1000 = 1.0) |
| `e7_engine_scene_draw_shape_tex(handle, kind, ..., r, g, b, texture_id) -> i64` | same as `draw_shape` plus a material texture id |
| `e7_engine_scene_texture_create(handle, image_handle) -> u64` | upload an `e7_image_load` RGBA8 image as a sampled texture; `0` on failure, ids start at 1 |
| `e7_engine_scene_texture_destroy(handle, texture_id) -> i64` | free a user texture (texture 0 is the built-in white texture and cannot be destroyed) |
| `e7_engine_scene_mesh_upload(handle, vertices, indices, layout) -> u64` | upload `[f32]` interleaved vertices + `[i32]` indices (layout 0 = pos3+normal3+uv2, layout 1 = pos3+normal3+colour3+uv2); `0` on failure, mesh ids start at 1 |
| `e7_engine_scene_draw_custom(handle, mesh_id, ..., r, g, b, texture_id) -> i64` | draw an uploaded custom mesh |
| `e7_engine_scene_draw_shape_rot(handle, kind, x, y, z, sx, sy, sz, rx, ry, rz, r, g, b, texture_id) -> i64` | full XYZ Euler orientation: `rx/ry/rz` are milli-radians (roll/pitch/yaw), composed `Rz * Ry * Rx` to match the physics quaternion convention |
| `e7_engine_scene_draw_custom_rot(handle, mesh_id, x, y, z, sx, sy, sz, rx, ry, rz, r, g, b, texture_id) -> i64` | same full-orientation draw for uploaded meshes |

Rotation convention: the legacy `draw_shape`/`draw_custom` ABI still takes a
single Y angle (radians); the `*_rot` variants take an intrinsic-XYZ Euler
triple in milli-radians (`x` = roll, `y` = pitch, `z` = yaw) and build
`model = T * Rz * Ry * Rx * S`, which is exactly
`physics::quat_from_euler`/`quat_to_euler`'s convention.  e7 passes
`Transform.rotation[0..2]` through `scene.e7` so physics tumbling around X/Z
now renders.

The per-object draw calls return `0` on success and `-1` when no frame is
active, the kind/texture/mesh is invalid, or allocation fails; handle-producing
calls return `0` on failure.  The renderer owns one vertex/index mesh per
built-in shape kind (`cube`, UV sphere, capsule with hemispherical caps, flat
XZ plane) plus uploaded custom meshes, so every object shares one pipeline
(two descriptor sets: set 0 dynamic uniforms, set 1 material texture/sampler)
while selecting geometry and material per draw.

The `i64`-bitcast convention exists because all JIT ABI values are `i64`. For
example `1.0f` is `0x3F800000` = `1065353216`; helpers truncate to 32 bits, so
zero-extended and sign-extended callers both work.

A scene owns its own `vulkan.Surface` (instance through offscreen targets), so
attach either a scene or a plain `e7_vk_attach` surface to a given window, not
both. Destroy the scene before the window. `e7_scene_draw` presents a frame
every call; `e7_scene_capture` is the readback path for tests/headless use.

Run the demo from the workspace root (needs a display and a Vulkan device):

```sh
zig build run-scene                                  # interactive
zig build run-scene -- --frames 120                  # auto-exit
zig build run-scene -- --headless --capture scene.ppm # hidden window + PPM
```

Controls: WASD moves on the ground plane, Q/E moves down/up, Shift sprints,
the mouse (relative mode) or arrow keys look around, Esc or the window close
button exits. With no SDL video driver or Vulkan device the demo prints a skip
message and exits successfully, so `zig build run-scene -- --headless` is safe
as a smoke test on headless machines. On nested/remote Wayland sessions where a
visible window never gets composited, force the X11 backend with
`SDL_VIDEODRIVER=x11`; the headless capture mode does not need a shown window.

## UI input and text rasterization

Low-level input state for an e7 UI layer (no widget policy lives here):

| Intrinsic | Notes |
| --- | --- |
| `e7_engine_mouse_x() -> i64`, `e7_engine_mouse_y() -> i64` | absolute cursor position in SDL window coordinates (top-left origin), updated from `SDL_EVENT_MOUSE_MOTION` |
| `e7_engine_mouse_down(button) -> i64` | `0` left, `1` right, `2` middle; other indices return 0. Tracked from mouse-button events |
| `e7_engine_text_input() -> str` | UTF-8 bytes collected from `SDL_EVENT_TEXT_INPUT` since the last `e7_engine_window_pump`; empty when nothing was typed, cleared at the start of the next pump |
| `e7_engine_key_down(code)` | existing action codes 0-11 plus `12` Backspace and `13` Enter (Return/Keypad Enter) |
| `e7_engine_scene_draw_ui_quad(handle, texture_id, x, y, w, h, r, g, b, a) -> i64` | screen-space textured quad for UI; see below |

The existing `e7_engine_mouse_dx/dy` relative-motion intrinsics still drive
camera look; absolute position is for hit-testing. `text_input` returns a
freshly allocated e7 `str` per call, so UI code should query it once per frame
(or free the handle). HiDPI callers may need to scale window coordinates to
pixel coordinates using the window size they already track.

Text/font ABI (`src/text.zig`, links `SDL3_ttf`):

| Intrinsic | Notes |
| --- | --- |
| `e7_font_load(path: str, size: i64) -> u64` | `TTF_OpenFont` at `size` points; `0` on failure (missing font/init error) |
| `e7_font_free(handle) -> i32` | closes the font; `0` success, `1` invalid/duplicate free |
| `e7_text_measure(font, text: str) -> i64` | packed `(width << 32) \| height` in pixels; `0` on invalid handle/API failure |
| `e7_text_image(font, text: str, r, g, b) -> u64` | blended UTF-8 text on a transparent background; returns an **image handle** in the existing image registry (tightly packed top-down RGBA8), usable with `e7_image_width/height/pixels/free` and as a GPU texture via `e7_engine_scene_texture_create` |

`path` is an ordinary filesystem path; the runtime does not bundle a font.
Callers can pass a system font path (e.g. `/usr/share/fonts/TTF/DejaVuSans.ttf`)
or a project asset path. Glyph colour components are clamped to 0..255. The
headless tests skip gracefully when no system TrueType font is installed.

### Screen-space UI quads

`e7_engine_scene_draw_ui_quad` must be called between
`e7_engine_scene_begin_frame` and `e7_engine_scene_end_frame`, after the 3D
world draws.  It records into the same render pass/frame and is presented with
the world (no separate pass or present):

- `x`/`y` are pixels from the **top-left** of the swapchain; `w`/`h` are pixel
  sizes.  The renderer converts them to Vulkan clip space with the current
  swapchain extent (y is flipped to match Vulkan's NDC), so it tracks window
  resizes.
- `r`/`g`/`b`/`a` are 0..255 straight-alpha tint components (multiplied with
  the texture).  Texture ids come from `e7_engine_scene_texture_create` (text
  images from `e7_text_image` work directly); id 0 is the built-in white
  texture, i.e. a solid tinted rectangle.
- Depth test and depth writes are disabled for the UI pipeline: quads paint
  over the 3D scene in call order.  Colour blending is straight alpha
  (`SrcAlpha`, `OneMinusSrcAlpha`; alpha `One`, `OneMinusSrcAlpha`).
- Up to a few hundred quads per frame are supported; the vertex buffer and the
  queued-quad list grow on demand.  Invalid frame/texture/size returns `-1`.
  `e7_engine_scene_capture`/engine captures replay the queued quads.

## Backend notes and limits

- **SDL/Vulkan** work must be serialized per window/surface. Window creation and
  event polling belong on the main thread on platforms that require it (macOS).
  The Vulkan path picks the first graphics-capable queue family that can present
  to the window; it does not implement multi-GPU transfer queues. A surface
  borrows its window, so destroy the surface first.
- `e7_vk_capture` renders a clear-colour frame to an offscreen colour image and
  copies it back as tightly packed RGBA8. It uses the swapchain format for the
  offscreen image, so the blit is format-identical; BGRA results are byte-swapped
  on the CPU. The offscreen render pass now also owns a depth attachment
  (`D32_SFLOAT` when available), which the scene renderer uses; the plain
  `e7_vk_present`/`e7_vk_capture` paths simply clear it. 3D drawing is exposed
  through `e7_scene_*`, not through `e7_vk_present`.
- **QUIC** supports one bidirectional stream per connection and one accepted
  connection per listener at a time. Both endpoints drive ngtcp2's timers in a
  blocking loop with short UDP receive timeouts. ALPN is mandatory. Certificates
  and keys are PEM byte slices; the test certificate under
  `src/ffi/testdata/` is for tests only.
- **WebRTC** uses non-trickle ICE: after gathering completes, the local SDP
  already contains host candidates. This works on loopback and LANs without
  STUN/TURN; pass STUN/TURN URLs in the comma-separated `ice_servers` argument
  when needed. Peer creation and SDP exchange are synchronous.
- **STDIO** writes are unbuffered at this layer. `e7_stdio_read_line` reads one
  byte at a time, which is fine for terminals and pipes but not intended for
  high-throughput bulk input; use `e7_stdio_read` for that.
- **TCP** accepts and reads honour millisecond timeouts by polling on POSIX; the
  Windows path falls back to blocking calls. `std.Io`'s POSIX connect deadline
  is currently unimplemented, so connects are blocking.
- **HTTP/HTTPS** uses libcurl's default trust store and follows up to ten
  redirects. Request bodies are byte slices; responses are returned as
  malloc-owned byte buffers with the numeric status code.

## Build dependencies

`build.zig` links `LLVM-23`, `SDL3`, `vulkan`, `curl`, `ssl`, `crypto`,
`ngtcp2`, `ngtcp2_crypto_ossl`, `datachannel`, and `SDL3_ttf` (with `png` and
`turbojpeg` for image decoding), plus the workspace
`scheduler`/`compiler` modules and LAPACK/BLAS. The `scene-demo` executable is
lighter: it links only SDL3 and Vulkan and embeds the checked-in SPIR-V through
the `shader_assets` module, so it does not need LLVM or the compiler. The vendored Khronos headers in
`vendor/` are added as an include path. Adjust link names in `build.zig` if your
distribution names the shared objects differently.

## Tests

`zig build test` from this directory runs the runtime tests. The suite includes:

- filesystem sandbox read/write/list/stat/rename and escape rejection;
- STDIO file reads/writes, CRLF line splitting, and invalid-stream rejection;
- dynamic loading of a system math library, `cos`/`strlen` calls, missing
  symbol/library errors, data-symbol reads, and process-handle resolution;
- TCP loopback echo, UDP request/response, hostname resolution;
- HTTP GET/POST against an in-process server;
- SDL hidden-window creation and event delivery;
- Vulkan probe (skipped when no physical device is visible) and, when a device
  is present, hidden-window present/capture;
- scene renderer math/shader validation, plus a headless pipeline test that
  renders a cube, checks lit pixels, and verifies spin/light/resize changes
  (skipped without display/Vulkan);
- QUIC client/server handshake and stream exchange;
- WebRTC offer/answer and data-channel loopback;
- SDL3_ttf text tests (system font -> measure -> RGBA8 text image with opaque
  glyphs and transparent background; skipped if no font exists);
- engine UI input tests (mouse position/buttons, per-frame text input,
  Backspace/Enter key codes) and a JIT probe that resolves the input and
  font/text intrinsics from generated IR;
- screen-space UI quad tests: world + overlapping opaque/50%-alpha/checker
  quads (blend values checked), 300-quad growable frame, capture replay, and a
  system-font `e7_text_image` uploaded as a UI texture;
- ORC JIT tests that install the full manifest and call filesystem, STDIO,
  TCP, UDP, HTTP, window, Vulkan, scene, QUIC, and WebRTC intrinsics from
  generated IR.
