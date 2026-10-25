// Probe: constants, enums, inline modules and scalar/vector math, i.e. the
// planned e7s -> Slang output shape for examples/consts.e7.
//
// Key points: top-level `name: Type := expr` -> `static const`; inline
// `mod name { ... }` -> Slang `namespace name`; unit-only enum -> Slang enum;
// vector literals -> constructor calls; `as [f32; N]` -> floatN(...) cast;
// e7 expression-bodied functions become ordinary block-bodied functions.

static const float PI = 3.14159265;
static const float TAU = 6.28318531;
static const uint MAX_LIGHTS = 8u;
static const float3 GRAVITY = float3(0.0, -9.81, 0.0);

namespace units
{
    public static const float MILLI = 0.001;
    public float to_metres(float milli) { return milli * MILLI; }
}

enum Tone
{
    Linear,
    Gamma,
    Aces
}

float wrap_angle(float angle)
{
    return angle - TAU * floor(angle / TAU);
}

float luminance(float3 colour)
{
    return dot(colour, float3(0.2126, 0.7152, 0.0722));
}

float tone_curve(Tone tone, float value)
{
    if (tone == Tone::Linear)
    {
        return value;
    }
    else if (tone == Tone::Gamma)
    {
        return pow(value, 2.2);
    }
    else
    {
        return value * 0.8;
    }
}

struct FragInput
{
    float4 frag_coord : SV_Position;
    [[vk::location(0)]] float2 uv;
};

struct FragOutput
{
    [[vk::location(0)]] float4 colour;
};

[shader("fragment")]
FragOutput fs_main(FragInput input)
{
    float angle = wrap_angle(input.uv.x * TAU * 8.0);
    float wave = sin(angle) * 0.5 + 0.5;
    float4 base = float4(wave, wave * 0.5, 1.0 - wave, 1.0);
    float lum = luminance(float3(base.r, base.g, base.b));
    float curved = tone_curve(Tone::Gamma, lum);
    float metres = units::to_metres(input.uv.y);

    FragOutput output;
    output.colour = float4(float3(curved, curved, curved) + GRAVITY * 0.0 + float3(units::MILLI * float(MAX_LIGHTS) * 0.0 + metres * 0.0), 1.0);
    return output;
}
