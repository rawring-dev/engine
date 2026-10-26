#version 450
layout(location = 0) in vec3 vcolor;
layout(location = 0) out vec4 outColor;
void main() { outColor = vec4(vcolor, 1.0); }
