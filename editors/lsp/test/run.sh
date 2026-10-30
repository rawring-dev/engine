#!/usr/bin/env bash
#
# End-to-end tests for the engine7 language server.
#
# Usage (from anywhere):
#   bash editors/lsp/test/run.sh
#
# Builds `zig-out/bin/e7-lsp` when needed, then drives it over stdio with the
# Python conformance client.  Exits 0 only if every assertion passes.
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
binary="${E7_LSP_BIN:-$repo_root/zig-out/bin/e7-lsp}"

# Rebuild when the binary is missing or older than the LSP/compiler sources, so
# the suite never passes against a stale server.  An explicit E7_LSP_BIN is
# authoritative and never rebuilt.
if [ -z "${E7_LSP_BIN:-}" ]; then
  needs_build=0
  if [ ! -x "$binary" ]; then
    needs_build=1
  elif [ -n "$(find "$repo_root/editors/lsp/src" "$repo_root/compiler/src" \
      "$repo_root/compiler/build.zig" "$repo_root/build.zig" "$repo_root/build.zig.zon" \
      -newer "$binary" -print -quit 2>/dev/null)" ]; then
    needs_build=1
  fi
  if [ "$needs_build" -eq 1 ]; then
    if command -v zig >/dev/null 2>&1; then
      echo "==> building e7-lsp"
      # The sandbox may make ~/.cache/zig read-only; keep Zig's global cache in
      # the workspace (also used by the writers of this repository).
      if ! (cd "$repo_root" && ZIG_GLOBAL_CACHE_DIR="$repo_root/.zig-cache/global" zig build lsp); then
        echo "error: failed to build e7-lsp (try: zig build lsp)" >&2
        exit 1
      fi
    else
      echo "error: e7-lsp is missing or stale and zig is not on PATH ($binary)" >&2
      echo "       run 'zig build lsp' from $repo_root or set E7_LSP_BIN" >&2
      exit 127
    fi
  fi
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for the LSP conformance test" >&2
  exit 127
fi

if [ ! -f "$script_dir/client.py" ]; then
  echo "error: missing test client: $script_dir/client.py" >&2
  exit 1
fi

echo "==> e7-lsp protocol conformance ($binary)"
python3 "$script_dir/client.py" "$binary" --workspace "$repo_root" "$@"
status=$?

if [ "$status" -ne 0 ]; then
  echo "FAIL: engine7 language server tests failed (exit $status)" >&2
  exit "$status"
fi

echo "PASS: engine7 language server tests"
