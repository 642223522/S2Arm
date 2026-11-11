#version 450
// 整屏三角形；深度取 push 常量（清深度时要写成给定值，其余情况不测也不写深度）
layout(push_constant) uniform P { layout(offset = 16) float depth; } p;
void main() {
    vec2 q = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
    gl_Position = vec4(q * 2.0 - 1.0, p.depth, 1.0);
}
