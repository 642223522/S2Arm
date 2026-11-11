#version 450
// 只写颜色输出 1（C77：颜色槽 0 是空位的通道）
layout(location = 1) out vec4 o1;
void main() {
    o1 = vec4(0.0, 1.0, 0.0, 1.0);
}
