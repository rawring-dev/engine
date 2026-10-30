# engine7 language server

`e7-lsp` is a Language Server Protocol server for the engine7 surface language
(`e7`, the language described by [`grammar.ebnf`](../../grammar.ebnf)).  It is a
small, from-scratch LSP 3.17 implementation over stdio that reuses the
compiler front end, so editor diagnostics always agree with the compiler:
lexer and layout errors, parser errors, and semantic errors all come from
`compiler/src/{lexer,parser,semantic}.zig` rather than a second grammar.

The Neovim plugin under [`editors/neovim`](../neovim/README.md) ships the client
side and starts the server automatically.  The VS Code extension stays
highlight-only for now.

## Features

| Feature | Method | Notes |
| --- | --- | --- |
| Diagnostics | `textDocument/publishDiagnostics` | Lexer/parser errors on every change; project-aware semantic errors on open/save (see below) |
| Document symbols | `textDocument/documentSymbol` | Hierarchical: functions, types, `mod`/`plugin`/`impl` blocks, fields, enum variants, trait/impl methods, top-level bindings |
| Hover | `textDocument/hover` | Fenced e7 declaration header for the symbol under the cursor |
| Completion | `textDocument/completion` | Keywords, built-in scalar types, and declarations in the current document |
| Go to definition | `textDocument/definition` | Jumps to the declaration of the identifier under the cursor in the same document |
| Formatting | `textDocument/formatting` | Runs `e7-fmt` (80-column layout, verified `:=`→`<-`, whitespace/spacing) and returns a whole-document edit |
| Full document sync | `textDocument/didOpen`/`didChange`/`didClose`/`didSave` | `TextDocumentSyncKind.Full` (`change: 1`) |

Lifecycle messages (`initialize`, `initialized`, `shutdown`, `exit`), unknown
request replies (`result: null`), and JSON-RPC error responses (`-32603` for
handler failures) follow the specification.  Positions are UTF-16 code units,
as LSP requires, while compiler diagnostics are byte-based; the conversion is
centralized in [`src/protocol.zig`](src/protocol.zig).

### Project-aware diagnostics

On `initialize` the server indexes the workspace `.e7` files and the
`mod`/`<dir>/<name>.e7` graph they form.  When a document belongs to a
multi-file project, semantic diagnostics are produced by compiling that whole
project with the open buffer substituted for its on-disk source and then
keeping only the diagnostics attributed to the open file (compiler diagnostics
carry a `module_path`, and the loader records the file that owns each module
path).  This is what makes `engine/*.e7` analyze cleanly despite their
`mod`/`use` imports: the project root is found automatically
(`engine/editor/main.e7` resolves through `engine/editor_main.e7`, and so on).

Project-wide analysis is the expensive part, so it runs on **open and save**;
`didChange` refreshes lexer/parser diagnostics and the symbol index only
(fast).  Standalone buffers — scratch files, `tests/e7` suites, files outside
the workspace — are analyzed on their own on every change.  e7 test suites
additionally have the e7-test harness prelude's `assert_*`/`e7_test_*` names
suppressed, since that prelude is injected by the test runner rather than
declared in the file.

### Scope and limitations

Navigation remains document-local: completion, hover, and go-to-definition
only see declarations in the current file, even though diagnostics use the
project graph.  Cross-file completion/definition is the main missing piece.
There is also no formatting, rename, folding, semantic tokens, inlay hints, or
workspace symbol search.  Diagnostics after a semantic pass can be coarser than
the token level because the analyzer reports statement spans.  If a project
dependency is mid-edit and cannot be parsed, project semantics is skipped until
it parses again (lexer/parser diagnostics for the open file are unaffected).

Contract details:

- transport: JSON-RPC 2.0 over stdin/stdout with `Content-Length` framing
  (bodies are counted in UTF-8 bytes, comments are not allowed);
- capabilities: `textDocumentSync` (`openClose`, full `change`, `save`),
  `documentSymbolProvider`, `hoverProvider`,
  `completionProvider.triggerCharacters = ["."]`, `definitionProvider`,
  `documentFormattingProvider`, `positionEncoding: "utf-16"`;
- diagnostics carry `source: "e7"` and severity `1` (error).

## Build and test

From the repository root (Zig 0.16.0, LLVM 23.1.3):

```sh
zig build lsp          # installs zig-out/bin/e7-lsp
zig build test-lsp     # protocol/analysis unit tests (also part of `zig build test`)
bash editors/lsp/test/run.sh   # end-to-end stdio conformance test
```

`editors/lsp/test/run.sh` builds the server if needed and drives it with
[`test/client.py`](test/client.py), a dependency-free Python LSP client that
asserts the initialize/shutdown handshake, diagnostics for valid, semantic-error,
and parse-error buffers, full-sync `didChange`, document symbols, hover,
completion, definition, formatting edits, unknown requests, and `didClose`
diagnostics.  It also
runs a project-mode scenario against this repository: opening
`engine/main.e7`, `engine/gameplay.e7`, and `engine/editor/model.e7` must
produce no false diagnostics, and a semantic error typed into a project buffer
must appear after `didSave`.  The script accepts `E7_LSP_BIN=/path/to/e7-lsp`
to test an existing binary and `--workspace DIR` to point the project scenario
at a checkout.

If Zig cannot write its global cache in your environment (for example inside a
read-only sandbox), set `ZIG_GLOBAL_CACHE_DIR` to a writable directory; the
editor test scripts do this automatically for the repository-local cache.

## Neovim

The plugin is discovered through the Neovim plugin in
[`editors/neovim`](../neovim/README.md).  With `zig-out/bin` on `PATH`, or with
`vim.g.engine7_lsp_path` set, opening a `*.tri`/`*.e7`/`*.engine7` buffer starts
the server with `filetype=engine7`; see the Neovim README for packpath,
lazy.nvim, and vim-plug examples as well as command-resolution rules.

Manual smoke test:

```sh
printf 'Content-Length: 58\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  | zig-out/bin/e7-lsp
```

## Architecture

```text
editors/lsp/src/
├── main.zig      entry point: argument handling, stdio setup, server loop
├── protocol.zig  Content-Length framing, JSON-RPC envelopes, JsonOut,
│                 UTF-16 <-> byte-offset positions, file: URI helpers
├── server.zig    lifecycle, document store, request dispatch, diagnostics,
│                 symbol/hover/completion/definition serialization
├── analysis.zig  compiler front-end adapter: lex/parse/analyze, diagnostic
│                 ranges, symbol index, hover/completion lookups; project mode
└── project.zig   workspace .e7 index, `mod` graph/root selection, multi-file
                  project loader, module-path -> file attribution
```

The root [`build.zig`](../../build.zig) defines the LSP module because it is
editor tooling rather than one of the four language packages; `zig build lsp`
links the `compiler` module and installs the executable.  The server does not
link code generation or the runtime beyond what the `compiler` module needs.

## Editor test scripts

Run everything with `bash editors/verify.sh`, or individually:

```sh
bash editors/lsp/test/run.sh
bash editors/neovim/test/run_lsp.sh
```
