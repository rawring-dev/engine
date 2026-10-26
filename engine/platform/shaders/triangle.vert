#version 450
void main() {
    vec2 positions[3] = vec2[](
        vec2(0.0, -0.6),
        vec2(0.6, 0.6),
        vec2(-0.6, 0.6)
    );
    gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
}
