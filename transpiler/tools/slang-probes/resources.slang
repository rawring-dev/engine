// Probe: resource bindings, push constants, global constants, enums.
//
// Covers: [[vk::binding(b, s)]] ConstantBuffer/Texture2D/SamplerState/
// StructuredBuffer/RWStructuredBuffer, [[vk::push_constant]] ConstantBuffer,
// static const globals (scalar/vector/matrix, derived), enum with explicit
// base type and :: member access, and writes to nested RWStructuredBuffer
// element fields.

struct Scene
{
    float4x4 mvp;
    float4 tint;
};

struct PushConstants
{
    float4x4 mvp;
    float alpha;
};

struct Particle
{
    float3 position;
    float3 velocity;
};

enum Tone : uint
{
    Linear,
    Gamma,
    Aces
}

static const float PI = 3.14159265;
static const float TAU = PI * 2.0;
static const float3 WHITE = float3(1.0, 1.0, 1.0);
static const float4x4 IDENT = float4x4(
    1.0, 0.0, 0.0, 0.0,
    0.0, 1.0, 0.0, 0.0,
    0.0, 0.0, 1.0, 0.0,
    0.0, 0.0, 0.0, 1.0);

[[vk::binding(0, 0)]] ConstantBuffer<Scene> scene;
[[vk::push_constant]] ConstantBuffer<PushConstants> push;
[[vk::binding(1, 0)]] Texture2D<float4> albedo;
[[vk::binding(2, 0)]] SamplerState albedo_sampler;
[[vk::binding(3, 0)]] StructuredBuffer<Particle> particles;
[[vk::binding(4, 0)]] RWStructuredBuffer<Particle> particles_out;

struct DispatchId
{
    uint3 tid : SV_DispatchThreadID;
};

[shader("fragment")]
float4 fs_main(float2 uv : SV_Position) : SV_Target
{
    float4 base = albedo.Sample(albedo_sampler, uv);
    float3 tinted = base.rgb * scene.tint.rgb * push.alpha;
    Tone tone = Tone::Gamma;
    float x = (tone == Tone::Gamma) ? pow(base.r, 2.2) : base.r;
    float2x2 m = float2x2(1.0, 2.0, 3.0, 4.0);
    float2 mv = mul(m, float2(uv.x, uv.y));
    float3 extra = WHITE * 0.0 + IDENT[0].xyz * 0.0;
    return float4(tinted + extra + float3(x + mv.x + TAU * 0.0), 1.0);
}

[shader("compute")]
[numthreads(64, 1, 1)]
void cs_main(DispatchId id)
{
    uint index = id.tid.x;
    if (index >= 1024u)
    {
        return;
    }
    Particle p = particles[index];
    p.velocity = p.velocity + float3(0.0, -9.81, 0.0) * 0.016;
    p.position = p.position + p.velocity * 0.016;
    particles_out[index] = p;
}
