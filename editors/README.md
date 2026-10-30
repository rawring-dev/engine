# engine7 editor support

Editor support for the engine7 surface language described by
[`grammar.ebnf`](../grammar.ebnf), for **Neovim** and **VS Code**.

Both plugins implement the same highlighting model, so a program looks the
same in either editor.  Neither uses a tree-sitter parser: both use the
editor's native regex-based highlighter (Neovim legacy `:syntax`, VS Code
TextMate), and there is no tree-sitter grammar in this tree.  The Neovim
plugin additionally ships an LSP client for the [`e7-lsp`](lsp/README.md)
language server, which gives it compiler-grade diagnostics, document symbols,
hover, completion, and go-to-definition; VS Code remains highlight-only.  The
sample in [`samples/kitchen_sink.tri`](samples/kitchen_sink.tri) is the shared
highlighting fixture and is kept parseable by the compiler in this repository.

```
editors/
├── README.md                     this file: shared model + conventions
├── samples/kitchen_sink.tri       shared highlighting fixture
├── neovim/                       Neovim plugin (highlighting + LSP client)
├── lsp/                          e7-lsp language server (Zig)
├── fmt/                          e7-fmt formatter (Zig)
└── vscode/                       VS Code extension
```

## Language identity

| Property | Value |
| --- | --- |
| Language name | `engine7` |
| Neovim filetype | `engine7` |
| VS Code language id | `engine7` |
| TextMate scope | `source.engine7` |
| File extension | `.tri` (canonical); `.e7` and `.engine7` are accepted aliases |
| Line comment | `#` |
| Indentation | spaces only; tabs are rejected by the lexer |
| String quotes | `"..."` and, per the lexer, `'...'` with backslash escapes |
| Statement separator | newline or `;` |

## Lexical model

Everything below comes from `grammar.ebnf` cross-checked against
`compiler/src/syntax.zig` and `compiler/src/lexer.zig`.  Do not invent
keywords: the reserved words are exactly these.

| Class | Tokens |
| --- | --- |
| Declaration / item | `use` `mod` `pub` `struct` `enum` `table` `trigger` `sys` `plugin` `impl` `trait` |
| Control (conditional) | `if` `elif` `else` `match` |
| Control (repeat) | `loop` `while` `for` `in` |
| Control (flow) | `ret` `break` `cont` `disown` |
| Modifier / effect | `async` `await` `spawn` `detach` `cancel` `unsafe` `mut` `raw` |
| Query | `select` `from` `where` `res` |
| Word operators | `as` `not` `and` `or` `xor` |
| Path roots | `crate` `self` `super` |
| Boolean constants | `true` `false` |
| Nil | `nil` |
| Contextual type | `map` when immediately followed by `[` |

Lexical details worth knowing:

- Comments are `#` to end of line; there are no block comments or doc comments.
- Integers are decimal digits with optional `_` separators (`1_000_000`).
- Floats are `digits "." digits` with an optional `e`/`E` exponent (`6.02e23`,
  `1.5E-9`).  There are no hex, octal, or binary literals.
- `!` is the error prefix (`!T`, `!NotFound`); boolean negation is the word
  `not`.  `!=` is a comparison operator.
- `?` is both the optional-type prefix (`?T`) and the postfix try operator
  (`value?`).
- Binding/assignment operators are `<-` (immutable), `:=` (mutable), and
  `=`/`+=`/`-=`/`*=`/`/=`/`%=` for assignment.
- `->` is the function arrow, `::` the path separator, `..`/`..=` ranges, and
  `...` the final table-entry ellipsis.
- `trait` is a lexer keyword even though the grammar's reserved-word comment
  omits it.  Highlight it.
- Single-quoted strings are accepted by the lexer even though the grammar only
  documents double quotes.  Highlight both.
- Primitive scalar type names are not reserved words but are built in:
  `i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f16 f32 f64 f128 bool
  str` (plus `String`, which the uppercase rule already covers).  Highlight
  them as types.

## Highlighting heuristics

The surface grammar is context-sensitive (layout blocks, generic arguments
versus comparisons, `name <- (` function declarations versus parenthesized
initializers).  Regex highlighting cannot parse it, so both plugins use the
same small, documented set of heuristics.  Keep these rules identical in both
plugins.

- An identifier matching `[A-Z][A-Za-z0-9_]*` is highlighted as a **type**.
  This covers type paths, enum variants, generic parameters, and aggregate
  names by convention.  The primitive scalar type names listed above are
  always types.
- A lowercase identifier followed by optional generics and
  `<- struct|enum|table|trigger|sys|plugin` is an **aggregate name** (highlight as a
  type).
- A name following `trait` is a **type**.
- A lowercase identifier followed by optional generics and
  `<- [async] (` is a **function declaration name**.
- A lowercase identifier followed by `(` is a **function call**, unless it is
  a keyword or preceded by `.`.
- An identifier after `.` is a **field**; a lowercase identifier directly
  before `:` (but not `::` or `:=`) is a **member** (struct fields, field
  patterns, field initializers, and also parameters — acceptable heuristic).
  Primitive scalar type names are excluded from this rule, so a return type
  written as `-> i32:` is a type, not a member.
- `map` immediately before `[` is a **type**.
- `@` plus a `::`-separated path is an **attribute**.
- All other identifiers stay the editor's default text color.

## Cross-editor scope model

Both plugins map the same constructs onto each editor's conventional groups.
Neovim uses `e7*` syntax groups linked to the standard groups below, so
colorschemes control the actual colors.  VS Code uses TextMate scopes.

| Construct | Neovim group (final) | VS Code scope |
| --- | --- | --- |
| comment | `Comment` | `comment.line.number-sign.engine7` |
| string | `String` | `string.quoted.double.engine7`, `string.quoted.single.engine7` |
| escape | `SpecialChar` | `constant.character.escape.engine7` |
| integer / float | `Number` | `constant.numeric.integer.engine7`, `constant.numeric.float.engine7` |
| `true` / `false` | `Boolean` | `constant.language.boolean.engine7` |
| `nil` | `Constant` | `constant.language.nil.engine7` |
| conditional keywords | `Conditional` | `keyword.control.conditional.engine7` |
| loop keywords | `Repeat` | `keyword.control.loop.engine7` |
| flow keywords (`ret` `break` `cont` `disown`) | `Statement` | `keyword.control.flow.engine7` |
| `use` / `mod` | `Include` | `keyword.control.import.engine7` |
| `struct` `enum` `table` `trigger` `sys` `plugin` | `Structure` | `storage.type.declaration.engine7` |
| `impl` / `trait` | `Keyword` | `keyword.other.declaration.engine7` |
| modifiers | `Keyword` | `keyword.other.modifier.engine7` |
| query keywords | `Keyword` | `keyword.other.query.engine7` |
| word operators | `Keyword` | `keyword.operator.word.engine7` |
| path roots | `Keyword` | `variable.language.engine7` |
| `pub` | `StorageClass` | `storage.modifier.visibility.engine7` |
| type names (uppercase, aggregate names, primitives) | `Type` | `entity.name.type.engine7` |
| function declarations / calls | `Function` | `entity.name.function.engine7` |
| fields / members | `Identifier` | `variable.other.property.engine7`, `variable.other.member.engine7` |
| attributes | `PreProc` | `entity.other.attribute-name.engine7` (`@` also `punctuation.definition.annotation.engine7`) |
| operators | `Operator` | `keyword.operator.engine7` (+ `.assignment`, `.arrow`, `.range`, `.error`, `.optional`, `.reference`, `.pattern` subscopes) |
| punctuation | `Delimiter` | `punctuation.separator.engine7`, `punctuation.section.*.engine7`, `punctuation.ellipsis.engine7` |

Neovim group naming: define `e7Comment`, `e7String`, ..., and finish with
`hi def link` to the standard group in the table.  This keeps the syntax
independently testable while still inheriting colorscheme colors.

## Formatter

[`fmt/`](fmt/README.md) contains `e7-fmt`, a conservative formatter built on the
compiler front end.  It enforces an 80-column layout (including a new
indented-assignment-value syntax), rewrites `:=` bindings to `<-` only when the
semantic analyzer proves they are never mutated, and normalizes whitespace,
spacing, and the final newline.  `zig build fmt` installs it; the LSP exposes it
as `textDocument/formatting` and the Neovim plugin runs it on `BufWritePre`
(LSP first, CLI fallback).  `e7-fmt --check` reports files that would change.
Shader `e7s` sources are a separate dialect and are not part of the formatter's
regular migration.

## Language server

[`lsp/`](lsp/README.md) contains `e7-lsp`, a Language Server Protocol
implementation over stdio that reuses the compiler front end
(`compiler/src/{lexer,parser,semantic}.zig`) instead of re-implementing the
grammar.  It is built from the repository root with `zig build lsp` and
installed as `zig-out/bin/e7-lsp`; the Neovim plugin starts it for
`filetype=engine7` buffers and resolves the executable from
`vim.g.engine7_lsp_path`, `E7_LSP_BIN`, the repository's `zig-out/bin`, or
`PATH`.  The VS Code extension has no LSP client.

The server currently provides, for the open document:

- diagnostics from the lexer, parser, and semantic analyzer, published after
  open/change/save;
- hierarchical document symbols (items, fields, variants, methods, bindings);
- hover with the fenced declaration header;
- keyword/type/declaration completion;
- same-file go-to-definition.

The server indexes the workspace `mod` graph at startup and runs project-wide
semantic analysis on open/save (`engine/*.e7` therefore analyzes cleanly);
lexer/parser diagnostics refresh on every change.  Navigation (completion,
hover, definition) is still document-local, so cross-file jumps are a documented
limitation.  See [`lsp/README.md`](lsp/README.md) for protocol details,
build/test commands, and the architecture, and
[`notes/design/lsp.md`](../notes/design/lsp.md) for the design rationale.

## Shared fixture and test contract

Both plugins are tested against
[`samples/kitchen_sink.tri`](samples/kitchen_sink.tri).  It parses with the
compiler parser and covers every construct in the grammar.  Do not edit the fixture from a plugin directory; it is shared.

Each plugin must provide a non-interactive test entry point:

| Plugin | Command | Requirements |
| --- | --- | --- |
| Neovim highlighting | `bash editors/neovim/test/run.sh` | exits 0 on success; uses `nvim --headless` with no user config and an explicit `runtimepath`; asserts highlighting groups at known tokens in the fixture |
| Formatter | `bash editors/fmt/test/run.sh` | exits 0 on success; builds `e7-fmt` if needed and asserts CLI behavior (in-place, `--check`, `--stdout`, `--stdin`, recursion, parse errors, idempotency) |
| Formatter unit tests | `zig build test-fmt` | exits 0 on success; layout/wrapping/spacing, `:=` conversion verification, normalization, fallbacks |
| Neovim format-on-write | `bash editors/neovim/test/run_fmt.sh` | exits 0 on success; headless Neovim writes a buffer and asserts LSP formatting plus `e7-fmt` CLI fallback, `:Engine7Format`, and `g:engine7_format_on_save=0` |
| Neovim LSP | `bash editors/neovim/test/run_lsp.sh` | exits 0 on success; builds `e7-lsp` (`zig build lsp`) if needed, then attaches a headless Neovim client and asserts diagnostics plus symbol/hover/completion/definition round trips |
| Language server | `bash editors/lsp/test/run.sh` | exits 0 on success; builds `e7-lsp` if needed and drives it over stdio with the dependency-free `editors/lsp/test/client.py` conformance client |
| VS Code | `bash editors/vscode/test/run.sh` | exits 0 on success; tokenizes the fixture with `vscode-textmate` + `vscode-oniguruma` and asserts scopes |

The tests must cover at least: comments, both string quote styles and an
escape, integer and float literals, booleans and `nil`, every keyword class
above, `map` as a type, uppercase types, aggregate declaration names,
function declaration and call names, `.field` access, a `name:` member,
`@attribute`, `<-` / `->` / `..=` / `...` / `!` / `?` operators, and `::`
punctuation.  Print the number of assertions so failures are diagnosable.

From the repository root, `bash editors/verify.sh` runs all of the suites above
(highlighting, language server, Neovim LSP, VS Code).  It needs `nvim`,
`python3`, Node/npm, and Zig 0.16; the LSP steps build `e7-lsp` on demand.

## Development conventions

- Keep the two plugins' token classes and heuristics in sync; update this file
  if the shared model changes.
- The language server's semantic model comes from the compiler, never from the
  highlighting heuristics.  Keep `editors/lsp` document-scoped unless cross-file
  project loading is implemented deliberately; do not silently grow it into a
  second compiler.
- Do not add a tree-sitter grammar or tree-sitter queries: there is no
  tree-sitter parser for engine7 in this repository, and Neovim's legacy
  syntax is the supported highlighter.  Likewise, the VS Code extension is
  declarative (TextMate grammar + language configuration); it has no runtime
  extension code.
- Generated/vendored artifacts stay out of git: `node_modules/`, `.vsix`,
  editor caches.  Each plugin owns its ignore rules.
- The sample fixture must keep parsing.  If you change it, rerun the compiler
  parser check described in the sample header (or ask the Lead).
