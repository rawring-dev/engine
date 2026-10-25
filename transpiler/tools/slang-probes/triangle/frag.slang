// Probe: triangle fragment stage, i.e. the planned e7s -> Slang output shape
// for examples/triangle.frag.e7.  Compiles standalone (no imports):
// e7s has no cross-file type identity, so the stage interface structs are
// redeclared here, matching the vertex stage attribute for attribute.
//
// Key points: struct output with [[vk::location(0)]] (no SV_Target needed);
// builtin position as SV_Position; texture sampling is covered in
// resources.slang.

struct Material
{
    float4 base_colour;
    float4 ambient;
};

struct FragInput
{
    float4 frag_coord : SV_Position;
    [[vk::location(0)]] float4 colour;
};

struct FragOutput
{
    [[vk::location(0)]] float4 colour;
};

[[vk::binding(0, 0)]] ConstantBuffer<Material> material;

[shader("fragment")]
FragOutput fs_main(FragInput input)
{
    FragOutput output;
    float4 lit = input.colour * material.base_colour + material.ambient;
    output.colour = float4(lit.rgb, 1.0);
    return output;
}
