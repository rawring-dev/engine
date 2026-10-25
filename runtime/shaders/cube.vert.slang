// Vertex shader for the engine7 scene renderer: spinning cube with a point
// light.  This is HLSL-compatible Slang.  Matrices are passed as explicit
// float4 columns so the constant-buffer layout is unambiguous across slangc,
// glslangValidator, and glslc, and the vertex format is position/normal/colour.
//
// Uniform layout (std140-compatible, 256 bytes, matching renderer.Uniforms):
//   model_c0..c3, view_c0..c3, proj_c0..c3, camera_pos, light_pos,
//   light_color, params
struct SceneUniform {
    float4 model_c0;
    float4 model_c1;
    float4 model_c2;
    float4 model_c3;
    float4 view_c0;
    float4 view_c1;
    float4 view_c2;
    float4 view_c3;
    float4 proj_c0;
    float4 proj_c1;
    float4 proj_c2;
    float4 proj_c3;
    float4 camera_pos;
    float4 light_pos;
    float4 light_color;
    float4 params;
};

[[vk::binding(0, 0)]] cbuffer Scene : register(b0) { SceneUniform scene; };

struct VSInput {
    [[vk::location(0)]] float3 position : POSITION;
    [[vk::location(1)]] float3 normal   : NORMAL;
    [[vk::location(2)]] float3 color    : COLOR0;
};

struct VSOutput {
    float4 position  : SV_Position;
    float3 world_pos : TEXCOORD0;
    float3 normal    : TEXCOORD1;
    float3 color     : TEXCOORD2;
};

// Column-major multiply: out = c0*v.x + c1*v.y + c2*v.z + c3*v.w.
float4 transform(float4 c0, float4 c1, float4 c2, float4 c3, float4 v) {
    return c0 * v.x + c1 * v.y + c2 * v.z + c3 * v.w;
}

VSOutput main(VSInput input) {
    float4 world = transform(
        scene.model_c0, scene.model_c1, scene.model_c2, scene.model_c3,
        float4(input.position, 1.0));
    float4 view = transform(
        scene.view_c0, scene.view_c1, scene.view_c2, scene.view_c3,
        world);

    VSOutput output;
    output.position = transform(
        scene.proj_c0, scene.proj_c1, scene.proj_c2, scene.proj_c3,
        view);
    output.world_pos = world.xyz;
    // The model matrix is rotation-only, so its upper 3x3 transforms normals.
    output.normal = scene.model_c0.xyz * input.normal.x +
                    scene.model_c1.xyz * input.normal.y +
                    scene.model_c2.xyz * input.normal.z;
    output.color = input.color;
    return output;
}
