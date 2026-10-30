# engine7 for VS Code

Syntax highlighting, snippets, and editor configuration for the **engine7**
surface language in Visual Studio Code.

This extension is **declarative**: it contains only a TextMate grammar, a
language configuration, and snippets.  It has no `main` entry point, no
activation events, and no runtime extension code.  Colors come entirely from
the active color theme through standard TextMate scopes, so the language looks
consistent in light and dark themes.

The highlighting model is shared with the Neovim plugin; the canonical
description lives in `editors/README.md` in the engine7 repository.

## Features

- Language id `engine7`, displayed as `engine7`, for files ending in `.tri`
  (with `.e7` and `.engine7` accepted as aliases).
- `#` line comments (there are no block comments in engine7).
- Double- and single-quoted strings with backslash escapes.
- Integer and float literals (`1_000_000`, `6.02e23`, `1.5E-9`), `true` /
  `false`, and `nil`.
- All reserved words grouped by class:
  - conditional `if` `elif` `else` `match`
  - loop `loop` `while` `for` `in`
  - flow `ret` `break` `cont` `disown`
  - import `use` `mod`
  - declaration keywords `struct` `enum` `table` `trigger` `sys` / `plugin`
    `impl` `trait`
  - effect modifiers `async` `await` `spawn` `detach` `cancel` `unsafe` `mut`
    `raw`
  - query keywords `select` `from` `where` `res`
  - word operators `as` `not` `and` `or` `xor`
  - path roots `crate` `self` `super`
  - visibility `pub`
- Type names (`Vec3`, enum variants, generic parameters, aggregate declaration
  names), function declaration names and calls.
- Primitive scalar types are always types: `i8` `i16` `i32` `i64` `i128`
  `isize`, `u8` `u16` `u32` `u64` `u128` `usize`, `f16` `f32` `f64` `f128`,
  `bool`, and `str` (plus `String`, covered by the uppercase rule).  They are
  never treated as struct members, so `-> i32:` is a type.
- Field access (`.position`) and struct/pattern members (`id:`).
- Attributes (`@derive`, `@component`, `@serialize`).
- Type constructors `!T`, `?T`, `&T`, `*T`, `map[K, V]`, function and tuple
  types.
- Operators: `<-` `:=` `=` `+=` `-=` `*=` `/=` `%=`, `->`, `..` `..=`, `!`,
  `?`, `&` `*`, `|`, and comparisons/arithmetic; `::` paths and `...` table
  ellipsis.
- Snippets for struct, enum, function, async function, system with query,
  system with resource, match, and if/elif/else.
- Bracket matching, auto-closing and surrounding pairs, `#` comment toggling,
  and indentation rules for `:` layout blocks and `{}` braces.

## Install

### From a packaged VSIX

If this checkout already contains the packaged extension, install it directly:

```bash
code --install-extension editors/vscode/dist/engine7-0.1.0.vsix
```

Otherwise build it first (VSIX artifacts are generated and git-ignored):

```bash
cd editors/vscode
npx --yes @vscode/vsce package --no-dependencies --allow-missing-repository -o dist/engine7-0.1.0.vsix
code --install-extension dist/engine7-0.1.0.vsix
```

### From the folder

Open the `editors/vscode` folder in VS Code and press **F5**.  A new
"Extension Development Host" window opens with the extension loaded.  Open any
file ending in `.tri` (or `.e7`) to see the highlighting.

Alternatively, copy the `editors/vscode` folder into your extensions directory
(for example `~/.vscode/extensions/engine7-0.1.0`), keeping the folder structure
intact, and restart VS Code.

## Development

This extension is intentionally dependency-free at runtime: the only files
shipped in the VSIX are `package.json`, `syntaxes/engine7.tmLanguage.json`,
`language-configuration.json`, `snippets/engine7.json`, `README.md`, and
`CHANGELOG.md`.

- `syntaxes/engine7.tmLanguage.json` — TextMate grammar (`source.engine7`).
- `language-configuration.json` — comments, brackets, pairs, indentation.
- `snippets/engine7.json` — snippet definitions.

After editing the grammar, use **Developer: Inspect Editor Tokens and Scopes**
in the Extension Development Host to verify a token's scope.

## Testing

The fixture is shared with the Neovim plugin and lives at
`editors/samples/kitchen_sink.tri` (do not edit it from here).

From the repository root:

```bash
bash editors/vscode/test/run.sh
```

The script installs the dev dependencies into `editors/vscode/` on first run
(`vscode-textmate` and `vscode-oniguruma`), tokenizes the fixture with the same
Oniguruma engine VS Code uses, asserts the expected scopes, prints the number
of assertions, and exits non-zero on failure.  Equivalent, from this directory:

```bash
npm test
```

The first run needs network access to download the two dev dependencies; they
are committed in `package-lock.json` but not vendored.

## Packaging

```bash
npm install
npm run package
# or:
npx --yes @vscode/vsce package --no-dependencies --allow-missing-repository -o dist/engine7-0.1.0.vsix
```

`dist/`, `node_modules/`, and `*.vsix` are git-ignored; only sources, the test
suite, and `package-lock.json` are tracked.

## Known limitations

Regex-based highlighting cannot parse engine7.  The documented heuristics are
intentional approximations:

- Any `[A-Z][A-Za-z0-9_]*` identifier is a type; uppercase constants are
  therefore also colored as types.
- The primitive scalar names listed above are always types, including in
  return position (`-> i32:`) and in `map[K, V]`; `raw` stays a keyword.
  Non-primitive lowercase type names at use sites are not inferred and stay
  the editor's default color.
- A lowercase identifier directly before a single `:` is treated as a member
  (struct fields, patterns, parameters, and a few expression positions such as
  `ret match color:`), except for the primitive scalar type names.
- `*` and `&` are always highlighted as reference operators, including
  multiplication and bitwise-style uses.
- Generic brackets `<...>` are highlighted as comparison operators, and
  `<` in `<-` is always the binding/assignment operator.

There is no language server, semantic analysis, formatting, or debugging
support in this extension.
