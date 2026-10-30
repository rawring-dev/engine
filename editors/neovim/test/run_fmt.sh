#!/usr/bin/env bash
#
# Non-interactive format-on-write tests for the engine7 Neovim plugin.
#
# Usage (from anywhere):
#   bash editors/neovim/test/run_fmt.sh
#
# The tests need both editor binaries:
#   * the language server, for the LSP `textDocument/formatting` path, and
#   * the `e7-fmt` CLI, for the fallback path,
# taken from $E7_LSP_BIN / $E7_FMT_BIN when set, otherwise from
# zig-out/bin/e7-lsp and zig-out/bin/e7-fmt in the repository root.  A missing
# or stale repository binary is built with
#   ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache/global zig build lsp fmt
# (the global cache override is required in sandboxes where ~/.cache/zig is
# read-only).
#
# Exits 0 only if every assertion passes.  Uses nvim with no user config and
# leaves no files behind.
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$plugin_dir/../.." && pwd)"

spec="$script_dir/fmt_spec.lua"
nvim_bin="${NVIM:-nvim}"

if ! command -v "$nvim_bin" >/dev/null 2>&1; then
  echo "error: nvim not found (set NVIM to point at a binary)" >&2
  exit 127
fi

if [ ! -f "$spec" ]; then
  echo "error: test spec not found: $spec" >&2
  exit 1
fi

# The formatter and the server share the compiler front end and the project
# index, so any change in these trees makes both binaries stale.
tooling_sources=(
  "$repo_root/editors/lsp/src"
  "$repo_root/editors/fmt/src"
  "$repo_root/compiler/src"
  "$repo_root/compiler/build.zig"
  "$repo_root/build.zig"
  "$repo_root/build.zig.zon"
)

# Returns 0 when $1 is missing or older than any tooling source.
needs_build() {
  local bin="$1"
  if [ ! -x "$bin" ]; then
    return 0
  fi
  [ -n "$(find "${tooling_sources[@]}" -newer "$bin" -print -quit 2>/dev/null)" ]
}

build_lsp=0
build_fmt=0

if [ -n "${E7_LSP_BIN:-}" ]; then
  lsp_bin="$E7_LSP_BIN"
  if [ ! -x "$lsp_bin" ]; then
    echo "error: E7_LSP_BIN is not executable: $lsp_bin" >&2
    exit 1
  fi
else
  lsp_bin="$repo_root/zig-out/bin/e7-lsp"
  needs_build "$lsp_bin" && build_lsp=1
fi

if [ -n "${E7_FMT_BIN:-}" ]; then
  fmt_bin="$E7_FMT_BIN"
  if [ ! -x "$fmt_bin" ]; then
    echo "error: E7_FMT_BIN is not executable: $fmt_bin" >&2
    exit 1
  fi
else
  fmt_bin="$repo_root/zig-out/bin/e7-fmt"
  needs_build "$fmt_bin" && build_fmt=1
fi

if [ "$build_lsp" -eq 1 ] || [ "$build_fmt" -eq 1 ]; then
  if ! command -v zig >/dev/null 2>&1; then
    echo "error: e7-lsp/e7-fmt are missing or stale and zig is not on PATH" >&2
    echo "       run 'zig build lsp fmt' in $repo_root (with a writable Zig cache)" >&2
    exit 1
  fi
  steps=()
  if [ "$build_lsp" -eq 1 ]; then
    steps+=("lsp")
  fi
  if [ "$build_fmt" -eq 1 ]; then
    steps+=("fmt")
  fi
  echo "building e7 tooling with 'zig build ${steps[*]}'..."
  if ! ( cd "$repo_root" && ZIG_GLOBAL_CACHE_DIR="$repo_root/.zig-cache/global" \
      zig build "${steps[@]}" ); then
    echo "error: 'zig build ${steps[*]}' failed" >&2
    exit 1
  fi
fi

for bin in "$lsp_bin" "$fmt_bin"; do
  if [ ! -x "$bin" ]; then
    echo "error: formatting test binary missing or not executable: $bin" >&2
    exit 1
  fi
done

# Absolute paths: the plugin may spawn the tools with a workspace directory as
# cwd, and the spec passes these through the environment.
lsp_bin="$(cd "$(dirname "$lsp_bin")" && pwd)/$(basename "$lsp_bin")"
fmt_bin="$(cd "$(dirname "$fmt_bin")" && pwd)/$(basename "$fmt_bin")"

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
E7_LSP_BIN="$lsp_bin" \
E7_FMT_BIN="$fmt_bin" \
  "$nvim_bin" --headless --clean -u NONE -i NONE \
  --cmd "execute 'set runtimepath^=' . fnameescape(\$E7_NEOVIM_PLUGIN_DIR)" \
  -l "$spec"
status=$?

if [ "$status" -ne 0 ]; then
  echo "FAIL: engine7 Neovim format-on-write tests failed (nvim exit $status)" >&2
  exit "$status"
fi

echo "PASS: engine7 Neovim format-on-write tests"
