// Probe: consuming a module that exports interfaces, generic extensions and
// public constants (see traits.slang).  The entry point lives in a module
// file and is not public: slangc still accepts it as -entry.

module use_traits;
import traits;

[shader("fragment")]
float4 fs_main() : SV_Target
{
    Circle c = Circle::unit();
    IShaded shaded = c;
    shaded.shade(2.0);

    Pair<Circle> pair = Pair<Circle>(c, c);
    IBox<float> box = FloatBox(2.0);

    float total = sum_area(c, c)
                + pair.combined_area()
                + pair.combined_area_direct()
                + box.get();

    float3 colour = shaded.albedo() + float3(total);
    return float4(colour, 1.0);
}
