// Probe: triangle vertex stage, i.e. the planned e7s -> Slang output shape
// for examples/triangle.vert.e7.  Compiles standalone (no imports).
//
// Key points: plain struct resource -> ConstantBuffer<T>; @location -> 
// [[vk::location(n)]]; @builtin(position) -> SV_Position; row-major matrix via
// mul(); struct return.

struct Scene
{
    float4x4 mvp;
    float4 tint;
};

struct Vertex
{
    [[vk::location(0)]] float3 position;
    [[vk::location(1)]] float4 colour;
};

struct Varying
{
    float4 clip_position : SV_Position;
    [[vk::location(0)]] float4 colour;
};

[[vk::binding(0, 0)]] ConstantBuffer<Scene> scene;

[shader("vertex")]
Varying vs_main(Vertex vertex)
{
    Varying output;
    output.clip_position = mul(scene.mvp, float4(vertex.position, 1.0));
    output.colour = vertex.colour * scene.tint;
    return output;
}
