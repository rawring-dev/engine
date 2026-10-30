#!/usr/bin/env bash
#
# Non-interactive highlighting tests for the engine7 Neovim plugin.
#
# Usage (from anywhere):
#   bash editors/neovim/test/run.sh
#
# Exits 0 only if every assertion passes.  Uses nvim with no user config.
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$plugin_dir/../.." && pwd)"

fixture="$repo_root/editors/samples/kitchen_sink.tri"
spec="$script_dir/highlight_spec.lua"
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

# Neovim 0.12 writes a startup log (./nvim.log) when its default server socket
# cannot be created (e.g. a read-only /run/user).  Redirect that log to a
# temporary file and remove it, so running the tests leaves no artifacts in
# the repository.  The LSP integration also writes lsp.log under
# stdpath("state"); this suite only exercises highlighting, so disable the
# optional client and keep the state directory temporary.
nvim_log="$(mktemp "${TMPDIR:-/tmp}/engine7-nvim.XXXXXX.log" 2>/dev/null)" || nvim_log=""
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/engine7-nvim-state.XXXXXX" 2>/dev/null)" || state_dir=""
cleanup() {
  if [ -n "$nvim_log" ]; then
    rm -f "$nvim_log"
  fi
  if [ -n "$state_dir" ]; then
    rm -rf "$state_dir"
  fi
}
trap cleanup EXIT

# Add the plugin to 'runtimepath' before Neovim loads filetype detection, so
# that ftdetect/engine7.vim is sourced and *.tri/*.e7 are not mistaken
# for the generic "conf" fallback.  The highlighting suite does not need the
# language server, so opt out before plugin/engine7.lua is sourced.
NVIM_LOG_FILE="${nvim_log:-/dev/null}" \
XDG_STATE_HOME="${state_dir:-${XDG_STATE_HOME:-}}" \
E7_NEOVIM_PLUGIN_DIR="$plugin_dir" \
E7_FIXTURE="$fixture" \
  "$nvim_bin" --headless --clean -u NONE -i NONE \
  --cmd "let g:engine7_lsp_enabled = 0" \
  --cmd "execute 'set runtimepath^=' . fnameescape(\$E7_NEOVIM_PLUGIN_DIR)" \
  -l "$spec"
status=$?

if [ "$status" -ne 0 ]; then
  echo "FAIL: engine7 Neovim highlighting tests failed (nvim exit $status)" >&2
  exit "$status"
fi

echo "PASS: engine7 Neovim highlighting tests"
