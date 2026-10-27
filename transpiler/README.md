# e7s -> Khronos Slang transpiler

`e7s` is the shading-language subset of [engine7](../grammar.ebnf).  This
package transpiles e7s source (ordinary e7 syntax, parsed by the real engine7
front end) to [Khronos Slang](https://shader-slang.org/) modules, which
`slangc` then compiles to SPIR-V.

```
foo.e7 ──► engine7 lexer/parser ──► e7s restriction + lowering ──► foo.slang ──► slangc ──► foo.spv
```

The goal is one surface language for engine code and shaders: shader source
stays e7, with a small attribute vocabulary for the things e7 has no spelling
for (descriptor bindings, shader stages, system-value semantics).  The
language is normative in [docs/e7s.md](docs/e7s.md); this README covers the
implementation and usage.

## Quick start

```sh
# Build the transpiler (workspace: `zig build` from the repo root installs it too)
cd transpiler
zig build
./zig-out/bin/e7s transpile examples/triangle.vert.e7 -o triangle.vert.slang

# Multi-file project: `mod math` loads sibling math.e7 and emits math.slang + main.slang
./zig-out/bin/e7s transpile examples/modules/main.e7 -o /tmp/e7s-out

# Diagnostics only
./zig-out/bin/e7s check examples/generics_traits.e7

# Write a single module to stdout
./zig-out/bin/e7s transpile examples/compute.e7 -o -
```

Compile the output with Slang:

```sh
slangc -target spirv -profile spirv_1_5 -entry vs_main -stage vertex \
       -I /tmp/e7s-out -o /tmp/triangle.vert.spv /tmp/e7s-out/triangle.vert.slang
```

Optional end-to-end check: transpile every example and compile all shader
entries to SPIR-V (uses `SLANGC`, the repo's `.tooling/slang/bin/slangc`, or
`slangc` on `PATH`):

```sh
sh tools/validate-examples.sh
```

## What e7s covers

| Feature | e7 input | Slang output |
| --- | --- | --- |
| functions | `name <- (a: f32) -> f32:` | `float name(float a) { ... }` |
| structs | `Vec3 <- struct` | `struct Vec3 { ... };` |
| fixed vectors/matrices | `[f32; 3]`, `[f32; 4, 4]` | `float3`, `column_major float4x4` (struct fields) |
| enums | `Mode <- enum` | `enum class Mode { ... };` |
| interfaces | `trait IThing` | `interface IThing { ... };` |
| trait impls / inherent impls | `impl IThing for S:` / `impl S:` | `extension S : IThing { ... }` / `extension S { ... }` |
| generics + bounds | `Pair<T: IThing>`, `where T: IThing` | `<T : IThing>`, trailing `where` |
| module (external) | `mod math` + `use math::*;` | `math.slang` (`module math;`) + `import math;` |
| module (inline) | `mod math { ... }` | `namespace math { ... }` |
| constants | `PI := 3.14159265` | `static const float PI = 3.14159265;` |
| resources | `@binding(0, 0) scene: SceneUniform` | `[[vk::binding(0, 0)]] ConstantBuffer<SceneUniform> scene;` |
| shader entries | `@vertex` / `@fragment` / `@compute(8, 8, 1)` | `[shader("...")]` / `[numthreads(...)]` |
| system values | `@builtin(position)` field | `: SV_Position` |
| varyings | `@location(0) uv: [f32; 2]` field | `[[vk::location(0)]] float2 uv;` |

All e7s extensions are e7 **attributes**, so the checked-in grammar needs no
new productions: resource declarations are ordinary top-level uninitialized
declarations (`name: Type`) tagged with `@binding`/`@push_constant`.

Where the two languages disagree, e7s chooses the Slang meaning (the task
allows this): vectors are Slang vector values, integer/float widths map to
Slang scalars, `:=`/`<-` become `var`/`let`, block tail expressions become
`return`, struct literals reorder to declaration order, `nil` is `void`, and
resource globals are constant buffers.  e7 `*` on matrix operands keeps its
e7 matrix-product meaning and is emitted as Slang `mul(...)` (Slang's own
`*` is componentwise for matrices); scalar/vector `*` stays componentwise.
Error types are not erased: only `!nil` maps to `void`; other `!T`/`E!T`
results are rejected with a diagnostic.

## Design

- **Real front end, no fork.** `src/project.zig` parses every module with
  `compiler.parser.parse`, then builds a declaration model (`src/model.zig`)
  and lowers the checked AST.  e7s is a semantic profile over e7, not a second
  parser.
- **Attribute extensions.** e7s additions never invent new syntax where an
  attribute fits: `@binding(binding, set)`, `@push_constant`, `@uniform`,
  `@resource`, `@vertex`, `@fragment`, `@compute(x, y, z)`, `@location(n)`,
  `@builtin(name)`, `@flat`, `@inline`.  Attribute arguments are therefore
  ordinary parseable expressions and existing tooling (highlighters, formatter)
  keeps working.
- **Slang-shaped semantics.** The subset deliberately follows Slang values:
  fixed-size vectors/matrices, method receivers, interface/extension blocks,
  constant buffers.  Matrix struct fields get an explicit `column_major`
  layout by default (matching Vulkan/std140 and column-major host matrices;
  `@row_major` opts out), and matrix `*` lowers to `mul(...)`.  Trait requirements use e7 receivers (`&self`,
  `&mut self`); impl bodies name the receiver `this: &Type` / `this: &mut Type`
  and the transpiler drops it, leaving Slang's implicit `this`.  Methods
  without a `this` parameter become `static` extension methods.
- **Modules map to Slang modules.** An external `mod name` loads sibling
  `name.e7` (recursively) and emits `name.slang` with `module name;`; imports
  become `import name;`.  Slang imports are unqualified/global, so e7
  qualifiers such as `math::dot2` are stripped for imported modules and kept
  for inline-module namespaces.  Selective imports and aliases are diagnosed.
- **Type-directed expressions.** A small inference pass (`src/lower_body.zig`)
  supplies expected types for vector/matrix literals, struct literals, call
  arguments, returns, and assignments; local bindings that cannot be inferred
  still use Slang's `var`/`let`.  The same pass classifies matrix operands so
  `*` can lower to `mul(...)`.
- **Bounds split across Slang syntax.** e7's `T: A + B` becomes `<T : A>` plus
  a trailing `where T : B`; multiple extra bounds use repeated `where`
  clauses because Slang rejects comma-separated predicates.  Structs,
  extensions, and functions all accept this form.  A `pub impl` becomes
  `public extension ... { public ... }` so interface implementations are
  visible across modules.
- **Readable, stable output.** Formatting is deterministic (4-space indent,
  one declaration per line, imports sorted), comments are not preserved, and
  each file starts with a generated-file banner.

### Source layout

| File | Responsibility |
| --- | --- |
| `src/main.zig` | CLI, project/file loading, output writing |
| `src/root.zig` | public library API (`transpile`, `transpileModules`, `loadProject`) |
| `src/project.zig` | multi-module orchestration, imports, filesystem loader |
| `src/model.zig` | declaration collection, name lookup, generic substitution |
| `src/lower_items.zig` | structs, enums, traits, impls, functions, resources, constants, modules |
| `src/lower_body.zig` | statements, expressions, type inference, control flow |
| `src/types.zig` | e7 type -> Slang type mapping |
| `src/session.zig` | writer/diagnostic/program context |
| `src/astx.zig` | AST attribute/path/span helpers |
| `src/emit.zig`, `src/diag.zig` | output writer, diagnostic list |
| `src/tests.zig` | end-to-end golden and diagnostic tests |

## Validation

```sh
cd transpiler
zig build test          # 23 end-to-end tests; no external tools required
```

The golden tests exercise functions, structs, vectors/matrices, resources,
entry points, traits/extensions, generics, modules, constants, enums, control
flow, match, and the main diagnostics.  For real compiler validation, run
`tools/validate-examples.sh` (or `tools/check-slang.sh` with `SLANGC` pointing
at a Slang compiler); it transpiles all examples and the canonical
`engine/shaders/*.e7` and `engine/platform/shaders/*.e7` shaders, compiles
every entry to SPIR-V, and fails
on any diagnostic.  This is done during development with Slang 2026.20 (see
`docs/slang-notes.md` for the verified syntax matrix).

## Limitations

- One `.slang` module per e7 file; the output directory must be on `-I` for
  `slangc` so sibling modules resolve.  External module imports are not
  transitive in Slang, so each file imports what it uses.
- `match` is a statement form only; `if` is a value only when all branches are
  single tail expressions.  There are no lambdas, closures, maps, strings,
  optionals, pointers, error values, or async/ECS constructs in e7s.
- Bounds are emitted with one bound in `<...>` and any remaining bounds in
  `where` clauses (supported for structs, extensions, and functions).  Enum
  `where` clauses are rejected because e7s enums cannot be generic.
- Comments and e7 spellings of built-in resource declarations are not
  round-tripped; only the generated Slang module text is produced.
- No golden `.slang` files are checked in; tests compare emitted text
  in-process and `tools/check-slang.sh` compiles the real output.

## Citation

The transpiler targets Khronos Slang [slang]; the e7 grammar is the one in
[`grammar.ebnf`](../grammar.ebnf).  See [`CITATIONS.bib`](../CITATIONS.bib).
