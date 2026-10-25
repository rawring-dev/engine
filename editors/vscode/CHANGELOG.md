# Changelog

All notable changes to the engine7 VS Code extension are documented here.
This project follows [Keep a Changelog](https://keepachangelog.com/) and uses
semantic versioning.

## 0.1.0

### Added

- Initial release: declarative engine7 language support.
- TextMate grammar `source.engine7`:
  - `#` line comments and double/single-quoted strings with escapes.
  - Integer, float, boolean, and `nil` literals.
  - All reserved-word classes (conditional, loop, flow, import, declaration,
    modifier, query, word operators, path roots, visibility).
  - Type names, aggregate and function declaration names, calls, fields,
    members, and `@attributes`.
  - Primitive scalar type names (`i8`–`i128`, `isize`, `u8`–`u128`, `usize`,
    `f16`–`f128`, `bool`, `str`) are types and are excluded from the member
    heuristic, including in return position (`-> i32:`).
  - Assignment, arrow, range, error, optional, reference, pattern, comparison,
    and arithmetic operators; `::` paths and `...` ellipsis.
- Language configuration for `.tri` (canonical), `.e7`, and `.engine7`: comment
  toggling (`#`), bracket
  matching, auto-closing/surrounding pairs, layout- and brace-aware indentation,
  and a word pattern.
- Snippets for struct, enum, function, async function, system (query/resource),
  match, and if/elif/else.
- Oniguruma-based test suite (`editors/vscode/test/run.sh`) tokenizing the
  shared `editors/samples/kitchen_sink.e7` fixture and asserting scopes.
