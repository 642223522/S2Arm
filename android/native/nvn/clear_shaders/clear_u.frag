#version 450
layout(push_constant) uniform P { uvec4 c; } p;
layout(location = 0) out uvec4 o;
void main() { o = p.c; }
