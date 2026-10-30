# e7-fmt: formatter for the engine7 surface language

`e7-fmt` formats `.e7` sources (the language in
[`grammar.ebnf`](../../grammar.ebnf)) using the compiler front end.  It is a
conservative, whitespace-and-layout formatter: it never reorders declarations,
rewrites expressions, or edits string contents.  The rules are:

| Rule | Behavior |
| --- | --- |
| Line length | Lines are wrapped at **80 columns** where a safe break exists |
| Indented assignment values | Long bindings/assignments break after the operator and put the value in an indented block (a language feature added for this style) |
| Long conditions/expressions | `if`/`elif`/`while`/`match`/`ret`/`disown`/`for ... in` expressions are grouped in parentheses and broken inside them |
| Comments | Overlong `#` comment lines are reflowed on word boundaries |
| `:=` → `<-` | Mutable bindings the compiler proves are never mutated become immutable |
| Whitespace | Trailing whitespace stripped, exactly one final newline, tabs expanded, spacing normalized around operators/commas/colons |
| Strings | Never modified; long string literals are reported instead of broken |
| Parse errors | Invalid source only gets whitespace normalization (never rewritten structurally) |

The `:=` → `<-` rewrite is **compiler-verified**: candidate bindings come from
the semantic analyzer (which tracks assignments, mutable borrows, and mutable
method receivers), and the formatter re-analyzes the rewritten buffer; if the
rewrite would add a compiler diagnostic it is discarded.  In project mode the
analysis includes sibling `mod` files, so engine sources are checked the same
way the compiler checks them.

## Usage

```sh
zig build fmt                 # build zig-out/bin/e7-fmt

e7-fmt engine tests/e7        # format files/directories in place
e7-fmt --check engine         # report files that would change; exit 1 if any
e7-fmt --list src/main.e7     # print files that were formatted
e7-fmt --stdout main.e7       # formatted text on stdout, no write
e7-fmt --stdin < main.e7      # editor integration: stdin -> formatted stdout
e7-fmt --no-wrap --no-immutable file.e7
```

Flags: `--check`, `--list`, `--stdout`, `--stdin`, `--workspace DIR`,
`--no-wrap`, `--no-immutable`, `--version`, `--help`.  Directories are walked
recursively for `*.e7`; `.git`, `.zig-cache`, `zig-out`, `zig-pkg`,
`node_modules`, `.team`, `.tooling`, `.local-vulkan`, and `target` are skipped.
The workspace root is inferred from the nearest `build.zig.zon`/`build.zig`/
`.git` ancestor (or pass `--workspace`).

Exit codes: `0` success (or everything already formatted), `1` `--check` found
differences / an I/O problem, `2` usage error.

## Automatic formatting on write

The Neovim plugin formats `engine7` buffers on `BufWritePre`, using the LSP
`textDocument/formatting` request when a client is attached and falling back to
`e7-fmt --stdin` otherwise.  See the
[Neovim README](../neovim/README.md#formatting).  Other editors can either use
the LSP formatting capability or run the CLI.

## The indented assignment-value style

The formatter uses (and the parser accepts) a layout container after a binding
or assignment operator:

```e7
colour <-
    if field.focused: [1.0, 1.0, 1.0, 1.0]
    else: [0.82, 0.86, 0.92, 1.0]
```

This is the preferred shape for a long right-hand side; it keeps the operator
visible, avoids invented parentheses, and keeps continuation lines inside the
80-column budget.

## Tests

```sh
zig build test-fmt                 # formatter unit tests
bash editors/fmt/test/run.sh       # CLI end-to-end tests (builds on demand)
bash editors/neovim/test/run_fmt.sh
```

LSP formatting is covered by `editors/lsp/test/client.py` and the Neovim format
tests.

## Notes and limitations

- The parser is fail-fast, so a file with a syntax error is only
  whitespace-normalized; it is not structurally formatted until it parses.
- Long string literals, very long identifiers/paths, and some generated
  constructs can remain over 80 columns; the CLI reports the line numbers.
  After the repository-wide migration, 10 lines remain: nine long JSON/message
  string literals and one overlong test-function identifier.
- `e7s` shader sources (`engine/shaders`, `engine/platform/shaders`) are a
  separate dialect and are intentionally not part of the `e7-fmt` migration
  even though they use `.e7` extensions; the formatter can still be pointed at
  them manually (they parse as e7), but shader output is owned by the `e7s` →
  Slang tooling.
- Formatting is idempotent: running it on its own output changes nothing.
