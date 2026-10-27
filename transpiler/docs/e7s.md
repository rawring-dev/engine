# e7s language reference

**Status:** normative for the e7s front end in `transpiler/`.
**Audience:** shader authors and the lowering implementation.

e7s is the **shading-language subset of e7**. Source files are ordinary e7
files (extension `.e7`) using the surface syntax of [`grammar.ebnf`](../../grammar.ebnf)
and parsed by engine7's real front end (`compiler/src/parser.zig`). The
transpiler restricts the parsed AST to the subset below and emits Khronos
Slang, one `.slang` translation unit per `.e7` file. The generated Slang is
compiled to SPIR-V with `slangc`; e7s itself never emits SPIR-V.

```
foo.e7 ──► engine7 parser ──► e7s restriction checks ──► foo.slang ──► slangc ──► foo.spv
```

The design goal is a single surface language for engine code and shaders:
e7 syntax for both, with the shading subset small enough to lower
predictably and validate with slangc. The transpiler is a **syntax-directed**
lowering: it preserves e7's surface forms and leaves type checking, overload
resolution and intrinsic resolution to Slang (see §10.2).

### Tooling

```
e7s transpile <input.e7> [-o <out.slang|dir>] [--module-name <name>]
                         [--single-file] [--no-module-decl]
e7s check <input.e7>          # diagnostics only; writes nothing
```

* Default output for a single file is the sibling `.slang` file
  (`compute.e7` → `compute.slang`).
* `-o <file>` writes a single file; `-o -` writes to stdout; `-o <dir>` in
  project mode writes one `<module>.slang` per module into `<dir>`.
* Every generated file starts with `module <name>;`, including the root file.
  `--no-module-decl` suppresses that line.
* Project mode (the default) loads sibling `.e7` files referenced by external
  `mod` declarations and emits the whole module graph.
* Validate generated output with `transpiler/tools/check-slang.sh`. slangc
  resolves `import` from files on its search path, so generated modules need
  `-I <output-dir>` (the harness adds an `-I` for each directory argument).

---

## 1. Source conventions

* Files are UTF-8, extension `.e7`. Comments start with `#` and run to the end
  of the line.
* Layout is Python-like: `:` followed by a newline and an indentation block is
  a layout block; explicit `{ ... }` braces are equivalent. Struct, enum,
  trait and module bodies also accept a bare newline + indent block (no `:`).
* Indentation is 4 spaces per level. Tabs in indentation are rejected by the
  lexer. Blank and comment-only lines do not change the indentation stack.
* Newlines inside `(` and `[` are suppressed, so argument/parameter lists may
  be split across lines.
* Items and fields are separated by newlines and/or `;`. The final separator
  is optional. `use` declarations require a `;`.
* A one-line block `: statement` is legal in e7 and accepted by e7s.
* Identifiers are `[A-Za-z_][A-Za-z0-9_]*` and may not be reserved words
  (`if`, `ret`, `struct`, `trait`, `impl`, `mod`, `use`, `pub`, `match`, `nil`,
  `true`, `false`, `as`, `and`, `or`, `xor`, `not`, `for`, `in`, `where`,
  `self`, ... — see the grammar's reserved-word list).

Numeric literals: decimal integers, optionally with `_` separators
(`1_000_000`); floats **must contain a decimal point** and may have an
exponent (`0.5`, `1.0e-5`, `6.02e23`). `1e-5` is not a valid e7 float.
Only `true`, `false` and `nil` are boolean/unit literals; e7s has no string
literals in value position.

---

## 2. Program structure

A translation unit is a sequence of items. e7s supports these item kinds:

| Item | e7s form | Slang output |
| --- | --- | --- |
| struct | `Name <- struct` + field block | `struct Name { ... };` |
| enum | `Name <- enum` + unit variants | `enum class Name { A, B, };` |
| trait | `trait Name ...` or `Name <- trait ...` | `interface Name { ... };` |
| impl | `impl Trait for Type:` / `impl Type:` | `extension Type : Trait { ... }` / `extension Type { ... }` |
| function | `name <- (params) -> Type` + body | `Type name(params) { ... }` |
| top-level constant | `NAME: Type := expr`, `NAME := expr`, `NAME <- expr` | `static const Type NAME = expr;` |
| inline module | `mod name { ... }` | `namespace name { ... }` |
| external module | `mod name` (+ `use name`/`use name::*`) | sibling `name.slang`, `import name;` |
| resource declaration | `name: Type` with binding attributes | `[[vk::binding(b, s)]] ConstantBuffer<Type> name;` (or explicit resource type) |
| use | `use name;` / `use name::*;` / `use name::{...};` | `import name;` |

Everything else in the e7 grammar (tables, triggers, plugins, systems, async
functions, pointers, optionals, maps, strings, ...) is rejected; see §12.

### 2.1 Items and separators

Items are grouped by kind in the output (types first, then value items,
impls, functions); source order does not matter except between constants that
refer to each other.

```e7s
# items at file scope, one per line
PI := 3.14159265

Circle <- struct
    radius: f32

area <- (r: f32) -> f32 = PI * r * r
```

```slang
static const float PI = 3.14159265;
struct Circle { float radius; };
float area(float r) { return (PI * r) * r; }
```

Enums, constants and resources are covered in the next sections.

### 2.2 Enums and file-scope constants

Enums are **unit-only** and lower to a Slang `enum class` (no explicit
underlying type). Variants are referenced as `Name::Variant`. Payload
variants (`Bar(i32)`, `Baz { ... }`), generic enums and `where` clauses on
enums are rejected.

```e7s
Tone <- enum
    Linear
    Gamma
    Aces
```

```slang
enum class Tone {
    Linear,
    Gamma,
    Aces,
};
```

File-scope bindings are **constants**. Both `:=` and `<-` are accepted, the
type annotation is optional when the initializer's type is inferable, and the
output is always immutable:

```e7s
PI := 3.14159265
TAU: f32 := 6.28318531
GRAVITY: [f32; 3] <- [0.0, -9.81, 0.0]
MAX_LIGHTS: u32 := 8
```

```slang
static const float PI = 3.14159265;
static const float TAU = 6.28318531;
static const float3 GRAVITY = float3(0.0, -9.81, 0.0);
static const uint MAX_LIGHTS = 8;
```

If the type cannot be inferred, the diagnostic is
`module-scope constant 'NAME' needs a type annotation in e7s`. Constant
initializers must be Slang constant expressions (literals, earlier constants,
arithmetic/casts, vector/matrix literals, zero-field struct values); calls
and mutable state are not constant and fail in slangc. Slang requires every
`static const` to have an initializer.

An optional `@resource` attribute may tag a struct or a resource declaration;
it is erased from the Slang output (see §6).

### 2.3 Visibility

`pub` maps to Slang `public`. Items of an external module must be `pub` to be
importable, and fields of a public struct are emitted `public` as well
(Slang modules require this for cross-module construction/field access).
`pub` in a root translation unit is accepted; it does not change shader
behavior.

```e7s
pub Vec3 <- struct
    x: f32
    y: f32

pub dot3 <- (a: [f32; 3], b: [f32; 3]) -> f32 = a.x * b.x + a.y * b.y + a.z * b.z
```

```slang
public struct Vec3 {
    public float x;
    public float y;
};
public float dot3(float3 a, float3 b) { return ((a.x * b.x) + (a.y * b.y)) + (a.z * b.z); }
```

Scoped visibility (`pub(crate)`, `pub(self)`, `pub(in path)`) is not supported
and produces a diagnostic.

### 2.4 Modules, imports and outputs

External modules:

* `mod foo` (terminated by a newline, `;`, or end of file) references the
  sibling file `foo.e7` next to the declaring file. It is not an inline body.
* `use foo;`, `use foo::*;` and selective `use foo::{a, b};` all emit a full
  `import foo;` (Slang imports are unqualified and global; selective imports
  become whole-module imports). Duplicate imports are emitted once.
* Aliases (`use foo as f;`) and module-relative `self`/`super` imports are
  diagnostics.
* Imported names are used **unqualified**. A module-qualified path such as
  `math::dot3` is emitted as `dot3` (the module qualifier is stripped), and
  imports are not transitive: if `a` imports `b`, a root that imports `a`
  must also import `b` to use `b`'s names.
* `use` is only allowed at module scope, not inside an inline module.
* A user module named `core` is rejected: `core` is a built-in Slang module
  name, and a user `core.slang` would resolve to the built-in instead.
* Missing module files, import cycles and nested module depth beyond the
  loader's limit are diagnostics.
* `inline mod name { ... }` is a *namespace*, not an import: names inside are
  qualified (`name::item`) in both e7s and Slang. Inline modules may hold
  structs, enums, traits, impls, functions and constants (not resources, not
  further modules, not `use`).
* Entry points may appear in any file, including imported modules; the
  driver emits one `.slang` file per module, and each stage attribute becomes
  a `[shader(...)]` function there.  Select an entry by compiling the module
  file that owns it (`slangc -entry X <owner>.slang`); `import` does not make
  an entry selectable from the importing root, and `-entry` auto-discovery on
  a root does not see entries in imported modules.

Module names and output files:

* A root file's module name is its file stem with invalid identifier
  characters replaced by `_` (`triangle.vert.e7` → module `triangle_vert`,
  output `triangle_vert.slang`; a leading digit gets a `_` prefix; `core` gets
  a `_` suffix).
* A sibling module referenced by `mod foo` is named `foo` and must exist at
  `foo.e7`; it is emitted as `foo.slang` with `module foo;`.
* Every generated file (root included) starts with `module <name>;`. Use
  `--no-module-decl` to omit it, and `--module-name <name>` to override in
  single-file mode.
* In project mode, `-o <dir>` writes `<module>.slang` for every module;
  `slangc` needs `-I <dir>` to resolve the `import` statements.

```e7s
# root: modules/main.e7
mod math
use math::*;

@fragment
fs_main <- (input: FragInput) -> FragOutput:
    n := normalize_safe(input.normal, 1.0e-5)
    ret FragOutput{colour: [n.x, n.y, n.z, 1.0]}
```

```e7s
# modules/math.e7
pub Vec3 <- struct
    x: f32
    y: f32
    z: f32

pub normalize_safe <- (v: [f32; 3], eps: f32) -> [f32; 3]:
    len_sq := dot3(v, v)
    if len_sq <= eps * eps:
        ret [0.0, 0.0, 1.0]
    ret v * (1.0 / sqrt(len_sq))
```

```slang
// main.slang
module main;

import math;

[shader("fragment")]
FragOutput fs_main(FragInput input) { ... }
```

```slang
// math.slang
module math;

public struct Vec3 {
    public float x;
    public float y;
    public float z;
};
public float3 normalize_safe(float3 v, float eps) { ... }
```

`dot3` above comes from the module example and is referenced through
`use math::*;` (unqualified). Inline namespaces keep their qualifier:
`units::to_metres(...)` is emitted as `units::to_metres(...)`.

---

## 3. Types

### 3.1 Scalars

| e7s | Slang | Notes |
| --- | --- | --- |
| `f32` | `float` | default shader float |
| `i32` | `int` | signed 32-bit |
| `u32` | `uint` | unsigned 32-bit |
| `bool` | `bool` | boolean |

No other scalar types are supported: `i64`, `u64`, `u8`, `i16`, `f16`, `str`,
... are rejected in type position. There is no half-precision scalar in e7s;
use `f32`.

### 3.2 Vectors — `[T; N]`

A one-dimension fixed array type is a **vector** when `N` is 2, 3 or 4 and `T`
is a scalar type.

| e7s | Slang |
| --- | --- |
| `[f32; 2]`, `[f32; 3]`, `[f32; 4]` | `float2`, `float3`, `float4` |
| `[i32; N]` | `int2`/`int3`/`int4` |
| `[u32; N]` | `uint2`/`uint3`/`uint4` |
| `[bool; N]` | `bool2`/`bool3`/`bool4` |

`N` outside 2..4, or a non-scalar element type, is rejected. Large arrays only
appear as `StructuredBuffer<T>` / `RWStructuredBuffer<T>` element storage.

Vector construction uses a list literal in a vector type context (see §5.4):

```e7s
dir := [0.0, 1.0, 0.0] as [f32; 3]
```

```slang
var dir = float3(0.0, 1.0, 0.0);
```

### 3.3 Matrices — `[T; R, C]`

A two-dimension fixed array type is a **matrix** with `R` rows and `C` columns.
`R, C` must each be 2..4 and the element type must be a floating-point scalar
(`f16`, `f32`, or `f64`; `f32` is the normal choice for shaders).

| e7s | Slang |
| --- | --- |
| `[f32; 2, 2]` | `float2x2` |
| `[f32; 3, 3]` | `float3x3` |
| `[f32; 4, 4]` | `float4x4` |
| `[f32; 3, 4]` | `float3x4` (3 rows, 4 columns) |

Matrices are logically **row-major values**: `[f32; R, C]` maps to `floatRxC`,
and a matrix literal/constructor fills rows first. Indexing `m[i, j]` selects
row `i`, column `j` and is emitted as `m[i][j]`; `m[i]` reads row `i` as a
vector.

#### Storage layout

A matrix **struct field** is emitted with an explicit Slang layout modifier:

```e7s
SceneUniform <- struct
    model: [f32; 4, 4]
    view: [f32; 4, 4]
    proj: [f32; 4, 4]
```

```slang
struct SceneUniform {
    column_major float4x4 model;
    column_major float4x4 view;
    column_major float4x4 proj;
};
```

The default is `column_major`, matching Vulkan/std140 and the common
column-major host matrix representation (`Mat4[col][row]` / GLM-style columns).
This is the layout a `ConstantBuffer<T>` expects for matrices uploaded as four
contiguous column vectors, so host code does **not** need to split a matrix into
separate `float4` fields to get an unambiguous payload. The modifier is
explicit, so e7s output does not depend on the compiler's default
matrix-layout mode.

Use `@row_major` on a field to select row-major storage instead, or
`@column_major` to spell out the default. Both are field-only attributes and
are valid only on matrix fields; using both on one field is a diagnostic.

> Slang's matrix convention is transposed relative to SPIR-V's decoration
> spelling: source-level `column_major` is emitted by slangc as the inverse
> `RowMajor` SPIR-V member decoration. Do not infer the host byte layout from
> the SPIR-V token alone — the e7s source-level layout is column-major, i.e.
> memory offset 0/16/32/48 holds columns 0..3 of a `4x4` matrix.

e7's `*` keeps e7's matrix meaning: when either operand is a matrix the
transpiler emits `mul(lhs, rhs)` (`matrix * matrix`, `matrix * vector`,
`vector * matrix`). Scalar/component-wise arithmetic with vectors is emitted
unchanged (`scalar * vector`, `vector * scalar`, vector `*` vector). An
explicit `mul(...)` call passes through unchanged.

```e7s
position := [x, y, z, 1.0] as [f32; 4]
clip := scene.proj * (scene.view * (scene.model * position))
```

```slang
var position = float4(x, y, z, 1.0);
var clip = mul(scene.proj, mul(scene.view, mul(scene.model, position)));
```

A local matrix literal also works, and `m[i]` / `m[i, j]` use logical rows:

```e7s
local := [[1.0, 0.0], [0.0, 1.0]] as [f32; 2, 2]
row := local[0]          # [f32; 2] row 0
value := local[1, 0]     # 0.0 (row 1, column 0)
```

### 3.4 User structs, generic parameters and unit results

* A struct name is a type: `Vertex`, `Vec3`, `Pair<Circle>`.
* A generic parameter is a type: `T` inside `Pair<T>` or `name<T> <- ...`.
* A trait/interface name may be used as a type (Slang interface-typed value,
  dynamic dispatch): `h <- (t: IShape) -> f32`.
* `nil`, `()`, and `!nil` are unit/error-or-nothing result types and all map
  to Slang `void`. They are only valid as function result types; e7s has no
  nil value.
* References `&T` and `&mut T` are accepted **only** in trait receivers and
  the first `this` parameter of an impl method (§9). They are not general
  parameter, field or local types.

### 3.5 Resource types

These path types are passed through to Slang with their type arguments mapped
using the normal type rules:

| e7s resource type | Slang |
| --- | --- |
| `Texture2D<[f32; 4]>` | `Texture2D<float4>` |
| `Texture2D<f32>` | `Texture2D<float>` |
| `Sampler2D<[f32; 4]>` | `Sampler2D<float4>` (combined image sampler) |
| `Sampler2D` | `Sampler2D` (combined image sampler, `float4` element) |
| `SamplerState` | `SamplerState` |
| `StructuredBuffer<T>` | `StructuredBuffer<SlangT>` |
| `RWStructuredBuffer<T>` | `RWStructuredBuffer<SlangT>` |

`Texture2D` requires one type argument; `StructuredBuffer` and
`RWStructuredBuffer` require one element type (a struct or scalar). The
transpiler maps the type arguments as written and leaves element-type legality
to slangc. These names are only meaningful in resource declarations (§7).

#### 3.5.1 Combined image samplers

`Sampler1D`, `Sampler1DArray`, `Sampler2D`, `Sampler2DArray`, `Sampler3D`,
`SamplerCube` and `SamplerCubeArray` are Slang's legacy **combined**
texture-sampler types: a single resource that combines an image and its
sampler. e7s accepts them as resource types and passes them through; the
optional type argument is the sampled element type (`Sampler2D<[f32; 4]>` is
`Sampler2D<float4>`) and defaults to `float4` when omitted.

A combined sampler lowers to one Slang resource, so slangc emits exactly one
SPIR-V `OpTypeSampledImage` variable — i.e. one
`VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER` Vulkan descriptor at the declared
`@binding(binding, set)`:

```e7s
@binding(0, 0)
albedo: Sampler2D<[f32; 4]>

@fragment
fs_main <- (input: FragInput) -> [f32; 4]:
    base := albedo.Sample(input.uv)
    ret [base.x, base.y, base.z, base.w]
```

```slang
[[vk::binding(0, 0)]] Sampler2D<float4> albedo;

[shader("fragment")]
float4 fs_main(FragInput input) : SV_Target {
    var base = albedo.Sample(input.uv);
    return float4(base.x, base.y, base.z, base.w);
}
```

`.Sample(coords)` on a combined sampler takes no separate sampler argument.
This is distinct from the separate-resource spelling
`Texture2D<T>` + `SamplerState`, which needs **two** descriptors on two
different bindings and is sampled as `texture.Sample(sampler, coords)`.

Do not try to write the same `@binding` for a `Texture2D` and a
`SamplerState`: e7s still diagnoses duplicate `set`+`binding` pairs, because
those two declarations are two resources (`SAMPLED_IMAGE` + `SAMPLER`), not a
combined descriptor. The combined descriptor is spelled with the single
`Sampler*` resource type.

Slang also has a `[[vk::combinedImageSampler]]` attribute for pairing a
`Texture2D` with a `SamplerState` on one binding. The committed toolchain
(Slang 2026.20, `.tooling/slang`) does not recognise that attribute
(`warning[E31000]: unknown attribute 'vk_combinedImageSampler'`), so e7s uses
the combined `Sampler*` types instead; they produce the equivalent SPIR-V
`OpTypeSampledImage` variable directly.

### 3.6 Unsupported types and diagnostics

Rejected with a diagnostic at the type's span:

`!T` (inferred error) and `E!T` (explicit error) — only `!nil` is accepted —
`?T` (optional), `*T` (box), `*raw T` (raw pointer), tuple types other than
`()`, `(A) -> B` function types, `map[K, V]`, `str`, `[T]` and any fixed array
whose shape is not a vector/matrix (`[f32; 8]`, `[f32; 1]`, `[f32; 4, 4, 4]`),
`&T`/`&mut T` outside receiver position, and `crate`/`self`/`super` path
roots. e7 error effects are **not** erased: an explicit error result (`!T`,
`E!T`) is rejected; only `!nil` is treated as `void` for ergonomics.

---

## 4. Statements

### 4.1 Bindings

| e7s | Slang | Meaning |
| --- | --- | --- |
| `x <- expr` | `let x = expr;` | immutable binding |
| `x := expr` | `var x = expr;` | mutable binding |
| `x: T <- expr` | `T x = expr;` | typed local (mutable Slang variable) |
| `x: T := expr` | `T x = expr;` | typed local |
| `x: T` | `T x;` | uninitialized local (mutable) |

Typed locals always emit an explicit Slang type and a plain initializer, so
they are mutable; use untyped `<-` for a Slang `let`.

```e7s
sum := 0.0
tint <- [1.0, 0.5, 0.25]
acc: [f32; 3] <- [0.0, 0.0, 0.0]
```

```slang
var sum = 0.0;
let tint = float3(1.0, 0.5, 0.25);
float3 acc = float3(0.0, 0.0, 0.0);
```

### 4.2 Assignment

`=`, `+=`, `-=`, `*=`, `/=`, `%=` are supported and emitted unchanged. The
left side must be a mutable variable, field, index or swizzle assignment;
e7s does no type checking, so assigning to a `let` binding is diagnosed by
slangc.

### 4.3 `ret`

| e7s | Slang |
| --- | --- |
| `ret expr` | `return expr;` |
| `ret` (in a unit-returning function) | `return;` |

Functions whose result is `nil`, `()`, or `!nil` return `void`; `ret expr` in
such a function is a Slang type error.

### 4.4 Conditionals

`if` / `elif` / `else` with layout or brace blocks lower to
`if (...) { ... } else if (...) { ... } else { ... }`.

```e7s
if index >= params.count:
    ret
elif index == 0:
    particles[index].velocity = [0.0, 0.0, 0.0]
else:
    particles[index].velocity += params.gravity * params.dt
```

```slang
if ((index >= params.count)) {
    return;
} else if ((index == 0)) {
    particles[index].velocity = float3(0.0, 0.0, 0.0);
} else {
    particles[index].velocity += (params.gravity * params.dt);
}
```

`if` can also be used as a value expression; see §5.7.

### 4.5 Loops

| e7s | Slang |
| --- | --- |
| `for i in 0..n:` | `for (int i = 0; i < n; i++)` |
| `for i in 0..=n:` | `for (int i = 0; i <= n; i++)` |
| `while cond:` | `while (cond)` |
| `loop:` | `for (;;)` |
| `break` | `break;` |
| `cont` | `continue;` |

Range loops require an explicit range; `for x in expr` over a non-range
expression is rejected (e7s has no iterators). e7 `loop` has no condition, so
it lowers to an infinite loop and must contain a `break` on every path slangc
can prove reachable.

```e7s
for i in 0..4:
    sum += float(i)
while sum > 1.0:
    sum *= 0.5
```

```slang
for (int i = 0; i < 4; i++) {
    sum += float(i);
}
while ((sum > 1.0)) {
    sum *= 0.5;
}
```

### 4.6 `match` statements

`match` is supported **as a statement** (not as a value). It lowers to a
Slang `switch`. Patterns may be literals, enum variants (`Tone::Red`), or `_`
(or-patterns such as `Red | Green` are allowed as case labels). Guards
(`if` after an arm pattern) are not supported, and a wildcard arm must be the
last arm.

```e7s
result: f32 <- 0.0
match tone:
    Tone::Linear: result = value
    Tone::Gamma: result = pow(value, 2.2)
    _: result = value * 0.8
```

```slang
float result = 0.0;
switch (tone) {
    case Tone::Linear:
        result = value;
        break;
    case Tone::Gamma:
        result = pow(value, 2.2);
        break;
    default:
        result = (value * 0.8);
        break;
}
```

### 4.7 Unsupported statements

`unsafe:` blocks, `disown`, `await`, `spawn`, `detach`, `cancel`, and the e7
engine item kinds are rejected. See §12.

---

## 5. Expressions

### 5.1 Literals

| e7s | Slang |
| --- | --- |
| `0`, `42`, `1_000_000` | `0`, `42`, `1000000` |
| `0.5`, `1.0e-5`, `6.02e23` | `0.5`, `1.0e-5`, `6.02e23` |
| `true`, `false` | `true`, `false` |
| `nil` | only as a `nil` result type / via `ret`; not a value |

There are no string literals in e7s; `"text"` is a diagnostic.

### 5.2 Paths, calls, fields, swizzles, indexing

* Paths name locals, constants, file-scope items, generic parameters, enum
  variants (`Tone::Gamma`) and namespace members (`units::to_metres`).
* Calls are emitted unchanged: `dot3(a, b)`, `normalize(v)`,
  `texture.Sample(sampler, uv)`, interface method calls (`t.area()`), and
  extension method calls inside impl bodies (`this.area()`).
* Field access and swizzles are emitted unchanged: `colour.rgb`, `p.xyz`,
  `v.x` are valid Slang swizzles (up to 4 components). Impl bodies keep their
  `this.` receiver references (`this.radius`), which is valid inside Slang
  extension methods.
* `expr[i]` indexes vectors, matrices (rows), storage buffers and arrays.
  `expr[i, j]` is emitted as `expr[i][j]`; chained `expr[i][j]` is equivalent.
* `&expr`, `*expr`, `expr?`, and `await`/`spawn`/`detach`/`cancel` are not
  expressions in e7s.

```e7s
base := albedo.Sample(albedo_sampler, input.uv)
tint := [base.r, base.g, base.b, push.alpha]
row := scene.mvp[0]
cell := scene.mvp[0, 1]
```

```slang
var base = albedo.Sample(albedo_sampler, input.uv);
var tint = float4(base.r, base.g, base.b, push.alpha);
var row = scene.mvp[0];
var cell = scene.mvp[0][1];
```

### 5.3 Struct literals

e7s struct literals are **named and order-independent**; Slang constructors
are positional in declaration order. The transpiler reorders fields to match
the struct declaration, expands shorthand fields (`S{a, b}` → `S(a, b)`) and
requires every field exactly once. Missing, duplicate and unknown fields are
diagnostics. A bare zero-field struct value `Empty` is emitted as `Empty()`.

```e7s
Varying <- struct
    @builtin(position) clip_position: [f32; 4]
    @location(0) colour: [f32; 4]

ret Varying{colour: vertex.colour, clip_position: clip}
```

```slang
struct Varying {
    float4 clip_position : SV_Position;
    [[vk::location(0)]] float4 colour;
};

return Varying(clip, vertex.colour);
```

Slang has no designated initializers (`S{.x = 1}` is a parse error); the
constructor call above is the only form.

### 5.4 List literals and vector/matrix construction

A list literal becomes a Slang vector/matrix constructor when a vector/matrix
type is in context. The context may come from:

* a typed local (`x: [f32; 3] <- [...]`),
* a parameter type, struct field type, or function return type,
* a call argument whose parameter type is known, or
* a cast: `[...] as [f32; N]` / `[...] as [f32; R, C]`.

A bare list literal with no context is a diagnostic
(`cannot infer the element type of a list literal; annotate the binding or
parameter`).

| e7s | Slang |
| --- | --- |
| `[x, y] as [f32; 2]` | `float2(x, y)` |
| `[x, y, z] as [f32; 3]` | `float3(x, y, z)` |
| `[x, y, z, w] as [f32; 4]` | `float4(x, y, z, w)` |
| `[[a, b], [c, d]] as [f32; 2, 2]` | `float2x2(a, b, c, d)` (logical row order) |
| `x: [f32; 3] <- [a, b, c]` | `float3 x = float3(a, b, c);` |
| `ret [a, b, c]` (return type `[f32; 3]`) | `return float3(a, b, c);` |

Matrix literals are nested row lists with `R` rows of `C` elements each and
are flattened row by row.

### 5.5 Casts

`expr as Type` lowers to a Slang constructor cast:

| e7s | Slang |
| --- | --- |
| `x as f32` | `float(x)` |
| `x as i32` | `int(x)` |
| `x as u32` | `uint(x)` |
| `x as bool` | `bool(x)` |
| `v as [f32; 3]` | `float3(v)` |
| `[a, b, c, d] as [f32; 4]` | `float4(a, b, c, d)` |
| `[[...], [...]] as [f32; R, C]` | `floatRxC(...)` |
| `x as SomeStruct` | diagnostic (no struct casts) |

For list literals the cast supplies the element-type context and emits a
single constructor (it does not nest constructors). Casts are otherwise
unchecked by e7s; invalid conversions are reported by slangc.

### 5.6 Operators

| e7s | Slang |
| --- | --- |
| `+ - * / %` | same (`*` becomes `mul` for matrix operands) |
| unary `-` | same |
| `== != < <= > >=` | same |
| `and` | `&&` |
| `or` | `\|\|` |
| `xor` (booleans) | `!=` |
| `not` | `!` |

There are no `&&`, `||` or `!` operators in e7 source; the word forms are the
only spellings. `xor` is boolean inequality and only valid on `bool` operands;
it is emitted as `!=` (the `^^` spelling is never used). Ranges (`..`, `..=`)
are only valid in `for` loops.

Matrix products keep e7's meaning: when either operand is a matrix, `*`
becomes `mul(lhs, rhs)` (`matrix * matrix`, `matrix * vector`,
`vector * matrix`). Scalar/vector component-wise arithmetic, including
`scalar * matrix` and `scalar * vector`, stays `*`. `%` is emitted unchanged
and follows Slang: use `fmod` for float modulo.

### 5.7 `if` as a value

An `if`/`elif`/`else` used as a value lowers to a Slang ternary expression.
Each branch must be a single tail expression (a branch consisting of
statements is not a value). Conditions must be scalar; for vector conditions
use the Slang `select(condition, ifTrue, ifFalse)` intrinsic.

```e7s
y := if x > 0.0: 1.0 else: 0.0
```

```slang
var y = ((x > 0.0) ? 1.0 : 0.0);
```

### 5.8 Intrinsics

e7s does not declare a standard library of its own. Any unqualified call whose
callee is not a user-defined function is emitted unchanged and resolved by
Slang. Typical intrinsics:

`abs`, `min`, `max`, `clamp`, `saturate`, `lerp`, `mix`, `step`, `smoothstep`,
`select`, `pow`, `exp`, `exp2`, `log`, `log2`, `sqrt`, `rsqrt`, `sin`, `cos`,
`tan`, `asin`, `acos`, `atan`, `atan2`, `floor`, `ceil`, `round`, `frac`,
`fmod`, `dot`, `cross`, `normalize`, `length`, `distance`, `reflect`,
`refract`, `faceforward`, `mul`, `transpose`, `determinant`, `any`, `all`,
`sign`, `degrees`, `radians`, `isnan`, `isinf`.

Unknown callees become Slang "identifier not found" errors, not e7s
diagnostics. User functions must be declared in the same file or imported via
`use`.

### 5.9 Unsupported expressions

`match` used as a value, anonymous function expressions, error literals
(`!NotFound`), map literals, string literals, row literals (`{a, b, c}`),
tuple values, `?`, `&`/`*` operators, ranges outside `for`, and
`await`/`spawn`/`detach`/`cancel`/`query` are rejected with diagnostics.
If-expressions used as values are supported only under the §5.7 rules.

---

## 6. Attributes (the e7s extensions)

e7s extensions are spelled as e7 attributes. Attributes attach to items or
struct fields and lower as follows.

### 6.1 Attribute mapping table

| e7s attribute | Placement | Slang output | Rules |
| --- | --- | --- | --- |
| `@binding(binding, set)` | resource declaration | `[[vk::binding(binding, set)]]` before the declaration | Exactly two non-negative integer literals. Order is **(binding, set)**, matching Slang/Vulkan `[[vk::binding(binding, set)]]`. Required on every resource declaration except `@push_constant`. Duplicate `set`+`binding` pairs are diagnosed. |
| `@push_constant` | resource declaration | `[[vk::push_constant]] ConstantBuffer<T>` | No arguments; mutually exclusive with `@binding` and `@uniform`. |
| `@uniform` | resource declaration (user struct only) | same `ConstantBuffer<T>` lowering as the default | Explicit-intent tag; rejected together with `@push_constant` and on explicit Slang resource types. Not needed for correctness. |
| `@resource` | struct declaration or resource declaration | erased | Optional documentation/engine tag; no semantic effect. |
| `@vertex` | function | `[shader("vertex")]` | No arguments. Exactly one stage attribute per function. |
| `@fragment` | function | `[shader("fragment")]` | No arguments. |
| `@compute(x, y, z)` | function | `[shader("compute")]` + `[numthreads(x, y, z)]` | Three positive integer literals. Emitted on the line after the shader attribute. |
| `@inline` | function or impl method | `[ForceInline]` | Contracts where the Slang backend supports force-inlining. On an entry point the stage attribute wins and no `[ForceInline]` is emitted. Rejected on structs, fields, traits and resources. |
| `@location(n)` | struct field | `[[vk::location(n)]]` | Non-negative integer literal. Used on entry/varying interface fields. |
| `@builtin(name)` | struct field | `: SV_Name` semantic (§8.5) | `name` is one of the listed identifiers; any other name is a diagnostic. A field cannot have both `@builtin` and `@location`. |
| `@flat` | struct field | `nointerpolation` modifier before the type | Meaningful on varying fields; required on integer varyings. Do not use Slang's `[flat]`: it is accepted but silently ignored. |
| `@column_major` | matrix struct field | `column_major` modifier before the matrix type | The default layout for matrix fields; may be written explicitly. Rejected on non-matrix fields and together with `@row_major`. |
| `@row_major` | matrix struct field | `row_major` modifier before the matrix type | Opts into row-major storage instead of the default column-major layout. Rejected on non-matrix fields and together with `@column_major`. |

Attribute placement is checked against a per-item allowlist; any other
attribute (including `@Components`, `@trigger`, `@plugin`, `@derive`) is a
diagnostic rather than being silently dropped.

### 6.2 Examples

```e7s
@resource
Frame <- struct
    view_proj: [f32; 4, 4]

@uniform
@binding(0, 0)
frame: Frame

@push_constant
push: DrawPush

@binding(1, 0)
albedo: Texture2D<[f32; 4]>

@binding(2, 0)
combined: Sampler2D<[f32; 4]>
```

```slang
struct Frame {
    column_major float4x4 view_proj;
};

[[vk::binding(0, 0)]] ConstantBuffer<Frame> frame;

[[vk::push_constant]] ConstantBuffer<DrawPush> push;

[[vk::binding(1, 0)]] Texture2D<float4> albedo;

[[vk::binding(2, 0)]] Sampler2D<float4> combined;
```

```e7s
Varying <- struct
    @builtin(position) clip_position: [f32; 4]
    @flat @location(1) instance_id: u32
    @location(0) uv: [f32; 2]
```

```slang
struct Varying {
    float4 clip_position : SV_Position;
    nointerpolation [[vk::location(1)]] uint instance_id;
    [[vk::location(0)]] float2 uv;
};
```

---

## 7. Resources and constants

### 7.1 Resource declarations

A **resource declaration** is a top-level uninitialized declaration
`name: Type` carrying a binding attribute:

```e7s
@binding(0, 0)
scene: Scene
```

```slang
[[vk::binding(0, 0)]] ConstantBuffer<Scene> scene;
```

Lowering rules:

1. Every resource declaration requires exactly one `@binding(binding, set)`
   or `@push_constant`; otherwise it is a diagnostic.
2. A user-defined **struct** type lowers to `ConstantBuffer<T>`, prefixed by
   `[[vk::binding(binding, set)]]` (or `[[vk::push_constant]]` for
   `@push_constant`).
3. `@uniform` produces the same `ConstantBuffer<T>` output as rule 2; it is
   the explicit spelling of that intent. It is rejected on explicit Slang
   resource types and together with `@push_constant`.
4. Explicit Slang resource types pass through with their type arguments
   mapped: `Texture2D<T>`, `Sampler2D<T>` (the combined image sampler, §3.5.1),
   `SamplerState`, `StructuredBuffer<T>`, `RWStructuredBuffer<T>`. Only
   `@binding` applies to these. A combined `Sampler*` type is one descriptor;
   `Texture2D` + `SamplerState` are two descriptors and therefore need two
   different bindings.
5. `@resource` is accepted on a resource declaration or on the resource's
   struct; it is erased.
6. Duplicate `set`+`binding` pairs across resource declarations are diagnosed
   by e7s. e7s does not otherwise validate descriptor-set usage; slangc and
   pipeline validation report the rest.
7. Resources are file-scope only: a resource declaration inside a function or
   inline module is a diagnostic.

Resources may be declared in any source order relative to their type
declarations. The transpiler emits type declarations first, then value items
(constants and resources) in source order, so forward references to structs
are fine:

```e7s
@binding(1, 0)
particles: RWStructuredBuffer<Particle>

Particle <- struct
    position: [f32; 3]
```

```slang
struct Particle { float3 position; };
[[vk::binding(1, 0)]] RWStructuredBuffer<Particle> particles;
```

### 7.2 Push constants

```e7s
@push_constant
push: DrawPush
```

```slang
[[vk::push_constant]] ConstantBuffer<DrawPush> push;
```

`@push_constant` takes no arguments and cannot be combined with `@binding` or
`@uniform`.

### 7.3 File-scope constants

File-scope bindings are immutable constants emitted after types. `:=` and
`<-` are both accepted; the type may be inferred when the initializer makes it
determinable (§2.2, §5.4):

```e7s
PI := 3.14159265
WHITE: [f32; 3] := [1.0, 1.0, 1.0]
```

```slang
static const float PI = 3.14159265;
static const float3 WHITE = float3(1.0, 1.0, 1.0);
```

Constants may refer to previously emitted constants; references to later
constants may fail in Slang because `static const` initializers are evaluated
in order.

---

## 8. Entry points

### 8.1 Model

Entry points are ordinary e7 functions carrying a stage attribute. The
function name is preserved in Slang. Entry functions need not be `pub`
(Slang entry points are not required to be public), and they may appear in a
root file or in an imported module file. A file can contain several entries.
Compile the file that owns the entry point when selecting it with
`slangc -entry`; Slang imports do not re-export entry points.

```e7s
@vertex
vs_main <- (vertex: Vertex) -> Varying:
    ret Varying{clip_position: [0.0, 0.0, 0.0, 1.0]}
```

```slang
[shader("vertex")]
Varying vs_main(Vertex vertex) { ... }
```

Rules:

* Exactly one of `@vertex`, `@fragment`, `@compute(x, y, z)` per function.
* Entry points take zero or one **user struct** parameter. Scalar/vector
  parameters are not part of e7s entry signatures; use a one-field struct.
* Struct fields of entry inputs/outputs carry `@location(n)` and/or
  `@builtin(name)`.
* `@compute` arguments become `[numthreads(x, y, z)]`; they must be positive
  integer literals. Vulkan's 1024-invocations-per-workgroup limit is checked
  by slangc/driver, not e7s.
* A unit result (`nil`, `()`, `!nil`) emits `void`; a fragment entry with a
  non-struct scalar/vector result additionally gets ` : SV_Target`.

### 8.2 Vertex stages

* Input struct fields use `@location(n)` only.
* Output must be a struct declared in the program and it must contain a
  `@builtin(position)` field (clip position); otherwise the diagnostic is
  `vertex output struct 'X' needs a field marked @builtin(position)`.
* Other output fields are `@location(n)` varyings.

```e7s
Vertex <- struct
    @location(0) position: [f32; 3]
    @location(1) colour: [f32; 4]

Varying <- struct
    @builtin(position) clip_position: [f32; 4]
    @location(0) colour: [f32; 4]

@vertex
vs_main <- (vertex: Vertex) -> Varying:
    clip := scene.mvp * [vertex.position.x, vertex.position.y, vertex.position.z, 1.0]
    ret Varying{clip_position: clip, colour: vertex.colour}
```

```slang
struct Vertex {
    [[vk::location(0)]] float3 position;
    [[vk::location(1)]] float4 colour;
};
struct Varying {
    float4 clip_position : SV_Position;
    [[vk::location(0)]] float4 colour;
};

[shader("vertex")]
Varying vs_main(Vertex vertex) {
    var clip = mul(scene.mvp, float4(vertex.position.x, vertex.position.y, vertex.position.z, 1.0));
    return Varying(clip, vertex.colour);
}
```

### 8.3 Fragment stages

* Input struct fields use `@location(n)` varyings and optionally
  `@builtin(position)` (`frag_coord`).
* Output struct fields use `@location(n)`; each is a colour attachment. No
  SL semantics (`SV_Target`) are needed for struct outputs: Slang assigns
  locations from `[[vk::location(n)]]`.
* A unit result writes no colour attachments. A non-struct scalar/vector
  result (for example `-> [f32; 4]`) is emitted as `float4 fs(...) : SV_Target`.

```e7s
FragInput <- struct
    @builtin(position) frag_coord: [f32; 4]
    @location(0) colour: [f32; 4]

FragOutput <- struct
    @location(0) colour: [f32; 4]

@fragment
fs_main <- (input: FragInput) -> FragOutput:
    ret FragOutput{colour: [input.colour.r, input.colour.g, input.colour.b, 1.0]}
```

```slang
struct FragInput {
    float4 frag_coord : SV_Position;
    [[vk::location(0)]] float4 colour;
};
struct FragOutput {
    [[vk::location(0)]] float4 colour;
};

[shader("fragment")]
FragOutput fs_main(FragInput input) {
    return FragOutput(float4(input.colour.r, input.colour.g, input.colour.b, 1.0));
}
```

### 8.4 Compute stages

* One parameter: a struct whose fields are compute builtins, typically
  `@builtin(dispatch_thread_id) tid: [u32; 3]`.
* Return type must be a unit type (`nil`); otherwise diagnostic.
* `@compute(x, y, z)` provides `[numthreads(x, y, z)]`.

```e7s
DispatchId <- struct
    @builtin(dispatch_thread_id) tid: [u32; 3]

@compute(64, 1, 1)
cs_update <- (id: DispatchId) -> nil:
    index := id.tid.x
    if index >= params.count:
        ret
    particles[index].position += particles[index].velocity * params.dt
```

```slang
struct DispatchId {
    uint3 tid : SV_DispatchThreadID;
};

[shader("compute")]
[numthreads(64, 1, 1)]
void cs_update(DispatchId id) {
    var index = id.tid.x;
    if ((index >= params.count)) {
        return;
    }
    particles[index].position += (particles[index].velocity * params.dt);
}
```

### 8.5 Builtin mapping table

`@builtin(name)` maps to a Vulkan/Slang system-value semantic. `position` and
`frag_coord` intentionally share `SV_Position`; they differ by stage and
direction.

| e7s `@builtin` name | Slang semantic | Legal stage/direction | Conventional e7s type |
| --- | --- | --- | --- |
| `position` | `SV_Position` | vertex output, fragment input | `[f32; 4]` |
| `vertex_index` | `SV_VertexID` | vertex input | `u32` |
| `instance_index` | `SV_InstanceID` | vertex input | `u32` |
| `primitive_id` | `SV_PrimitiveID` | fragment input | `u32` |
| `front_facing` | `SV_IsFrontFace` | fragment input | `bool` |

> Slang rebases `SV_VertexID`/`SV_InstanceID` with `BaseVertex`/`BaseInstance`,
> so vertex shaders using `vertex_index` or `instance_index` emit the SPIR-V
> `DrawParameters` capability and require the Vulkan 1.1
> `shaderDrawParameters` feature.  This is a Slang lowering detail, not an
> e7s-level error; `engine/platform/shaders/triangle.vert.e7` is an example.
| `sample_index` | `SV_SampleIndex` | fragment input | `u32` |
| `depth` | `SV_Depth` | fragment output | `f32` |
| `frag_coord` | `SV_Position` | fragment input | `[f32; 4]` |
| `dispatch_thread_id` | `SV_DispatchThreadID` | compute input | `[u32; 3]` |
| `group_thread_id` | `SV_GroupThreadID` | compute input | `[u32; 3]` |
| `group_id` | `SV_GroupID` | compute input | `[u32; 3]` |
| `group_index` | `SV_GroupIndex` | compute input | `u32` |

Any other `@builtin` name is a diagnostic. There is no geometry/tessellation
stage support in e7s.

### 8.6 Interface matching between files

Every `.e7` file is transpiled independently; there is no cross-file type
identity. The vertex stage's output struct and the fragment stage's input
struct must therefore be declared twice with matching field attributes and
types (or imported from a shared module). A mismatch is reported by Slang or
when the SPIR-V modules are paired, not by e7s.

---

## 9. Traits, impls and generics

### 9.1 Trait declarations → Slang interfaces

Both e7 spellings are accepted:

```e7s
trait IShape
    area <- (&self) -> f32

IShaded <- trait : IShape
    albedo <- (&self) -> [f32; 3]
```

```slang
interface IShape {
    float area();
};
interface IShaded : IShape {
    float3 albedo();
};
```

* A trait body is optional (`trait Empty;` is valid) and contains
  signature-only requirements.
* `&self` → non-mutating interface method; `&mut self` → `[mutating]` method.
* A supertrait list (`trait B : A + C`) lowers to interface inheritance
  (`interface B : A, C`).
* Trait methods require a `self` receiver; static trait methods are rejected.
  Generic trait methods and `where` clauses on trait methods are also
  rejected. Parameters may omit names (`&mut Gpu`); unnamed parameters are
  emitted as `argN`.
* Attributes on trait methods are rejected.

### 9.2 Impl blocks → Slang extensions

`impl Trait for Type:` lowers to `extension Type : Trait`.
`impl Type:` (no trait) is an inherent extension `extension Type`.

```e7s
impl IShape for Circle:
    @inline
    area <- (this: &Circle) -> f32 = PI * this.radius * this.radius

impl IShaded for Circle:
    shade <- (this: &mut Circle, amount: f32) -> nil:
        this.colour = this.colour * amount
```

```slang
extension Circle : IShape {
    [ForceInline] float area() { return ((PI * this.radius) * this.radius); }
}
extension Circle : IShaded {
    [mutating] void shade(float amount) { this.colour = (this.colour * amount); }
}
```

Receiver rules:

* Impl methods may declare a receiver as the **first parameter named `this`**
  with type `&Type` or `&mut Type`.
* The parameter is dropped; Slang's extension receiver is the implicit `this`,
  and body references such as `this.radius` are emitted as written (valid
  Slang inside extension methods).
* `&mut Type` receivers are emitted with the Slang `[mutating]` attribute.
* A method with **no `this` parameter is emitted as a `static` method**. This
  is how factories/constructors are exposed:
  `make <- () -> Rig = Rig{...}` → `static Rig make() { ... }`.
  Call them as `Rig::make(...)` from e7s.
* The receiver type must match the impl target; mismatches are diagnostics.
* `@inline` on an impl method emits `[ForceInline]`; other method attributes
  are rejected.
* All required trait methods must be implemented; missing methods are
  reported by slangc.

### 9.3 Generic parameters and bounds

Generic parameters are declared on the item name: `Pair<T>`, `sum_area<T>`,
`impl<T>`. A `where` clause after the signature/type constrains a parameter.
e7 `+` bounds are accepted: the **first** bound for a parameter is emitted in
the angle-bracket list, and any extra bounds are emitted in a trailing
`where` clause (Slang supports one bound per parameter in `<...>` and accepts
additional `where T : Bound` clauses).

Structs and extensions:

```e7s
Pair<T> <- struct where T: IShape + IClamped
    first: T
    second: T

impl<T> Pair<T> where T: IShape:
    combined_area <- (this: &Pair<T>) -> f32 = this.first.area() + this.second.area()
```

```slang
struct Pair<T : IShape> where T : IClamped {
    T first;
    T second;
};

extension<T : IShape> Pair<T> {
    float combined_area() { return (this.first.area() + this.second.area()); }
}
```

Functions support multiple parameters and multiple bounds; predicates are
merged per parameter (first bound in `<...>`, rest in `where`):

```e7s
sum2<T> <- (x: T) -> f32 where T: IA + IB:
    ret x.a() + x.b()

pick<T, U> <- (x: T, y: U) -> f32 where T: IA, U: IB:
    ret x.a() + y.b()
```

```slang
float sum2<T : IA>(T x) where T : IB {
    return (x.a() + x.b());
}

float pick<T : IA, U : IB>(T x, U y) {
    return (x.a() + y.b());
}
```

Additional rules:

* Enums cannot be generic and reject `where` clauses.
* Multiple `where` predicates across different parameters are accepted;
  their extra bounds are emitted as repeated `where T : ... where U : ...`
  clauses because Slang 2026.20 rejects comma-separated where predicates.
* `where` predicates must name a bare generic parameter.

### 9.4 Trait names in type position

A trait name can be used as an ordinary value type (parameter, local, field),
lowering to a Slang interface-typed value with dynamic dispatch:

```e7s
h <- (shape: IShape) -> f32:
    ret shape.area()
```

```slang
float h(IShape shape) {
    return shape.area();
}
```

Prefer generic parameters with bounds for static dispatch (§9.3). Interface
values have dynamic-dispatch costs and limited shader support; use them
deliberately.

### 9.5 Cross-module impls

Within the defining module, an impl may stay non-public (Slang's default
internal visibility). To use an impl through an imported module, mark the impl
`pub`; the transpiler emits `public extension ...` and marks its methods
`public` so they are visible to importers:

```e7s
pub impl IShape for A:
    area <- (this: &A) -> f32 = this.x
```

```slang
public extension A : IShape {
    public float area() { return this.x; }
}
```

```slang
public extension A : IShape {
    public float area() { return this.x; }
}
```

Non-public impls in a module are emitted without `public`, and cross-module
calls through them fail in slangc (not e7s).

---

## 10. Semantics differences from e7

e7s is a syntax-directed subset: it preserves surface syntax but changes
meaning where the GPU model has no equivalent.

| e7 concept | e7s behavior |
| --- | --- |
| `<-` local binding | immutable `let` |
| `:=` local binding | mutable `var` |
| typed local `x: T <- expr` / `x: T := expr` | `T x = expr;` (mutable Slang variable) |
| file-scope binding (`<-`, `:=`, with or without type) | **constant**, emitted `static const T name = expr;`, always immutable |
| top-level uninitialized `name: T` | resource declaration only; requires `@binding`/`@push_constant` |
| named struct literal | positional Slang constructor in declaration order |
| `as` cast | constructor cast (`float(x)`, `float3(v)`, `float4x4(...)`) |
| `nil`, `()`, `!nil` result | `void`; `ret` → `return;` |
| other error effects (`!T`, `E!T`) | rejected — error effects are not erased |
| enum | Slang `enum class`; variants `Name::Variant` |
| `match` | statement only → `switch` |
| `if` as value | ternary, single tail expression per branch, scalar condition |
| `matrix * vector` | emitted `mul(matrix, vector)` (and matrix*matrix, vector*matrix) |
| `[a, b] as [f32; 2]` | vector/matrix constructors; bare list literals need a context |
| `use foo::*;` | `import foo;`; names become unqualified |
| module-qualified name `foo::bar` | emitted `bar` for imported modules (qualifier stripped); inline namespace qualifiers are kept |
| `T: A + B` bounds | first bound in `<...>`, extra bounds in trailing `where` |
| `xor` | boolean `!=` |
| recursion | not restricted by e7s; Slang/SPIR-V reject recursion in shader call graphs |

### 10.1 Constants

File-scope bindings are constants regardless of `<-`/`:=`. The type
annotation is optional when the initializer type is inferable. Slang requires
`static const` variables to have an initializer, so an initializer is
mandatory. Initializers must be Slang constant expressions: literals, earlier
constants, arithmetic/comparisons/casts, vector/matrix literals, and
zero-field struct values. Calls and mutable state are invalid and fail in
slangc.

### 10.2 Type and semantic checking

**Type and semantic checking is delegated to Slang.** e7s validates structure
(which items/types/attributes/expressions belong to the subset), not value
types, overload resolution, constant folding or descriptor-set validity.
Anything that requires types — assigning a `float3` to a `float4`, calling an
undeclared intrinsic, mutating a `let`, missing interface methods, invalid
resource captures — is reported by `slangc` against the generated `.slang`
file, with Slang source locations. Structural e7s restrictions fail earlier,
with e7s diagnostics that carry the e7 source span.

### 10.3 Indexing and component access

* `v.x`, `v.y`, `v.z`, `v.w`, `v.r`, `v.g`, `v.b`, `v.a` and swizzles
  (`v.xyz`, `v.rgb`, ...) are emitted unchanged; Slang accepts 1–4 component
  swizzles.
* `m[i][j]` is row `i`, column `j`; the comma form `m[i, j]` is emitted as
  `m[i][j]`; `m[i]` reads a row vector.
* Constant-buffer/struct layout alignment is Slang's; e7s has no padding
  attribute. Order fields to avoid unexpected std140 padding (or declare
  explicit padding fields).

---

## 11. Worked example

This is the complete vertex shader from `transpiler/examples/triangle.vert.e7`
and the Slang it lowers to (generated by the current transpiler; the header
comment is omitted).

```e7s
# Triangle vertex stage (e7s).
Scene <- struct
    mvp: [f32; 4, 4]
    tint: [f32; 4]

Vertex <- struct
    @location(0) position: [f32; 3]
    @location(1) colour: [f32; 4]

Varying <- struct
    @builtin(position) clip_position: [f32; 4]
    @location(0) colour: [f32; 4]

@binding(0, 0)
scene: Scene

@vertex
vs_main <- (vertex: Vertex) -> Varying:
    clip := mul(scene.mvp, [vertex.position.x, vertex.position.y, vertex.position.z, 1.0])
    ret Varying{clip_position: clip, colour: vertex.colour * scene.tint}
```

```slang
module triangle_vert;

struct Scene {
    column_major float4x4 mvp;
    float4 tint;
};

struct Vertex {
    [[vk::location(0)]] float3 position;
    [[vk::location(1)]] float4 colour;
};

struct Varying {
    float4 clip_position : SV_Position;
    [[vk::location(0)]] float4 colour;
};

[[vk::binding(0, 0)]] ConstantBuffer<Scene> scene;

[shader("vertex")]
Varying vs_main(Vertex vertex) {
    var clip = mul(scene.mvp, float4(vertex.position.x, vertex.position.y, vertex.position.z, 1.0));
    return Varying(clip, (vertex.colour * scene.tint));
}
```

Note the module name: `triangle.vert.e7` has a dotted stem, so the module is
`sanitized` to `triangle_vert` and the default output file is
`triangle_vert.slang`.

---

## 12. Unsupported features and diagnostics

### 12.1 Diagnostic behavior

e7s has three kinds of failure:

1. **Parse errors** come from engine7's parser and report `line:column` plus a
   message (same diagnostics as the e7 compiler). The file is not transpiled.
2. **e7s restriction errors** are reported by the e7s restriction pass with
   the source span of the offending construct and a message naming the
   feature or rule, e.g. `async functions are not supported in e7s`,
   `resource 'x' needs @binding(binding, set) or @push_constant`. The file is
   not written; the transpiler exits non-zero. `e7s check` reports the same
   diagnostics without writing output.
3. **Slang errors** (types, overloads, intrinsics, bindings, interface
   conformance) are not e7s diagnostics: the generated `.slang` is valid e7s
   output but may still fail `slangc`. Run the generated files through
   `slangc` (or `transpiler/tools/check-slang.sh`) to see these.

In project mode a restriction error in any module aborts the project and no
module files are written.

### 12.2 Unsupported features

| Category | Rejected forms | Diagnostic |
| --- | --- | --- |
| ECS / engine | `table`, `trigger`, `plugin`, `sys` declarations; `select ... from`; `res`/`res &`/`res &mut` parameters; `@trigger`, `@plugin`, `@Components` attributes | unsupported item/parameter/attribute |
| Async & tasks | `async` functions/methods, `await`, `spawn`, `detach`, `cancel`, `disown` | unsupported feature: async/task |
| Error handling | `!T`, `E!T`, `ret !Error`, error literals `!Name` (`!nil` is supported and maps to `void`) | unsupported type/expression: error effects |
| Optionals | `?T`, postfix `?` | unsupported type/operator: optional |
| Memory | `*T` box, `*raw T`, unary `&`/`*`, `unsafe:` blocks, `raw`/`mut` keywords outside receivers | unsupported type/expression/statement |
| Collections & strings | `map[K, V]`, `str`, string literals, `[T]` dynamic arrays | unsupported type/literal |
| Functions | anonymous functions `(x: T) -> U: ...`, function types, function values | unsupported expression |
| Declarations | scoped visibility `pub(crate)`/`pub(self)`/`pub(in ...)`, `self`/`crate`/`super` paths, nested inline modules, `use` inside an inline module | unsupported declaration/import |
| Enums | payload variants (`Bar(i32)`, `Baz { ... }`), generic enums, `where` on enums | unsupported enum form |
| Traits | static trait methods (no `self` receiver), generic trait methods, `where` on trait methods, attributes on trait methods | unsupported trait form |
| Impls | receiver `this` not first or not `&Type`/`&mut Type`, receiver type mismatch, unsupported method attributes | invalid impl |
| Match | `match` as a value, guards (`Arm if cond:`), non-last wildcard | unsupported match form |
| Imports | aliases (`use foo as bar;`), `self`/`super` imports, missing module file, import cycles, module name `core` (file stems are sanitized instead), duplicate module names | unsupported import / module error |
| Attributes | `@binding` without a resource, `@push_constant` on a non-struct resource, `@binding`+`@push_constant` together, `@uniform`+`@push_constant`, `@uniform` on an explicit resource type, duplicate binding+set, `@location` duplicates/non-integer, `@builtin`+`@location` on one field, matrix layout attributes on non-matrix fields or both layout attributes on one field, unknown `@builtin` name, unknown attribute, misplaced attribute | invalid attribute |
| Types | `[f32; N]` with `N` outside 2..4, matrices with non-float elements or dimensions outside 2..4, `&T` outside receivers, struct casts, tuples | unsupported type |
| Expressions | bare list literal with no vector/matrix context, missing/extra/duplicate struct-literal fields, non-constant constant initializer that Slang rejects, `match` as value | invalid expression |
| Entry points | more than one stage attribute, entry scalar parameters, vertex output without `@builtin(position)`, compute entry not returning a unit type, `@compute` not three positive integers | invalid entry point |

`@resource` is accepted and erased; `@inline` is accepted on functions and
impl methods. Everything else in the e7 grammar that is not listed as
supported in this document is a diagnostic rather than being silently
dropped.

---

## 13. Examples and validation

All examples live in `transpiler/examples/`.

| File | Feature cluster | Module / entries |
| --- | --- | --- |
| `triangle.vert.e7` | vertex stage, `ConstantBuffer`, `@location` attributes, `@builtin(position)`, varyings, matrix product | `triangle_vert`; `vs_main` (vertex) |
| `triangle.frag.e7` | fragment stage, matching interface struct, struct output, swizzles | `triangle_frag`; `fs_main` (fragment) |
| `compute.e7` | compute stage, `RWStructuredBuffer`, `[numthreads]` from `@compute`, dispatch builtin, `if`/`ret` | `compute`; `cs_update` (compute) |
| `generics_traits.e7` | traits/interfaces, supertrait, `[mutating]`, `impl`/extension, `@inline`, generic struct/function/impl with `where` | `generics_traits` (library unit) |
| `resources.e7` | `@uniform`, `@push_constant`, `@resource`, `Texture2D`/`SamplerState`/`StructuredBuffer`, `@flat`, `@binding` | `resources`; `vs_main`, `fs_main` |
| `combined_sampler.e7` | combined image samplers (`Sampler2D`/`SamplerCube`, one `COMBINED_IMAGE_SAMPLER` descriptor each), default element type | `combined_sampler`; `fs_main` (fragment) |
| `consts.e7` | top-level constants, inline `mod`→`namespace`, `enum class`, scalar/vector math, casts | `consts`; `fs_main` (fragment) |
| `matrices.e7` | regular `[f32; R, C]` matrix fields, default `column_major` layout, `@row_major` override, matrix-vector `*` → `mul`, row/column indexing | `matrices`; `vs_main` (vertex) |
| `modules/main.e7` | external `mod math`, `use math::*`, imported helpers, two stages in one root | `main`; `vs_main`, `fs_main` |
| `modules/math.e7` | `pub` module items, exported struct/constants/functions, `@inline` | `math` (module) |

Expected artifacts: every `.e7` file produces a sibling `.slang` file;
project mode names files after their module (`modules/main.e7` +
`modules/math.e7` → `main.slang` + `math.slang`). External modules are
libraries (no entries); root files carry the example entry points.

Run the examples end-to-end:

```sh
./transpiler/zig-out/bin/e7s transpile transpiler/examples/triangle.vert.e7 -o /tmp/e7s/tv.slang
./transpiler/zig-out/bin/e7s check transpiler/examples/triangle.vert.e7
./transpiler/zig-out/bin/e7s transpile transpiler/examples/modules/main.e7 -o /tmp/e7s/modules
transpiler/tools/check-slang.sh -I /tmp/e7s/modules /tmp/e7s/modules
```

The generated Slang for every example in this directory compiles to SPIR-V
with slangc 2026.20 (target `spirv`, profile `spirv_1_5`); the two library
modules (`generics_traits`, `math`) pass the Slang front end.
