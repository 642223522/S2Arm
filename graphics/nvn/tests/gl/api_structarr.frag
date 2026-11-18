#version 300 es
precision mediump float;
in vec3 vCol;
struct Light { vec4 color; float scale; };
uniform Light Lights[2];
out vec4 oColor;
void main() { oColor = Lights[0].color * Lights[0].scale + Lights[1].color * Lights[1].scale + vec4(vCol, 0.0) * 0.0; }
