// Probe: traits -> interfaces, impl -> extensions, generics.
//
// This is a library module (no [shader] entry points) imported by
// use_traits.slang.  Covers: interface inheritance / supertraits, [mutating]
// methods, public extension with implicit `this`, static extension methods,
// generic structs with both `where` and direct bounds, generic functions with
// `where` bounds, generic extensions with `where` / direct bounds, a generic
// interface, and public visibility required for cross-module use.

module traits;

public static const float PI = 3.14159265;

public interface IShape
{
    float area();
    float circumference();
}

public interface IShaded : IShape
{
    float3 albedo();
    [mutating] void shade(float amount);
}

public struct Circle
{
    public float radius;
    public float3 colour;
}

public extension Circle : IShape
{
    public float area() { return PI * this.radius * this.radius; }
    public float circumference() { return 2.0 * PI * this.radius; }
}

public extension Circle : IShaded
{
    public float3 albedo() { return this.colour; }
    [mutating] public void shade(float amount) { this.colour = this.colour * amount; }
}

public extension Circle
{
    public static Circle unit() { return Circle(1.0, float3(1.0, 0.5, 0.25)); }
}

// Generic struct constrained with a `where` clause (allowed in slangc 2026.20
// and enforced: Pair<float> would be rejected).
public struct Pair<T> where T : IShape
{
    public T first;
    public T second;
}

public float sum_area<T>(T a, T b) where T : IShape
{
    return a.area() + b.area();
}

public extension<T> Pair<T> where T : IShape
{
    public float combined_area() { return this.first.area() + this.second.area(); }
}

public extension<T : IShape> Pair<T>
{
    public float combined_area_direct() { return this.first.area() + this.second.area(); }
}

public interface IBox<TValue>
{
    TValue get();
}

public struct FloatBox
{
    public float value;
}

public extension FloatBox : IBox<float>
{
    public float get() { return this.value; }
}
