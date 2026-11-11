#version 450
layout(push_constant) uniform P { vec4 c; } p;
layout(location = 0) out vec4 o;
void main() { o = p.c; }
