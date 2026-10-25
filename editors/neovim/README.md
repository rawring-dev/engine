# engine7 for Neovim

Syntax highlighting, filetype detection, and editor settings for the
[engine7](../../README.md) surface language in Neovim.

This plugin uses **legacy `:syntax` highlighting only**.  There is no
tree-sitter grammar, no tree-sitter queries, no language server, and no plugin
runtime code.  It implements the same token classes and the same small,
documented set of regex heuristics as the VS Code extension, so an engine7
program looks the same in both editors.  The shared model lives in
[`editors/README.md`](../README.md).

## Requirements

- Neovim 0.9 or newer (developed and tested against **0.12.6**).
- A colorscheme.  Groups are linked to standard Vim highlight groups, so the
  colorscheme controls the colors; the plugin never hardcodes colors.

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
| `ret` `break` `cont` | `e7Statement` | `Statement` |
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
- Statement: `ret` `break` `cont`
- Include: `use` `mod`
- Structure: `struct` `enum` `table` `trigger` `sys`
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
  `<- struct|enum|table|trigger|sys` is an aggregate declaration name (type).
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

## Files

```text
editors/neovim/
├── README.md
├── ftdetect/engine7.vim    filetype detection (*.tri, *.e7, *.engine7)
├── ftplugin/engine7.vim    comment/indent/suffix settings
├── syntax/engine7.vim      legacy :syntax highlighting
└── test/
    ├── run.sh              non-interactive test entry point
    └── highlight_spec.lua  assertions
```

## Known limitations

- Regex heuristics are not a parser.  Primitive scalar type names are always
  types, so `-> i32:` is highlighted correctly, but the member heuristic still
  colors a *non-primitive* lowercase identifier before `:` even when that
  colon opens a layout block, e.g. a user-defined return type such as
  `-> pair<T>:`.
- Lowercase user type names used as values (e.g. `pair<T>{...}`) are only
  highlighted at their declaration, not at every use.
- No semantic highlighting, no inlay hints, no diagnostics, no folding: those
  need a parser or language server, neither of which exists for engine7 here.
- Neovim's generic filetype fallback would classify unknown extensions as
  `conf`; `ftdetect/engine7.vim` registers the extensions with
  `vim.filetype.add` so that does not happen.
