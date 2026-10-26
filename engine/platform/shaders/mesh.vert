#version 450
layout(location = 0) in vec3 position;
layout(location = 1) in vec3 color;
layout(set = 0, binding = 0) uniform Scene {
    mat4 model;
    mat4 view;
    mat4 proj;
} scene;
layout(location = 0) out vec3 vcolor;
void main() {
    gl_Position = scene.proj * scene.view * scene.model * vec4(position, 1.0);
    vcolor = color;
}
