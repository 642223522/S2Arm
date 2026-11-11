#version 450
// 整数格式的贴图用整数采样器读：读到的是存进去的位
layout(location = 0) out uvec4 oColor;
layout(set = 0, binding = 0) uniform usampler2D uTex;
void main() {
    oColor = texture(uTex, gl_FragCoord.xy / vec2(textureSize(uTex, 0)));
}
