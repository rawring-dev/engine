# engine7 runtime

The runtime is the bridge between generated code and the host. It provides:

- the LLVM ORC `LLJIT` wrapper (`src/orc.zig`);
- bytecode-to-IR translation for the compiler pipeline (`src/bytecode_ir.zig`);
- a stable `e7_*` C ABI (`src/intrinsics.zig`) for windows, Vulkan, the
  filesystem, standard I/O, TCP/UDP, HTTP/HTTPS, QUIC, and WebRTC;
- the host-side FFI implementations under `src/ffi/`;
- a basic Vulkan 3D scene renderer (`src/ffi/renderer.zig`) with e7s shader
  sources (`../engine/shaders/`) compiled to embedded SPIR-V (`shaders/`) and a
  native demo (`src/scene_demo.zig`).

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
| `src/ffi/fs.zig` | executable-directory sandbox |
| `src/ffi/stdio.zig` | stdin/stdout/stderr byte and line I/O |
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
Up to `renderer.max_objects` (64) boxes can be drawn per frame; each `drawBox`
writes its own model matrix into a dynamic uniform-buffer slot, so all objects
share the frame's camera/light while having independent position/scale/Y
rotation. `drawMesh` (legacy single cube), `captureFrame` (single cube) and
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

Both return `0` on success and `-1` when no frame is active, the kind is
invalid, or the 64-object limit is exceeded.  The renderer owns one
vertex/index mesh per shape kind (`cube`, UV sphere, capsule with hemispherical
caps, flat XZ plane), so every object shares one pipeline and one dynamic
uniform slot while selecting its geometry per draw.

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
`ngtcp2`, `ngtcp2_crypto_ossl`, and `datachannel`, plus the workspace
`scheduler`/`compiler` modules and LAPACK/BLAS. The `scene-demo` executable is
lighter: it links only SDL3 and Vulkan and embeds the checked-in SPIR-V through
the `shader_assets` module, so it does not need LLVM or the compiler. The vendored Khronos headers in
`vendor/` are added as an include path. Adjust link names in `build.zig` if your
distribution names the shared objects differently.

## Tests

`zig build test` from this directory runs the runtime tests. The suite includes:

- filesystem sandbox read/write/list/stat/rename and escape rejection;
- STDIO file reads/writes, CRLF line splitting, and invalid-stream rejection;
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
- ORC JIT tests that install the full manifest and call filesystem, STDIO,
  TCP, UDP, HTTP, window, Vulkan, scene, QUIC, and WebRTC intrinsics from
  generated IR.
