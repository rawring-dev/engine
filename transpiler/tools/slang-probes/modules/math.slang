// Probe: multi-file module project, library side.
//
// `import math;` resolves the FILE math.slang in a -I directory.  Public
// declarations are required for cross-module use; a public extension also
// needs `public` on each member.

module math;

public static const float PI = 3.14159265;
public static const float TAU = 6.28318531;

public struct Vec2
{
    public float x;
    public float y;
}

public extension Vec2
{
    public float dot(Vec2 other) { return this.x * other.x + this.y * other.y; }
    public float length() { return sqrt(this.dot(this)); }
}

public float saturate(float x)
{
    return clamp(x, 0.0, 1.0);
}
