# engine7 for Neovim

Syntax highlighting, filetype detection, editor settings, format-on-write, and
an optional language-server client for the [engine7](../../README.md) surface
language in Neovim.

Highlighting uses **legacy `:syntax` only**: there is no tree-sitter grammar and
no tree-sitter queries.  It implements the same token classes and the same
small, documented set of regex heuristics as the VS Code extension, so an
engine7 program looks the same in both editors.  The shared model lives in
[`editors/README.md`](../README.md).

The plugin also ships an LSP client for the [`e7-lsp`](../lsp/README.md)
language server, a from-scratch LSP 3.17 implementation in Zig built with
`zig build lsp`.  The server reuses the compiler front end, so it adds
project-aware compiler diagnostics, hierarchical document symbols, hover,
completion, and same-file go-to-definition.  The server is optional: when no
`e7-lsp` executable can be found, or when Neovim cannot write its LSP log,
highlighting keeps working and the plugin warns once.  See
[Language server (LSP)](#language-server-lsp).

Saving an engine7 buffer also formats it: the plugin uses the server's
`textDocument/formatting` request when a formatting-capable client is attached
and falls back to the `e7-fmt` CLI otherwise.  See
[Formatting](#formatting).



## Requirements

- Neovim 0.9 or newer (developed and tested against **0.12.6**).
- A colorscheme.  Groups are linked to standard Vim highlight groups, so the
  colorscheme controls the colors; the plugin never hardcodes colors.
- For the language server: a built `e7-lsp` binary (Zig 0.16.0,
  `zig build lsp`).  The client works on Neovim 0.9+ and prefers the
  `vim.lsp.config` / `vim.lsp.enable` API on 0.11+.
- For format-on-write without an LSP client: a built `e7-fmt` binary
  (Zig 0.16.0, `zig build fmt`).  With a formatting-capable `e7-lsp` attached,
  the CLI is not needed.

## Installation

### Native packpath

Clone (or symlink) this directory into a `start` package:

```sh
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/pack/engine7/start"
ln -s /path/to/engine7/editors/neovim \
      "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/pack/engine7/start/engine7"
```

Restart Neovim, open a `*.tri` file (or the `.e7`/`.engine7` aliases), and
check `:set filetype?` — it should
print `filetype=engine7`.

### lazy.nvim

```lua
{
  dir = "~/src/engine7/editors/neovim",
  name = "engine7",
  ft = { "engine7" },
  -- plugin/engine7.lua registers the LSP client when the plugin loads.
  -- vim.lsp.enable() (and the FileType fallback on older Neovim) also
  -- activates clients for buffers that already have filetype=engine7, so the
  -- buffer that triggered the lazy load is covered too.
}
```

To point the plugin at a server built outside the repository, set the path
before the plugin loads:

```lua
{
  dir = "~/src/engine7/editors/neovim",
  name = "engine7",
  ft = { "engine7" },
  init = function()
    vim.g.engine7_lsp_path = vim.fn.expand("~/opt/e7-lsp")
  end,
}
```

`ftdetect/engine7.vim` registers the `e7` / `engine7` extensions through
`vim.filetype.add`.  If your configuration runs filetype detection before
lazy.nvim adds the plugin to `'runtimepath'`, register the extension in your
config as well:

```lua
vim.filetype.add({ extension = { e7 = "engine7", engine7 = "engine7" } })
```

### vim-plug

```vim
" Plugin repository, using only the Neovim subdirectory:
Plug 'engine7-lang/engine7', { 'rtp': 'editors/neovim' }

" Or from a local checkout:
Plug '~/src/engine7', { 'rtp': 'editors/neovim' }
```

Then run `:PlugInstall` and restart Neovim.

## What gets highlighted

| Construct | Group | Linked to |
| --- | --- | --- |
| `#` comment to end of line | `e7Comment` | `Comment` |
| `"..."` and `'...'` strings | `e7String` | `String` |
| backslash escapes inside strings | `e7Escape` | `SpecialChar` |
| integers (`1_000_000`) and floats (`6.02e23`, `1.5E-9`) | `e7Number` | `Number` |
| `true` / `false` | `e7Boolean` | `Boolean` |
| `nil` | `e7Constant` | `Constant` |
| `if` `elif` `else` `match` | `e7Conditional` | `Conditional` |
| `loop` `while` `for` `in` | `e7Repeat` | `Repeat` |
| `ret` `break` `cont` `disown` | `e7Statement` | `Statement` |
| `use` `mod` | `e7Include` | `Include` |
| `struct` `enum` `table` `trigger` `sys` | `e7Structure` | `Structure` |
| `impl` `trait` and the modifier/query/word/path keywords | `e7Keyword` | `Keyword` |
| `pub` | `e7Storage` | `StorageClass` |
| types: uppercase names, aggregate names, `map`, primitive scalars | `e7Type` | `Type` |
| function declarations and calls | `e7Function` | `Function` |
| fields and members | `e7Field` | `Identifier` |
| `@attribute` paths | `e7Attribute` | `PreProc` |
| operators | `e7Operator` | `Operator` |
| delimiters and punctuation | `e7Delimiter` | `Delimiter` |

### Keyword classes

- Conditional: `if` `elif` `else` `match`
- Repeat: `loop` `while` `for` `in`
- Statement: `ret` `break` `cont` `disown`
- Include: `use` `mod`
- Structure: `struct` `enum` `table` `trigger` `sys` `plugin`
- Keyword: `impl` `trait` `async` `await` `spawn` `detach` `cancel`
  `unsafe` `select` `from` `where` `res` `as` `not` `and` `or` `xor`
  `crate` `self` `super` `mut` `raw`
- StorageClass: `pub`
- Boolean: `true` `false`; Constant: `nil`

### Type, function, field, and attribute heuristics

These are documented in the shared model and cannot be exact without a parser:

- An uppercase identifier is a type (type paths, enum variants, generic
  parameters, aggregate names).
- A lowercase name before optional generics and
  `<- struct|enum|table|trigger|sys|plugin` is an aggregate declaration name (type).
- A name after `trait` is a type; `map` immediately before `[` is a type.
- A lowercase name before optional generics, `<-`, optional `async`, and `(`
  is a function declaration name.
- A lowercase name directly before `(` is a function call, except after `.`
  (field access) or when it is a keyword (e.g. `if(` stays a keyword).
- The built-in primitive scalar type names are always types: `i8` `i16` `i32`
  `i64` `i128` `isize` `u8` `u16` `u32` `u64` `u128` `usize` `f16` `f32`
  `f64` `f128` `bool` `str` (`String` is covered by the uppercase rule).
- An identifier after `.` is a field; a lowercase identifier directly before
  a single `:` (not `::` or `:=`) is a member (field, pattern, initializer,
  or parameter).  Primitive scalar type names are excluded from this rule, so
  a return type such as `-> i32:` is a type, not a member.
- `@` followed by a `::`-separated path is an attribute.

All other identifiers keep the editor's default text color.

## Language server (LSP)

`plugin/engine7.lua` registers the `engine7` client config and starts
[`e7-lsp`](../lsp/README.md) for buffers with `filetype=engine7`.  The server
runs over stdio and reuses the compiler front end
(`compiler/src/{lexer,parser,semantic}.zig`), so its diagnostics always agree
with the compiler rather than with the highlighting heuristics.

### What it provides

| Feature | Notes |
| --- | --- |
| Diagnostics | Lexer/layout and parser errors on every change; project-aware semantic errors on open and save; `source = "e7"`, severity `ERROR` |
| Document symbols | Hierarchical: items, fields, enum variants, `mod`/`impl` methods, top-level bindings |
| Hover | Fenced e7 declaration header for the symbol under the cursor |
| Completion | Keywords, built-in scalar types, and declarations in the current document |
| Go to definition | Jumps to a declaration in the **current file** (document-local) |
| Formatting | Whole-document `textDocument/formatting` edits, used by format-on-write and `:Engine7Format` (see [Formatting](#formatting)) |
| Full document sync | The client sends full text on every change; no incremental sync |

Diagnostics are **project-aware**.  On `initialize` the server indexes the
workspace `.e7` files and the `mod` graph they form; when the open buffer
belongs to a multi-file project it compiles the whole project (with the buffer
substituted for its on-disk source) and keeps the diagnostics attributed to the
open file.  Sibling `mod` modules therefore resolve instead of producing false
"unknown type/name" errors, and a project root such as `engine/editor/main.e7`
is found automatically.  Project analysis is the expensive part, so it reruns on
**open and save**; `didChange` refreshes lexer/parser diagnostics and the symbol
index only (fast).  Standalone buffers (scratch files, single files outside a
project) are analyzed on their own on every change.  Navigation stays
document-local — see [Limitations](#limitations).

Use them through the standard Neovim interfaces:

- diagnostics: `vim.diagnostic` (signs, undercurl, `:lua
  vim.diagnostic.setloclist()`), configured with `vim.diagnostic.config()`;
- document symbols: `:lua vim.lsp.buf.document_symbol()` opens your picker;
- hover: `K` (the client sets `keywordprg` for engine7 buffers when it is
  unset);
- completion: `<C-x><C-o>` (the client sets `omnifunc` when it is unset), or
  enable automatic completion once per buffer with
  `vim.lsp.completion.enable(true, client_id, bufnr, { autotrigger = true })`;
- go to definition: `:lua vim.lsp.buf.definition()`, or `<C-]>` through the
  default LSP `tagfunc`.

### Building the server

From the repository root:

```sh
zig build lsp          # installs zig-out/bin/e7-lsp
```

If Zig cannot write its global cache (sandboxes, read-only homes), point it at
a writable directory:

```sh
ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" zig build lsp
```

The plugin never builds the server itself; run the command above (or point the
plugin at a binary you built elsewhere).

### Command resolution

The first executable found wins:

1. `vim.g.engine7_lsp_path` — an explicit executable path.  Set this when the
   server is built or installed outside the repository.
2. `$E7_LSP_BIN` — environment override for CI, sandboxes, and custom builds.
3. `<repository>/zig-out/bin/e7-lsp` — derived from the plugin file location
   (`editors/neovim/plugin/engine7.lua`), so a checkout that has run
   `zig build lsp` works with no configuration.  Symlinked installs are
   resolved before deriving the path.
4. `e7-lsp` on `$PATH`.

When none of these is executable the plugin does not start a client and emits
one `vim.notify` warning the first time an engine7 buffer is opened;
highlighting is unaffected.  The same applies when Neovim's LSP log directory
is not writable, because starting a client would otherwise fail on every
`:edit`.

The workspace root is resolved from the markers `build.zig.zon`, `build.zig`,
and `.git` (nearest ancestor); outside a repository the client runs in
single-file mode.

### Configuration

| Setting | Default | Meaning |
| --- | --- | --- |
| `vim.g.engine7_lsp_path` | unset | explicit `e7-lsp` executable path (highest priority) |
| `$E7_LSP_BIN` | unset | environment override, next in priority |
| `vim.g.engine7_lsp_enabled` | enabled | set to `0` / `false` to skip LSP registration entirely |
| `vim.lsp.config("engine7", {...})` | plugin defaults | merge extra `vim.lsp.Config` fields (for example `on_attach`, `capabilities`, `settings`) |

The client config uses `root_markers = { "build.zig.zon", "build.zig", ".git" }`
and `filetypes = { "engine7" }`.  The resolved root becomes the workspace the
server indexes for project diagnostics at `initialize`; on Neovim 0.11+ it is
registered with
`vim.lsp.config("engine7", ...)` and activated with `vim.lsp.enable("engine7")`.
Older Neovim versions use a `FileType` autocmd plus `vim.lsp.start()`.
On Neovim 0.11+, a later `vim.lsp.config()` call merges with the plugin
defaults:

```lua
vim.lsp.config("engine7", {
  on_attach = function(client, bufnr)
    vim.keymap.set("n", "gd", vim.lsp.buf.definition, { buffer = bufnr })
  end,
})
```

### Checking the client

```vim
" Neovim 0.11+: shows attached clients, capabilities, and log path
:checkhealth vim.lsp

" Print the engine7 clients attached to the current buffer
:lua =vim.lsp.get_clients({ name = "engine7", bufnr = 0 })

" With nvim-lspconfig installed, :LspInfo is a shortcut for the above
:LspInfo
```

Client logs go to `stdpath("log")/lsp.log` (print it with
`:lua =vim.lsp.log.get_filename()`); set `vim.lsp.log.set_level("debug")` for
verbose protocol logging.  If the log directory is read-only, the plugin
disables the client and warns once, because Neovim cannot start an LSP client
without its log file.

### Limitations

- **Navigation is document-local** even though diagnostics use the project
  graph: completion, hover, and go-to-definition only see declarations in the
  open file.  Cross-file completion/definition and workspace symbol search are
  not implemented.
- Project semantics refresh on open/save, not on every keystroke; syntax
  diagnostics do refresh on every change.  If a project dependency is mid-edit
  and cannot be parsed, project semantics is skipped until it parses again.
- No formatting, rename, code actions, folding, semantic tokens, or inlay hints.
- Semantic diagnostics report statement spans, so they can be coarser than
  token-level ranges.
- The server does not replace the highlighter: `:syntax` still provides the
  colors, and the LSP adds semantics on top.
- The server must be built separately (`zig build lsp`) and is started per
  workspace root; there is no auto-download.

See [`editors/lsp/README.md`](../lsp/README.md) for the protocol-level details.

## Formatting

The plugin formats engine7 buffers automatically before they are written.  It
prefers the language server's `textDocument/formatting` request when a
formatting-capable `engine7` client is attached, and otherwise runs the
`e7-fmt` CLI in `--stdin` mode.  Format-on-write is enabled by default.

### Behavior

- On `BufWritePre` for a `filetype=engine7` buffer the plugin requests a
  whole-document format **synchronously** (2 s timeout) and then writes the
  formatted buffer.  Formatting therefore happens before the file is saved.
- If no client that advertises `textDocument/formatting` is attached, the
  `e7-fmt` CLI formats the buffer instead.
- Formatting failures never abort the write: the buffer is written unformatted
  and the user is warned once per session.
- A second save of already formatted text is a no-op (the formatter is
  idempotent and the plugin does not rewrite identical lines).
- `:Engine7Format` formats the current buffer on demand **without writing the
  file**.  It refuses non-engine7 buffers, and reports a missing formatter or a
  parse-error-only normalization.
- `g:engine7_lsp_enabled = 0` disables only the language server; format-on-write
  and `:Engine7Format` keep working through `e7-fmt`.

### Building the formatter

```sh
zig build fmt          # installs zig-out/bin/e7-fmt
```

`zig build lsp fmt` builds both binaries.  The CLI is only needed for the
no-LSP fallback: an attached `e7-lsp` that advertises
`textDocument/formatting` formats without it.  The plugin never builds the
tools itself.  In sandboxes where Zig's global cache is read-only, use
`ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" zig build lsp fmt`.

### Configuration

| Setting | Default | Meaning |
| --- | --- | --- |
| `vim.g.engine7_format_on_save` | enabled | set to `0` / `false` to stop formatting on write; `:Engine7Format` still works |
| `vim.g.engine7_fmt_path` | unset | explicit `e7-fmt` executable path (highest priority) |
| `$E7_FMT_BIN` | unset | environment override, next in priority |

The CLI is resolved in this order, first executable wins:

1. `vim.g.engine7_fmt_path`
2. `$E7_FMT_BIN`
3. `<repository>/zig-out/bin/e7-fmt` (derived from this plugin's location)
4. `e7-fmt` on `$PATH`

The language server has its own, analogous resolution rules described in
[Command resolution](#command-resolution), so the two binaries can be installed
independently.

### Limitations

- Files with parse errors can only be whitespace-normalized (trailing spaces,
  stray tabs, final newline); the formatter does not rewrite invalid syntax.
  `:Engine7Format` notifies when only normalization happened.
- Long string literals and some comment-only lines cannot be reflowed and may
  remain longer than 80 columns.
- Formatting is synchronous inside `:write`; a slow formatter delays the save
  (the LSP request is capped at 2 s).
- Without either a formatting-capable `e7-lsp` or `e7-fmt`, writes proceed
  unformatted and a single warning is shown.

## Editor settings

`ftplugin/engine7.vim` applies, buffer-locally:

- `commentstring=# %s`, `comments=:#`
- `expandtab`, `shiftwidth=4`, `tabstop=4`, `softtabstop=4` (the lexer rejects
  tabs in indentation)
- `suffixesadd=.tri,.e7` so `:find` and `gf` locate engine7 modules

## Testing

From the repository root:

```sh
bash editors/neovim/test/run.sh
```

The script resolves every path relative to its own location, so it also works
from any other directory.  It runs Neovim with no user configuration:

```sh
nvim --headless --clean -u NONE -i NONE \
  --cmd "execute 'set runtimepath^=' . fnameescape($E7_NEOVIM_PLUGIN_DIR)" \
  -l test/highlight_spec.lua
```

It prints the number of assertions and exits `0` only if all pass:

```text
187 assertions, 0 failures
PASS: engine7 Neovim highlighting tests
```

On failure every mismatch is printed with the fixture line, byte column,
token, expected group, actual group, and source line, and the exit status is
non-zero.  `nvim` must be on `PATH`; set `NVIM=/path/to/nvim` to override.
Neovim's startup log (which can otherwise appear as `./nvim.log` when the
default server socket is unavailable) is redirected to a temporary file and
removed, so the tests leave no files behind.

The assertions cover, against [`editors/samples/kitchen_sink.tri`](../samples/kitchen_sink.tri)
and a scratch buffer:

- comments; both string quote styles and escapes (and that `#` or keywords
  inside strings are not mis-highlighted, nor strings inside comments)
- integer and float literals, including full-literal coverage
- `true`/`false`/`nil`
- every keyword class listed above
- uppercase and aggregate types, generic parameters, `map[...]`, lowercase
  names after `trait`, and the primitive scalar type names (including the
  return position of `-> i32:`, which must not be a member)
- function declarations (including `<- async (`) and calls, with keyword-
  followed-by-`(` staying a keyword
- `.field` access and `name:` members (including that `:=`/`::` do not count)
- `@attribute` paths
- operators `<-` `->` `:=` `=` `==` `!=` `<` `>=` `..` `..=` `...` `!` `?`
  `&` `|` `*` `%` `+=`, and `::` / `.` / `:` punctuation
- filetype detection for `*.tri` (canonical), `*.e7`, and `*.engine7`
- ftplugin settings and the full highlight-link table

### LSP integration test

```sh
bash editors/neovim/test/run_lsp.sh
```

The script resolves the server from `$E7_LSP_BIN` if set, otherwise from
`zig-out/bin/e7-lsp`; when the repository binary is missing or older than the
server or compiler sources it builds it with
`ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" zig build lsp`.  It then starts
Neovim with no user configuration, puts this plugin on `'runtimepath'`, and
drives the client against a throwaway workspace under `$TMPDIR`:

- asserts that `plugin/engine7.lua` registers and enables the `engine7` config
  and resolves the command with the documented priority
  (`g:engine7_lsp_path` > `$E7_LSP_BIN` > repository `zig-out` > `$PATH`);
- opens a file with a parser error and a file with a semantic type error and
  waits (5 s) for `Error` diagnostics with `source = "e7"`;
- opens a well-typed file and asserts that it produces no diagnostics;
- requests `textDocument/documentSymbol`, `hover`, `completion`, and
  `definition` against a copy of
  [`editors/samples/kitchen_sink.tri`](../samples/kitchen_sink.tri) and checks
  the expected declarations, hover text, completion labels, and same-file
  definition target.

It prints the number of assertions and exits `0` only if all pass:

```text
59 assertions, 0 failures
PASS: engine7 Neovim LSP tests
```

Set `E7_LSP_BIN=/path/to/e7-lsp` to test a server built or installed
elsewhere (that binary is used as-is and never rebuilt).  The temporary
workspace, Neovim's startup log, and the LSP state/log directory are created
under `$TMPDIR` and removed afterwards, so the test leaves no files behind.

### Format-on-write test

```sh
bash editors/neovim/test/run_fmt.sh
```

The script needs both `e7-lsp` (for the LSP formatting path) and `e7-fmt` (for
the fallback).  It takes them from `$E7_LSP_BIN` / `$E7_FMT_BIN` when set,
otherwise from `zig-out/bin/e7-lsp` and `zig-out/bin/e7-fmt`; missing or stale
repository binaries are rebuilt with
`ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-cache/global" zig build lsp fmt`.  It then
drives headless Neovim against a throwaway workspace under `$TMPDIR`:

- the LSP path (client advertising `textDocument/formatting`): `:write`
  formats the buffer before saving, converting the unnecessary `:=` binding,
  using the indented-RHS layout for the overlong assignment, and staying within
  80 columns; a second save of already formatted text changes nothing;
- the CLI fallback (`g:engine7_lsp_enabled = 0`): `:write` runs
  `e7-fmt --stdin` and normalizes spacing, tabs, and the final newline;
  `g:engine7_format_on_save = 0` writes the buffer untouched;
- `:Engine7Format` formats the buffer without writing the file and ignores
  non-engine7 buffers.

It prints the number of assertions and exits `0` only if all pass:

```text
33 assertions, 0 failures
PASS: engine7 Neovim format-on-write tests
```

Set `E7_LSP_BIN` / `E7_FMT_BIN` to test binaries built elsewhere (those are
used as-is and never rebuilt).  The temporary workspace, Neovim startup log,
and LSP state/log directory are created under `$TMPDIR` and removed afterwards,
so the test leaves no files behind.

## Files

```text
editors/neovim/
├── README.md
├── ftdetect/engine7.vim    filetype detection (*.tri, *.e7, *.engine7)
├── ftplugin/engine7.vim    comment/indent/suffix settings
├── plugin/engine7.lua      LSP client registration and command resolution
├── syntax/engine7.vim      legacy :syntax highlighting
└── test/
    ├── run.sh              non-interactive highlighting test entry point
    ├── highlight_spec.lua  highlighting/grammar assertions
    ├── run_lsp.sh          non-interactive LSP test entry point
    ├── lsp_spec.lua        LSP registration/features assertions
    ├── run_fmt.sh          non-interactive format-on-write test entry point
    └── fmt_spec.lua        formatting/format-on-write assertions
```

## Known limitations

- Regex heuristics are not a parser.  Primitive scalar type names are always
  types, so `-> i32:` is highlighted correctly, but the member heuristic still
  colors a *non-primitive* lowercase identifier before `:` even when that
  colon opens a layout block, e.g. a user-defined return type such as
  `-> pair<T>:`.
- Lowercase user type names used as values (e.g. `pair<T>{...}`) are only
  highlighted at their declaration, not at every use.
- The highlighter itself has no semantic highlighting, inlay hints, or folding:
  colors come from the regex `:syntax` file.  The LSP adds diagnostics,
  document symbols, hover, completion, and same-file go-to-definition on top,
  but it does not change highlighting.
- Neovim's generic filetype fallback would classify unknown extensions as
  `conf`; `ftdetect/engine7.vim` registers the extensions with
  `vim.filetype.add` so that does not happen.
