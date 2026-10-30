#!/usr/bin/env bash
# Run every editor-plugin check for engine7.
#
# Usage (from anywhere):
#   bash editors/verify.sh
#
# Requires: python3, nvim, node/npm, and zig (0.16) because the formatter and
# language-server suites build `e7-fmt`/`e7-lsp` on demand.  The VS Code suite
# installs its devDependencies into editors/vscode/node_modules on first run.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

printf '==> static checks\n'
python3 "$here/scripts/check_keywords.py"

printf '\n==> neovim syntax highlighting\n'
bash "$here/neovim/test/run.sh"

printf '\n==> formatter\n'
bash "$here/fmt/test/run.sh"

printf '\n==> language server\n'
bash "$here/lsp/test/run.sh"

printf '\n==> neovim LSP client\n'
bash "$here/neovim/test/run_lsp.sh"

printf '\n==> neovim format-on-write\n'
bash "$here/neovim/test/run_fmt.sh"

printf '\n==> vscode\n'
bash "$here/vscode/test/run.sh"

printf '\neditors: all checks passed\n'
