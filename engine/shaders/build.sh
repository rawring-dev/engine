#!/usr/bin/env sh
# Engine shader build: Slang -> SPIR-V for the engine scaffold.
# The runtime scene renderer embeds the same Slang sources from
# runtime/shaders; this script keeps engine assets in sync.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime="$root/../../runtime/shaders"
cp "$runtime/cube.vert.slang" "$root/cube.vert.slang"
cp "$runtime/cube.frag.slang" "$root/cube.frag.slang"
sh "$runtime/build.sh" "$@"
cp "$runtime/cube.vert.spv" "$root/cube.vert.spv"
cp "$runtime/cube.frag.spv" "$root/cube.frag.spv"
