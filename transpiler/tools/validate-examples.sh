#!/bin/sh
# Transpile every e7s example (plus the canonical engine/shaders sources) and
# compile the generated Slang to SPIR-V.
#
# Requires a built CLI and a Slang compiler:
#   (cd transpiler && zig build)
#   sh transpiler/tools/validate-examples.sh
#
# SLANGC can point at a specific slangc; otherwise check-slang.sh falls back to
# the repo's .tooling/slang/bin/slangc and then PATH.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
transpiler_dir=$(CDPATH= cd -- "$script_dir/.." && pwd) || exit 2
e7s=${E7S:-"$transpiler_dir/zig-out/bin/e7s"}

if [ ! -x "$e7s" ]; then
    echo "validate-examples: no e7s binary at $e7s" >&2
    echo "  build it first: (cd transpiler && zig build)" >&2
    exit 2
fi

tmpdir=$(mktemp -d 2>/dev/null) || { echo "validate-examples: cannot create temp dir" >&2; exit 2; }
trap 'rm -rf "$tmpdir"' EXIT INT TERM HUP
mkdir -p "$tmpdir/single" "$tmpdir/modules" "$tmpdir/engine"

# Every single-module example.  Dotted stems (triangle.vert.e7) are sanitized
# to triangle_vert.slang by the CLI.
for source in "$transpiler_dir"/examples/*.e7; do
    [ -f "$source" ] || continue
    echo "e7s: $(basename "$source")"
    "$e7s" transpile "$source" -o "$tmpdir/single"
done

# Multi-module project (root loads sibling math.e7).
echo "e7s: examples/modules/main.e7 (project)"
"$e7s" transpile "$transpiler_dir/examples/modules/main.e7" -o "$tmpdir/modules"

# Canonical engine scene shaders (already e7s).
for source in "$transpiler_dir"/../engine/shaders/*.e7; do
    [ -f "$source" ] || continue
    echo "e7s: engine/shaders/$(basename "$source")"
    "$e7s" transpile "$source" -o "$tmpdir/engine"
done

echo
sh "$script_dir/check-slang.sh" "$tmpdir/single" "$tmpdir/modules" "$tmpdir/engine"
