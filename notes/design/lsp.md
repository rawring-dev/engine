# e7 language server

The engine7 language server (`e7-lsp`) gives editors compiler-grade feedback
for the e7 surface language without duplicating the compiler's grammar.  It
reuses the `compiler` package front end and speaks LSP 3.17 over stdio; the
Neovim plugin in [`editors/neovim`](../../editors/neovim/README.md) is the
supported client.  This note records the design decisions behind it.

## Goals

- Diagnostics that match `zig build test` semantics: the lexer's layout rules,
  the parser, and semantic analysis all come from `compiler/src`, so an editor
  error is the same error the compiler reports.
- A small, dependency-free server that is easy to build from the workspace
  (`zig build lsp`) and easy to test without an editor (`bash
  editors/lsp/test/run.sh`).
- Document symbols, hover, completion, and same-file go-to-definition — enough
  navigation for everyday editing while keeping the first version honest about
  its scope.
- Semantic diagnostics for multi-file e7 projects, because the engine itself is
  one: single-file analysis reports hundreds of false "unknown type/name"
  errors for `engine/*.e7`.

Non-goals for this iteration: cross-file navigation, formatting, rename,
semantic tokens, folding, and workspace symbols.

## Architecture

`editors/lsp` is editor tooling, not one of the language packages
(`scheduler`, `compiler`, `runtime`, `transpiler`), so the root `build.zig`
defines its module inline and builds it with the `lsp` step.  The module imports
`compiler` and links the same LLVM system library; it never calls codegen.

```text
main.zig        std.process.Init, buffered stdio, Server.run
  |
server.zig      JSON-RPC dispatch + document store + LSP result builders
  |         |          \
  |         |        analysis.zig
  |         |          |        \
  |         |          |      project.zig   workspace .e7 index + mod loader
  |         |          |        |
protocol.zig |          |      compiler.parser (project files)
  |         |          |
  |         |        compiler.{lexer,parser,semantic}
  +--> Content-Length framing, JsonOut, UTF-16 positions, file: URIs
```

Data flow for one buffer:

1. `initialize` builds a `project.Index` from the client's workspace root: it
   scans `.e7` files, resolves the `<dir>/<name>.e7` (or `<dir>/<name>/main.e7`)
   `mod` convention, and memoizes the project root for each file.
2. `didOpen`/`didChange` stores the full text and calls
   `analysis.Document.initWithOptions` with the document path, phase, and the
   index.
3. `analysis.Document` always lexes and parses the buffer (fail-fast on the
   first lexer/parser problem) and builds the symbol index.  For `.full`
   phases it adds semantics: a standalone buffer is analyzed alone; a
   project document is loaded through `project.Index.load` (the open buffer
   overrides its on-disk source), analyzed as a whole project, and only the
   diagnostics whose owning module path maps to this file are kept.  The
   compiler's `Diagnostic.module_path` (a small additive compiler change) is
   what makes that attribution possible.
4. The same document builds a symbol index: top-level items, nested
   `mod`/`plugin` items, aggregate fields, enum variants, trait/impl methods,
   and top-level bindings.  Each symbol records its full range, its name range,
   a declaration header for hovers, and a parent index for the hierarchical
   `documentSymbol` response.
5. The server publishes diagnostics and serves symbol/hover/completion/
   definition requests from that index until the next change.  `didSave`
   refreshes the project index entry for the file and re-runs full analysis;
   `didChange` uses the `.change` phase so project-wide semantics is not
   re-run on every keystroke (project analysis costs ~200 ms on the engine
   project, lexer/parser diagnostics cost ~2 ms).

Hover and completion are precomputed when the document is indexed, so request
handling is read-only and allocation-light.  Definition resolution maps the
identifier token under the cursor to a symbol (preferring the declaration
itself), which keeps hover/definition consistent for shadowed names.

## Encoding and protocol details

- The compiler reports 1-based, byte-based line/column spans and byte offsets.
  LSP wants zero-based lines and UTF-16 code units.  All conversion happens in
  `protocol.zig`; diagnostics, symbol ranges, and cursor positions all travel
  through those helpers.
- `Content-Length` counts UTF-8 bytes of the JSON body.  `readMessage` is
  tolerant of CRLF or bare LF line endings, ignores unknown headers, and caps
  bodies at 32 MiB.
- Sync is full (`TextDocumentSyncKind.Full`): e7 files are small and a fresh
  parse is cheaper than maintaining incremental text edits in two places.
- Requests with unknown methods answer `result: null`; unknown notifications
  are ignored, which keeps newer clients from breaking the server.
- `shutdown` records the handshake; `exit` uses status 0 after a shutdown and
  1 otherwise, per the specification.

## Testing

- Zig unit tests (`zig build test-lsp`, also collected by `zig build test`)
  cover framing/escaping/positions/URIs, diagnostic mapping, symbol indexing,
  hover/definition/completion behaviour, and parser/semantic error cases.
- `editors/lsp/test/run.sh` runs `test/client.py`, a stdlib-only Python LSP
  client that spawns the real binary and exercises the protocol end to end:
  lifecycle, diagnostics for clean/semantic-error/parse-error buffers, full-sync
  `didChange`, document symbols (including nested fields), hover, completion,
  definition, unknown requests, and `didClose`.
- The Neovim plugin adds `editors/neovim/test/run_lsp.sh`, a headless client
  test that verifies registration, attach, diagnostics, and request/response
  round trips through `vim.lsp`.
- `bash editors/verify.sh` runs the syntax-highlighting suites plus both LSP
  suites.

## Known limitations and next steps

- Navigation is still document-local: external `mod` symbols are loaded for
  diagnostics but not merged into the document symbol index, so completion,
  hover, and definition do not cross files.  The next step is to merge the
  project's symbol tables into the index (the loader already knows every
  module path and source).
- Project semantics runs on open/save, not on every keystroke.  A debounced
  background analysis (or cancellation support) would make it live without
  making typing wait on the full project.
- Fail-fast parser: only the first parse error is reported per change.  Error
  recovery in the parser (or a second recovery pass) would improve multi-error
  diagnostics.
- Semantic diagnostics point at statement spans, so the underline can be
  coarser than the token that caused the error.
- e7 test suites (`tests/e7`) rely on a prelude injected by the e7-test
  runner; the server suppresses the resulting `assert_*`/`e7_test_*`
  unknown-name diagnostics rather than modeling the prelude.
- No `textDocument/semanticTokens`: the existing Neovim/VS Code regex
  highlighters remain the coloring path; semantic tokens could later reuse the
  compiler token stream.
- The server is synchronous; a debounce or cancellation strategy may be worth
  adding if very large files make keystroke-rate reanalysis noticeable.
