#version 450
layout(set = 0, binding = 0) uniform A { vec4 a; } ua;
layout(set = 0, binding = 8) uniform B { vec4 b; } ub;
layout(location = 0) out vec4 out_color;
void main() { out_color = vec4(ua.a.x, ub.b.y, 0.0, 1.0); }
