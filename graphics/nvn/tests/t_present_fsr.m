// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 直连上屏 AMD FSR 1（S2A_SCALING_FILTER=Fsr，graphics/nvn/gfx/nvn/nvn_present_fsr.inc）。含生产 nvn_mtl.m 源码（同 t_present_aspect.m 写法）+ 真 Metal 设备，
//   离屏跑真的上屏编码（present_encode_slot / present_encode_m4），不开窗口。后端与抗锯齿由环境定（NXGAL_BE=mtl3、S2A_ANTI_ALIASING），构建规则各跑一遍。
// 期望都不靠被测实现：
//   - 逐像素：独立的 CPU 参考 fsr1_ref.h（按 AMD 公式写的 EASU / RCAS）。分两段比，每段容差 1 个 8 位级：
//       ① GPU 的 EASU 输出（中间图读回）对 CPU EASU(输入)；② GPU 的最终图对 CPU RCAS(GPU 的 EASU 输出)。
//     容差的来源：两边都把结果四舍五入到 8 位，着色器关了快速数学、算式次序与 CPU 参考相同，剩下的只是融合乘加 / 归一化读数的末位差落在舍入边界上翻一级。
//     RCAS 不直接对 CPU 的 EASU 结果比：EASU 差 1 级经 RCAS 最多放大到 1 / (1 − 0.75 × 系数) + 4 × 0.1875 × 系数 / (1 − 0.75 × 系数) 倍（缺省级别约 4 倍），容差就没意义了。
//   - 面积缩小那条路（来源超过视口 1.25 倍）：CPU 按「4 个双线性样本、偏移 ±1/4 输出像素」重算，容差 2（GPU 双线性权重是 8 位定点，每个样本至多差半级多，四个平均后再舍入）。
//   - 手算值：纯色不变；纯白在最大锐化下 = 254（APrxMedRcpF1(0.25) = 3.987388，(1 − 0.75) × 3.987388 × 255 = 254.2）；64 | 192 的竖直阶跃边两侧
//     在级别 100 / 80 / 0 下分别是 48 | 208、52 | 204、60 | 196（算式见 step_expect）；0 | 255 的阶跃边不变；级别到档数 / 系数的换算。
//   - 负对照：把着色器改错一处（EASU 的 25/16 改 24/16、采样偏半个输入像素、RCAS 改成原样输出、面积缩小改成单样本），对应那一段必须对不上。
#ifndef PRESENT_FSR_SOURCE
#define PRESENT_FSR_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include PRESENT_FSR_SOURCE
#include "fsr1_ref.h"

static unsigned checks, failures;
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failures += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

typedef struct { int w, h; uint8_t *px; } img;   // BGRA8
static img img_new(int w, int h) { img m = {w, h, calloc((size_t)w * h, 4)}; return m; }
static void put(img m, int x, int y, int r, int g, int b) { uint8_t *p = m.px + 4 * ((size_t)y * m.w + x); p[0] = (uint8_t)b; p[1] = (uint8_t)g; p[2] = (uint8_t)r; p[3] = 255; }
// 图样：渐变底 + 斜边 + 1 像素棋盘格 + 细线 + 纯黑 / 纯白 / 纯原色块（RCAS 的 NaN 通道）+ 伪随机噪声块。位置按尺寸比例摆
static img scene(int w, int h) {
    img m = img_new(w, h); uint32_t lcg = 12345;
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        double u = (x + 0.5) / w, v = (y + 0.5) / h; int r = (int)(40 + 160 * u), g = (int)(30 + 180 * v), b = (int)(60 + 120 * (u + v) / 2);
        if (u < 0.45 && v < 0.5) { int on = (x + 0.5) > 0.27 * (y + 0.5) + 0.12 * w; r = g = b = on ? 235 : 12; }               // 斜边
        else if (u > 0.5 && u < 0.72 && v < 0.3) { int c = (x + y) & 1; r = g = b = c ? 255 : 0; }                               // 棋盘格
        else if (u > 0.75 && v < 0.3) { int c = (x % 5) == 0 || (y % 7) == 0; r = c ? 250 : 20; g = c ? 240 : 30; b = c ? 90 : 200; }   // 细线
        else if (v > 0.55 && v < 0.8) { int k = (int)(u * 8);                                                                     // 纯色块
            static const int pal[8][3] = {{0, 0, 0}, {255, 255, 255}, {255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 0}, {0, 0, 0}, {255, 255, 255}};
            r = pal[k][0]; g = pal[k][1]; b = pal[k][2]; }
        else if (v >= 0.8 && u < 0.5) { lcg = lcg * 1664525u + 1013904223u; r = lcg >> 24; g = (lcg >> 16) & 255; b = (lcg >> 8) & 255; }   // 噪声
        put(m, x, y, r, g, b);
    }
    return m;
}
static img flat(int w, int h, int r, int g, int b) { img m = img_new(w, h); for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) put(m, x, y, r, g, b); return m; }
static img vstep(int w, int h, int lo, int hi) { img m = img_new(w, h); for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { int v = x < w / 2 ? lo : hi; put(m, x, y, v, v, v); } return m; }
// 裁剪 + 上下翻转后的规范图（上屏看到的那张）
static img canon(img s, const int crop[4], int flip) {
    int cx = crop ? crop[0] : 0, cy = crop ? crop[1] : 0, cw = crop ? crop[2] : s.w, ch = crop ? crop[3] : s.h; img m = img_new(cw, ch);
    for (int y = 0; y < ch; y++) memcpy(m.px + 4 * (size_t)y * cw, s.px + 4 * ((size_t)(cy + (flip ? ch - 1 - y : y)) * s.w + cx), 4 * (size_t)cw);
    return m;
}

static id<MTLTexture> tex_new(int w, int h, MTLPixelFormat pf) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView; d.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; res_add(t); return t;
}
static id<MTLTexture> tex_of(img m) { id<MTLTexture> t = tex_new(m.w, m.h, MTLPixelFormatBGRA8Unorm); [t replaceRegion:MTLRegionMake2D(0, 0, m.w, m.h) mipmapLevel:0 withBytes:m.px bytesPerRow:4 * (NSUInteger)m.w]; return t; }
// 读回任意存储方式的图（中间图是私有存储）：经典队列拷进共享缓冲
static img rd(id<MTLTexture> t) {
    img m = img_new((int)t.width, (int)t.height); NSUInteger row = 4 * t.width;
    id<MTLBuffer> b = [g_dev newBufferWithLength:row * t.height options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = g_m3 ? [g_q3 commandBuffer] : [g_q commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * t.height];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.error) { printf("SETUP FAIL 读回失败 %s\n", cb.error.description.UTF8String); exit(2); }
    memcpy(m.px, b.contents, row * t.height); return m;
}
// 一次真的上屏编码（离屏目标）。slot：0–2 出图槽，3 抓图槽。返回 GPU 时间（秒）；编码失败退出
static double g_gpu_s;
static void run_cb(int slot, int (^enc3)(id<MTLCommandBuffer> cb), int (^enc4)(id cb)) {
    if (g_m3 || slot == 3) {   // 抓图槽在两种后端上都走经典命令缓冲（同 grab_present）
        id<MTLCommandBuffer> cb = g_m3 ? [g_q3 commandBuffer] : [g_q commandBuffer];
        if (!enc3(cb)) { printf("SETUP FAIL 上屏编码返回 0\n"); exit(2); }
        [cb commit]; [cb waitUntilCompleted];
        if (cb.error) { printf("SETUP FAIL 命令缓冲出错 %s\n", cb.error.description.UTF8String); exit(2); }
        g_gpu_s = cb.GPUEndTime - cb.GPUStartTime; return;
    }
    [g_present_alloc4[slot] reset]; id<MTL4CommandBuffer> cb = g_present_cb[slot]; [cb beginCommandBufferWithAllocator:g_present_alloc4[slot]];
    int ok = enc4(cb); [cb endCommandBuffer];
    if (!ok) { printf("SETUP FAIL 上屏编码返回 0（Metal 4）\n"); exit(2); }
    dispatch_semaphore_t done = dispatch_semaphore_create(0); __block int bad = 0; __block double gpu = 0;
    id o = fb_new(); fb_add(o, ^(id<MTL4CommitFeedback> f) { bad = f.error != nil; gpu = f.GPUEndTime - f.GPUStartTime; dispatch_semaphore_signal(done); });
    res_commit(); id<MTL4CommandBuffer> b[] = {cb}; [g_q4 commit:b count:1 options:o];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) || bad) { printf("SETUP FAIL Metal 4 提交超时 / 出错\n"); exit(2); }
    g_gpu_s = gpu;
}
static img present(id<MTLTexture> src, int dw, int dh, const int crop[4], int flip, int slot) {
    id<MTLTexture> dst = tex_new(dw, dh, MTLPixelFormatBGRA8Unorm);
    atomic_store(&g_origin_ll, flip);
    run_cb(slot, ^int(id<MTLCommandBuffer> cb) { return present_encode_slot(cb, src, dst, crop, slot); }, ^int(id cb) { return present_encode_m4(cb, src, dst, crop, slot); });
    atomic_store(&g_origin_ll, 0);
    img m = rd(dst); res_remove(dst); return m;
}

static int diff(img a, img b, int tol, int *worst) {   // 超过容差的像素数（含不透明度不是 255 的）；尺寸不同 = −1
    *worst = 0; if (a.w != b.w || a.h != b.h) { *worst = 255; return -1; }
    int bad = 0;
    for (size_t i = 0; i < (size_t)a.w * a.h; i++) { int px = 0;
        for (int c = 0; c < 3; c++) { int d = abs(a.px[4 * i + c] - b.px[4 * i + c]); if (d > *worst) *worst = d; px |= d > tol; }
        bad += px || a.px[4 * i + 3] != 255; }
    return bad;
}
// CPU 参考：EASU（m 缩放到 ow×oh）、RCAS
static img ref_easu(img m, int ow, int oh, const fsr_ref_mut *mu) {
    float *in = fsr_ref_load8(m.px, m.w, m.h, 2), *out = malloc((size_t)ow * oh * 3 * sizeof *out); img r = img_new(ow, oh);
    fsr_ref_easu(in, m.w, m.h, out, ow, oh, mu); fsr_ref_store8(out, r.px, ow, oh, 2); free(in); free(out); return r;
}
static img ref_rcas(img m, float con) {
    float *in = fsr_ref_load8(m.px, m.w, m.h, 2), *out = malloc((size_t)m.w * m.h * 3 * sizeof *out); img r = img_new(m.w, m.h);
    fsr_ref_rcas(in, out, m.w, m.h, con); fsr_ref_store8(out, r.px, m.w, m.h, 2); free(in); free(out); return r;
}
static double bil(const img m, double sx, double sy, int c) {   // 钳边双线性，sx / sy 是纹素中心坐标系（纹素 i 的中心在 i）
    sx = fmax(0, fmin(m.w - 1, sx)); sy = fmax(0, fmin(m.h - 1, sy));
    int x0 = (int)floor(sx), y0 = (int)floor(sy), x1 = x0 + 1 < m.w ? x0 + 1 : m.w - 1, y1 = y0 + 1 < m.h ? y0 + 1 : m.h - 1; double fx = sx - x0, fy = sy - y0;
    #define P(x, y) m.px[4 * ((size_t)(y) * m.w + (x)) + c]
    double v = (P(x0, y0) * (1 - fx) + P(x1, y0) * fx) * (1 - fy) + (P(x0, y1) * (1 - fx) + P(x1, y1) * fx) * fy;
    #undef P
    return v;
}
static img ref_bilinear(img m, int ow, int oh) {   // 像素中心对齐的双线性（原上屏拷贝）
    img r = img_new(ow, oh);
    for (int y = 0; y < oh; y++) for (int x = 0; x < ow; x++) { uint8_t *p = r.px + 4 * ((size_t)y * ow + x);
        for (int c = 0; c < 3; c++) p[c] = (uint8_t)lround(bil(m, (x + 0.5) * m.w / ow - 0.5, (y + 0.5) * m.h / oh - 0.5, c)); p[3] = 255; }
    return r;
}
static img ref_area4(img m, int ow, int oh, int taps) {   // 4 个双线性样本，偏移 ±1/4 输出像素（taps = 0：单样本，负对照的期望）
    img r = img_new(ow, oh); double rx = (double)m.w / ow, ry = (double)m.h / oh;
    for (int y = 0; y < oh; y++) for (int x = 0; x < ow; x++) { uint8_t *p = r.px + 4 * ((size_t)y * ow + x);
        for (int c = 0; c < 3; c++) { double a = 0;
            for (int j = -1; j <= 1; j += 2) for (int i = -1; i <= 1; i += 2) a += bil(m, (x + 0.5) * rx - 0.5 + (taps ? i * rx / 4 : 0), (y + 0.5) * ry - 0.5 + (taps ? j * ry / 4 : 0), c);
            p[c] = (uint8_t)lround(a / 4); }
        p[3] = 255; }
    return r;
}
// 把着色器源码改一处重编一条管线（负对照）。找不到要改的那段 = 对照失效，返回 nil
static id<MTLRenderPipelineState> mutant(const char *find, const char *repl, NSString *fn) {
    NSString *src = @(k_present_fsr_msl);
    if ([src componentsSeparatedByString:@(find)].count != 2) return nil;   // 恰好出现一次
    NSError *e = nil; id<MTLLibrary> lib = present_fsr_library([src stringByReplacingOccurrencesOfString:@(find) withString:@(repl)].UTF8String, &e);
    id<MTLRenderPipelineState> p = lib ? present_fsr_pso(lib, fn, &e) : nil;
    if (!p) printf("  （改错的着色器没编过：%s）\n", e ? e.localizedDescription.UTF8String : "?");
    return p;
}
// 64 | 192 竖直阶跃边、RCAS 系数 con：边两侧紧邻的两列的手算期望。暗侧像素：上下左同为 a、右邻 b；每通道 mn4 = a、mx4 = b，
//   hitMin = a / (4b)，hitMax = (1 − b) / (4a − 4)，lobe = max(−hitMin, hitMax)（夹在 −0.1875…0）× con，结果 = (lobe × (3a + b) + a) / (1 + 4 lobe)。亮侧对称：(lobe × (3b + a) + b) / (1 + 4 lobe)
static void step_expect(double con, double *dark, double *bright) {
    double a = 64 / 255.0, b = 192 / 255.0, hitMin = a / (4 * b), hitMax = (1 - b) / (4 * a - 4), lobe = fmax(-0.1875, fmin(fmax(-hitMin, hitMax), 0)) * con;
    *dark = (lobe * (3 * a + b) + a) / (1 + 4 * lobe) * 255; *bright = (lobe * (3 * b + a) + b) / (1 + 4 * lobe) * 255;
}

static double median(double *v, int n) { for (int i = 1; i < n; i++) { double x = v[i]; int j = i - 1; while (j >= 0 && v[j] > x) { v[j + 1] = v[j]; j--; } v[j + 1] = x; } return v[n / 2]; }
// 开销读数：真上屏编码的 GPU 时间（命令缓冲 / 提交反馈的 GPUEndTime − GPUStartTime），每种 41 次取中位与最小；对照是同一来源只做原来那次双线性上屏拷贝
static void bench(void) {
    const int cases[][4] = {{1280, 720, 2420, 1362}, {2560, 1440, 2420, 1362}, {3840, 2160, 2420, 1362}}; enum { N = 41 };
    for (unsigned k = 0; k < sizeof cases / sizeof cases[0]; k++) {
        int sw = cases[k][0], sh = cases[k][1], dw = cases[k][2], dh = cases[k][3]; img s = scene(sw, sh); id<MTLTexture> src = tex_of(s), dst = tex_new(dw, dh, MTLPixelFormatBGRA8Unorm);
        static id<MTLBuffer> uv; static id tab; if (!uv) { uv = [g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared]; res_add(uv); tab = tab_new(1, 1, 1, NULL); }
        double fsr[N], base[N];
        for (int i = -8; i < N; i++) {   // 前 8 次热身
            run_cb(i & 1, ^int(id<MTLCommandBuffer> cb) { return present_encode_slot(cb, src, dst, NULL, i & 1); }, ^int(id cb) { return present_encode_m4(cb, src, dst, NULL, i & 1); });
            if (i >= 0) fsr[i] = g_gpu_s * 1000;
            run_cb(2, ^int(id<MTLCommandBuffer> cb) { return present_blit(cb, src, dst, NULL, NO, 1); }, ^int(id cb) { return present_blit_m4(cb, src, dst, NULL, uv, tab, NO, 1); });
            if (i >= 0) base[i] = g_gpu_s * 1000;
        }
        double fmin_ = fsr[0], bmin = base[0]; for (int i = 1; i < N; i++) { if (fsr[i] < fmin_) fmin_ = fsr[i]; if (base[i] < bmin) bmin = base[i]; }
        printf("开销 %s %s：%dx%d → %dx%d（%s）FSR 整条 GPU 中位 %.3f ms / 最小 %.3f ms；只双线性拷贝 中位 %.3f ms / 最小 %.3f ms（各 %d 次）\n", g_m3 ? "Metal 3" : "Metal 4", g_present_aa ? "带抗锯齿" : "不带抗锯齿",
               sw, sh, dw, dh, present_fsr_down(sw, sh, dw, dh) ? "面积缩小 + RCAS" : "EASU + RCAS", median(fsr, N), fmin_, median(base, N), bmin, N);
        res_remove(src); res_remove(dst); free(s.px);
    }
}

int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_ARCHIVE", "0", 1); setenv("S2A_SCALING_FILTER", "Fsr", 1);
    if (!getenv("S2A_ANTI_ALIASING")) setenv("S2A_ANTI_ALIASING", "None", 1);
    // ⓪ 不碰 GPU 的换算（手算）：级别解析、级别 → 档数 → 系数
    { static const struct { const char *s; int want; } t[] = {{"0", 0}, {"80", 80}, {"100", 100}, {"7", 7}, {"101", -1}, {"-1", -1}, {"80.5", -1}, {"", -1}, {"abc", -1}, {"1000", -1}, {" 80", -1}, {"080", 80}};
      int bad = 0; for (unsigned i = 0; i < sizeof t / sizeof t[0]; i++) bad += present_fsr_level_parse(t[i].s) != t[i].want;
      CHECK(bad == 0 && present_fsr_level_parse(NULL) == -1, "⓪ S2A_SCALING_FILTER_LEVEL 解析：12 例里 %d 例不符（0…100 的整数才收）", bad);
      CHECK(fabsf(present_fsr_stops(80) - 0.3f) < 1e-6f && present_fsr_stops(100) == 0 && fabsf(present_fsr_stops(0) - 1.49985f) < 1e-6f,
            "⓪ 级别 → RCAS 衰减档数（Ryujinx：1.5 − 级别 × 0.01 × 1.5，级别下限 0.01）：80 → %.5f（期望 0.3），100 → %.5f（期望 0），0 → %.5f（期望 1.49985）", present_fsr_stops(80), present_fsr_stops(100), present_fsr_stops(0));
      CHECK(strstr(k_present_fsr_msl, "Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.") && strstr(k_present_fsr_msl, "Permission is hereby granted, free of charge") &&
            strstr(k_present_fsr_msl, "Copyright (c) 2014 Michal Drobot") && strstr(k_present_fsr_msl, "THE SOFTWARE IS PROVIDED \"AS IS\""),
            "⓪ 着色器源码（编进二进制的那份）带 AMD 与 Michal Drobot 的版权和 MIT 许可声明"); }
    mtl_init();
    if (argc > 1 && !strcmp(argv[1], "init")) { printf("INIT OK\n"); return 0; }   // 构建规则带非法的 S2A_SCALING_FILTER_LEVEL 跑：必须死在 mtl_init 里（起局），到不了这行，也没读过 present_options
    present_options();
    int aa = g_present_aa != 0; const char *be = g_m3 ? "Metal 3" : "Metal 4";
    printf("后端 %s，抗锯齿 %s，FSR 系数 %.4f\n", be, aa ? getenv("S2A_ANTI_ALIASING") : "无", g_present_fsr_con);
    if (argc > 1 && !strcmp(argv[1], "level")) { printf("LEVEL %.0f con=%.6f\n", g_present_fsr_level, g_present_fsr_con); return 0; }   // 构建规则带 S2A_SCALING_FILTER_LEVEL 跑：核环境变量真的进了系数
    if (argc > 1 && !strcmp(argv[1], "bench")) { bench(); return 0; }
    CHECK(g_present_fsr == 1 && !g_present_fx && !g_present_nearest && fabsf(g_present_fsr_con - 0.812252f) < 1e-5f, "⓪ S2A_SCALING_FILTER=Fsr 认出，缺省级别 80 → 系数 %.6f（期望 2^-0.3 = 0.812252）", g_present_fsr_con);
    float con80 = fsr_ref_rcas_con(80); int worst = 0, bad = 0;

    // ① 放大（96×54 → 182×102，比例同 720p → 1362p）、近 1:1 缩小（128×72 → 121×68，比例同 2560×1440 → 2420×1362）、1:1（64×36）。
    //    不带抗锯齿时来源就是 EASU 的输入；带抗锯齿时 EASU 的输入是抗锯齿的输出（读回），抗锯齿在来源尺寸做（先抗锯齿、后缩放）
    static const int up[][4] = {{96, 54, 182, 102}, {128, 72, 121, 68}, {64, 36, 64, 36}};
    for (int k = 0; k < 3; k++) { int sw = up[k][0], sh = up[k][1], dw = up[k][2], dh = up[k][3]; img s = scene(sw, sh); id<MTLTexture> src = tex_of(s);
        img out = present(src, dw, dh, NULL, 0, k); NvPresentFSR *f = g_present_fsr_slots[k];
        CHECK(f && f->mid && f->ow == (NSUInteger)dw && f->oh == (NSUInteger)dh && !present_fsr_down(sw, sh, dw, dh), "① %dx%d → %dx%d：本槽建了 FSR 中间图，走 EASU", sw, sh, dw, dh);
        if (!f || !f->mid) exit(1);
        img mid = rd(f->mid), in = s;
        if (aa) { NvPresentAA *a = g_present_aa_slots[k]; CHECK(a && a->input.width == (NSUInteger)sw && a->input.height == (NSUInteger)sh, "① 抗锯齿在来源尺寸做：中间图 %lux%lu（期望 %dx%d）", (unsigned long)a->input.width, (unsigned long)a->input.height, sw, sh);
            in = rd(a->output); bad = diff(in, s, 0, &worst); CHECK(bad > 0, "① 抗锯齿确实改了画面：%d 像素与来源不同（最大差 %d）", bad, worst); }
        img e = ref_easu(in, dw, dh, NULL); bad = diff(mid, e, 1, &worst);
        CHECK(bad == 0, "① %dx%d → %dx%d EASU：GPU 中间图对 CPU 参考，超过 1 级的像素 %d / %d（最大差 %d）", sw, sh, dw, dh, bad, dw * dh, worst);
        img r = ref_rcas(mid, con80); bad = diff(out, r, 1, &worst);
        CHECK(bad == 0, "① %dx%d → %dx%d RCAS：GPU 最终图对 CPU RCAS(GPU 的 EASU 输出)，超过 1 级的像素 %d / %d（最大差 %d）", sw, sh, dw, dh, bad, dw * dh, worst);
        img bl = ref_bilinear(in, dw, dh); bad = diff(out, bl, 1, &worst);
        CHECK(bad > dw * dh / 20, "① %dx%d → %dx%d 结果确实不是双线性：%d / %d 像素差超过 1 级（最大差 %d）", sw, sh, dw, dh, bad, dw * dh, worst);
        res_remove(src); }

    // ② 手算性质（不带抗锯齿时才判：抗锯齿不改纯色与竖直边，但这里要的是 FSR 自己的读数）
    if (!aa) {
        static const int cols[][3] = {{0, 0, 0}, {255, 255, 255}, {29, 79, 153}, {255, 0, 0}, {0, 255, 255}}; int off = 0, w254 = -1;
        for (int k = 0; k < 5; k++) for (int big = 0; big < 2; big++) { img s = flat(40, 24, cols[k][0], cols[k][1], cols[k][2]); id<MTLTexture> src = tex_of(s);
            img out = present(src, big ? 76 : 40, big ? 46 : 24, NULL, 0, 0);
            for (size_t i = 0; i < (size_t)out.w * out.h; i++) off += abs(out.px[4 * i + 2] - cols[k][0]) > 1 || abs(out.px[4 * i + 1] - cols[k][1]) > 1 || abs(out.px[4 * i] - cols[k][2]) > 1 || out.px[4 * i + 3] != 255;
            res_remove(src); }
        CHECK(off == 0, "② 纯色进 = 纯色出（黑 / 白 / 蓝灰 / 纯红 / 青，放大与 1:1 各一次，容差 1）：%d 像素不符", off);
        { float keep = g_present_fsr_con; g_present_fsr_con = exp2f(-present_fsr_stops(100)); img s = flat(40, 24, 255, 255, 255); id<MTLTexture> src = tex_of(s); img out = present(src, 40, 24, NULL, 0, 0);
          w254 = out.px[4 * (12 * 40 + 20) + 1]; g_present_fsr_con = keep; res_remove(src);
          CHECK(w254 == 254, "② 纯白在级别 100（系数 1）下 = %d（手算 254：APrxMedRcpF1(0.25) = 3.987388，0.25 × 3.987388 × 255 = 254.2）", w254); }
        static const float lv[3] = {100, 80, 0}; int got[3][2];
        for (int k = 0; k < 3; k++) { float keep = g_present_fsr_con; g_present_fsr_con = exp2f(-present_fsr_stops(lv[k]));
            img s = vstep(64, 36, 64, 192); id<MTLTexture> src = tex_of(s); img out = present(src, 64, 36, NULL, 0, 0); img mid = rd(g_present_fsr_slots[0]->mid);
            double d, b; step_expect(g_present_fsr_con, &d, &b); got[k][0] = out.px[4 * (18 * 64 + 31)]; got[k][1] = out.px[4 * (18 * 64 + 32)];
            int far = 0; for (int y = 2; y < 34; y++) for (int x = 0; x < 64; x++) if (x != 31 && x != 32) far += abs(out.px[4 * (y * 64 + x)] - (x < 32 ? 64 : 192)) > 1;   // 平坦处：值 × (1 + 4 lobe) × 近似倒数，近似倒数偏小至多约 0.4%
            if (!k) { bad = diff(mid, s, 0, &worst); CHECK(bad == 0, "② 1:1 下竖直阶跃边过 EASU 不变（去振铃夹回 2×2 邻域的最小 / 最大）：%d 像素不同", bad); }
            CHECK(abs(got[k][0] - (int)lround(d)) <= 1 && abs(got[k][1] - (int)lround(b)) <= 1 && far == 0,
                  "② 64 | 192 阶跃边，级别 %.0f：边两侧 %d | %d（手算 %.2f | %.2f，容差 1），离边的像素 %d 个偏离原值超过 1", lv[k], got[k][0], got[k][1], d, b, far);
            g_present_fsr_con = keep; res_remove(src); }
        CHECK(got[0][0] < got[1][0] && got[1][0] < got[2][0] && got[0][1] > got[1][1] && got[1][1] > got[2][1], "② 级别越高锐化越强：暗侧 %d < %d < %d，亮侧 %d > %d > %d（级别 100 / 80 / 0）", got[0][0], got[1][0], got[2][0], got[0][1], got[1][1], got[2][1]);
        // 0 | 255 的阶跃边：两侧 lobe 都是 0（限幅：再锐化就溢出 0…1），暗侧 = 0；亮侧紧邻边的一列 = 255 × APrxMedRcpF1(1) = 255 × 0.996847 = 254.2 → 254，其余容差 1
        { img s = vstep(64, 36, 0, 255); id<MTLTexture> src = tex_of(s); img out = present(src, 64, 36, NULL, 0, 0); bad = diff(out, s, 1, &worst); int dark = 0, edge = 0;
          for (int y = 0; y < 36; y++) { for (int x = 0; x < 32; x++) dark += out.px[4 * (y * 64 + x)] != 0; edge += out.px[4 * (y * 64 + 32)] != 254; }
          CHECK(bad == 0 && dark == 0 && edge == 0, "② 0 | 255 阶跃边不被锐化：偏离超过 1 的像素 %d，暗侧非 0 的 %d，亮侧紧邻边那列不是手算 254 的 %d", bad, dark, edge); res_remove(src); }
    }

    // ③ 裁剪 + 上下翻转、sRGB 来源：EASU 直接读窗口贴图（裁剪起点、钳边、翻转都在着色器里），结果应等于规范图（先裁剪翻转好的那张）的结果
    { img big = scene(79, 61); int crop[4] = {5, 4, 64, 36}; id<MTLTexture> src = tex_of(big);
      for (int flip = 0; flip < 2; flip++) { img c = canon(big, crop, flip); id<MTLTexture> ct = tex_of(c);
          img got = present(src, 121, 68, crop, flip, 1), want = present(ct, 121, 68, NULL, 0, 2);
          bad = diff(got, want, aa ? 1 : 0, &worst); CHECK(bad == 0, "③ 裁剪 5,4 64x36%s → 121x68 等于规范图的结果：%d 像素不同（最大差 %d）", flip ? " + 上下翻转" : "", bad, worst);
          if (!aa) { img e = ref_easu(c, 121, 68, NULL), mid = rd(g_present_fsr_slots[1]->mid); bad = diff(mid, e, 1, &worst);
              CHECK(bad == 0, "③ 裁剪%s 的 EASU 对 CPU 参考（越界钳到裁剪边，不读裁剪外的纹素）：超过 1 级 %d（最大差 %d）", flip ? " + 翻转" : "", bad, worst); }
          res_remove(ct); }
      img plain = scene(64, 36); id<MTLTexture> pt = tex_of(plain), sv = [pt newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB]; res_add(sv);
      img a = present(pt, 121, 68, NULL, 0, 0), b = present(sv, 121, 68, NULL, 0, 0); bad = diff(a, b, 0, &worst);
      CHECK(bad == 0, "③ sRGB 格式的来源按存储原字节过 FSR（与同字节的非 sRGB 来源逐像素相同）：%d 像素不同（最大差 %d）", bad, worst);
      res_remove(src); res_remove(pt); res_remove(sv); }

    // ④ 来源超过视口 1.25 倍：面积缩小 → [抗锯齿，视口尺寸] → RCAS，不走 EASU
    { static const int dn[][4] = {{128, 72, 80, 45}, {192, 108, 91, 51}};
      for (int k = 0; k < 2; k++) { int sw = dn[k][0], sh = dn[k][1], dw = dn[k][2], dh = dn[k][3]; img s = scene(sw, sh); id<MTLTexture> src = tex_of(s);
          img out = present(src, dw, dh, NULL, 0, k); NvPresentFSR *f = g_present_fsr_slots[k]; NvPresentAA *a = aa ? g_present_aa_slots[k] : nil;
          CHECK(present_fsr_down(sw, sh, dw, dh) && f && (aa ? !f->mid || f->has_mid : f->mid != nil), "④ %dx%d → %dx%d（%.2f 倍）走面积缩小", sw, sh, dw, dh, (double)sw / dw);
          if (aa) CHECK(a && a->input.width == (NSUInteger)dw && a->input.height == (NSUInteger)dh, "④ 抗锯齿在视口尺寸做：中间图 %lux%lu（期望 %dx%d）", (unsigned long)a->input.width, (unsigned long)a->input.height, dw, dh);
          img down = rd(aa ? a->input : f->mid), want = ref_area4(s, dw, dh, 1); bad = diff(down, want, 2, &worst);
          CHECK(bad == 0, "④ %dx%d → %dx%d 面积缩小：GPU 对 CPU 的 4 样本参考，超过 2 级的像素 %d / %d（最大差 %d）", sw, sh, dw, dh, bad, dw * dh, worst);
          img one = ref_area4(s, dw, dh, 0); bad = diff(down, one, 2, &worst); CHECK(bad > dw * dh / 20, "④ 面积缩小确实不是单个双线性样本：%d / %d 像素差超过 2 级", bad, dw * dh);
          img r = ref_rcas(aa ? rd(a->output) : down, con80); bad = diff(out, r, 1, &worst);
          CHECK(bad == 0, "④ %dx%d → %dx%d RCAS：GPU 最终图对 CPU RCAS(它的输入)，超过 1 级的像素 %d / %d（最大差 %d）", sw, sh, dw, dh, bad, dw * dh, worst);
          res_remove(src); }
      // 裁剪 + 翻转也走得对
      img big = scene(140, 84); int crop[4] = {6, 5, 128, 72}; id<MTLTexture> src = tex_of(big); img c = canon(big, crop, 1); id<MTLTexture> ct = tex_of(c);
      // 分段比（最终图不直接比：缩小那段差 1 级经 RCAS 会放大）
      img got = present(src, 80, 45, crop, 1, 0), gd = rd(aa ? g_present_aa_slots[0]->input : g_present_fsr_slots[0]->mid); bad = diff(gd, ref_area4(c, 80, 45, 1), 2, &worst);
      CHECK(bad == 0, "④ 面积缩小带裁剪 6,5 128x72 + 上下翻转：GPU 对规范图的 CPU 4 样本参考，超过 2 级的像素 %d（最大差 %d）", bad, worst);
      bad = diff(got, ref_rcas(aa ? rd(g_present_aa_slots[0]->output) : gd, con80), 1, &worst); CHECK(bad == 0, "④ 其后的 RCAS 对 CPU 参考：超过 1 级的像素 %d（最大差 %d）", bad, worst); res_remove(src); res_remove(ct);
      CHECK(present_fsr_down(2560, 1440, 2420, 1362) == 0 && present_fsr_down(2880, 1620, 2420, 1362) == 0 && present_fsr_down(3840, 2160, 2420, 1362) == 1 && present_fsr_down(5120, 2880, 2420, 1362) == 1 &&
            present_fsr_down(1280, 720, 2420, 1362) == 0 && present_fsr_down(3025, 1702, 2420, 1362) == 0 && present_fsr_down(3026, 1702, 2420, 1362) == 1,
            "④ 1.25 倍的分界：2560 / 2880 / 1280 / 3025 宽 → 2420 走 EASU，3026 / 3840 / 5120 宽走面积缩小"); }

    // ⑤ 截图 / 抓图（3 号槽）不过 FSR：与双线性参考一致、与 FSR 的结果不同
    { img s = scene(96, 54); id<MTLTexture> src = tex_of(s); img grab = present(src, 182, 102, NULL, 0, 3), fsr = present(src, 182, 102, NULL, 0, 0);
      NvPresentFSR *none = g_present_fsr_slots[3];
      if (!aa) { img bl = ref_bilinear(s, 182, 102); bad = diff(grab, bl, 1, &worst); CHECK(bad == 0, "⑤ 3 号槽（截图 / 抓图）是双线性：对 CPU 双线性参考超过 1 级的像素 %d（最大差 %d）", bad, worst); }
      bad = diff(grab, fsr, 1, &worst); CHECK(bad > 182 * 102 / 20 && !none, "⑤ 3 号槽不带 FSR：与 FSR 上屏结果有 %d 像素不同，没建 FSR 槽", bad); res_remove(src); }

    // ⑥ 负对照：把着色器改错一处，对应那一段必须对不上（改不动 = 对照失效，也算不过）
    if (!aa) { img s = scene(96, 54); id<MTLTexture> src = tex_of(s); img e = ref_easu(s, 182, 102, NULL); id<MTLRenderPipelineState> keep, m;
        keep = g_fsr_pso[1]; m = mutant("float(25.0 / 16.0) * wB + float(-(25.0 / 16.0 - 1.0))", "float(24.0 / 16.0) * wB + float(-(24.0 / 16.0 - 1.0))", @"fsr_easu");
        if (m) { g_fsr_pso[1] = m; (void)present(src, 182, 102, NULL, 0, 0); bad = diff(rd(g_present_fsr_slots[0]->mid), e, 1, &worst); g_fsr_pso[1] = keep; }
        CHECK(m && bad > 0, "⑥ 负对照 EASU 系数 25/16 → 24/16：对 CPU 参考超过 1 级的像素 %d（应 > 0，最大差 %d）", m ? bad : -1, worst);
        fsr_ref_mut mu = {24.0f / 16.0f, 0}; img e2 = ref_easu(s, 182, 102, &mu); if (m) { g_fsr_pso[1] = m; (void)present(src, 182, 102, NULL, 0, 0); bad = diff(rd(g_present_fsr_slots[0]->mid), e2, 1, &worst); g_fsr_pso[1] = keep; }
        CHECK(m && bad == 0, "⑥ 同一处改法放进 CPU 参考后又对上（证明红的就是这个系数）：%d 像素（最大差 %d）", m ? bad : -1, worst);
        m = mutant("floor(in.p.xy) * c.con0.xy + c.con0.zw", "floor(in.p.xy) * c.con0.xy + c.con0.zw + 0.5", @"fsr_easu");
        if (m) { g_fsr_pso[1] = m; (void)present(src, 182, 102, NULL, 0, 0); bad = diff(rd(g_present_fsr_slots[0]->mid), e, 1, &worst); g_fsr_pso[1] = keep; }
        CHECK(m && bad > 182 * 102 / 20, "⑥ 负对照 采样偏半个输入像素：对 CPU 参考超过 1 级的像素 %d / %d（最大差 %d）", m ? bad : -1, 182 * 102, worst);
        keep = g_fsr_pso[2]; m = mutant("return float4((lobe * b + lobe * d + lobe * h + lobe * f + e) * rcpL, 1.0); }", "return float4(e, 1.0); }", @"fsr_rcas");
        if (m) { g_fsr_pso[2] = m; img out = present(src, 182, 102, NULL, 0, 0); bad = diff(out, ref_rcas(rd(g_present_fsr_slots[0]->mid), con80), 1, &worst); g_fsr_pso[2] = keep; }
        CHECK(m && bad > 0, "⑥ 负对照 跳过 RCAS（原样输出）：最终图对 CPU RCAS 超过 1 级的像素 %d（应 > 0，最大差 %d）", m ? bad : -1, worst);
        img s2 = scene(128, 72); id<MTLTexture> src2 = tex_of(s2); keep = g_fsr_pso[0]; m = mutant("  return float4(a * 0.25, 1); }", "  return float4(t.sample(s, clamp(uv, c.edge.xy, c.edge.zw)).rgb, 1); }", @"fsr_down");
        if (m) { g_fsr_pso[0] = m; (void)present(src2, 80, 45, NULL, 0, 0); bad = diff(rd(g_present_fsr_slots[0]->mid), ref_area4(s2, 80, 45, 1), 2, &worst); g_fsr_pso[0] = keep; }
        CHECK(m && bad > 0, "⑥ 负对照 面积缩小改成单样本：对 CPU 的 4 样本参考超过 2 级的像素 %d（应 > 0，最大差 %d）", m ? bad : -1, worst);
        res_remove(src); res_remove(src2); }

    // ⑦ 出图补帧用的 4 / 5 号槽（只有 Metal 4；不做抗锯齿，上屏拷贝用调用方给的裁剪参数缓冲与参数表；槽挂在「这一代补帧对象」上，这里拿普通对象当一代）：
    //   结果与出图槽逐像素相同；不带那一代对象调补帧槽、或带着对象调出图槽 = 用法错，返回 −1 不动任何槽
    if (!g_m3 && !aa) { img s = scene(96, 54); id<MTLTexture> src = tex_of(s); img want = present(src, 182, 102, NULL, 0, 0);
        id<MTLBuffer> uv = [g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared]; res_add(uv); id tab = tab_new(1, 1, 1, NULL); NSObject *gen = [NSObject new];
        for (int slot = FSR_SLOT_FI_MID; slot <= FSR_SLOT_FI_REAL; slot++) { id<MTLTexture> dst = tex_new(182, 102, MTLPixelFormatBGRA8Unorm);
            run_cb(0, nil, ^int(id cb) { return present_fsr_encode(cb, src, dst, NULL, slot, NO, YES, 0, uv, tab, gen); });
            bad = diff(rd(dst), want, 0, &worst); CHECK(bad == 0 && present_fsr_slot_get(slot, gen) && !g_present_fsr_slots[slot], "⑦ 补帧的 %d 号槽过 FSR，结果与出图槽相同：%d 像素不同；槽挂在这一代对象上、不在全局表里", slot, bad); res_remove(dst); }
        { id<MTLTexture> dst = tex_new(182, 102, MTLPixelFormatBGRA8Unorm); __block int r1 = 9, r2 = 9;
          run_cb(0, nil, ^int(id cb) { r1 = present_fsr_encode(cb, src, dst, NULL, FSR_SLOT_FI_MID, NO, YES, 0, uv, tab, nil); r2 = present_fsr_encode(cb, src, dst, NULL, 1, NO, YES, 0, uv, tab, gen); return 1; });
          CHECK(r1 == -1 && r2 == -1, "⑦ 补帧槽不带那一代对象 → %d、出图槽带对象 → %d（期望都是 −1）", r1, r2); res_remove(dst); }

        // ⑩ 出图补帧整个重建（游戏画面尺寸变了）：新旧两代各有自己的命令槽信号量，旧的一代的提交可能还在 GPU 上、旧任务还可能再编一次。
        //   两代共用一份全局 FSR 槽的话，新的一代换个视口尺寸一编，旧的一代还在用的图就被摘出驻留集（Metal 4 的命令缓冲不保留资源 → GPU 读到不在驻留的内存）。
        //   判据：新的一代编过之后，旧的一代的槽对象还是原来那个、图还是原来那几张且仍在驻留集；旧的一代再编一次结果照旧对；
        //   旧的一代放掉后图进延后释放队列（围栏 = 下一次游戏提交）、当场仍在驻留集；那次提交做完（这里把完成水位推到围栏）后才摘
        int (^resident)(id) = ^int(id o) { pthread_mutex_lock(&g_res_mu); int in = [g_res_objects containsObject:o]; pthread_mutex_unlock(&g_res_mu); return in; };
        __block id<MTLTexture> aout = nil, amid = nil; NSObject *genB = [NSObject new]; id<MTLTexture> dstA = tex_new(182, 102, MTLPixelFormatBGRA8Unorm), dstB = tex_new(121, 68, MTLPixelFormatBGRA8Unorm);
        @autoreleasepool { NSObject *genA = [NSObject new];
            run_cb(0, nil, ^int(id cb) { return present_fsr_encode(cb, src, dstA, NULL, FSR_SLOT_FI_MID, NO, YES, 0, uv, tab, genA); });
            NvPresentFSR *fa = present_fsr_slot_get(FSR_SLOT_FI_MID, genA); aout = fa->output; amid = fa->mid;
            run_cb(1, nil, ^int(id cb) { return present_fsr_encode(cb, src, dstB, NULL, FSR_SLOT_FI_MID, NO, YES, 0, uv, tab, genB); });
            NvPresentFSR *fb = present_fsr_slot_get(FSR_SLOT_FI_MID, genB), *fa2 = present_fsr_slot_get(FSR_SLOT_FI_MID, genA);
            CHECK(fa && fb && fa != fb && fa2 == fa && fa->output == aout && fa->ow == 182 && fb->ow == 121 && resident(aout) && resident(amid),
                  "⑩ 新的一代用另一个视口（121x68）编过之后：旧的一代的槽对象%s、视口 %lux%lu（期望 182x102），它的输出图%s驻留集、中间图%s驻留集",
                  fa2 == fa && fa != fb ? "还是原来那个" : "被换掉了", (unsigned long)fa2->ow, (unsigned long)fa2->oh, resident(aout) ? "仍在" : "已被摘出", resident(amid) ? "仍在" : "已被摘出");
            run_cb(0, nil, ^int(id cb) { return present_fsr_encode(cb, src, dstA, NULL, FSR_SLOT_FI_MID, NO, YES, 0, uv, tab, genA); });
            bad = diff(rd(dstA), want, 0, &worst); CHECK(bad == 0 && present_fsr_slot_get(FSR_SLOT_FI_MID, genA)->output == aout, "⑩ 旧的一代在新的一代之后再编一次：结果与出图槽相同（%d 像素不同），没有重建", bad);
        }   // 旧的一代在这里放掉
        { int queued = 0; uint64_t fence = 0; pthread_mutex_lock(&g_deferred_mu); for (NvDeferredRelease *d in g_deferred) if (d->object == aout || d->object == amid) { queued++; fence = d->fence; } pthread_mutex_unlock(&g_deferred_mu);
          CHECK(queued == 2 && fence == g_fence + 1 && resident(aout) && resident(amid), "⑩ 旧的一代放掉后：两张图进延后释放队列 %d 张（期望 2），围栏 %llu（期望下一次游戏提交 %llu），当场%s驻留集",
                queued, (unsigned long long)fence, (unsigned long long)g_fence + 1, resident(aout) && resident(amid) ? "仍在" : "已被摘出");
          pthread_mutex_lock(&g_mu); uint64_t keep = g_done; g_done = g_fence + 1; pthread_mutex_unlock(&g_mu); defer_drain();
          CHECK(!resident(aout) && !resident(amid), "⑩ 那次提交做完后才摘出驻留集：输出图%s、中间图%s", resident(aout) ? "还在" : "已摘", resident(amid) ? "还在" : "已摘");
          pthread_mutex_lock(&g_mu); g_done = keep; pthread_mutex_unlock(&g_mu); }
        res_remove(src); res_remove(dstA); res_remove(dstB); }

    // ⑧ 做不了时退回双线性：管线建不出之后（状态 −1），上屏结果 = 原来的双线性
    if (!aa) { int keep = g_fsr_state; g_fsr_state = -1; img s = scene(96, 54); id<MTLTexture> src = tex_of(s); img out = present(src, 182, 102, NULL, 0, 0); g_fsr_state = keep;
        bad = diff(out, ref_bilinear(s, 182, 102), 1, &worst); CHECK(bad == 0, "⑧ FSR 管线建不出时上屏照旧双线性：对 CPU 双线性参考超过 1 级的像素 %d（最大差 %d）", bad, worst); res_remove(src); }

    // ⑨ 画布比画面宽 / 高（有黑边）：FSR 按视口尺寸出图，最后那次上屏是 1:1 拷贝——视口里逐字节等于 FSR 的输出图，视口外是黑。视口是手算的
    //   （pf_viewport 的式子：s = min(dw / cw, dh / ch)，尺寸四舍五入、原点向下取整；画幅相差不到 1% 才铺满）：
    //   96×54 → 200×150：s = 2.0833，200×112.5 → 200×113，y = ⌊18.75⌋ = 18；96×54 → 260×102：s = 1.8889，181.33×102 → 181×102，x = ⌊39.33⌋ = 39；
    //   1267×720 → 1920×1080：画幅差 1.03%（不铺满），s = 1.5，1900.5×1080 → 1901×1080，x = ⌊9.75⌋ = 9。最后这组守「上屏拷贝不许拿取整后的 1901×1080 再算一次视口」：
    //   1920/1080 ÷ 1901/1080 = 1.00999 < 1%，再算一次就成了铺满，画面被横向拉宽、黑边没了
    { static const int lb[][8] = {{96, 54, 200, 150, 0, 18, 200, 113}, {96, 54, 260, 102, 39, 0, 181, 102}, {1267, 720, 1920, 1080, 9, 0, 1901, 1080}};
      for (int k = 0; k < 3; k++) { int sw = lb[k][0], sh = lb[k][1], dw = lb[k][2], dh = lb[k][3], vx = lb[k][4], vy = lb[k][5], vw = lb[k][6], vh = lb[k][7];
          img s = scene(sw, sh); id<MTLTexture> src = tex_of(s); img out = present(src, dw, dh, NULL, 0, 0); NvPresentFSR *f = g_present_fsr_slots[0]; img fo = rd(f->output); int in_bad = 0, bar_bad = 0;
          if ((int)fo.w == vw && (int)fo.h == vh) for (int y = 0; y < dh; y++) for (int x = 0; x < dw; x++) { const uint8_t *p = out.px + 4 * ((size_t)y * dw + x);
              if (x >= vx && x < vx + vw && y >= vy && y < vy + vh) in_bad += memcmp(p, fo.px + 4 * ((size_t)(y - vy) * vw + (x - vx)), 3) != 0; else bar_bad += p[0] || p[1] || p[2]; }
          CHECK((int)f->ow == vw && (int)f->oh == vh && in_bad == 0 && bar_bad == 0, "⑨ %dx%d → 画布 %dx%d，手算视口 %d,%d %dx%d：FSR 输出 %lux%lu，视口内与它不同的像素 %d，黑边里非黑的像素 %d / %d", sw, sh, dw, dh, vx, vy, vw, vh, (unsigned long)f->ow, (unsigned long)f->oh, in_bad, bar_bad, dw * dh - vw * vh);
          res_remove(src); free(s.px); free(out.px); free(fo.px); } }

    printf("%s t_present_fsr（%s，抗锯齿 %s）：%u 项，%u 项不符\n", failures ? "✗" : "✓", be, aa ? getenv("S2A_ANTI_ALIASING") : "无", checks, failures);
    return failures != 0;
} }
