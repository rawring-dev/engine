#!/bin/sh
# Compile runtime/shaders/*.slang to SPIR-V.
#
# The sources are HLSL-compatible Slang.  Toolchain preference:
#   1. slangc               (canonical Slang compiler; not installed everywhere)
#   2. glslangValidator -D  (HLSL front end; the tested fallback here)
#   3. glslc -x hlsl        (shaderc HLSL front end)
#   4. no compiler          -> keep the checked-in SPIR-V and print a warning
#
# The generated .spv files are checked in so `zig build run-scene` works on
# machines without any shader compiler.  Run `zig build shaders` after editing
# a .slang source.
set -eu

cd "$(dirname "$0")"

compile_pair() {
    src="$1"
    stage="$2"
    out="$3"

    if [ -n "${SLANGC:-}" ] || command -v slangc >/dev/null 2>&1; then
        slangc_bin="${SLANGC:-slangc}"
        "$slangc_bin" -target spirv -entry main -stage "$stage" -o "$out" "$src"
        echo "slangc: $src -> $out"
    elif command -v glslangValidator >/dev/null 2>&1; then
        glslangValidator -D -e main -S "$stage" --target-env vulkan1.1 -o "$out" "$src"
        echo "glslangValidator (HLSL fallback): $src -> $out"
    elif command -v glslc >/dev/null 2>&1; then
        glslc -x hlsl -fshader-stage="$stage" -fentry-point=main -o "$out" "$src"
        echo "glslc (HLSL fallback): $src -> $out"
    elif [ -f "$out" ]; then
        echo "warning: no shader compiler (slangc/glslangValidator/glslc) found;" \
             "using checked-in $out" >&2
    else
        echo "error: no shader compiler found and $out is missing" >&2
        exit 1
    fi
}

compile_pair cube.vert.slang vert cube.vert.spv
compile_pair cube.frag.slang frag cube.frag.spv

# SPIR-V magic, little endian: 0x07230203.
check_magic() {
    magic=$(od -An -tx1 -N4 "$1" | tr -d ' \n')
    if [ "$magic" != "03022307" ]; then
        echo "error: $1 is not SPIR-V (magic $magic)" >&2
        exit 1
    fi
}

check_magic cube.vert.spv
check_magic cube.frag.spv
echo "SPIR-V ready: $(ls -l cube.vert.spv cube.frag.spv | awk '{print $9 " (" $5 " bytes)"}' | tr '\n' ' ')"
