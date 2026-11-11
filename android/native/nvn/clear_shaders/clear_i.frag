#version 450
layout(push_constant) uniform P { ivec4 c; } p;
layout(location = 0) out ivec4 o;
void main() { o = p.c; }
