// SPDX-License-Identifier: MIT
// Copyright (C) 2026 Advanced Micro Devices, Inc. (EASU port; see nvn_vk_easu_license.txt)
//
// EASU (Edge-Adaptive Spatial Upsampling) from AMD FidelityFX FSR1, fragment-pass port.
// Upstream: GPUOpen-LibrariesAndSDKs/FidelityFX-SDK
//   Kits/FidelityFX/upscalers/fsr3/include/gpu/fsr1/ffx_fsr1.h
//   blob 2ae12de1074188695a51f55123bede2c301fdd8b
// Ported from ffxFsrEasuFloat / fsrEasuTapFloat / fsrEasuSetFloat (FP32 path).
//
// Differences from the compute spike version (android/tests/vk/shaders/fsr_easu.comp):
//   * output pixel index comes from gl_FragCoord minus the destination rect origin;
//   * con0 folds the source crop offset and the vertical flip (EASU is equivariant under a
//     vertical flip, because the tap weight depends only on distance^2 in the rotated frame),
//     so this is still one branch-free affine map;
//   * the gradient-ratio divide is guarded at zero: GLSL min/max do not drop NaN the way
//     AMD's min/max-based saturate does, and 0*INF would otherwise poison a flat region.
// ffxApproximateReciprocal / ...SquareRoot are replaced by exact 1.0/x and inversesqrt();
// they are a GPU cycle-saving trick and do not change the filter shape.

#version 450

layout(location = 0) out vec4 fragColor;

layout(set = 0, binding = 0) uniform sampler2D srcTex;

layout(push_constant) uniform EasuPc {
    vec4 con0;      // output pixel -> source texel affine (x, y scales and offsets)
    vec4 con1;      // 1/inputSize, and the first gather offset from 'F'
    vec4 con2;      // gather offsets 1 and 2, from (0)
    vec4 con3;      // gather offset 3, from (0)
    vec2 dstOrigin; // destination rect origin in framebuffer pixels
    vec2 dstSize;   // destination rect size in pixels
    uint swapRb;    // 1 = source and destination disagree on R/B byte order
    uint encodeSrgb; // 1 = destination is a non-sRGB UNORM image; write sRGB-encoded bytes
} pc;

// vkCmdBlitImage decodes an sRGB source; a non-linear UNORM swapchain needs the encoded
// bytes back (see wsi_encoded_target). When the presentation path would blit through an
// sRGB intermediate, the EASU output has to carry the same encoding, so apply it here.
vec3 srgbEncode(vec3 c) {
    c = clamp(c, 0.0, 1.0);
    vec3 lo = c * 12.92;
    vec3 hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
    return mix(hi, lo, lessThanEqual(c, vec3(0.0031308)));
}

void easuTap(inout vec3 aC, inout float aW, vec2 off, vec2 dir, vec2 len2,
             float lob, float clp, vec3 c) {
    vec2 v;
    v.x = off.x * dir.x + off.y * dir.y;
    v.y = off.x * (-dir.y) + off.y * dir.x;
    v *= len2;
    float d2 = v.x * v.x + v.y * v.y;
    d2 = min(d2, clp);
    float wB = (2.0 / 5.0) * d2 - 1.0;
    float wA = lob * d2 - 1.0;
    wB *= wB;
    wA *= wA;
    wB = (25.0 / 16.0) * wB - (25.0 / 16.0 - 1.0);
    float w = wB * wA;
    aC += c * w;
    aW += w;
}

void easuSet(inout vec2 dir, inout float len, vec2 pp, int quad,
             float lA, float lB, float lC, float lD, float lE) {
    float w = 0.0;
    if (quad == 0) w = (1.0 - pp.x) * (1.0 - pp.y);
    if (quad == 1) w = pp.x * (1.0 - pp.y);
    if (quad == 2) w = (1.0 - pp.x) * pp.y;
    if (quad == 3) w = pp.x * pp.y;

    float dc = lD - lC;
    float cb = lC - lB;
    float lenX = max(abs(dc), abs(cb));
    float dirX = lD - lB;
    dir.x += dirX * w;
    float rX = lenX > 0.0 ? clamp(abs(dirX) / lenX, 0.0, 1.0) : 0.0;
    len += rX * rX * w;

    float ec = lE - lC;
    float ca = lC - lA;
    float lenY = max(abs(ec), abs(ca));
    float dirY = lE - lA;
    dir.y += dirY * w;
    float rY = lenY > 0.0 ? clamp(abs(dirY) / lenY, 0.0, 1.0) : 0.0;
    len += rY * rY * w;
}

void main() {
    ivec2 ip = ivec2(floor(gl_FragCoord.xy)) - ivec2(pc.dstOrigin);
    if (ip.x < 0 || ip.y < 0 || ip.x >= int(pc.dstSize.x) || ip.y >= int(pc.dstSize.y)) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    vec2 pp = vec2(ip) * pc.con0.xy + pc.con0.zw;
    vec2 fp = floor(pp);
    pp -= fp;

    // 12-tap kernel, in source storage order (y down):
    //     b c
    //   e f g h
    //   i j k l
    //     n o
    vec2 p0 = fp * pc.con1.xy + pc.con1.zw;
    vec2 p1 = p0 + pc.con2.xy;
    vec2 p2 = p0 + pc.con2.zw;
    vec2 p3 = p0 + pc.con3.xy;

    vec4 bczzR = textureGather(srcTex, p0, 0);
    vec4 bczzG = textureGather(srcTex, p0, 1);
    vec4 bczzB = textureGather(srcTex, p0, 2);
    vec4 ijfeR = textureGather(srcTex, p1, 0);
    vec4 ijfeG = textureGather(srcTex, p1, 1);
    vec4 ijfeB = textureGather(srcTex, p1, 2);
    vec4 klhgR = textureGather(srcTex, p2, 0);
    vec4 klhgG = textureGather(srcTex, p2, 1);
    vec4 klhgB = textureGather(srcTex, p2, 2);
    vec4 zzonR = textureGather(srcTex, p3, 0);
    vec4 zzonG = textureGather(srcTex, p3, 1);
    vec4 zzonB = textureGather(srcTex, p3, 2);

    vec4 bczzL = bczzB * 0.5 + (bczzR * 0.5 + bczzG);
    vec4 ijfeL = ijfeB * 0.5 + (ijfeR * 0.5 + ijfeG);
    vec4 klhgL = klhgB * 0.5 + (klhgR * 0.5 + klhgG);
    vec4 zzonL = zzonB * 0.5 + (zzonR * 0.5 + zzonG);

    float bL = bczzL.x, cL = bczzL.y;
    float iL = ijfeL.x, jL = ijfeL.y, fL = ijfeL.z, eL = ijfeL.w;
    float kL = klhgL.x, lL = klhgL.y, hL = klhgL.z, gL = klhgL.w;
    float oL = zzonL.z, nL = zzonL.w;

    vec2 dir = vec2(0.0);
    float len = 0.0;
    easuSet(dir, len, pp, 0, bL, eL, fL, gL, jL);
    easuSet(dir, len, pp, 1, cL, fL, gL, hL, kL);
    easuSet(dir, len, pp, 2, fL, iL, jL, kL, nL);
    easuSet(dir, len, pp, 3, gL, jL, kL, lL, oL);

    float dirR = dir.x * dir.x + dir.y * dir.y;
    bool zro = dirR < (1.0 / 32768.0);
    dirR = inversesqrt(max(dirR, 1e-30));
    dirR = zro ? 1.0 : dirR;
    dir.x = zro ? 1.0 : dir.x;
    dir *= dirR;

    len = len * 0.5;
    len *= len;
    float stretch = (dir.x * dir.x + dir.y * dir.y) / max(abs(dir.x), abs(dir.y));
    vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);
    float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;
    float clp = 1.0 / lob;

    vec3 min4 = min(min(vec3(ijfeR.z, ijfeG.z, ijfeB.z), vec3(klhgR.w, klhgG.w, klhgB.w)),
                    min(vec3(ijfeR.y, ijfeG.y, ijfeB.y), vec3(klhgR.x, klhgG.x, klhgB.x)));
    vec3 max4 = max(max(vec3(ijfeR.z, ijfeG.z, ijfeB.z), vec3(klhgR.w, klhgG.w, klhgB.w)),
                    max(vec3(ijfeR.y, ijfeG.y, ijfeB.y), vec3(klhgR.x, klhgG.x, klhgB.x)));

    vec3 aC = vec3(0.0);
    float aW = 0.0;
    easuTap(aC, aW, vec2(0.0, -1.0) - pp, dir, len2, lob, clp, vec3(bczzR.x, bczzG.x, bczzB.x)); // b
    easuTap(aC, aW, vec2(1.0, -1.0) - pp, dir, len2, lob, clp, vec3(bczzR.y, bczzG.y, bczzB.y)); // c
    easuTap(aC, aW, vec2(-1.0, 1.0) - pp, dir, len2, lob, clp, vec3(ijfeR.x, ijfeG.x, ijfeB.x)); // i
    easuTap(aC, aW, vec2(0.0, 1.0) - pp, dir, len2, lob, clp, vec3(ijfeR.y, ijfeG.y, ijfeB.y));  // j
    easuTap(aC, aW, vec2(0.0, 0.0) - pp, dir, len2, lob, clp, vec3(ijfeR.z, ijfeG.z, ijfeB.z));  // f
    easuTap(aC, aW, vec2(-1.0, 0.0) - pp, dir, len2, lob, clp, vec3(ijfeR.w, ijfeG.w, ijfeB.w)); // e
    easuTap(aC, aW, vec2(1.0, 1.0) - pp, dir, len2, lob, clp, vec3(klhgR.x, klhgG.x, klhgB.x));  // k
    easuTap(aC, aW, vec2(2.0, 1.0) - pp, dir, len2, lob, clp, vec3(klhgR.y, klhgG.y, klhgB.y));  // l
    easuTap(aC, aW, vec2(2.0, 0.0) - pp, dir, len2, lob, clp, vec3(klhgR.z, klhgG.z, klhgB.z));  // h
    easuTap(aC, aW, vec2(1.0, 0.0) - pp, dir, len2, lob, clp, vec3(klhgR.w, klhgG.w, klhgB.w));  // g
    easuTap(aC, aW, vec2(1.0, 2.0) - pp, dir, len2, lob, clp, vec3(zzonR.z, zzonG.z, zzonB.z));  // o
    easuTap(aC, aW, vec2(0.0, 2.0) - pp, dir, len2, lob, clp, vec3(zzonR.w, zzonG.w, zzonB.w));  // n

    vec3 pix = min(max4, max(min4, aC / aW));
    if (pc.encodeSrgb != 0u) pix = srgbEncode(pix);
    // 采样拿到的分量是源图的字节序；写进目标附件按目标的字节序解释。
    // 两侧不一致时在这里换回来，否则 R/B 会对调。
    if (pc.swapRb != 0u) pix = pix.bgr;
    fragColor = vec4(pix, 1.0);
}