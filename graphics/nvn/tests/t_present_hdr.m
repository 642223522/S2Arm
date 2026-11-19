// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// PR3b：present_mode 数学闭环 GPU 对拍（评审稿 v3 §2.4 模式矩阵 / §4 PR3b；形态照 nxnative #1176 的 t_present_hdr 适配本仓）。
//   生产 nvn_mtl.m 隔离编译进本单测（#include——真着色器上 GPU，present_encode 全链路）；前端替身按 t_nvn2 直调先例注入
//   （nvn2_hdr_snapshot_publish 合成快照 + nvn2_hdr_answer 同源答案入口直调 + setenv S2ARM_HDR，不照搬 nxnative 的 swforce 段）；
//   期望值 CPU 双精度复算（本文件自带 PQ / 肩部 / 矩阵参考式），容差 ±1 LSB（着色器 float32 对 CPU double 的固有差）。
//   ① off 不变量：S2ARM_HDR 缺省（vi 未答过）+ 8 位目标 ⇒ 平凡直通——与改前 trivial 采样着色器（本文件按改前源码原样编译的对照管线，
//      同一裁切 / 边缘钳制 / 采样器）逐字节一致：10 位源（含 512→128 的硬件换算）、8 位源、sRGB 源、float 源、alpha 透传。
//   ② 未答过的 10 位窗进 PQ 层目标：按 gamma SDR 解码、纸白 100 nit 编码（mode 2 语义——「vi 答过 HDR 才当 PQ 码值解码」的反面锁定）。
//   ③ mode 1（S3 兜底 + PR6 截图共用）：vi 答 on=1（S3 路径：S2ARM_HDR=on ∧ can 未持稳）后 HDR10 窗 → 8 位目标：
//      先 BT.2020→BT.709 矩阵（负值截断在矩阵后）→ 肩部压缩到 SDR 白 → 2.2 编码；灰阶逐档 + 橙色高光保色相（先压缩后转换会把
//      红绿比 6.9 压成 4.6——次序铁律锁定）+ 转换态 alpha 1。
//   ④ mode 2：8 位 SDR → PQ 层：SDR 白 255 = 纸白锚 100 nit、中灰 128 = 线性值、阴影按 2.2 解码不抬肩（码 16 = 2.2 下 sRGB 的约 1/2.3 光）、alpha 1。
//   ⑤ mode 3：float 线性 BT.709 → PQ 层：1.0 = 纸白、4.0 = 四倍、负值矩阵后才截断（scRGB 的广色域青保住其 BT.2020 值）；
//      ⑤b float 格式全集（RG11B10F 同走 mode 3——对齐 nxnative present_mode 的四款 float 源）。
//   ⑥ mode 0 PQ 直通：vi 答过后 HDR10 窗码值原样写 PQ 层（逐码相等——主路径，游戏已按 told peak 自 tone-map）。
//   ⑦ mode 4 滚降（无 metadata）：已告知 peak 在步进保持期（屏变暗、答案还没跟上）压过当前净空时——膝点下逐位直通、
//      肩部曲线（knee 300 / target 400 / 源峰 1580 = min(声明 1801, 已告知 1580)）、单调有界（≤ target+3 nit）、色相保持（各通道同缩放）、
//      三个门限（源峰 ≤ 1.05×target 不滚、knee > 0.9×target 不滚、已告知峰值追平净空后不滚）、缩放上屏与直通逐位一致。
//   ⑧ latch：答过 HDR 后回答转 SDR（S2ARM_HDR=off），present 仍按 PQ 解码游戏保持的 HDR10 窗（排空过渡帧的唯一不糊画面解法，nxnative 口径）；
//      游戏自降回 8 位窗后 off 恢复平凡直通。
//   ⑨ S2ARM_HDR_SDR_GAMMA=0（分段 sRGB 曲线，Q13 参数留可调）：mk 第二遍单独进程跑 mode 2 的 sRGB 期望（首遍缺省 2.2；
//      该开关读一次缓存，进程内不换——所以分进程）。
// PQ 层目标（RGB10A2）在 PR3b 阶段还没有真层（PR4 落地）：②④⑤⑥⑦ 的 RGB10A2 目标是单测直接建的——验的是转换数学与管线接线，
//   真机路径随 PR4/PR5 验收（§4 PR3b 的时点口径）。S3 真机路径同理：vi 门控接线是 PR5，本测经同源答案入口直调驱动。
#ifndef T_PRESENT_HDR_SOURCE
#define T_PRESENT_HDR_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include T_PRESENT_HDR_SOURCE
#include "../gfx/nvn/nvn_hdr_policy.h"   // PR3a 已合入的快照/答案入口声明（基线上 nvn_mtl.m 还不引它，测试自己引——红态也编得过）
#include <math.h>

static unsigned checks, failures;
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
// 改前 trivial 采样着色器（present_pipeline 旧源码原样）：off 不变量的对照管线——mode 0 与它逐字节一致
static const char *k_trivial_msl =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; float2 uv; };\n"
    "vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
    "struct Crop { float4 rect; float4 edge; };\n"
    "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) { return t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw)); }\n";

// CPU 双精度参考式（nxnative t_present_hdr 同式）：ST 2084 码值 ↔ nit、SDR 2.2 解 / 编码、分段 sRGB、有理肩部
static double pq_code(double nits) {
    const double m1 = 2610.0 / 16384, m2 = 2523.0 / 32, c1 = 3424.0 / 4096, c2 = 2413.0 / 128, c3 = 2392.0 / 128;
    double y = pow(nits / 10000.0, m1);
    return pow((c1 + c2 * y) / (1 + c3 * y), m2) * 1023.0;
}
static double pq_nits(double code) {
    const double m1 = 2610.0 / 16384, m2 = 2523.0 / 32, c1 = 3424.0 / 4096, c2 = 2413.0 / 128, c3 = 2392.0 / 128;
    double e = pow(code / 1023.0, 1.0 / m2);
    return 10000.0 * pow(fmax(e - c1, 0) / (c2 - c3 * e), 1.0 / m1);
}
static double sdr_dec(double c) { return pow(c, 2.2); }                 // Q13 缺省口径（S2ARM_HDR_SDR_GAMMA 不设）
static double sdr_enc(double l) { return pow(l, 1.0 / 2.2); }
static double srgb_dec(double c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
static double shoulder(double m, double k, double t, double s) {        // present_shoulder 的双精度参考式
    if (!(m > k)) return m;
    double a = t - k, x = m - k; return fmin(k + x / (1 + x * (1 / a - 1 / fmax(s - k, a))), t);
}

#define N 8
static uint8_t t_src_alpha = 255;   // src8 的 alpha
static id<MTLTexture> src10(const unsigned c[N][3]) {   // N×1 RGB10A2 源：10 位码值 r/g/b、alpha 3（不透明）
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:N height:1 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; uint32_t w[N];
    for (int i = 0; i < N; i++) w[i] = c[i][0] | c[i][1] << 10 | c[i][2] << 20 | 3u << 30;
    [t replaceRegion:MTLRegionMake2D(0, 0, N, 1) mipmapLevel:0 withBytes:w bytesPerRow:sizeof w];
    return t;
}
static id<MTLTexture> src8(const uint8_t c[N][3], MTLPixelFormat pf) {   // N×1 8 位源（RGBA8 / RGBA8_sRGB：字节原样，sRGB 经非 sRGB 视图读）
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:N height:1 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; uint8_t b[N * 4];
    for (int i = 0; i < N; i++) { b[4 * i] = c[i][0]; b[4 * i + 1] = c[i][1]; b[4 * i + 2] = c[i][2]; b[4 * i + 3] = t_src_alpha; }
    [t replaceRegion:MTLRegionMake2D(0, 0, N, 1) mipmapLevel:0 withBytes:b bytesPerRow:sizeof b];
    return t;
}
static id<MTLTexture> src16f(const float c[N][3]) {   // N×1 RGBA16Float 源：线性光（float 窗）
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:N height:1 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; __fp16 h[N * 4];
    for (int i = 0; i < N; i++) { for (int k = 0; k < 3; k++) h[4 * i + k] = (__fp16)c[i][k]; h[4 * i + 3] = 1; }
    [t replaceRegion:MTLRegionMake2D(0, 0, N, 1) mipmapLevel:0 withBytes:h bytesPerRow:sizeof h];
    return t;
}
static double t_alpha[N];   // 上一次 run 的 alpha（0-1）
static id<MTLTexture> dst_tex(MTLPixelFormat fmt, NSUInteger w, NSUInteger h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return [g_dev newTextureWithDescriptor:d];
}
// 生产 present 全链路（present_encode → present_blit：模式化着色器 + UV 常量缓冲 p[0..7]）；out 取 RGB 0-1023（RGB10A2）或 0-255（8 位目标）
static int run(id<MTLTexture> src, MTLPixelFormat fmt, double out[N][3]) {
    id<MTLTexture> dst = dst_tex(fmt, N, 1); id<MTLCommandBuffer> cb = [g_q commandBuffer];
    if (!present_encode(cb, src, dst, NULL)) { printf("SETUP FAIL present_encode 返回 0（目标格式 %lu）\n", (unsigned long)fmt); return 0; }
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) { printf("SETUP FAIL 命令缓冲 %ld：%s\n", (long)cb.status, cb.error.localizedDescription.UTF8String ?: "?"); return 0; }
    if (fmt == MTLPixelFormatRGB10A2Unorm) {   // PQ 层目标：10 位码值
        uint32_t w[N]; [dst getBytes:w bytesPerRow:sizeof w fromRegion:MTLRegionMake2D(0, 0, N, 1) mipmapLevel:0];
        for (int i = 0; i < N; i++) { for (int k = 0; k < 3; k++) out[i][k] = w[i] >> (10 * k) & 0x3ff; t_alpha[i] = (w[i] >> 30) / 3.0; }
    } else {   // 8 位目标
        uint8_t b[N * 4]; [dst getBytes:b bytesPerRow:sizeof b fromRegion:MTLRegionMake2D(0, 0, N, 1) mipmapLevel:0];
        for (int i = 0; i < N; i++) { for (int k = 0; k < 3; k++) out[i][k] = b[4 * i + k]; t_alpha[i] = b[4 * i + 3] / 255.0; }
    }
    return 1;
}
// 改前 trivial 采样（对照管线）：同尺寸目标、同裁切 / 边缘钳制 / 采样器 / uv——off 不变量的逐字节基准
static id<MTLRenderPipelineState> trivial_pso(MTLPixelFormat fmt) {
    static id<MTLRenderPipelineState> ps[2]; int i = fmt == MTLPixelFormatRGB10A2Unorm;
    if (!ps[i]) {
        NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(k_trivial_msl) options:nil error:&e];
        if (!lib) { printf("SETUP FAIL 对照着色器编译：%s\n", e.localizedDescription.UTF8String); return nil; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = fmt;
        ps[i] = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
        if (!ps[i]) { printf("SETUP FAIL 对照管线：%s\n", e.localizedDescription.UTF8String); return nil; }
    }
    return ps[i];
}
static int trivial_run(id<MTLTexture> src, id<MTLTexture> dst) {
    id<MTLRenderPipelineState> pso = trivial_pso(dst.pixelFormat);
    if (!pso) return 0;
    id<MTLCommandBuffer> cb = [g_q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dst; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:pso]; [en setFragmentTexture:present_raw_src(src) atIndex:0]; [en setFragmentSamplerState:g_blit_samp atIndex:0];
    float uv[8] = {0, 0, 1, 1, 0.5f / N, 0.5f, (N - 0.5f) / N, 0.5f};   // 与 present_blit 无裁切同尺寸的 uv 同值
    [en setFragmentBytes:uv length:sizeof uv atIndex:0];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    return cb.status == MTLCommandBufferStatusCompleted;
}
static int bytes_equal(id<MTLTexture> a, id<MTLTexture> b) {   // 逐字节比（同格式同尺寸）
    NSUInteger w = a.width, h = a.height;
    size_t n = (size_t)w * h * 4; uint8_t *x = malloc(n), *y = malloc(n);   // 两目标都是 4 字节 / 像素
    [a getBytes:x bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    [b getBytes:y bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    int same = !memcmp(x, y, n); free(x); free(y); return same;
}
static int present_into(id<MTLTexture> src, id<MTLTexture> dst) {   // 生产 present 全链路画进给定目标并提交（①⑦⑧ 的逐字节对照用）
    id<MTLCommandBuffer> cb = [g_q commandBuffer];
    if (!present_encode(cb, src, dst, NULL)) { printf("SETUP FAIL present_encode 返回 0（目标格式 %lu）\n", (unsigned long)dst.pixelFormat); return 0; }
    [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) { printf("SETUP FAIL 命令缓冲 %ld：%s\n", (long)cb.status, cb.error.localizedDescription.UTF8String ?: "?"); return 0; }
    return 1;
}

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    unsetenv("S2ARM_HDR"); if (!getenv("T_PRESENT_HDR_GAMMA0")) unsetenv("S2ARM_HDR_SDR_GAMMA");   // ⑨ 第二遍进程带着 S2ARM_HDR_SDR_GAMMA=0 起：别在这里清掉
    unsetenv("S2A_ANTI_ALIASING"); unsetenv("S2A_SCALING_FILTER"); unsetenv("S2A_CPATCH_ON");
    setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_ARCHIVE", "0", 1);
    mtl_init();
    if (getenv("T_PRESENT_HDR_GAMMA0")) {   // ⑨ 第二遍进程（mk 起的）：S2ARM_HDR_SDR_GAMMA=0 的分段 sRGB 曲线（读一次缓存，分进程才换得动）
        setenv("S2ARM_HDR", "on", 1);
        uint8_t c[N][3] = {{255, 255, 255}, {128, 128, 128}, {64, 64, 64}, {32, 32, 32}, {16, 16, 16}, {8, 8, 8}, {4, 4, 4}, {0, 0, 0}};
        double o[N][3]; int ran = run(src8(c, MTLPixelFormatRGBA8Unorm), MTLPixelFormatRGB10A2Unorm, o), bad = 0;
        for (int i = 0; ran && i < N; i++) bad += fabs(o[i][1] - pq_code(srgb_dec(c[i][1] / 255.0) * 100)) > 1.0;
        CHECK(ran && !bad, "⑨ SDR gamma=0：SDR 源按分段 sRGB 曲线解码（码 16 的光是 2.2 的 2.3 倍——抬肩可见）");
        return failures != 0;
    }
    double o[N][3];

    // ① off 不变量（latch 未置、8 位目标 = 现状全部真实路径）：与改前 trivial 采样逐字节一致
    {
        unsigned g[N][3]; for (int i = 0; i < N; i++) { unsigned code = (unsigned)(i * 146); g[i][0] = g[i][1] = g[i][2] = code; }   // 0..1022 扫一排
        id<MTLTexture> s10 = src10(g), d1 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1), d2 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1);
        CHECK(present_into(s10, d1) && trivial_run(s10, d2) && bytes_equal(d1, d2),
              "① off：10 位源码值扫描 → 8 位目标 = 改前 trivial 采样逐字节一致（含 512→128 的纯格式换算）");
        uint8_t c[N][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 255}, {1, 2, 3}, {200, 100, 50}, {16, 16, 16}, {0, 0, 0}};
        t_src_alpha = 0; id<MTLTexture> s8 = src8(c, MTLPixelFormatRGBA8Unorm); t_src_alpha = 255;
        d1 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1); d2 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1);
        CHECK(present_into(s8, d1) && trivial_run(s8, d2) && bytes_equal(d1, d2),
              "① off：8 位源（alpha 0）→ 8 位目标 = trivial 逐字节一致（alpha 原样透传）");
        id<MTLTexture> s8s = src8(c, MTLPixelFormatRGBA8Unorm_sRGB);
        d1 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1); d2 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1);
        CHECK(present_into(s8s, d1) && trivial_run(s8s, d2) && bytes_equal(d1, d2),
              "① off：sRGB 源经非 sRGB 视图原样字节 → 8 位目标 = trivial 逐字节一致（scan-out 语义不变）");
        float f[N][3] = {{1, 1, 1}, {0.25f, 0.5f, 0.75f}, {4, 4, 4}, {0, 0, 0}, {-1, -1, -1}, {2, 1, 0}, {99, 0.01f, 0.5f}, {0.5f, 0.5f, 0.5f}};
        id<MTLTexture> sf = src16f(f);
        d1 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1); d2 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1);
        CHECK(present_into(sf, d1) && trivial_run(sf, d2) && bytes_equal(d1, d2),
              "① off：float 源 → 8 位目标 = trivial 逐字节一致（float 窗到 SDR 目标原样直通）");
        CHECK(run(src10(g), MTLPixelFormatRGBA8Unorm, o) && fabs(o[3][0] - lround(438 / 1023.0 * 255)) <= 1,   // 3×146 = 438
              "① off：10 位码 438 → 8 位 = 硬件换算 %d（期望 %d，±1）", (int)o[3][0], (int)lround(438 / 1023.0 * 255));
    }

    // ② 未答过的 10 位窗 → PQ 层目标：按 gamma SDR 解码、纸白 100 nit 编码（mode 2；答过才当 PQ 码值的反面）
    {
        unsigned g[N][3]; for (int i = 0; i < N; i++) { unsigned code = (unsigned)(i * 131 + 5); g[i][0] = g[i][1] = g[i][2] = code; }
        int ran = run(src10(g), MTLPixelFormatRGB10A2Unorm, o), bad = 0, at = -1;
        for (int i = 0; ran && i < N; i++) if (fabs(o[i][1] - pq_code(sdr_dec(g[i][1] / 1023.0) * 100)) > 1.0) { bad++; if (at < 0) at = i; }
        if (bad) printf("② 首个不符：码 %d 出 %d（期望 %.1f）\n", (int)g[at][1], (int)o[at][1], pq_code(sdr_dec(g[at][1] / 1023.0) * 100));
        CHECK(ran && !bad, "② 未答过：10 位窗进 PQ 层按 gamma SDR 解码、100 nit 编码（mode 2，不当 PQ 码值）");
        unsigned c512[N][3]; for (int i = 0; i < N; i++) c512[i][0] = c512[i][1] = c512[i][2] = 512;
        CHECK(run(src10(c512), MTLPixelFormatRGB10A2Unorm, o) && fabs(o[0][1] - pq_code(sdr_dec(512 / 1023.0) * 100)) <= 1.0,
              "② 未答过：10 位码 512 = 半灰 → %d（期望 pq(%.1f nit)±1）", (int)o[0][1], sdr_dec(512 / 1023.0) * 100);
    }

    // ③ mode 1（S3 兜底 + PR6 截图共用）：vi 答 on=1（S3 路径）后 HDR10 窗 → 8 位目标。
    //   声明范围（PR1 存储的 vi Set* 值）在本单测二进制里驱动不到：vi 注册表条目经 nvn2_vi_entry 取，ounce 判定
    //   （s2a_platform_ounce，宿主对象 svc_mem.o 的 NPDM 读数）在单测里恒 0——源峰的 min(声明, 已告知) 落已告知一侧验证
    //   （已告知 400 nit = 4 纸白），声明侧（min 取声明，DKB 声明低于告知的形态）随 PR5 元数据消费接线验收
    {
        setenv("S2ARM_HDR", "on", 1);
        hdr_snapshot pub = {.potential_edr = 2.0, .current_headroom = 4.0, .s1_ready = 0, .paper_white = 100};
        nvn2_hdr_snapshot_publish(&pub);   // can 未持稳 / s1_ready=0 → S3 强制路径
        hdr_decision d = nvn2_hdr_answer(1, 1000);
        CHECK(d.mode == HDR_S3 && d.vi_on == 1 && d.vi_fmt == 1 && d.vi_peak == 400, "③ 前端替身：S3 强制路径答 on=1 / fmt=1 / peak=400（headroom 4）");
        const double nits[N] = {0, 0.1, 10, 80, 203, 500, 1000, 10000};
        unsigned g[N][3]; for (int i = 0; i < N; i++) g[i][0] = g[i][1] = g[i][2] = (unsigned)lround(pq_code(nits[i]));
        int ran = run(src10(g), MTLPixelFormatRGBA8Unorm, o), bad = 0;
        for (int i = 0; ran && i < N; i++) bad += fabs(o[i][0] - 255.0 * sdr_enc(shoulder(pq_nits(g[i][0]) / 100.0, 0.75, 1, 4))) > 1.0;
        CHECK(ran && !bad && o[6][0] >= 254, "③ mode 1：灰阶沿肩部——暗部中灰照 SDR（≤75 nit），亮灰压进 SDR 白（源峰 400 nit 精确落白）");
        CHECK(ran && t_alpha[0] == 1.0 && t_alpha[N - 1] == 1.0, "③ mode 1：转换态 alpha 写 1");
        unsigned c[N][3]; for (int i = 0; i < N; i++) { c[i][0] = c[i][1] = c[i][2] = 400; }
        c[7][0] = (unsigned)lround(pq_code(1000)); c[7][1] = (unsigned)lround(pq_code(300)); c[7][2] = 0;   // 橙色高光：BT.2020 1000/300/0 nit
        ran = run(src10(c), MTLPixelFormatRGBA8Unorm, o);
        double v[3] = {pq_nits(c[7][0]) / 100.0, pq_nits(c[7][1]) / 100.0, 0}, m709[3];
        static const double m[3][3] = {{1.660491, -0.587641, -0.072850}, {-0.124550, 1.132900, -0.008349}, {-0.018151, -0.100579, 1.118730}};
        for (int k = 0; k < 3; k++) m709[k] = fmax(m[k][0] * v[0] + m[k][1] * v[1] + m[k][2] * v[2], 0);
        double mx = fmax(fmax(m709[0], m709[1]), m709[2]), fs = shoulder(mx, 0.75, 1, 4) / mx, e[3];
        for (int k = 0; k < 3; k++) e[k] = 255.0 * sdr_enc(fmin(m709[k] * fs, 1));
        double rg_lin = sdr_dec(o[7][0] / 255.0) / sdr_dec(o[7][1] / 255.0);
        CHECK(ran && fabs(o[7][0] - e[0]) <= 1.0 && fabs(o[7][1] - e[1]) <= 1.0 && fabs(o[7][2] - e[2]) <= 1.0 && fabs(rg_lin - m709[0] / m709[1]) < 0.4,
              "③ mode 1：橙色高光（BT.2020 1000/300/0）保色相——先矩阵后肩部（红绿线性比 %.2f，保持 %.2f；先压缩后转换会变 4.6）", rg_lin, m709[0] / m709[1]);
    }

    // ④ mode 2：8 位 SDR → PQ 层（纸白锚 100 nit；SDR 白 255 = 100 nit、黑 = 码 0、阴影 2.2 不抬肩）
    {
        uint8_t c[N][3] = {{255, 255, 255}, {128, 128, 128}, {64, 64, 64}, {32, 32, 32}, {16, 16, 16}, {8, 8, 8}, {4, 4, 4}, {0, 0, 0}};
        int ran = run(src8(c, MTLPixelFormatRGBA8Unorm), MTLPixelFormatRGB10A2Unorm, o), bad = 0;
        for (int i = 0; ran && i < N; i++) bad += fabs(o[i][1] - pq_code(sdr_dec(c[i][1] / 255.0) * 100)) > 1.0;
        CHECK(ran && !bad && fabs(o[0][1] - pq_code(100)) <= 1.0 && o[7][1] <= 1,
              "④ mode 2：SDR 白 255 = 纸白 100 nit、中灰 128 = 线性值、黑 = 码 0（各档 ±1）");
        CHECK(ran && !bad && o[4][1] < pq_code(srgb_dec(16 / 255.0) * 100) - 10,
              "④ mode 2：阴影（码 16）按 2.2 解码——不抬到分段 sRGB 的 2.3 倍光");
        t_src_alpha = 0; ran = run(src8(c, MTLPixelFormatRGBA8Unorm), MTLPixelFormatRGB10A2Unorm, o); t_src_alpha = 255;
        CHECK(ran && t_alpha[0] == 1.0 && t_alpha[N - 1] == 1.0, "④ mode 2：转换态 alpha 写 1（源 alpha 0 也写 1）");
    }

    // ⑤ mode 3：float 线性 BT.709 → PQ 层（1.0 = 纸白；负值矩阵后才截断——scRGB 广色域保真）
    {
        float f[N][3] = {{1, 1, 1}, {0.5f, 0.5f, 0.5f}, {4, 4, 4}, {0, 0, 0}, {-1, -1, -1}, {-0.05f, 1, 1}, {1, 1, 1}, {1, 1, 1}};
        int ran = run(src16f(f), MTLPixelFormatRGB10A2Unorm, o);
        CHECK(ran && fabs(o[0][1] - pq_code(100)) <= 1.0 && fabs(o[1][1] - pq_code(50)) <= 1.0 && fabs(o[2][1] - pq_code(400)) <= 1.0,
              "⑤ mode 3：float 源是线性光——1.0 = 纸白 100 nit、0.5 = 50、4.0 = 400（不当 sRGB 解码）");
        CHECK(ran && o[3][1] <= 1 && o[4][1] <= 1, "⑤ mode 3：0 与负 float 值 = 黑");
        CHECK(ran && fabs(o[5][0] - pq_code(0.34122 * 100)) <= 1.0,
              "⑤ mode 3：BT.709 外的负红（scRGB -0.05,1,1）在矩阵后才截断——红 = 34.1 nit（先截断会是 37.3）");
        CHECK(ran && t_alpha[5] == 1.0, "⑤ mode 3：转换态 alpha 写 1");
        // ⑤b mode 3 的 float 格式全集对齐（nxnative present_mode：RG11B10Float / RGB9E5Float 与 RGBA16/32Float 同为线性 BT.709 源——
        //    只认 16/32F 会让这两款窗进 PQ 层时被当未知格式原样直通，浮点字节被当 PQ 码值）。RG11B10F 源用硬编码浮点字
        //    （R/G 11 位：1.0 / 0.5 = 指数 15 / 14、尾数 0；B 10 位：4.0 = 指数 17、尾数 0——都是精确值），全排同一像素 → 矩阵 → PQ 层，期望 CPU 双精度复算
        {
            uint32_t words[N]; for (int i = 0; i < N; i++) words[i] = 960u | 896u << 11 | 544u << 22;   // (R,G,B) = (1, 0.5, 4)
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG11B10Float width:N height:1 mipmapped:NO];
            d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; [t replaceRegion:MTLRegionMake2D(0, 0, N, 1) mipmapLevel:0 withBytes:words bytesPerRow:sizeof words];
            static const double m7[3][3] = {{0.627404, 0.329283, 0.043313}, {0.069097, 0.919540, 0.011362}, {0.016391, 0.088013, 0.895595}};   // kRec709To2020 各行（shader 同一矩阵）
            double lin[3] = {1, 0.5, 4}, e[3];
            for (int k = 0; k < 3; k++) e[k] = m7[k][0] * lin[0] + m7[k][1] * lin[1] + m7[k][2] * lin[2];
            int r2 = run(t, MTLPixelFormatRGB10A2Unorm, o);
            CHECK(r2 && fabs(o[0][0] - pq_code(e[0] * 100)) <= 1.0 && fabs(o[0][1] - pq_code(e[1] * 100)) <= 1.0 && fabs(o[0][2] - pq_code(e[2] * 100)) <= 1.0,
                  "⑤b mode 3：RG11B10Float 源按线性 BT.709 进矩阵 → PQ（%.1f / %.1f / %.1f nit，±1）——float 格式全集对齐 nxnative", e[0] * 100, e[1] * 100, e[2] * 100);
        }
    }

    // ⑥ mode 0 PQ 直通：vi 答过后 HDR10 窗码值原样写 PQ 层（主路径——游戏已按 told peak 自 tone-map）
    {
        const double nits[N] = {0, 0.1, 10, 80, 203, 500, 1000, 10000};
        unsigned g[N][3]; for (int i = 0; i < N; i++) g[i][0] = g[i][1] = g[i][2] = (unsigned)lround(pq_code(nits[i]));
        int ran = run(src10(g), MTLPixelFormatRGB10A2Unorm, o), same = 1;
        for (int i = 0; ran && i < N; i++) for (int k = 0; k < 3; k++) same &= o[i][k] == g[i][k];
        CHECK(ran && same, "⑥ mode 0：vi 答过 HDR 后，HDR10 窗码值原样直通 PQ 层（逐码相等）");
        CHECK(ran && t_alpha[0] == 1.0, "⑥ mode 0：直通态 alpha 原样（码值 3/3）");
    }

    // ⑦ mode 4 滚降（无 metadata；已告知 peak 在步进保持期压过变暗的屏——PR3b 唯一真实触发形态，PR5 步进接线后常态）
    {
        hdr_snapshot pub = {.potential_edr = 16.0, .current_headroom = 16.0, .s1_ready = 0, .paper_white = 100};
        nvn2_hdr_snapshot_publish(&pub);
        nvn2_hdr_answer(1, 2000);   // 候选 1580 出带 → 等 1s 持稳（答案与已告知 peak 都还 400）
        hdr_decision d = nvn2_hdr_answer(1, 3100);
        CHECK(d.vi_on == 1 && d.vi_peak == 1580, "⑦ 前端替身：headroom 16 持稳后已告知 peak = 1580 nit");
        const double nits[N] = {0, 0.1, 10, 80, 203, 500, 1000, 10000};
        unsigned g[N][3]; for (int i = 0; i < N; i++) g[i][0] = g[i][1] = g[i][2] = (unsigned)lround(pq_code(nits[i]));
        int ran = run(src10(g), MTLPixelFormatRGB10A2Unorm, o), same = 1;
        for (int i = 0; ran && i < N; i++) for (int k = 0; k < 3; k++) same &= o[i][k] == g[i][k];
        CHECK(ran && same, "⑦ 门限①：headroom 16（target 1600）下源峰 1580 ≤ 1.05×target → 不滚降，码值原样");
        pub.current_headroom = 4.0; nvn2_hdr_snapshot_publish(&pub);   // 屏变暗：净空 400，已告知 peak 1580 还在保持期
        const double rn[N] = {100, 203, 300, 350, 400, 1580, 10000, 10000};   // 第 5 位 = 源峰本身（已告知 1580）：肩部把它精确落在 target 上
        unsigned r[N][3]; for (int i = 0; i < N; i++) r[i][0] = r[i][1] = r[i][2] = (unsigned)lround(pq_code(rn[i]));
        ran = run(src10(r), MTLPixelFormatRGB10A2Unorm, o);
        int under = 1, mono = 1, curve = 0;
        for (int i = 0; ran && i < 2; i++) for (int k = 0; k < 3; k++) under &= o[i][k] == r[i][k];
        for (int i = 0; ran && i < N; i++) { if (i) mono &= o[i][1] >= o[i - 1][1]; under &= pq_nits(o[i][1]) <= 403; }
        for (int i = 2; ran && i < 6; i++) curve += fabs(o[i][1] - pq_code(shoulder(rn[i], 300, 400, 1580))) <= 1.0;
        CHECK(ran && under, "⑦ 滚降：膝点（300 nit）以下码值逐位原样；以上有界（≤ target+3 nit）");
        CHECK(ran && mono && curve == 4, "⑦ 滚降：300/350/400/1580 nit 在肩部曲线上（knee 300 / target 400 / 源峰 1580 精确落 target，±1）且单调");
        CHECK(ran && fabs(pq_nits(o[5][1]) - 400) < 4, "⑦ 滚降：源峰 1580 nit 落在 target 400 nit 上（±4）");
        unsigned col[N][3]; for (int i = 0; i < N; i++) { col[i][0] = (unsigned)lround(pq_code(1000)); col[i][1] = (unsigned)lround(pq_code(500)); col[i][2] = (unsigned)lround(pq_code(100)); }
        ran = run(src10(col), MTLPixelFormatRGB10A2Unorm, o);
        double rr = pq_nits(o[0][0]), gg = pq_nits(o[0][1]), bb = pq_nits(o[0][2]);
        CHECK(ran && rr <= 403 && fabs(gg / rr - 0.5) < 0.03 && fabs(bb / rr - 0.1) < 0.01, "⑦ 滚降：色（1000/500/100 nit）各通道同缩放保色相");
        {   // 缩放上屏（膝点以下整排）：滚降态（已告知 1580 还在保持期）先跑，直通态（追平后）后跑——滚降不碰采样路径
            const double lo[N] = {0.1, 10, 80, 120, 203, 250, 280, 290};
            unsigned lw[N][3]; for (int i = 0; i < N; i++) lw[i][0] = lw[i][1] = lw[i][2] = (unsigned)lround(pq_code(lo[i]));
            id<MTLTexture> s = src10(lw), d1 = dst_tex(MTLPixelFormatRGB10A2Unorm, 13, 1);
            CHECK(present_into(s, d1), "⑦ 滚降：膝点以下的缩放上屏（13×1 目标）可跑");
            nvn2_hdr_answer(1, 4200);   // 候选 400 出带 → 等持稳
            d = nvn2_hdr_answer(1, 5300);
            CHECK(d.vi_on == 1 && d.vi_peak == 400, "⑦ 前端替身：已告知 peak 追平净空（400 @ headroom 4）");
            id<MTLTexture> d2 = dst_tex(MTLPixelFormatRGB10A2Unorm, 13, 1);
            CHECK(present_into(s, d2) && bytes_equal(d1, d2), "⑦ 滚降：膝点以下的缩放上屏与直通逐位一致（滚降不碰采样）");
        }
        ran = run(src10(g), MTLPixelFormatRGB10A2Unorm, o); same = 1;
        for (int i = 0; ran && i < N; i++) for (int k = 0; k < 3; k++) same &= o[i][k] == g[i][k];
        CHECK(ran && same, "⑦ 门限②：已告知追平后源峰 400 ≤ 1.05×target 420 → 不滚降，码值原样");
        pub.current_headroom = 1.05; nvn2_hdr_snapshot_publish(&pub);   // 净空 105：膝点 100 > 0.9×105 → 白上没余量，不硬滚
        ran = run(src10(r), MTLPixelFormatRGB10A2Unorm, o); same = 1;
        for (int i = 0; ran && i < N; i++) for (int k = 0; k < 3; k++) same &= o[i][k] == r[i][k];
        CHECK(ran && same, "⑦ 门限③：knee 100 > 0.9×target 105 → 不滚降（让屏去截断，不硬滚）");
        pub.current_headroom = 4.0; nvn2_hdr_snapshot_publish(&pub);
    }

    // ⑧ latch：答过 HDR 后回答转 SDR（off），present 仍按 PQ 解码游戏保持的 HDR10 窗；游戏自降回 8 位窗后 off 恢复平凡直通
    {
        setenv("S2ARM_HDR", "off", 1);
        hdr_decision d = nvn2_hdr_answer(1, 6000);
        CHECK(d.mode == HDR_S0 && d.vi_on == 0 && d.vi_fmt == 0 && d.vi_peak == 0, "⑧ 前端替身：off 后回答转 SDR（on=0 / fmt=0 / peak=0）");
        const double nits[N] = {0, 0.1, 10, 80, 203, 500, 1000, 10000};
        unsigned g[N][3]; for (int i = 0; i < N; i++) g[i][0] = g[i][1] = g[i][2] = (unsigned)lround(pq_code(nits[i]));
        int ran = run(src10(g), MTLPixelFormatRGBA8Unorm, o), bad = 0;   // 源峰 = min(声明 1801, 已告知 400) = 400 → s = 4（与 ③ 同参）
        for (int i = 0; ran && i < N; i++) bad += fabs(o[i][0] - 255.0 * sdr_enc(shoulder(pq_nits(g[i][0]) / 100.0, 0.75, 1, 4))) > 1.0;
        CHECK(ran && !bad, "⑧ latch：off 后 HDR10 窗仍按 PQ 解码（mode 1）——排空过渡帧不糊画面（已告知 400、源峰 400 同 ③）");
        uint8_t c[N][3] = {{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 255}, {1, 2, 3}, {200, 100, 50}, {16, 16, 16}, {0, 0, 0}};
        id<MTLTexture> s8 = src8(c, MTLPixelFormatRGBA8Unorm), d1 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1), d2 = dst_tex(MTLPixelFormatRGBA8Unorm, N, 1);
        CHECK(present_into(s8, d1) && trivial_run(s8, d2) && bytes_equal(d1, d2),
              "⑧ off：游戏自降回 8 位窗后恢复平凡直通（与改前 trivial 逐字节一致）");
        unsetenv("S2ARM_HDR");
    }

    printf("%s t_present_hdr：%u 项，%u 项不符\n", failures ? "✗" : "✓", checks, failures);
    return failures != 0;
} }
