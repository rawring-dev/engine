// Probe: expression and statement forms the e7s lowering relies on.
//
// Covers: var/let inference, scalar/vector/matrix constructors, struct
// constructor calls S(a, b), constructor casts, swizzles (read and lvalue),
// matrix row-major construction and indexing, mul(matrix, vector), standard
// scalar intrinsics, ternary, boolean xor via `^`, in/inout/out parameters,
// for/while/if/else/continue, compound assignment and ++.

struct Point
{
    float2 pos;
    float3 colour;
};

static const float GRAVITY = -9.81;
static const float2 HALF2 = float2(0.5, 0.5);
static const float2x2 IDENT2 = float2x2(1.0, 0.0, 0.0, 1.0);

float accumulate(in float x, inout float acc, out float doubled)
{
    acc += x;
    doubled = x * 2.0;
    return acc;
}

[shader("fragment")]
float4 fs_main(float2 uv : SV_Position) : SV_Target
{
    var a = 1.0;
    let b = 2.0;

    var sum = 0.0;
    var doubled = 0.0;
    accumulate(a, sum, doubled);

    float3 v = float3(a, b, 3.0);
    v.xy = v.yx;

    float2x2 m = float2x2(1.0, 2.0, 3.0, 4.0);
    float2 mv = mul(m, v.xy);
    float2 id = mul(IDENT2, HALF2);

    Point p = Point(float2(mv.x, mv.y), float3(v.x));

    bool cond = b > a;
    float tern = cond ? 1.0 : 0.0;
    bool xorb = cond ^ (b < a);

    int i = int(uv.x * 4.0);
    uint u = uint(i);
    float f = float(i) + float(u) + float(xorb) + tern + sum + doubled;
    f += p.pos.x + p.colour.x + id.x + GRAVITY * 0.0;

    for (int k = 0; k < 4; k++)
    {
        if (k == 2)
        {
            continue;
        }
        f += float(k);
    }

    var w = 0;
    while (w < 2)
    {
        w++;
    }
    f += float(w);

    return float4(f, mv.x, v.z, 1.0);
}
