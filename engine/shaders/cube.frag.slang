// Fragment shader for the engine7 scene renderer: Lambert diffuse point light
// with distance attenuation plus a constant ambient term.  HLSL-compatible
// Slang; compiled to SPIR-V by slangc when available, or by the
// glslangValidator/glslc HLSL fallback.
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

struct VSOutput {
    float4 position  : SV_Position;
    float3 world_pos : TEXCOORD0;
    float3 normal    : TEXCOORD1;
    float3 color     : TEXCOORD2;
};

float4 main(VSOutput input) : SV_Target {
    float3 n = normalize(input.normal);
    float3 to_light = scene.light_pos.xyz - input.world_pos;
    float distance_to_light = length(to_light);
    float3 light_dir = to_light / max(distance_to_light, 1e-4);
    float diffuse = max(dot(n, light_dir), 0.0);

    // Inverse-square-ish falloff with a linear term to keep near faces bright.
    float attenuation = 1.0 / (1.0 + 0.15 * distance_to_light +
                               0.02 * distance_to_light * distance_to_light);
    // light_color.w carries the light intensity.
    float3 light = scene.light_color.rgb * (scene.light_color.w * attenuation);
    // params.rgb * params.w is the ambient colour.
    float3 ambient = scene.params.rgb * scene.params.w;

    float3 lit = input.color * (ambient + light * diffuse);
    return float4(lit, 1.0);
}
