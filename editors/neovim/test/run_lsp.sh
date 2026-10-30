#!/usr/bin/env bash
#
# Non-interactive LSP integration tests for the engine7 Neovim plugin.
#
# Usage (from anywhere):
#   bash editors/neovim/test/run_lsp.sh
#
# The server binary is taken from $E7_LSP_BIN when set, otherwise from
# zig-out/bin/e7-lsp in the repository root.  When the repository-local binary
# is missing (or older than the server sources) it is built with
#   ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache/global zig build lsp
# The global cache override is required in sandboxes where ~/.cache/zig is
# read-only.
#
# Exits 0 only if every assertion passes.  Uses nvim with no user config and
# leaves no files behind.
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$plugin_dir/../.." && pwd)"

fixture="$repo_root/editors/samples/kitchen_sink.tri"
spec="$script_dir/lsp_spec.lua"
nvim_bin="${NVIM:-nvim}"

if ! command -v "$nvim_bin" >/dev/null 2>&1; then
  echo "error: nvim not found (set NVIM to point at a binary)" >&2
  exit 127
fi

if [ ! -f "$fixture" ]; then
  echo "error: shared fixture not found: $fixture" >&2
  exit 1
fi

if [ ! -f "$spec" ]; then
  echo "error: test spec not found: $spec" >&2
  exit 1
fi

# Resolve the language server.  An explicit E7_LSP_BIN is authoritative and is
# never rebuilt; otherwise use (and, if needed, build) the repository binary.
if [ -n "${E7_LSP_BIN:-}" ]; then
  bin="$E7_LSP_BIN"
  if [ ! -x "$bin" ]; then
    echo "error: E7_LSP_BIN is not executable: $bin" >&2
    exit 1
  fi
else
  bin="$repo_root/zig-out/bin/e7-lsp"
  needs_build=0
  if [ ! -x "$bin" ]; then
    needs_build=1
  elif [ -n "$(find "$repo_root/editors/lsp/src" "$repo_root/compiler/src" \
      "$repo_root/compiler/build.zig" "$repo_root/build.zig" "$repo_root/build.zig.zon" \
      -newer "$bin" -print -quit 2>/dev/null)" ]; then
    # Never test a stale server: it links the compiler module, so compiler
    # changes require a rebuild just like changes to the LSP sources.
    needs_build=1
  fi

  if [ "$needs_build" -eq 1 ]; then
    if ! command -v zig >/dev/null 2>&1; then
      echo "error: $bin is missing or stale and zig is not on PATH" >&2
      echo "       run 'zig build lsp' in $repo_root (with a writable Zig cache)" >&2
      exit 1
    fi
    echo "building e7-lsp with 'zig build lsp'..."
    if ! ( cd "$repo_root" && ZIG_GLOBAL_CACHE_DIR="$repo_root/.zig-cache/global" zig build lsp ); then
      echo "error: 'zig build lsp' failed" >&2
      exit 1
    fi
    if [ ! -x "$bin" ]; then
      echo "error: 'zig build lsp' did not produce $bin" >&2
      exit 1
    fi
  fi
fi

# Make the path absolute: the spec compares the resolved client command against
# $E7_LSP_BIN, and the server may be launched with a workspace directory as cwd.
bin="$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")"

# Neovim 0.12 writes a startup log (./nvim.log) when its default server socket
# cannot be created (e.g. a read-only /run/user).  The LSP client also writes
# lsp.log under stdpath("state"), which is read-only in some sandboxes; point
# XDG_STATE_HOME at a temporary directory instead.  Both are removed on exit so
# running the tests leaves no artifacts.
nvim_log="$(mktemp "${TMPDIR:-/tmp}/engine7-nvim.XXXXXX.log" 2>/dev/null)" || nvim_log=""
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/engine7-nvim-state.XXXXXX" 2>/dev/null)" || state_dir=""
cleanup() {
  if [ -n "$nvim_log" ]; then
    rm -f -- "$nvim_log"
  fi
  if [ -n "$state_dir" ]; then
    rm -rf -- "$state_dir"
  fi
}
trap cleanup EXIT

# Add the plugin to 'runtimepath' before Neovim loads filetype detection, so
# that the plugin (and its ftdetect/ files) behave exactly as for a real user.
NVIM_LOG_FILE="${nvim_log:-/dev/null}" \
XDG_STATE_HOME="${state_dir:-${XDG_STATE_HOME:-}}" \
E7_NEOVIM_PLUGIN_DIR="$plugin_dir" \
E7_LSP_BIN="$bin" \
E7_FIXTURE="$fixture" \
  "$nvim_bin" --headless --clean -u NONE -i NONE \
  --cmd "execute 'set runtimepath^=' . fnameescape(\$E7_NEOVIM_PLUGIN_DIR)" \
  -l "$spec"
status=$?

if [ "$status" -ne 0 ]; then
  echo "FAIL: engine7 Neovim LSP tests failed (nvim exit $status)" >&2
  exit "$status"
fi

echo "PASS: engine7 Neovim LSP tests"
