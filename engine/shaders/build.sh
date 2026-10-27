#!/usr/bin/env sh
# Build the engine7 scene shaders from their e7s sources.
#
#   engine/shaders/cube.vert.e7 --(e7s)--> cube_vert.slang --(slangc)--> cube.vert.spv
#   engine/shaders/cube.frag.e7 --(e7s)--> cube_frag.slang --(slangc)--> cube.frag.spv
#   engine/shaders/ui.vert.e7   --(e7s)--> ui_vert.slang   --(slangc)--> ui.vert.spv
#   engine/shaders/ui.frag.e7   --(e7s)--> ui_frag.slang   --(slangc)--> ui.frag.spv
#
# The generated Slang and SPIR-V are produced in a temporary directory.  The
# SPIR-V is copied into this directory, where the e7 engine loads it from disk
# through `e7_engine_read_shader`, so `zig build run-engine` and `zig build
# test` never need a shader compiler.
#
# Toolchain resolution:
#   e7s:    $E7S, the first script argument (used by `zig build shaders` to pass
#           the exact transpiler artifact), <repo>/transpiler/zig-out/bin/e7s,
#           or `e7s` on PATH.  Build it with `(cd transpiler && zig build)`.
#   slangc: $SLANGC, <repo>/.tooling/slang/bin/slangc, or `slangc` on PATH.
#           Without slangc the checked-in SPIR-V is kept (with a warning), but
#           the e7s sources are still transpiled so source errors are caught.
#
# Usage:
#   sh engine/shaders/build.sh [e7s]
#   E7S=/path/to/e7s SLANGC=/path/to/slangc sh engine/shaders/build.sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$root/../.." && pwd)

# ---------------------------------------------------------------------------
# Resolve the e7s transpiler
# ---------------------------------------------------------------------------
e7s_bin=''
if [ $# -ge 1 ] && [ -n "$1" ]; then
    candidate=$1
    if [ -x "$candidate" ]; then
        e7s_bin=$candidate
    fi
elif [ -n "${E7S:-}" ]; then
    if [ -x "$E7S" ]; then
        e7s_bin=$E7S
    fi
elif [ -x "$repo/transpiler/zig-out/bin/e7s" ]; then
    e7s_bin="$repo/transpiler/zig-out/bin/e7s"
elif command -v e7s >/dev/null 2>&1; then
    e7s_bin=$(command -v e7s)
fi

if [ -z "$e7s_bin" ]; then
    echo "error: e7s transpiler not found." >&2
    echo "  build it first: (cd \"$repo/transpiler\" && zig build)" >&2
    echo "  or set E7S=/path/to/e7s" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve slangc (optional; checked-in SPIR-V is the fallback)
# ---------------------------------------------------------------------------
slangc_bin=''
if [ -n "${SLANGC:-}" ]; then
    if [ -x "$SLANGC" ]; then
        slangc_bin=$SLANGC
    fi
elif [ -x "$repo/.tooling/slang/bin/slangc" ]; then
    slangc_bin="$repo/.tooling/slang/bin/slangc"
elif command -v slangc >/dev/null 2>&1; then
    slangc_bin=$(command -v slangc)
fi

tmpdir=$(mktemp -d 2>/dev/null) || {
    echo "error: cannot create temporary build directory" >&2
    exit 1
}
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# e7s -> Slang
# ---------------------------------------------------------------------------
transpile() {
    source=$1
    output=$2
    if ! "$e7s_bin" transpile "$root/$source" -o "$tmpdir" >/dev/null 2>"$tmpdir/e7s.err"; then
        echo "error: e7s failed for $source:" >&2
        cat "$tmpdir/e7s.err" >&2
        exit 1
    fi
    if [ ! -f "$tmpdir/$output" ]; then
        echo "error: e7s did not produce $tmpdir/$output for $source" >&2
        exit 1
    fi
    echo "e7s:   $source -> $output"
}

transpile cube.vert.e7 cube_vert.slang
transpile cube.frag.e7 cube_frag.slang
transpile ui.vert.e7 ui_vert.slang
transpile ui.frag.e7 ui_frag.slang

# ---------------------------------------------------------------------------
# Slang -> SPIR-V, then sync the SPIR-V into engine/shaders/
# ---------------------------------------------------------------------------
check_magic() {
    magic=$(od -An -tx1 -N4 "$1" | tr -d ' \n')
    if [ "$magic" != "03022307" ]; then
        echo "error: $1 is not SPIR-V (magic $magic)" >&2
        exit 1
    fi
}

publish() {
    spv=$1
    check_magic "$tmpdir/$spv"
    cp "$tmpdir/$spv" "$root/$spv"
    echo "slangc: $spv"
}

if [ -n "$slangc_bin" ]; then
    compile_pair() {
        source=$1
        stage=$2
        output=$3
        # The e7 Vulkan platform module creates a Vulkan 1.1 device; target
        # SPIR-V 1.3 to match the original glslang-generated assets
        # (Vulkan 1.1's SPIR-V baseline).
        "$slangc_bin" -target spirv -profile spirv_1_3 \
            -entry main -stage "$stage" -o "$tmpdir/$output" "$tmpdir/$source"
    }
    compile_pair cube_vert.slang vertex cube.vert.spv
    compile_pair cube_frag.slang fragment cube.frag.spv
    compile_pair ui_vert.slang vertex ui.vert.spv
    compile_pair ui_frag.slang fragment ui.frag.spv
    publish cube.vert.spv
    publish cube.frag.spv
    publish ui.vert.spv
    publish ui.frag.spv
    echo "SPIR-V ready: cube.vert.spv, cube.frag.spv, ui.vert.spv, ui.frag.spv"
else
    echo "warning: no slangc found; keeping checked-in SPIR-V." >&2
    echo "         e7s sources transpiled successfully; install slangc to rebuild." >&2
    if [ -f "$root/cube.vert.spv" ] && [ -f "$root/cube.frag.spv" ] &&
        [ -f "$root/ui.vert.spv" ] && [ -f "$root/ui.frag.spv" ]; then
        check_magic "$root/cube.vert.spv"
        check_magic "$root/cube.frag.spv"
        check_magic "$root/ui.vert.spv"
        check_magic "$root/ui.frag.spv"
    else
        echo "error: no slangc and no checked-in SPIR-V at $root" >&2
        exit 1
    fi
fi
