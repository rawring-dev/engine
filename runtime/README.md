# engine7 runtime

The runtime is the bridge between generated code and the host. It provides:

- the LLVM ORC `LLJIT` wrapper (`src/orc.zig`);
- bytecode-to-IR translation for the compiler pipeline (`src/bytecode_ir.zig`);
- a stable `e7_*` C ABI (`src/intrinsics.zig`) for the filesystem, standard
  I/O, TCP/UDP, HTTP/HTTPS, QUIC, WebRTC, and the generic C FFI bridge;
- the host-side FFI implementations under `src/ffi/`;
- SDL/Vulkan-free engine host helpers (`src/host_engine.zig`): monotonic time
  and shader/asset reads. SDL windows, input, and the Vulkan scene pipeline are
  owned by e7 platform modules (`engine/platform/*.e7`), which bind both
  libraries dynamically through the generic C FFI, so the runtime links neither
  SDL3 nor Vulkan;
- the frame limiter and capture bookkeeping (`src/host.zig`).

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
| `src/image.zig` | PNG/JPEG decoding + text output registry (`e7_image_*`) |
| `src/host_engine.zig` | e7 engine host helpers: shader/asset read and monotonic clock |
| `src/host.zig` | headless flag, deterministic frame limiter, capture buffer |
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

## Backend notes and limits

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

`build.zig` links `LLVM-23`, `curl`, `ssl`, `crypto`, `ngtcp2`,
`ngtcp2_crypto_ossl`, `datachannel` (with `png` and `turbojpeg` for image
decoding), plus the workspace `scheduler`/`compiler` modules and LAPACK/BLAS.
SDL3 and Vulkan are deliberately not linked: e7 platform code binds them at
runtime through the generic C FFI. Adjust link names in `build.zig` if your
distribution names the shared objects differently.

## Tests

`zig build test` from this directory runs the runtime tests. The suite includes:

- filesystem sandbox read/write/list/stat/rename and escape rejection;
- STDIO file reads/writes, CRLF line splitting, and invalid-stream rejection;
- dynamic loading of a system math library, `cos`/`strlen` calls, missing
  symbol/library errors, data-symbol reads, and process-handle resolution;
- TCP loopback echo, UDP request/response, hostname resolution;
- HTTP GET/POST against an in-process server;
- QUIC client/server handshake and stream exchange;
- WebRTC offer/answer and data-channel loopback;
- image decoding/upload and text/image intrinsics used by the e7 UI layer;
- e7 platform tests that bind SDL3 and Vulkan dynamically through the generic C
  FFI (window lifecycle, Vulkan surface/triangle capture), including the
  `engine/platform/*.e7` modules and the generic C FFI call path;
- ORC JIT tests that install the full manifest and call filesystem, STDIO,
  TCP, UDP, HTTP, QUIC, and WebRTC intrinsics from generated IR, plus
  e7-source JIT runs.
