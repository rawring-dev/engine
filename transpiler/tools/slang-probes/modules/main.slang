// Probe: multi-file module project, root translation unit.
//
// The root may declare a module and still contain [shader] entry points.
// Symbols imported from `math` are used unqualified (Slang imports are
// unqualified; `math::helper` is NOT valid).

module main;
import math;

[shader("fragment")]
float4 fs_main(float2 uv : SV_Position) : SV_Target
{
    Vec2 v = Vec2(uv.x, uv.y);
    return float4(v.dot(Vec2(1.0, 0.0)), saturate(v.length()), PI * 0.0, TAU * 0.0);
}
