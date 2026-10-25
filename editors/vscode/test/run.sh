#!/usr/bin/env bash
#
# engine7 VS Code extension test suite.
#
# Runs from anywhere; documented entry point is the repository root:
#
#     bash editors/vscode/test/run.sh
#
# Installs the dev dependencies into editors/vscode/ if node_modules is
# missing, then tokenizes the shared fixture with vscode-textmate +
# vscode-oniguruma (the same Oniguruma engine VS Code uses) and asserts
# scopes.  Prints the assertion count and exits non-zero on failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"
FIXTURE="$REPO_ROOT/editors/samples/kitchen_sink.tri"

if [ ! -f "$FIXTURE" ]; then
  echo "error: shared fixture not found: $FIXTURE" >&2
  echo "       expected repository layout editors/samples/kitchen_sink.tri" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "error: node is required (tested with node 25)" >&2
  exit 1
fi

if [ ! -d "$PLUGIN_DIR/node_modules/vscode-textmate" ] || \
   [ ! -d "$PLUGIN_DIR/node_modules/vscode-oniguruma" ]; then
  echo "installing dev dependencies in $PLUGIN_DIR ..."
  # Use a workspace-local npm cache: sandboxed CI environments sometimes make
  # $HOME/.npm read-only, and this keeps the test self-contained.
  (
    cd "$PLUGIN_DIR"
    npm_config_cache="$PLUGIN_DIR/.npm-cache" \
      npm_config_logs_dir="$PLUGIN_DIR/.npm-cache/_logs" \
      npm install --no-audit --no-fund
  )
fi

cd "$PLUGIN_DIR"
exec node "$SCRIPT_DIR/tokenize.js" "$PLUGIN_DIR" "$FIXTURE"
