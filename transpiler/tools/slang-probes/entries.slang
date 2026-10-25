// Probe: shader entry points and stage interfaces (slangc 2026.20, SPIR-V).
//
// Covers: [shader("vertex"|"fragment"|"compute")], [numthreads],
// [[vk::location(n)]] fields, SV_* semantics, a vertex input struct that only
// has [[vk::location]] fields, a fragment output struct that only has
// [[vk::location]] fields, a compute entry taking a struct with an
// SV_DispatchThreadID field, and signatures spread over several lines.

struct VertexIn
{
    [[vk::location(0)]] float3 position;
    [[vk::location(1)]] float3 normal;
};

struct Varying
{
    float4 clip_position : SV_Position;
    [[vk::location(0)]] float3 normal;
    [[vk::location(1)]] nointerpolation uint instance_id;
};

struct FragInput
{
    float4 frag_coord : SV_Position;
    [[vk::location(0)]] float3 normal;
    [[vk::location(1)]] nointerpolation uint instance_id;
};

struct FragOutput
{
    [[vk::location(0)]] float4 colour;
};

struct DispatchId
{
    uint3 tid : SV_DispatchThreadID;
};

[shader("vertex")]
Varying vs_main(VertexIn input)
{
    Varying output;
    output.clip_position = float4(input.position, 1.0);
    output.normal = input.normal;
    output.instance_id = 0u;
    return output;
}

[shader("fragment")]
FragOutput fs_main(FragInput input)
{
    FragOutput output;
    output.colour = float4(input.normal, float(input.instance_id));
    return output;
}

// Attribute and signature on one line, multi-line parameter list, return
// semantic on yet another line: the harness must still find this entry.
[shader("fragment")] float4 fs_multiline(
    FragInput input,
    float2 uv : TEXCOORD0)
    : SV_Target0
{
    return float4(input.normal, 1.0) + float4(uv, 0.0, 0.0);
}

[numthreads(8, 8, 1)]
[shader("compute")]
void cs_main(DispatchId id)
{
    uint3 clamped = min(id.tid, uint3(1023, 1023, 1));
    if (clamped.x > 100u)
    {
        return;
    }
}
