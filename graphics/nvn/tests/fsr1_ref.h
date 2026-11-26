// SPDX-License-Identifier: MIT
// Copyright 2026 S2Arm contributors; EASU / RCAS port: Copyright (c) 2021 Advanced Micro Devices, Inc., Copyright (c) 2014 Michal Drobot (graphics/nvn/third_party/ffx_fsr1/LICENSE.txt)
// AMD FSR 1（EASU + RCAS）的 CPU 参考，给单测当期望用（graphics/nvn/tests/t_present_fsr.m）。
//   与被测的 MSL（graphics/nvn/gfx/nvn/nvn_present_fsr.inc）各写各的：这里按 AMD 的公式逐式抄自 Ryujinx 内嵌的 ffx_a.h / ffx_fsr1.h
//   （compat/tree/src/Ryujinx.Graphics.Vulkan/Effects/Shaders/FsrScaling.glsl 的 FsrEasuCon / FsrEasuSetF / FsrEasuTapF / FsrEasuF，
//    FsrSharpening.glsl 的 FsrRcasCon / FsrRcasF；32 位浮点路径，未开 FSR_RCAS_DENOISE / FSR_RCAS_PASSTHROUGH_ALPHA，同 Ryujinx），
//   取纹素用整数坐标加钳边（等价于 Ryujinx 的 textureGather + 钳边采样器：四个 gather 的 12 个有用纹素就是下面 b…o 这 12 个）。
//   版权与许可：Copyright (c) 2021 Advanced Micro Devices, Inc.，近似倒数 / 倒数平方根的做法 Copyright (c) 2014 Michal Drobot，均为 MIT，
//   全文见 graphics/nvn/third_party/ffx_fsr1/LICENSE.txt。
// 纯 C，单精度（与 GPU 同宽）；图是 w×h×3 的 float（0…1），8 位图用 fsr_ref_load8 / fsr_ref_store8 进出（存：四舍五入到最近的 8 位值，同 Metal 写 UNORM）。
#ifndef S2A_FSR1_REF_H
#define S2A_FSR1_REF_H
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static inline uint32_t fsr_ref_f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static inline float fsr_ref_u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
// ffx_a.h：APrxLoRcpF1 / APrxLoRsqF1 / APrxMedRcpF1 / ASatF1
static inline float fsr_ref_lo_rcp(float a) { return fsr_ref_u2f(0x7ef07ebbu - fsr_ref_f2u(a)); }
static inline float fsr_ref_lo_rsq(float a) { return fsr_ref_u2f(0x5f347d74u - (fsr_ref_f2u(a) >> 1)); }
static inline float fsr_ref_med_rcp(float a) { float b = fsr_ref_u2f(0x7ef19fffu - fsr_ref_f2u(a)); return b * (-b * a + 2.0f); }
static inline float fsr_ref_sat(float a) { return fminf(1.0f, fmaxf(0.0f, a)); }

// 负对照用的开关（缺省全 0 = 照 AMD 原式）：单测把被测着色器改错，或把这里改错，两边应对不上
typedef struct { float lanczos_a;   // 0 = 25/16（原式）；别的值替换 FsrEasuTapF 里的 25/16
                 float phase;       // 加在 con0.zw 上的偏移（0 = 原式；0.5 = 采样偏半个输入像素）
} fsr_ref_mut;

static inline const float *fsr_ref_at(const float *in, int w, int h, int x, int y) {
    x = x < 0 ? 0 : x >= w ? w - 1 : x; y = y < 0 ? 0 : y >= h ? h - 1 : y;
    return in + 3 * ((size_t)y * (size_t)w + (size_t)x);
}
static inline float fsr_ref_luma2(const float *c) { return c[2] * 0.5f + (c[0] * 0.5f + c[1]); }   // 亮度的 2 倍：B*0.5+(R*0.5+G)

// FsrEasuSetF：w 是这一个 2x2 角的双线性权（原式由四个布尔挑出）
static inline void fsr_ref_easu_set(float dir[2], float *len, float w, float lA, float lB, float lC, float lD, float lE) {
    float dc = lD - lC, cb = lC - lB;
    float lenX = fmaxf(fabsf(dc), fabsf(cb));
    lenX = fsr_ref_lo_rcp(lenX);
    float dirX = lD - lB;
    dir[0] += dirX * w;
    lenX = fsr_ref_sat(fabsf(dirX) * lenX);
    lenX *= lenX;
    *len += lenX * w;
    float ec = lE - lC, ca = lC - lA;
    float lenY = fmaxf(fabsf(ec), fabsf(ca));
    lenY = fsr_ref_lo_rcp(lenY);
    float dirY = lE - lA;
    dir[1] += dirY * w;
    lenY = fsr_ref_sat(fabsf(dirY) * lenY);
    lenY *= lenY;
    *len += lenY * w;
}
// FsrEasuTapF
static inline void fsr_ref_easu_tap(float aC[3], float *aW, float offx, float offy, const float dir[2], const float len[2], float lob, float clp, const float *c, float lanczos_a) {
    float vx = offx * dir[0] + offy * dir[1];
    float vy = offx * (-dir[1]) + offy * dir[0];
    vx *= len[0]; vy *= len[1];
    float d2 = vx * vx + vy * vy;
    d2 = fminf(d2, clp);
    float wB = (2.0f / 5.0f) * d2 + -1.0f;
    float wA = lob * d2 + -1.0f;
    wB *= wB; wA *= wA;
    wB = lanczos_a * wB + -(lanczos_a - 1.0f);
    float w = wB * wA;
    aC[0] += c[0] * w; aC[1] += c[1] * w; aC[2] += c[2] * w; *aW += w;
}
// FsrEasuF：输出像素 (ox, oy)；in 是 iw×ih，输出图 ow×oh（con0 = FsrEasuCon(iw, ih, iw, ih, ow, oh)）
static inline void fsr_ref_easu_px(const float *in, int iw, int ih, int ow, int oh, int ox, int oy, const fsr_ref_mut *m, float out[3]) {
    float la = m && m->lanczos_a != 0 ? m->lanczos_a : 25.0f / 16.0f, ph = m ? m->phase : 0;
    float con0x = (float)iw * (1.0f / (float)ow), con0y = (float)ih * (1.0f / (float)oh);
    float con0z = 0.5f * (float)iw * (1.0f / (float)ow) - 0.5f + ph, con0w = 0.5f * (float)ih * (1.0f / (float)oh) - 0.5f + ph;
    float ppx = (float)ox * con0x + con0z, ppy = (float)oy * con0y + con0w;
    float fpx = floorf(ppx), fpy = floorf(ppy);
    ppx -= fpx; ppy -= fpy;
    int sx = (int)fpx, sy = (int)fpy;
    //    b c
    //  e f g h
    //  i j k l
    //    n o
    const float *b = fsr_ref_at(in, iw, ih, sx, sy - 1), *c = fsr_ref_at(in, iw, ih, sx + 1, sy - 1);
    const float *e = fsr_ref_at(in, iw, ih, sx - 1, sy), *f = fsr_ref_at(in, iw, ih, sx, sy), *g = fsr_ref_at(in, iw, ih, sx + 1, sy), *h = fsr_ref_at(in, iw, ih, sx + 2, sy);
    const float *i = fsr_ref_at(in, iw, ih, sx - 1, sy + 1), *j = fsr_ref_at(in, iw, ih, sx, sy + 1), *k = fsr_ref_at(in, iw, ih, sx + 1, sy + 1), *l = fsr_ref_at(in, iw, ih, sx + 2, sy + 1);
    const float *n = fsr_ref_at(in, iw, ih, sx, sy + 2), *o = fsr_ref_at(in, iw, ih, sx + 1, sy + 2);
    float bL = fsr_ref_luma2(b), cL = fsr_ref_luma2(c), eL = fsr_ref_luma2(e), fL = fsr_ref_luma2(f), gL = fsr_ref_luma2(g), hL = fsr_ref_luma2(h);
    float iL = fsr_ref_luma2(i), jL = fsr_ref_luma2(j), kL = fsr_ref_luma2(k), lL = fsr_ref_luma2(l), nL = fsr_ref_luma2(n), oL = fsr_ref_luma2(o);
    float dir[2] = {0, 0}, len = 0;
    fsr_ref_easu_set(dir, &len, (1.0f - ppx) * (1.0f - ppy), bL, eL, fL, gL, jL);
    fsr_ref_easu_set(dir, &len, ppx * (1.0f - ppy), cL, fL, gL, hL, kL);
    fsr_ref_easu_set(dir, &len, (1.0f - ppx) * ppy, fL, iL, jL, kL, nL);
    fsr_ref_easu_set(dir, &len, ppx * ppy, gL, jL, kL, lL, oL);
    float dirR = dir[0] * dir[0] + dir[1] * dir[1];
    int zro = dirR < 1.0f / 32768.0f;
    dirR = fsr_ref_lo_rsq(dirR);
    dirR = zro ? 1.0f : dirR;
    dir[0] = zro ? 1.0f : dir[0];
    dir[0] *= dirR; dir[1] *= dirR;
    len = len * 0.5f;
    len *= len;
    float stretch = (dir[0] * dir[0] + dir[1] * dir[1]) * fsr_ref_lo_rcp(fmaxf(fabsf(dir[0]), fabsf(dir[1])));
    float len2[2] = {1.0f + (stretch - 1.0f) * len, 1.0f + -0.5f * len};
    float lob = 0.5f + ((1.0f / 4.0f - 0.04f) - 0.5f) * len;
    float clp = fsr_ref_lo_rcp(lob);
    float aC[3] = {0, 0, 0}, aW = 0;
    fsr_ref_easu_tap(aC, &aW, 0.0f - ppx, -1.0f - ppy, dir, len2, lob, clp, b, la);
    fsr_ref_easu_tap(aC, &aW, 1.0f - ppx, -1.0f - ppy, dir, len2, lob, clp, c, la);
    fsr_ref_easu_tap(aC, &aW, -1.0f - ppx, 1.0f - ppy, dir, len2, lob, clp, i, la);
    fsr_ref_easu_tap(aC, &aW, 0.0f - ppx, 1.0f - ppy, dir, len2, lob, clp, j, la);
    fsr_ref_easu_tap(aC, &aW, 0.0f - ppx, 0.0f - ppy, dir, len2, lob, clp, f, la);
    fsr_ref_easu_tap(aC, &aW, -1.0f - ppx, 0.0f - ppy, dir, len2, lob, clp, e, la);
    fsr_ref_easu_tap(aC, &aW, 1.0f - ppx, 1.0f - ppy, dir, len2, lob, clp, k, la);
    fsr_ref_easu_tap(aC, &aW, 2.0f - ppx, 1.0f - ppy, dir, len2, lob, clp, l, la);
    fsr_ref_easu_tap(aC, &aW, 2.0f - ppx, 0.0f - ppy, dir, len2, lob, clp, h, la);
    fsr_ref_easu_tap(aC, &aW, 1.0f - ppx, 0.0f - ppy, dir, len2, lob, clp, g, la);
    fsr_ref_easu_tap(aC, &aW, 1.0f - ppx, 2.0f - ppy, dir, len2, lob, clp, o, la);
    fsr_ref_easu_tap(aC, &aW, 0.0f - ppx, 2.0f - ppy, dir, len2, lob, clp, n, la);
    float rw = 1.0f / aW;
    for (int ch = 0; ch < 3; ch++) {
        float mn = fminf(fminf(fminf(f[ch], g[ch]), j[ch]), k[ch]), mx = fmaxf(fmaxf(fmaxf(f[ch], g[ch]), j[ch]), k[ch]);
        out[ch] = fminf(mx, fmaxf(mn, aC[ch] * rw));
    }
}
static inline void fsr_ref_easu(const float *in, int iw, int ih, float *out, int ow, int oh, const fsr_ref_mut *m) {
    for (int y = 0; y < oh; y++) for (int x = 0; x < ow; x++) fsr_ref_easu_px(in, iw, ih, ow, oh, x, y, m, out + 3 * ((size_t)y * (size_t)ow + (size_t)x));
}

// Ryujinx FsrScalingFilter.Run：sharpness（档）= 1.5 − Level × 0.01 × 1.5，Level 下限 0.01；FsrRcasCon：con = exp2(−sharpness)
static inline float fsr_ref_rcas_stops(float level) { if (level < 0.01f) level = 0.01f; return 1.5f - (level * 0.01f * 1.5f); }
static inline float fsr_ref_rcas_con(float level) { return exp2f(-fsr_ref_rcas_stops(level)); }
#define FSR_REF_RCAS_LIMIT (0.25f - (1.0f / 16.0f))
// FsrRcasF：像素 (x, y)；图边钳边（Ryujinx 的 texelFetch 越界未定义，这里与被测实现同取钳边）。max / min 是 IEEE maxNum / minNum（一边是 NaN 取另一边，C 的 fmaxf / fminf）：
//   某通道五个纹素全 0 时 hitMin = 0 × (1 / 0) = NaN，全 1 时 hitMax = 0 × (1 / 0) = NaN，这个通道不参与定 lobe
static inline void fsr_ref_rcas_px(const float *in, int w, int h, int x, int y, float con, float out[3]) {
    const float *b = fsr_ref_at(in, w, h, x, y - 1), *d = fsr_ref_at(in, w, h, x - 1, y), *e = fsr_ref_at(in, w, h, x, y), *f = fsr_ref_at(in, w, h, x + 1, y), *hh = fsr_ref_at(in, w, h, x, y + 1);
    float lobe3[3];
    for (int ch = 0; ch < 3; ch++) {
        float mn4 = fminf(fminf(fminf(b[ch], d[ch]), f[ch]), hh[ch]), mx4 = fmaxf(fmaxf(fmaxf(b[ch], d[ch]), f[ch]), hh[ch]);
        float hitMin = fminf(mn4, e[ch]) * (1.0f / (4.0f * mx4));
        float hitMax = (1.0f - fmaxf(mx4, e[ch])) * (1.0f / (4.0f * mn4 + -4.0f));
        lobe3[ch] = fmaxf(-hitMin, hitMax);
    }
    float lobe = fmaxf(-FSR_REF_RCAS_LIMIT, fminf(fmaxf(fmaxf(lobe3[0], lobe3[1]), lobe3[2]), 0.0f)) * con;
    float rcpL = fsr_ref_med_rcp(4.0f * lobe + 1.0f);
    for (int ch = 0; ch < 3; ch++) out[ch] = (lobe * b[ch] + lobe * d[ch] + lobe * hh[ch] + lobe * f[ch] + e[ch]) * rcpL;
}
static inline void fsr_ref_rcas(const float *in, float *out, int w, int h, float con) {
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) fsr_ref_rcas_px(in, w, h, x, y, con, out + 3 * ((size_t)y * (size_t)w + (size_t)x));
}

// 8 位图（每像素 4 字节，rgb 在偏移 r_off / 1 / 2 − r_off：BGRA 传 2，RGBA 传 0）↔ float 图
static inline float *fsr_ref_load8(const uint8_t *px, int w, int h, int r_off) {
    float *f = malloc((size_t)w * (size_t)h * 3 * sizeof *f);
    for (size_t i = 0; f && i < (size_t)w * (size_t)h; i++) { f[3 * i] = (float)px[4 * i + (size_t)r_off] / 255.0f; f[3 * i + 1] = (float)px[4 * i + 1] / 255.0f; f[3 * i + 2] = (float)px[4 * i + 2 - (size_t)r_off] / 255.0f; }
    return f;
}
static inline uint8_t fsr_ref_q8(float v) { if (!(v > 0)) return 0; if (v > 1) v = 1; return (uint8_t)lrintf(v * 255.0f); }   // NaN 落到 0（!(v > 0)）：Metal 把 NaN 写成 0
static inline void fsr_ref_store8(const float *f, uint8_t *px, int w, int h, int r_off) {
    for (size_t i = 0; i < (size_t)w * (size_t)h; i++) { px[4 * i + (size_t)r_off] = fsr_ref_q8(f[3 * i]); px[4 * i + 1] = fsr_ref_q8(f[3 * i + 1]); px[4 * i + 2 - (size_t)r_off] = fsr_ref_q8(f[3 * i + 2]); px[4 * i + 3] = 255; }
}
// 量化一遍（EASU 的输出落在 8 位中间图上，RCAS 读的是量化后的值，同 Ryujinx 的 RGBA8 中间图）
static inline void fsr_ref_quant8(float *f, size_t n) { for (size_t i = 0; i < n; i++) f[i] = (float)fsr_ref_q8(f[i]) / 255.0f; }
#endif
