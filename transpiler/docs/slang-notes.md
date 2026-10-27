# Slang syntax notes — e7s lowering target, verified against slangc 2026.20

Status: **verified empirically** on 2026-10-25 with the real compiler checked into
this repo (not from memory/docs):

```
$ .tooling/slang/bin/slangc -v
2026.20
```

Everything below was compiled with:

```
slangc -target spirv -profile spirv_1_5 -entry <name> -stage <stage> -o <out>.spv <file.slang>
```

`-profile spirv_1_5` is accepted (so are `spirv_1_3` … `spirv_1_6`). Every entry
below that is marked PASS also produced a SPIR-V module accepted by
`spirv-val` (SPIRV-Tools v2026.4), when checked.

Re-runnable probe sources: [`tools/slang-probes/`](../tools/slang-probes/).
Harness: [`tools/check-slang.sh`](../tools/check-slang.sh). Reproduce:

```sh
transpiler/tools/check-slang.sh --spirv-val transpiler/tools/slang-probes
```

When this document says "planned output shape", it means the lowering described
by the e7s task: modules named `<module>.slang`, `public` declarations,
`extension` blocks for `impl`, `ConstantBuffer<T>` resources, etc.

**Read §11 first if you only care about what must change in the lowering.**

---

## 1. Validation harness (`tools/check-slang.sh`)

POSIX `sh`; no bashisms. It discovers entries from `[shader("...")]` attributes
(handles attributes/signatures on one line or spread over several lines) and
compiles every entry to a temporary `.spv`, printing one PASS/FAIL line per
entry. Files with no entries (modules/libraries) are front-end checked with
`slangc -target none` (semantic analysis runs; errors are caught) instead.

```sh
# whole generated output tree, modules resolved via every directory in args:
transpiler/tools/check-slang.sh out/slang/

# files + explicit module dirs:
transpiler/tools/check-slang.sh --module-dir out/slang/math shaders/*.slang

# also validate the SPIR-V with spirv-val:
transpiler/tools/check-slang.sh --spirv-val my_project/
```

Options: `--slangc PATH` (default `$SLANGC`, then
`<repo>/.tooling/slang/bin/slangc`, then `slangc` on PATH), `--module-dir DIR` /
`-I DIR` (import search path; every directory argument and every file's parent
directory is added automatically), `--keep` (keep `.spv`s and print the temp
dir), `--spirv-val`, `-v`. Exit codes: `0` all pass, `1` any failure
(per-entry list printed), `2` usage/config (no slangc, no inputs).

Notes/limits:
* `-entry astage` is always passed explicitly, one compile per entry, so one
  broken entry does not hide the others.
* `slangc` **does** auto-detect `[shader]` entries when no `-entry` is given, and
  compiles *all* entries of the file into a single multi-`OpEntryPoint` SPIR-V
  module (verified). The harness still uses explicit `-entry` for per-entry
  granularity.
* A selected entry point must live in the file passed to `slangc`; entries in
  *imported* modules cannot be selected from the importing root file
  (`error[E38000]: no function found matching entry point name`). See §2.7.
* The harness does not cross-check vertex→fragment interface matching (slangc
  does not either when entries are compiled one at a time; `spirv-val` does not
  check cross-stage links either). Match struct fields manually / in the
  transpiler.

---

## 2. Modules

### 2.1 `import name;` resolves the *file* `name.slang`

`import foo;` looks for `foo.slang` on the import search path (`-I`, defaults to
the importing file's directory). A missing file is a hard error:

```
error[E00001]: cannot open file 'math.slang'
 --> m3/useby.slang:1:22
```

So **generated module files must be named `<module>.slang` for `import <module>;`
to work**. The *declared* module name is a separate matter (§2.2).

### 2.2 `module <name>;` is optional, and its name need not match the filename

All of these compile in 2026.20:

* an imported file with `module foo;` and filename `foo.slang` (recommended);
* an imported file whose `module` name differs from the filename
  (`wrongname.slang` containing `module math;`, imported as `import wrongname;`)
  — no error, no warning, public symbols still visible;
* an imported file with **no** `module` declaration at all;
* two different files both declaring `module dup;` and both imported under
  their own filenames.

The top-level filename is what `import` resolves, so emit `module <name>;` with
the matching filename anyway (portable, self-documenting, and required by older
Slang releases/serialized-module workflows); do not rely on the tolerance.

### 2.3 A root translation unit may declare `module main;` and contain entries

Verified: a file with `module main; import math;` plus `[shader("fragment")]`
entries compiles to SPIR-V normally. A root file with *no* module declaration
also works (both were used throughout the probes). Entry points do **not** need
to be `public` in a module (both `-entry` and attribute auto-detection work).

### 2.4 Visibility: `public` is required for cross-module use

Inside a module, declarations default to *internal*. Using a non-`public`
function from another module:

```
error[E30600]: declaration not accessible
--> m2/use1.slang:3:75
 | float4 f() : SV_Target { return float4(helper(1.0) + defaultVis(2.0)); }
 |                                              ^^^^^^^^^^ 'defaultVis' is not accessible from the current context.
```

Rules verified:
* `public struct S { public float x; ... }` — type **and** its fields that are
  used across modules must be public.
* `public float f()` — functions used across modules must be public.
* `public static const float PI = …;` at module scope is visible cross-module
  (verified).
* Interface members: an explicit `public` on an interface method is allowed
  when the interface is public, but **not** when the interface is internal
  (`error[E30601]: visibility higher than parent`). Members of a `public
  interface` are usable cross-module even without an explicit `public`
  modifier on the method. Safest lowering: emit `public` on members only when
  the trait itself is public — or simply omit the modifier on interface
  method requirements (verified to work cross-module).
* Extensions are *not* exported by default: see §5.6.

### 2.5 `core` is a built-in module name — reject it

```slang
module core;
public float corefun() { return 42.0; }
```

compiled as `core.slang`; but another file with `import core;` and a call to
`corefun()` fails with `error[E30015]: undefined identifier 'corefun'` — the
import resolved to the **built-in** `core` module, silently shadowing the local
file. Other names tested (`slang`, `gfx`, `std`, `mathlib`) are **not** reserved
and work as user modules. The transpiler must reject/diagnose a module named
`core`.

### 2.6 Imports are unqualified; `math::helper` is invalid; no transitive imports

After `import math;`, use symbols unqualified. Module-qualified access fails:

```
error[E30600]: declaration not accessible
 | float e = math::helper(1.0);
 |           ^^^^ 'math' is not accessible from the current context.
```

There is no transitive import. If module `a` imports `b`, a file importing only
`a` cannot see `b`'s symbols (`'dep' is not accessible from the current
context.`). The lowering must flatten/resolve e7s `use`/qualified names:
* `foo::bar(...)` in e7s source → `bar(...)` in Slang;
* every module whose public items are used must be imported explicitly by the
  file that uses them (e7s `use foo;` → Slang `import foo;` is enough for
  unqualified references, but a *transitive* user of `bar` must not rely on
  `foo` importing it).

Two imports exporting the same name produced:

```
error[E39999]: ambiguous call to 'helper' with arguments of type (float)
```

so cross-module name collisions need a policy (per-file renaming is out of scope
for Slang modules — collisions only matter when both modules are imported into
one translation unit).

### 2.7 Entries and imported modules

* An entry point must be present in the file being compiled. `-entry modfs` on a
  root that only `import`s the module defining `modfs` fails with
  `error[E38000]: no function found matching entry point name 'modfs'`, and
  auto-detection on the root fails with
  `error[E57004]: SPIR-V output contains no exported symbols` (no entry).
* Compiling the *module file* that contains the entry directly (with its own
  imports resolved by `-I`) works. All probe stage entries therefore live in
  their own translation unit, which matches the planned one-`.slang`-per-stage
  output.

Consequence for the harness: search for `[shader]` attributes only in the file
being compiled; never treat an imported entry as belonging to the root.

---

## 3. Generic constraints and `where` clauses

### 3.1 Direct constraints on generic parameters: exactly one bound per parameter

```slang
struct Pair<T : IShape> { T first; T second; }         // PASS
float f<T : IShape>(T x) { return x.area(); }           // PASS
```

`+` is **not** accepted:

```
error[E20001]: unexpected token
 | struct S3<T : IA + IB> { T x; }
 |                  ^ unexpected '+', expected '>'
```

### 3.2 Structs **do** accept `where` clauses (and enforce them)

This contradicts a provisional assumption in the task brief. Verified:

```slang
interface IThing { float value(); }
struct S2<T> where T : IThing                 // PASS (compiles)
{
    T x;
    float f() { return x.value(); }
}
```

It is enforced — instantiating `S2<float>` gives:

```
error[E38029]: type argument doesn't conform to the interface
 | S2<float> s = S2<float>(1.0);
 | ^^ type argument 'float' does not conform to the required interface 'IThing'
```

`struct S<T : IThing> where T : IThing` (both forms) also compiles. Multiple
bounds for one parameter use a comma list *inside one where clause*:

```slang
struct S<T> where T : IA, IB { T x; }        // PASS, both bounds enforced
```

Caution: in direct-parameter position `struct S<T : IA, IB>` is parsed as **two**
generic parameters (`T : IA` and a second unconstrained `IB`), not two bounds
for `T`: `generic 'Pair2' expects 2 generic argument(s) but 1 were provided`.

### 3.3 Function `where` clauses: one predicate per `where`, comma = bounds of one parameter

This is the other place where the provisional plan is wrong. In slangc 2026.20,
**comma-separated predicates for different parameters are a parse error**:

```slang
float f<T, U>(T x, U y) where T : IA, U : IB    // INVALID
```
```
error[E20001]: unexpected token
 | float f2<T, U>(T x, U y) where T : IA, U : IB { ... }
 |                                          ^ unexpected ':', expected '{'
```

Valid forms (all verified, bounds enforced):

```slang
float g<T>(T x) where T : IA, IB                          // comma = bounds of T
float h<T, U>(T x, U y) where T : IA where U : IB         // repeated `where`
float k<T : IA, U : IB>(T x, U y) { ... }                 // direct bounds
float m<T : IA>(T x) where T : IB { ... }                 // direct + where
```

`where T : IA, IB` really means two bounds for `T` (`g(OnlyA())` fails with
`type argument 'OnlyA' does not conform to the required interface 'IB'`).
Repeating `where` really enforces both (second parameter violating IB fails).

**Lowering rule:** for a generic function with several constrained parameters,
either emit direct bounds `<T : IA, U : IB>` or repeat the keyword
`where T : IA where U : IB`. Never emit `where T : IA, U : IB`.

Explicit specialization `f<Impl>(x)` is valid.

### 3.4 Generic struct + generic extension combination

```slang
struct Pair<T> where T : IShape { T first; T second; }
extension<T> Pair<T> where T : IShape { float combined_area() { ... } }   // PASS
extension<T : IShape> Pair<T> { ... }                                     // PASS
```

Both extension spellings work; they also work cross-module when declared
`public extension` with `public` members (verified in `slang-probes/traits.slang`
+ `use_traits.slang`).

---

## 4. Interfaces (e7s `trait`)

All verified in `slang-probes/traits.slang`:

```slang
interface IShape
{
    float area();
    float circumference();
}

interface IShaded : IShape                       // supertrait/inheritance: PASS
{
    float3 albedo();
    [mutating] void shade(float amount);         // mutating requirement: PASS
}

interface IBox<TValue> { TValue get(); }         // generic interface: PASS
```

* Implementation is an `extension` (§5). `[mutating]` must appear on both the
  interface requirement and the implementing method.
* Interface-typed variables work (`IShaded shaded = circle;`,
  `IBox<float> box = FloatBox(2.0);`), including calling methods and passing
  through local variables (existential types).
* Interface-typed struct fields also compile, but are not needed by e7s.
* Interface member visibility: see §2.4.

---

## 5. Extensions (e7s `impl`)

### 5.1 Trait implementation and implicit `this`

```slang
extension Circle : IShape
{
    float area() { return PI * this.radius * this.radius; }
}
```

* The receiver parameter is implicit — do **not** emit `this: &Circle`.
* Field access can be unqualified (`radius`) or explicit (`this.radius`); both
  compile, and `this.field` works in plain and `[mutating]` methods. This means
  e7s method bodies that spell out `this.radius` can be emitted almost verbatim.
* Multiple traits on one type: one `extension Type : TraitN` per trait (verified
  `IShape` and `IShaded` on the same `Circle`).

### 5.2 `[mutating]` methods

```slang
extension Circle : IShaded
{
    [mutating] public void shade(float amount) { this.colour = this.colour * amount; }
}
```

Both modifier orders parse in a public extension:
`[mutating] public void f()` and `public [mutating] void f()`. `[mutating]`
methods can only be called on mutable l-values (a `var`, a buffer element, an
interface-typed `var`).

### 5.3 Inherent extensions, generic extensions, static methods

```slang
extension Circle { public static Circle unit() { return Circle(1.0, float3(...)); } }  // PASS
extension<T> Box<T> { float getInner() { ... } }                                     // PASS
extension<T : IThing> Box<T> { float getVal() { return inner.value(); } }             // PASS
extension<T> Pair<T> where T : IThing { ... }                                        // PASS
```

Static extension methods are called `Circle::unit()` (`Type::static()`), and
this works cross-module when the extension and member are public (verified).
Both `public static` and `static public` orders compile.

### 5.4 Visibility inside extensions — **important**

Inside an extension, members default to internal. A `public` member is only
allowed if the **whole extension** is public:

```slang
extension Vec2 { public float length2() { ... } }         // INVALID
```
```
error[E30601]: visibility higher than parent
 | extension Vec2 { public float length2() { x*x + y*y; } }
 |                               ^^^^^^^ 'length2' cannot have a higher visibility than 'extension'.
```

Cross-module use therefore needs **both**:

```slang
public extension Vec2 : IShape
{
    public float area() { ... }
    [mutating] public void shade(float a) { ... }
}
```

This was verified end-to-end (`traits.slang` module imported by
`use_traits.slang`: interface variable, mutating call, generic extension method,
static factory all work). If the `impl` is only used in the same module/file,
plain `extension Type` with unmarked members is enough.

Note: `public extension` on an internal (non-`pub`) type compiled; but a public
*interface method* on an internal interface is rejected (§2.4). Mirror the
e7s visibility of the type/trait when choosing `public extension`.

### 5.5 What is not needed / not valid

* No receiver parameter, no `self`, no explicit `impl` keyword.
* `extension public Type` is a parse error (`modifier 'public' is not allowed
  here`); `public` goes **before** `extension`.
* Trait impls are not `struct` inheritance: write `extension Type : Trait`.

---

## 6. Resources, bindings, constants, enums

### 6.1 Resource declarations (all PASS, produce correct Vulkan decorations)

```slang
struct Scene { float4x4 mvp; float4 tint; };
struct Push  { float4x4 mvp; float alpha; };
struct Particle { float3 position; float3 velocity; };

[[vk::binding(0, 0)]] ConstantBuffer<Scene> scene;
[[vk::push_constant]] ConstantBuffer<Push> push;
[[vk::binding(1, 0)]] Texture2D<float4> albedo;
[[vk::binding(2, 0)]] SamplerState albedo_sampler;
[[vk::binding(3, 0)]] StructuredBuffer<Particle> particles;
[[vk::binding(4, 0)]] RWStructuredBuffer<Particle> particles_out;
```

Verified usage:
* `scene.mvp`, `push.alpha` — field access on the constant buffer;
* `albedo.Sample(albedo_sampler, uv)` — returns `float4` for `Texture2D<float4>`;
* `particles[i]`, `particles_out[i] = p`, and nested writes
  `particles_out[i].velocity = …` (the e7s compute example shape) — all PASS;
* SPIR-V gets `Binding`/`DescriptorSet` decorations from
  `[[vk::binding(binding, set)]]`, argument order = (binding, set) — matches
  e7s `@binding(binding, set)`;
* `[[vk::push_constant]] ConstantBuffer<T>` becomes an `OpVariable … PushConstant`;
  no binding decoration.

Attribute placement is before the declaration: `[[vk::binding(0, 0)]] T name;`.
`@uniform` needs no special Slang syntax: the default `ConstantBuffer<T>`
lowering is exactly what `uniform` would mean (a plain `uniform Scene scene;`
with `[[vk::binding]]` also parses, but is not needed).

### 6.1.1 Combined image samplers (PASS; one descriptor, verified)

Slang's legacy `Sampler1D`/`Sampler2D`/`Sampler3D`/... types are **combined**
texture-samplers. Declaring one resource produces a single
`OpTypeSampledImage` variable, which is exactly one Vulkan
`VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER` descriptor:

```slang
[[vk::binding(0, 0)]] Sampler2D<float4> tex;   // one combined descriptor
[shader("fragment")]
float4 fs_main(float2 uv : TEXCOORD0) : SV_Target {
    return tex.Sample(uv);                      // no separate sampler argument
}
```

Verified with slangc 2026.20 (`-target spirv -profile spirv_1_3`):

* SPIR-V declares `OpTypeImage` + `OpTypeSampledImage` plus one
  `OpVariable … UniformConstant` carrying `Binding 0` / `DescriptorSet 0`;
  there is no separate `OpTypeSampler` variable;
* `Sampler2D` without a type argument defaults to `float4`
  (`Sampler2D<float4>`);
* `Sampler1D`, `Sampler1DArray`, `Sampler2D`, `Sampler2DArray`, `Sampler3D`,
  `SamplerCube` and `SamplerCubeArray` all compile with the matching
  `Sample(coords)` arity and produce a combined descriptor;
* `spirv-val` accepts the output (also inside the engine's textured/UI/lit
  fragment stages once converted to e7s).

Slang's `[[vk::combinedImageSampler]]` attribute — the alternative spelling
for pairing a `Texture2D` with a `SamplerState` on one binding — is **not**
recognised by this toolchain:

```
warning[E31000]: unknown attribute
 | [[vk::combinedImageSampler]]
 |   ^^^^^^^^^^^^^^^^^^^^ unknown attribute 'vk_combinedImageSampler'
```

So the combined `Sampler*` types are the supported construct; e7s passes them
through as resource types and emits no extra attribute.

### 6.2 Do **not** emit a bare struct global even though it parses

`[[vk::binding(0,0)]] Scene scene;` (without `ConstantBuffer<>`) compiles and
even gets auto-wrapped into a `GlobalParams_std140` block — but with *multiple*
such globals, only one merged `globalParams` block appears with the first
binding/set; the other `[[vk::binding(b,s)]]` decorations are **silently
dropped** (verified with two globals: SPIR-V had a single `Binding 0 /
DescriptorSet 0` block). Same story for a bare struct marked
`[[vk::push_constant]]` (works for one, but the explicit `ConstantBuffer<T>`
wrapper is the predictable form). **Always emit `ConstantBuffer<T>`.**

### 6.3 `static const` globals

```slang
static const float PI = 3.14159265;                  // PASS
static const float TAU = PI * 2.0;                   // PASS (derived)
static const float3 WHITE = float3(1.0, 1.0, 1.0);    // PASS
static const float4x4 IDENT = float4x4(1.0, 0.0, …);  // PASS (16 scalars)
static const uint MAX_LIGHTS = 8u;                    // PASS
```

The initializer is mandatory:

```
error[E31225]: missing initializer for static const
 | static const float PI;
 |                    ^^ static const variable 'PI' must have an initializer
```

At module scope, `public static const float PI = …;` is visible cross-module
(PASS). A `static const` struct global (`static const S CS = S(1.0);`) also
compiles.

### 6.4 Enums

```slang
enum Color : uint { Red, Green, Blue }     // PASS
enum Plain { A, B }                        // PASS (no base type)
enum Mode : int { Off = 0, On = 5, Auto = -1 }   // explicit/negative values PASS
```

* Access is `Color::Green`.
* Enum-typed struct fields work (`struct Mat { Color color; … }`).
* Comparison works (`tone == Tone::Gamma`), so e7s enum equality lowers
  directly (`if/else if/else` verified).
* Cast to the underlying type with `float(mode)` / `int(mode)`.

---

## 7. Entry points and stage interfaces

All verified in `slang-probes/entries.slang` (plus triangle probes), including
SPIR-V `Location`/`BuiltIn`/`Flat` decorations via `spirv-dis` and `spirv-val`.

### 7.1 Attributes

```slang
[shader("vertex")]   Varying vs_main(VertexIn input) { … }
[shader("fragment")] FragOutput fs_main(FragInput input) { … }
[shader("compute")] [numthreads(64, 1, 1)] void cs_main(DispatchId id) { … }
```

* Stage names `"vertex"`, `"fragment"`, `"compute"` accepted.
* `[numthreads(x, y, z)]` may appear before or after `[shader("compute")]` —
  both compile. (slangc even accepts a compute entry *without* `[numthreads]`,
  but e7s `@compute(x,y,z)` should emit it.)
* Multiple entries per file are fine.
* Entry point visibility: not required to be `public`, in a root file or a
  module file.

### 7.2 Struct parameters and returns

```slang
struct VertexIn { [[vk::location(0)]] float3 position; [[vk::location(1)]] float3 normal; };
struct Varying  { float4 clip_position : SV_Position; [[vk::location(0)]] float3 normal;
                  [[vk::location(1)]] nointerpolation uint instance_id; };
struct FragInput{ float4 frag_coord : SV_Position; [[vk::location(0)]] float3 normal;
                  [[vk::location(1)]] nointerpolation uint instance_id; };
struct FragOutput { [[vk::location(0)]] float4 colour; };
```

Verified:
* **Vertex input struct with only `[[vk::location(n)]]` fields works** — no
  extra semantic needed (`OpDecorate … Location 0/1`); position output uses the
  `SV_Position` field of the returned struct.
* Vertex return struct: `float4 clip : SV_Position` gives
  `OpDecorate … BuiltIn Position`; `[[vk::location(n)]]` payload fields get
  `Location n`.
* Fragment **output struct** with `[[vk::location(0)]] float4 colour;` works
  without `SV_Target` (`Output Location 0`). `: SV_Target` on the field, or
  `: SV_Target` / `: SV_Target0` on a scalar/vector return type, also work
  (`float4 fs(float4 pos : SV_Position) : SV_Target0` PASS, including with
  `[[vk::location(0)]]` + `SV_Target` + `SV_Depth` mixed in an output struct).
* Fragment **input struct**: `SV_Position` builtin field + `[[vk::location]]`
  varyings work; a fragment entry may take the same struct type the vertex stage
  returns, or a separately-declared struct with matching fields (both verified).
  e7s re-declares stage structs per file — that is fine.
* Compute: struct parameter with `uint3 tid : SV_DispatchThreadID;` field works;
  `void cs(uint3 tid : SV_DispatchThreadID)` also works.
* `: SV_VertexID`, `: SV_Position`, etc. are accepted on the entry's direct
  parameters.

### 7.3 `@flat` → `nointerpolation` (the one real trap)

* `nointerpolation` on a struct field produces `OpDecorate … Flat` on the
  fragment input (verified). Use it on the field in the fragment *input*
  struct; putting it on the vertex output field is tolerated too.
* `[flat]` as an attribute is **accepted but silently ignored** — no `Flat`
  decoration is emitted (checked with `spirv-dis`). Emitting `[flat]` would
  produce shaders that compile but behave wrongly (and integer varyings may fail
  Vulkan validation).
* Verified correct form: `[[vk::location(1)]] nointerpolation uint instance_id;`
  also works with `nointerpolation float3 n : TEXCOORD0;`.

---

## 8. Expressions, statements, literals

All verified in `slang-probes/expressions.slang` etc.

| Form | Verdict |
|---|---|
| `var a = 1.0;` / `var x: float = 1.0;` | PASS |
| `let b = 2.0;` / `let y: float = 2.0;` | PASS |
| assigning to a `let` | `error[E30011]: left of '=' is not an l-value` |
| `S(a, b)` positional struct constructor | PASS (declaration order) |
| `S s = {1.0, 2.0};` brace init in declaration | PASS (partial lists zero-fill; too many → `error[E30523]: too many initializers`) |
| `take({1.0, 2.0})` brace init in expression position | **PASS** (so "C-style lists only in declarations" is not true in 2026.20; still prefer `S(a, b)` for deterministic order) |
| `S{.x = 1.0, .y = 2.0}` designated init | **INVALID** — `error[E20001]: unexpected token … unexpected '{', expected ';'` |
| `float3(a, b, c)`, `float3(v2, z)`, `float3(1.0)` (splat), `float2(1.0, 2.0)` | PASS |
| `float2x2(1.0, 2.0, 3.0, 4.0)` row-major | PASS — m[0]=(1,2), m[1]=(3,4) (SPIR-V `OpConstantComposite` + `mul(m, float2(10,20))` = (50,110), i.e. row·vector) |
| `float2x2(float2(1,2), float2(3,4))`, `float4x4(1.0)` diagonal | PASS |
| casts `int(f)`, `uint(f)`, `bool(1)`, `float(i)`, `double(f)`, `float3(v)` | PASS (constructor casts) |
| scalar `cond ? a : b` | PASS, no warning |
| vector-condition `?:` | PASS but `warning[E30056]: non-short-circuiting '?:' operator is deprecated, use 'select' instead` |
| `select(condition, ifTrue, ifFalse)` | PASS — **condition is the FIRST argument**; verify semantics: `static_assert(select(true, 2.0, 1.0) == 2.0)` PASS; wrong argument order still compiles (with implicit-conversion warnings) but is wrong |
| boolean xor | `a ^ b` PASS; `a != b` PASS; `a ^^ b` **parse error** (`syntax error`) — Slang has no `^^` |
| `!`, `&&`, `\|\|` | PASS |
| swizzles `v.xyz`, `v.rgb`, `v.zyx`, lvalue `v.xy = v.yx`, `v.x *= 2.0` | PASS |
| matrix indexing `m[i][j]`, row vector `m[0]` | PASS (row-major logical indexing) |
| `matrix * vector`, `vector * matrix` | **INVALID** — `error[E39999]: no overload for '*'`; emit `mul(matrix, vector)` |
| `matrix * matrix` | PASS but componentwise (not matrix product); use `mul(m, n)` for the product |
| vector `*` vector / vector `*` scalar | PASS (componentwise) |
| `in` / `inout` / `out` parameters | PASS (`void f(in float x, inout float y, out float z)`) |
| `for`, `while`, `if/else`, `break`, `continue`, `return;`, `++`, `+=` | PASS |
| `nil` → `void` and `return;` | PASS (`void f() { return; }`) |
| float literals `1.0`, `1.0f`, `1e-3`, `2.5e2`, `2u`, `-3` | PASS |
| `bool2` comparisons + `any()` / `all()` | PASS |
| uint bit ops `& \| ^ << >> / % ~` | PASS |
| `static_assert(cond, "msg")` | PASS in function scope only; global-scope `static_assert` does not parse; condition must be compile-time constant |

Intrinsics used by the e7s examples (`normalize`, `dot`, `length`, `max`,
`clamp`, `pow`, `floor`, `sin`, `sqrt`, `min`, `mul`) all PASS.

---

### 8.1 Matrix layout — verified decorations

Matrix memory layout is or can be decided with field modifiers, and the
*field* modifier wins over the `-matrix-layout-*` command-line mode:

```slang
struct M {
    column_major float4x4 model;
    row_major    float4x4 other;
};
[[vk::binding(0, 0)]] ConstantBuffer<M> cb;
```

Compiled with `-target spirv -profile spirv_1_3`, the emitted decorations are:

| Source spelling | SPIR-V member decoration |
| --- | --- |
| `column_major float4x4` | `RowMajor` + `MatrixStride 16` |
| `row_major float4x4` | `ColMajor` + `MatrixStride 16` |
| no modifier (slangc default) | `RowMajor` + `MatrixStride 16` |

The decoration token is **inverted** relative to the source spelling because
Slang's matrix convention is transposed relative to SPIR-V's (Slang documents
this: a source-level *row-major* layout emits `ColMajor`, source-level
*column-major* emits `RowMajor`). To keep a `ConstantBuffer<T>` matrix field
unambiguous and independent of compiler defaults, e7s emits an explicit
`column_major` on every matrix struct field (or `row_major` with
`@row_major`). The source-level column-major layout is what a column-major host
matrix (`Mat4[col][row]`, 4 contiguous columns) uploads directly; the SPIR-V
`RowMajor` token must not be read as host row-major bytes.

Matrix values remain logically row-major (literals fill rows first;
`m[i][j]` is row/column), and `mul(m, v)` is row·column = mathematical
`M * v`. Changing the storage modifier does not change those value semantics.

### 8.2 `SV_VertexID` / `SV_InstanceID` pull in `DrawParameters`

Slang rebases `SV_VertexID` to `gl_VertexIndex - gl_BaseVertex` (HLSL's
zero-based ID semantics), so a vertex shader that uses it declares the SPIR-V
`DrawParameters` capability, even when the source only needs the Vulkan
`VertexIndex` builtin:

```slang
struct In { uint index : SV_VertexID; };
[shader("vertex")]
float4 main(In input) : SV_Position { ... }
```

Compiled with `-profile spirv_1_3`, the SPIR-V contains
`OpCapability DrawParameters`, `BuiltIn VertexIndex`, `BuiltIn BaseVertex`, and
an `OpISub`; `spirv-val --target-env vulkan1.1` accepts it (Vulkan 1.1's
`shaderDrawParameters` feature), but the device must enable that feature for
strict validation (`engine/platform/vulkan.e7` enables it). With `-profile spirv_1_0` the same shader is rejected
without the `SPV_KHR_shader_draw_parameters` extension. Prefer SPIR-V 1.3 for
Vulkan 1.1 targets, or avoid `SV_VertexID` when the host cannot enable the
feature. `engine/platform/shaders/triangle.vert.e7` documents this case.

## 9. Type mapping (verified spellings)

| e7s | Slang |
|---|---|
| `f32`, `f64`, `i32`, `u32`, `bool` | `float`, `double`, `int`, `uint`, `bool` |
| `[f32; 2/3/4]` | `float2/float3/float4` |
| `[f32; R, C]` | `floatRxC` (e.g. `[f32; 4, 4]` → `float4x4`), row-major |
| `-> nil` | `void` |
| `@location(n)` | `[[vk::location(n)]]` |
| `@builtin(position)` | `: SV_Position` (field) |
| `@builtin(vertex_index)` | `: SV_VertexID` |
| `@builtin(dispatch_thread_id)` | `: SV_DispatchThreadID` |
| `@flat` | `nointerpolation` (NOT `[flat]`) |
| `@binding(b, s)` | `[[vk::binding(b, s)]]` before the declaration |
| `@push_constant` | `[[vk::push_constant]] ConstantBuffer<T>` |
| `@uniform` / plain struct resource | `ConstantBuffer<T>` (no extra keyword) |
| `@vertex/@fragment/@compute(x,y,z)` | `[shader("vertex"/"fragment"/"compute")]` (+ `[numthreads(x,y,z)]`) |
| top-level `NAME: T := expr` | `static const T NAME = expr;` (module-scope `public static const` if `pub`) |
| `mod foo { … }` | `namespace foo { … }`; qualified `foo::name` valid |
| external `mod foo` + `use foo::*;` | file `foo.slang` (`module foo;`) + `import foo;` — symbols **unqualified** |
| enum | `enum E { … }` / `enum E : uint { … }`; members `E::Member` |
| struct literal `T{ field: expr, … }` | reorder to declaration order and emit `T(expr, …)` |
| `as [f32; N]` | `floatN(expr)` |

---

## 10. Attribute/declaration order that compiles

* `[[vk::binding(0, 0)]] ConstantBuffer<T> name;` — attribute(s) first.
* `[shader("vertex")] Varying vs(VertexIn v)` — attribute(s) first.
* `[shader("compute")] [numthreads(8, 8, 1)] void cs(…)` and
  `[numthreads(8, 8, 1)] [shader("compute")] void cs(…)` — both.
* `public extension Type : Trait { [mutating] public void m() { … } }` and
  `public [mutating]` — both parse.
* `public static Circle unit()` / `static public Circle unit()` — both parse.
* `public struct S { public float x; }`, `public interface I { … }`,
  `public static const float PI = …;`.
* Module declarations go first: `module foo;` then `import bar;`.

---

## 11. Corrections / constraints for the e7s lowering

These invalidate or refine the provisional output shape. Ordered by impact:

1. **`@flat` must emit `nointerpolation`, never `[flat]`.** `[flat]` compiles
   but is ignored (no `Flat` decoration). e7s varying fields marked `@flat`
   should get `nointerpolation` in the fragment-input struct (and it is harmless
   to repeat it in the vertex-output struct). Integer varyings need it.
2. **Struct `where` clauses are legal** (`struct Pair<T> where T : IShape`), and
   generic extensions can use `extension<T> Pair<T> where T : IShape` — the e7s
   `Pair<T> <- struct where T: IShape` and
   `impl<T> Pair<T> where T: IShape` forms lower directly. No need to rewrite
   struct bounds into direct `<T : IShape>` form (though that also works).
3. **Function `where` clauses need one predicate per `where` keyword.**
   `where T : IA, U : IB` is a parse error. Emit
   `where T : IA where U : IB`, or direct bounds `<T : IA, U : IB>`. Comma
   lists are only for multiple bounds of the *same* parameter
   (`where T : IA, IB`).
4. **`+` bounds are invalid.** One bound per generic parameter.
5. **Cross-module `impl`/`extension` needs `public extension` + `public` members.**
   Plain `extension` members are internal; `public` inside a non-public
   extension is `error[E30601]`. For impls only used within their own file, plain
   `extension` is fine.
6. **No qualified module access.** e7s `math::foo(...)` must lower to
   `foo(...)` (after `import math;`). Every used module must be imported in the
   file that references it (no transitive imports). Duplicate public names
   across imports are ambiguous.
7. **`core` cannot be a user module name** — `import core;` resolves the builtin
   module and silently hides the local file. Reject/diagnose in the transpiler.
8. **Designated initializers are invalid.** e7s `ret Varying{clip_position: c,
   colour: v}` must be reordered to declaration order and emitted as
   `Varying(c, v)`. Brace lists (`Varying{c, v}` / `{1.0, 2.0}`) do compile,
   but positional constructors are unambiguous.
9. **Matrix/vector products:** `m * v` and `v * m` do not compile in Slang.
   e7s `*` on a matrix operand must lower to `mul(m, v)` (and `mul(m, n)` for
   matrix products). `m * n` compiles but is componentwise — not a substitute.
10. **Matrix constructors are row-major logical.** `float4x4(a,b,c,d, …)` fills
    rows: `m[0] = (a,b,c,d)`; `mul` multiplies row·vector. e7s emits explicit
    `column_major` / `row_major` field modifiers so `ConstantBuffer` layout is
    deterministic; see §8.1 (source `column_major` emits SPIR-V `RowMajor`).
11. **Plain struct globals with bindings are a trap** (bindings can be silently
    merged/dropped when there are several). Always emit
    `ConstantBuffer<T>` for `@uniform`/plain struct resources, and
    `[[vk::push_constant]] ConstantBuffer<T>` for push constants.
12. **`static const` needs an initializer**; enum fields compare with `==` and
    are cast with `T(enumValue)`.
13. **Entries must stay in the file that owns the `[shader]` attribute**;
    `-entry`/auto-detection does not see entries in imported modules. One
    `.slang` per stage works; multi-entry files work too.
14. **Interface member visibility must not exceed the interface's**: don't emit
    `public` on methods of a non-`pub` trait (E30601). For a public trait,
    either explicit `public` members or no modifier both work.
15. **Ternary:** scalar `?:` is fine and warning-free; for vector conditions
    emit `select(condition, ifTrue, ifFalse)` (condition first) instead of
    `?:` to avoid the deprecation warning (and avoid argument-order mistakes).
    Boolean xor: use `^` or `!=` (there is no `^^`).

---

## 12. Probe index

| File | Covers |
|---|---|
| `slang-probes/entries.slang` | multi-entry file: vertex/fragment/compute, struct stage interfaces, vk::location + SV_*, compute `SV_DispatchThreadID` struct, multi-line signature |
| `slang-probes/resources.slang` | ConstantBuffer, push constant, Texture2D+SamplerState, Structured/RWStructuredBuffer nested writes, static const, enum, fragment+compute entries |
| `slang-probes/traits.slang` | library module: interfaces/supertrait/generic interface, public extensions with implicit `this`, `[mutating]`, static factory, generic struct `where`, generic function `where`, generic extension (`where` and direct bound) |
| `slang-probes/use_traits.slang` | consumes `traits`: interface-typed variables, cross-module public extensions/generics/constants, entry in a module file |
| `slang-probes/expressions.slang` | var/let, casts, constructors, swizzles, matrix row-major + `mul`, ternary, bool xor, `in`/`inout`/`out`, loops/statements |
| `slang-probes/library.slang` | entry-less library file (`-target none` path) |
| `slang-probes/modules/math.slang`, `.../main.slang` | multi-file module project: `module`, `import`, public struct/fields/extension/consts, root module with entry |
| `slang-probes/consts.slang` | planned consts.e7 lowering: static consts, inline `mod`→namespace, enum, expression-bodied functions → block bodies, vector casts, swizzles |
| `slang-probes/triangle/vert.slang`, `.../frag.slang` | planned triangle stage lowering as two standalone translation units (ConstantBuffer, vk::location, SV_Position, struct returns/outputs) |

All 11 files / 12 entries pass under
`check-slang.sh --spirv-val` with slangc 2026.20 (2026-10-25).
