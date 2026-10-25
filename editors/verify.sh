#!/usr/bin/env bash
# Run every editor-plugin check for engine7.
#
# Usage (from anywhere):
#   bash editors/verify.sh
#
# Requires: python3, nvim, node/npm.  The VS Code suite installs its
# devDependencies into editors/vscode/node_modules on first run.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

printf '==> static checks\n'
python3 "$here/scripts/check_keywords.py"

printf '\n==> neovim\n'
bash "$here/neovim/test/run.sh"

printf '\n==> vscode\n'
bash "$here/vscode/test/run.sh"

printf '\neditors: all checks passed\n'
