# Repository Guidelines

## Project Structure & Module Organization

engine7 is a Zig workspace with four standalone packages: `scheduler/` (numerical scheduling), `compiler/` (language front end and bytecode), `runtime/` (LLVM JIT, ECS, and FFI), and `transpiler/` (e7s shaders to Slang). Each has `build.zig` and `src/`; the root build composes them. `engine/` contains e7 engine modules, demo assets, and shaders. `tests/e7/` holds language-level suites; Zig tests live alongside source or in dedicated test modules. `editors/` contains Neovim and VS Code support, the `e7-lsp` language server (built by the root `lsp` step from `editors/lsp/src`), and shared fixtures. Treat `grammar.ebnf` as the surface-language specification.

## Build, Test, and Development Commands

Use Zig **0.16.0** and LLVM **23.1.3**. Install the native libraries listed in `README.md` and `runtime/build.zig` before building.

- `zig build test`: run all four packages’ Zig tests plus the `e7-lsp` and `e7-fmt` unit tests.
- `(cd compiler && zig build test)`: run one package’s tests; substitute another package as needed.
- `zig build test-e7`: run e7 suites; append `-- --filter string` to select tests.
- `zig build run-engine`: launch the JIT engine demo; append `-- --frames 2 --headless --capture /tmp/engine.ppm` for a capture.
- `(cd transpiler && zig build)`: build the `e7s` CLI.
- `zig build shaders`: regenerate both shader sets; requires Slang.
- `zig build lsp`: build/install the `e7-lsp` language server (`zig-out/bin/e7-lsp`); `zig build test-lsp` runs its unit tests.
- `zig build fmt`: build/install the `e7-fmt` formatter (`zig-out/bin/e7-fmt`); `zig build test-fmt` runs its unit tests. `e7-fmt --check <path>` reports unformatted files.
- `bash editors/verify.sh`: validate editor highlighting, the formatter, and the language server/Neovim LSP integration; requires Neovim, Node/npm, python3, and Zig.

## Language Priorities & e7 Design

All agents should prioritize implementing functionality in e7 over Zig wherever possible. Compiler changes are a normal, expected part of development: extend the compiler when needed to support e7 implementations rather than moving functionality into Zig solely to work around language limitations.

Write all shaders in e7s, the shader language consumed by `transpiler/`. Treat e7s sources as authoritative and regenerate Slang/SPIR-V outputs through the shader tooling.

When working in e7, favor functional design patterns: small composable functions, higher-order functions, function composition, immutable values, and explicit data transformations. Keep side effects localized, and use these patterns where they improve clarity and fit the engine's performance needs.

## Coding Style & Naming Conventions

Use four-space indentation and `zig fmt` on changed Zig files. Follow existing Zig conventions: `camelCase` functions, `PascalCase` types, and `snake_case` fields and filenames. e7 indentation is significant; use spaces, never tabs. Keep reusable engine modules independent of demo-specific `engine/main.e7`. Prefer supported native methods over direct `e7_*` intrinsic calls. Record external algorithm and project references in `CITATIONS.bib`.

## Testing Guidelines

Use Zig’s built-in `test` blocks for unit and integration coverage. Add regression cases for changed behavior. e7 tests are parameterless `test_*` functions returning `0` on success; asynchronous cases use `test_async_*`. Use harness assertions such as `assert_eq_i64`. Run both suites for compiler/runtime changes. No numeric coverage threshold is documented.

## Commit & Pull Request Guidelines

Follow history’s concise, scoped subjects, such as `runtime: fix JSON decoding` or `docs: update engine usage`. Pull requests should explain the behavior change, link relevant issues, and report validation commands and results. Include captures for rendering/UI changes and identify native dependencies needed to reproduce them.
