# e7 formatter

`e7-fmt` is a whitespace-and-layout formatter for the e7 surface language.  It
sits on the compiler front end and is wrapped by the CLI
([`editors/fmt`](../../editors/fmt/README.md)) and the LSP
(`textDocument/formatting`), and the Neovim plugin runs it on write.

## Goals

- Make an 80-column budget practical without a second parser: use the
  compiler's lexer/parser to find safe breakpoints and verify every rewrite.
- Rewrite mutable bindings to immutable ones only when the compiler proves the
  binding is never mutated.
- Stay conservative: strings are never edited, declarations are never
  reordered, and invalid source is only whitespace-normalized.
- Be idempotent and safe to run over the whole engine/test corpus.

Non-goals: canonical reprinting from the AST, import sorting, rename/refactor,
and formatting the `e7s` shader dialect.

## Pipeline

```text
source
  -> normalize (CRLF, trailing space, tabs, final newline)       formatter.zig
  -> lex/parse (fail => whitespace-only result)
  -> semantic analysis (project-aware) and `:=` candidates        analysis.Document
  -> `:=` -> `<-` rewrite + re-analysis verification              formatter.zig
  -> layout (80-col wrapping, new syntax, comments, spacing)      layout.zig
  -> re-parse/re-analyze verification (fallback on regression)    formatter.zig
```

The formatter core owns normalization, the `:=` rewrite, and the
analysis-based verification; the layout pass is token-driven and does not need
semantic information.  `layout.zig` validates its own output with the parser
and falls back to its input if the generated text does not parse, so the two
passes can degrade independently.

## Indented assignment values

e7 now allows the value of a binding/assignment to be an indented layout block:

```e7
colour <-
    if field.focused: [1.0, 1.0, 1.0, 1.0]
    else: [0.82, 0.86, 0.92, 1.0]
```

The parser (`parseAssignmentValue` in `compiler/src/parser.zig`) treats
`newline + indent` after `<-`/`:=`/`=`/compound assignments as a single
expression terminated by the matching `dedent`; the AST is unchanged.  This
gives the formatter a much better shape for long assignments than wrapping
inside call parentheses or inventing parentheses, and it is the reason the
formatter no longer adds parentheses for assignment right-hand sides.

## Compiler-verified immutability

`semantic.analyzer` already resolves lexical bindings and enforces mutability
(assignments, `&mut` borrows, mutable method receivers).  It now records, per
binding, the declaration offset and whether any of those mutation paths were
seen, and exposes the never-mutated subset on `Analysis` as
`never_mutated_bindings` (name, module path, offset).  The LSP analysis adapter
copies the subset that belongs to the open file into
`Document.mutable_candidates`.

The formatter maps each candidate to its `:=` token by scanning the token
stream from the declaration offset (attributes may precede the name), rewrites
the operator (both are two bytes, so offsets stay stable), re-analyzes, and
discards the rewrite if the diagnostic count grew.  This is intentionally
verifiable rather than heuristics: anything the semantic analyzer would reject
as a mutation of an immutable binding causes the rewrite to be withheld.

## Layout rules

- **Bracket depth** is computed over the token stream, so continuation lines of
  an already-multiline call can be broken further; layout is suppressed inside
  `()`, `[]`, and `{}` by the lexer, which makes those safe breakpoints.
- **Assignments** break after the operator and indent the RHS one level,
  recursively applying bracket breaks inside it.
- **Conditions/expressions without brackets** get a parenthesized group
  (`if (`, `while (`, ...) and are broken inside it; the parser treats a
  parenthesized expression as the expression itself, so this is semantics-
  preserving.
- **Comments** are reflowed on word boundaries; trailing comments stay with
  their code.
- **Spacing** is normalized for commas, semicolons, colons, assignment/binding/
  arrow/arithmetic/comparison operators, and prefix operators, while `<`/`>`
  are left alone because they are ambiguous with generic arguments.
- **Unbreakable lines** (long strings, single huge identifiers) are reported in
  `Result.unformatted` and by `e7-fmt --check`, not silently truncated.

## Testing and migration

- Unit tests: `zig build test-fmt` (normalization, conversion verification,
  wrapping, spacing, comments, fallbacks, idempotency, parse checks).
- CLI tests: `bash editors/fmt/test/run.sh` (in-place/check/stdout/stdin,
  recursion, parse errors, idempotency, exit codes).
- LSP/Neovim: `editors/lsp/test/client.py` formatting assertions and
  `editors/neovim/test/run_fmt.sh` format-on-write.
- The corpus (`engine/**/*.e7`, `tests/e7/*.e7`, 54 files) was formatted once
  with `e7-fmt`: 48 files changed, 2,358 `:=`→`<-` conversions, 847 wrapped
  lines, then a second pass changed nothing (`0 file(s) formatted`), `--check`
  exits 0, and the compiler test suite, `zig build test-e7`, the LSP/Neovim
  suites, and a headless engine run verified the result.  Shader `e7s` sources
  under `engine/shaders`/`engine/platform/shaders` are excluded from the
  migration (separate dialect), even though they carry `.e7` extensions.
- Ten lines in the corpus remain over 80 columns: nine long string literals
  (JSON fixtures and messages whose content must not change) and one 89-column
  test-function identifier in `tests/e7/inspector.e7`.  These are reported by
  `e7-fmt --check`, which is the intended behavior for unbreakable content.

## Known limitations

- The parser is fail-fast, so structurally formatting requires valid source.
- Metadata such as blank-line grouping is preserved; only the 80-column rule
  and spacing are enforced (no import sorting, no blank-line policy).
- Some lines cannot be made short without changing string contents or
  identifiers; those are reported.
- The `:=` rewrite is all-or-nothing per file: if the compiler rejects any
  conversion in a file, the whole file keeps its mutable bindings.  This keeps
  the first version's safety simple; a per-binding bisect or richer mutation
  facts could recover the remaining cases.
