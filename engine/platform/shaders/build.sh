#!/usr/bin/env sh
# Build the e7 engine platform shaders from their e7s sources.
#
# Each `<name>.<stage>.e7` is transpiled to Slang with the workspace `e7s`
# tool and the generated Slang is compiled to `<name>.<stage>.spv` with slangc.
# The SPIR-V files are checked in so the JIT engine can run without a shader
# toolchain; `zig build shaders` from the repository root rebuilds both this
# directory and engine/shaders.
#
# Toolchain resolution:
#   e7s:    $E7S, the first script argument (used by `zig build shaders` to pass
#           the exact transpiler artifact), <repo>/transpiler/zig-out/bin/e7s,
#           or `e7s` on PATH.  Build it with `(cd transpiler && zig build)`.
#   slangc: $SLANGC, <repo>/.tooling/slang/bin/slangc, or `slangc` on PATH.
#           Without slangc the e7s sources are still transpiled (so syntax and
#           lowering errors surface) and the checked-in SPIR-V is kept.
#
# Usage:
#   sh engine/platform/shaders/build.sh [e7s]
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$root/../../.." && pwd)

e7s_bin=''
if [ $# -ge 1 ] && [ -n "$1" ]; then
    if [ -x "$1" ]; then e7s_bin=$1; fi
elif [ -n "${E7S:-}" ]; then
    if [ -x "$E7S" ]; then e7s_bin=$E7S; fi
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

slangc_bin=''
if [ -n "${SLANGC:-}" ]; then
    if [ -x "$SLANGC" ]; then slangc_bin=$SLANGC; fi
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

check_magic() {
    magic=$(od -An -tx1 -N4 "$1" | tr -d ' \n')
    if [ "$magic" != "03022307" ]; then
        echo "error: $1 is not SPIR-V (magic $magic)" >&2
        exit 1
    fi
}

# e7s source -> Slang -> SPIR-V.  `triangle.vert.e7` produces the sanitized
# Slang module `triangle_vert.slang` and the SPIR-V file `triangle.vert.spv`.
build_one() {
    source=$1
    stage=$2
    stem=${source%.e7}
    module=$(printf '%s' "$stem" | tr '.' '_')
    output="$stem.spv"

    if ! "$e7s_bin" transpile "$root/$source" -o "$tmpdir" >/dev/null 2>"$tmpdir/e7s.err"; then
        echo "error: e7s failed for $source:" >&2
        cat "$tmpdir/e7s.err" >&2
        exit 1
    fi
    if [ ! -f "$tmpdir/$module.slang" ]; then
        echo "error: e7s did not produce $tmpdir/$module.slang for $source" >&2
        exit 1
    fi

    if [ -n "$slangc_bin" ]; then
        "$slangc_bin" -target spirv -profile spirv_1_3 \
            -entry main -stage "$stage" -o "$root/$output" "$tmpdir/$module.slang"
        check_magic "$root/$output"
        echo "slangc:  $source -> $output"
    else
        echo "e7s:     $source -> $module.slang"
    fi
}

for source_path in "$root"/*.e7; do
    [ -f "$source_path" ] || continue
    source=$(basename "$source_path")
    case "$source" in
        *.vert.e7) stage=vertex ;;
        *.frag.e7) stage=fragment ;;
        *)
            echo "error: cannot infer shader stage from $source" >&2
            exit 1
            ;;
    esac
    build_one "$source" "$stage"
done

if [ -z "$slangc_bin" ]; then
    echo "warning: no slangc found; keeping checked-in SPIR-V." >&2
    for spv in "$root"/*.spv; do
        [ -f "$spv" ] || continue
        check_magic "$spv"
    done
fi
