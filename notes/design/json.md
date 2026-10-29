# JSON for e7 values

The compiler and runtime provide first-class JSON encoding and decoding.  The
e7-facing API uses the builtin namespace:

```e7
text := json::encode(value)          # -> str
value := json::decode::<T>(text)     # -> T
schema := json::schema::<T>()        # -> str (compile-time type schema)
```

The single-segment spellings `json_encode(value)` and
`json_decode::<T>(text)` are kept as aliases, so existing code keeps working.
`encode` also accepts `json_encode`; the namespace forms are preferred.

`T` may be any statically known supported type: a primitive, `str`, optional,
vector, fixed-size array, matrix, map, enum, or a struct/enum that declares
`@derive(Serialize)` / `@derive(Deserialize)`.  Structs and enums are opt-in:
both the value and every nested struct/enum must declare the matching derive.
A call on a non-derived struct/enum is a compile error.

Decoding returns `0` on malformed JSON, schema mismatch, unsupported value, or
out-of-memory.  `0` is also the value of `false`, integer `0`, and `nil`, so use
a handle-shaped target (struct, enum, vector, map, string) when failure must be
distinguishable.

## Schema reflection and inspectors

`json::schema::<T>()` exposes the exact compact schema already generated for
encoding/decoding, embedded as a string constant. It takes one type argument
and no value arguments. Struct/enum targets and their nested types must derive
both `Serialize` and `Deserialize`; primitives and supported collections work
without derives. Unsupported or recursive types receive the existing serializer
diagnostics. No runtime registry or second field declaration is involved.

For example, a derived `Settings { enabled: bool, speed: f32 }` produces
`{enabled=b;speed=f}`. The compact grammar is documented in
`runtime/src/json.zig`: scalar tags are `b`, `i`, `f`, `s`; structs use
`{field=type;...}`, enums `E{Variant=u;Payload=(type)}`, optionals `?type`,
vectors `[type]`, fixed arrays `A<count>:type`, matrices
`M<rows>:<columns>:type`, and maps `<key,value>`.

The reusable e7 inspector (`engine/editor/inspector.e7`) consumes this schema:

```e7
source := json::encode(&settings)
fields := inspect_fields(json::schema::<Settings>(), source)
values := inspect_values(&fields)
# Edit values by index, or locate a property with inspect_find(&fields, "speed").
values[1] = "3.25"
candidate := inspect_patch(source, &fields, &values)
updated := json::decode::<Settings>(candidate)
# Check ffi::handle(&updated) != 0, then domain rules, before replacing settings.
```

`inspect_patch` builds a new JSON string; it does not mutate the original value
or validate the target type. The caller commits only after typed decoding and
application-specific validation succeed. Keep the source and its field spans
together; regenerate them when the inspected value changes. Handle-shaped
targets allow unambiguous rejection, including valid `false`, zero, and null
properties inside a record.

Nested structs expand into dotted property paths. Strings use normal text with
JSON escaping on write; numeric text retains serializer precision. Boolean and
unit-enum fields provide finite choices. Arrays, matrices, maps, optionals, and
payload enums use JSON text and the existing deserializer's validation. After
32 nested struct levels, the remaining subtree stays editable as JSON. Unknown
source members and unchanged JSON fragments survive patch construction.

## Wire format

| e7 type | JSON |
| --- | --- |
| `bool` | `true` / `false` |
| integers (`i8`..`u128`, `usize`) | JSON integer; fraction and exponent forms are rejected on decode; the in-memory value is an `i64` slot |
| floats (`f16`..`f128`) | shortest round-trip decimal; `NaN`/`Inf` are rejected; `-0.0` round-trips |
| `str` | JSON string; UTF-8 validated on encode, `"` `\` and control characters escaped, `\uXXXX` (including valid surrogate pairs) decoded |
| `[T]` dynamic vector | JSON array |
| `[T; N]` fixed array | JSON array of exactly `N` elements |
| `[T; R, C]` matrix | array of `R` row arrays with `C` elements each, row-major |
| `?T` optional | `null` for `nil`, otherwise the wrapped value |
| `map[K, V]` | JSON object; keys are stringified by `K` (see below) |
| enum | tagged representation (see below) |
| derived struct | JSON object with one member per field |

### Structs

* Field order on the wire is free; the decoder matches member names.
* Unknown members are skipped (forward compatibility).
* A member repeated in the object keeps the last value.
* Missing `?T` fields decode as `nil`; a missing required field fails the
  decode.
* A decoded struct is a normal e7 aggregate; the runtime does not decode into
  memory the caller already owns (e7 has no placement construction).

### Enums

Enums use a tagged representation (the in-memory layout is `[tag, payload...]`):

| variant shape | JSON |
| --- | --- |
| unit variant `Red` | `"Red"` |
| one unnamed payload `Circle(f32)` | `{"Circle": 1.5}` |
| several unnamed payloads `Rgb(i64, i64, i64)` | `{"Rgb": [1, 2, 3]}` |

The variant name is the tag.  Named enum payload fields and enum variants with
struct payloads are not supported by `@derive` yet; the compiler reports a
diagnostic.

### Maps

JSON object keys must be strings, so non-string e7 map keys are stringified:

| key type | example key | wire key |
| --- | --- | --- |
| `str` | `"a"` | `"a"` |
| integer | `7` | `"7"` |
| bool | `true` | `"true"` |
| float | `1.5` | `"1.5"` |
| unit-only enum | `Color::Red` | `"Red"` |

Other key types (structs, vectors, enums with payloads) are not encodable as
JSON object keys and make encode/decode fail.  Entries keep insertion order on
encode; duplicate wire keys keep the last value on decode.

### Optionals

An optional is one i64 slot: `0` is `nil`.  Consequently an optional whose
present payload is also zero (e.g. `?i64` holding `0`, or `?bool` holding
`false`) encodes as `null` and cannot be distinguished from a missing value.
Use an optional aggregate/string, or a wrapper struct with an explicit present
flag, when zero-valued payloads are meaningful.

### Matrices

Matrices use the runtime aggregate `[rows, columns, row-major elements]` layout
and are encoded as nested arrays.  Fixed arrays and dynamic vectors share the
`[rows, columns=0, elements]` layout, so the static type decides whether the
schema expects `A<N>:...` or `[...]`.

## Limitations

* Recursive derived types are rejected ("recursive @derive(...) is not
  supported").
* Generic derived types are rejected.
* Fixed-size array/matrix dimensions must match the static type on encode and
  are enforced on decode.
* NaN and infinity have no JSON spelling and fail encode/decode.
* Non-UTF-8 e7 strings cannot be encoded; a JSON document whose raw bytes are
  not valid UTF-8 is rejected.
* Decoded aggregates are malloc-owned for the process lifetime; the e7
  aggregate ABI has no free path.
* Error reporting is a `0` return; there is no structured decode diagnostic
  yet.

## Implementation

* `compiler/src/semantic/analyzer.zig` validates `@derive`, builds the compact
  schema string, and records one schema per `json::encode` / `json::decode`
  call expression.
* `compiler/src/codegen.zig` embeds that schema as a string literal and lowers
  the call to `e7_json_encode` / `e7_json_decode`.
* `runtime/src/json.zig` parses the schema, walks the aggregate representation,
  and implements the strict JSON reader/writer described above.
