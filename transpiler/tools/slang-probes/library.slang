// Probe: a generated library unit with no shader entry points.
//
// The validation harness front-end-checks such files with `slangc -target none`
// instead of compiling an entry point to SPIR-V.  A module declaration is not
// required for a file that is compiled/imported directly by path.

float remap(float v, float in_min, float in_max, float out_min, float out_max)
{
    return out_min + (v - in_min) * (out_max - out_min) / (in_max - in_min);
}

float luminance(float3 colour)
{
    return dot(colour, float3(0.2126, 0.7152, 0.0722));
}

float3 safe_normalize(float3 v, float eps)
{
    float len_sq = dot(v, v);
    if (len_sq <= eps * eps)
    {
        return float3(0.0, 0.0, 1.0);
    }
    return v * (1.0 / sqrt(len_sq));
}
