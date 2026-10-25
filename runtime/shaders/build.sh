#!/usr/bin/env sh
# Compatibility entry point for the runtime shader assets.
#
# Canonical shader sources now live in engine/shaders as e7s (.e7).  This
# script simply delegates to engine/shaders/build.sh, which transpiles the e7s
# sources to Slang, compiles them to SPIR-V, and publishes the updated .spv
# files here (the runtime embeds them via `assets.zig`).
#
# Usage:
#   sh runtime/shaders/build.sh
#   sh engine/shaders/build.sh          # canonical entry point
#   zig build shaders                   # from the workspace or runtime package
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
engine_build="$root/../../engine/shaders/build.sh"

if [ ! -f "$engine_build" ]; then
    echo "error: engine/shaders/build.sh not found at $engine_build" >&2
    exit 1
fi

exec sh "$engine_build" "$@"
