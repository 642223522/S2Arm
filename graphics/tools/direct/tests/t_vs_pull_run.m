// t_vs_pull.py 的 GPU 一侧（照上游参考实现（MIT）t_pull 的思路）：拉取式顶点输入（S2A.Dsh DshPull 的 Prelude：dm_vlayout / dm_fetch）读出的 32 位寄存器字
//   与 Metal 顶点描述抓取逐位相同。宿主的格式映射 vfmt / vconv_i2f 由 t_vs_pull.py 从 graphics/nvn/gfx/nvn/nvn_mtl.m 原样摘出，编译时 -include 进来（同宿主一份，不另抄表）。
//   ① 每个 vfmt 认得的 NVN 格式：同一份顶点数据，拉取版 vs 顶点描述（输入按格式类别取 float4 / uint4 / int4）；整数读成浮点的格式（vconv_i2f，Metal 没有这种抓取）
//      期望 = 同布局整数格式的 Metal 抓取、CPU 逐分量转浮点（缺的分量 0, 0, 0, 1.0）。8 位格式另在 2 字节偏移、1 字节格式另在跨距 1 各跑一遍；半精度 / 单精度特殊值、10:10:10:2 端值
//   ② 跨距 0（Metal 常量步进）与除数 1 / 2 / 3（逐实例步进）配起始实例 5：每个实例读到的元素与 Metal 的一致
//   ③ 基址不是 4 的倍数（契约：宿主把基址低 2 位并进属性偏移，布局块里的基址 4 对齐）：读出与「把元素拷到对齐处再用 Metal 抓取」的一致
//   ④ 端到端：同一支小顶点着色器的原样（[[stage_in]] + 顶点描述）与变体（布局块，槽 16），三种类型的输入、属性号 0 / 5 / 20、一个逐实例流，着色器写出的输入逐字相同
//   打印「FMT <格式号>…」（vfmt 认得的全部格式）与各项 CHECK 行，末行「t_vs_pull_run: N checks, M failed」。用法：t_vs_pull_run <prelude.metal> <原样.metal> <变体.metal>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int checks, failed;
#define EXPECT(name, want, got) do { uint64_t w_ = (uint64_t)(want), g_ = (uint64_t)(got); checks++; if (w_ != g_) { fprintf(stderr, "%s: expected %llu, got %llu\n", name, (unsigned long long)w_, (unsigned long long)g_); failed++; } } while (0)

typedef struct { uint64_t base; uint32_t stride, divisor; } dm_vstream_c;
typedef struct { dm_vstream_c s[16]; uint32_t attr[32]; } dm_vlayout_c;   // Prelude 的 dm_vlayout（契约：16 × 16 字节流 + 32 个属性状态字 = 384 字节）
_Static_assert(sizeof(dm_vlayout_c) == 384, "dm_vlayout");
static uint32_t attr_word(uint32_t fmt, uint32_t off, uint32_t st) { return fmt | off << 8 | st << 27; }   // NVN 属性状态字：格式 8 位 | 偏移 19 位 | 流号 5 位

static id<MTLDevice> dev; static id<MTLCommandQueue> q; static id<MTLTexture> rt; static id<MTLLibrary> lib;
static NSString *k_test = @"\n"
"vertex void pull_test(constant dm_vlayout &L [[buffer(16)]], device uint4 *out [[buffer(1)]], constant uint &mode [[buffer(2)]], uint vid [[vertex_id]], uint iid [[instance_id]], uint bi [[base_instance]]) { out[mode ? iid : vid] = dm_fetch(L, 0, vid, iid, bi); }\n"
"struct vinf { float4 a [[attribute(0)]]; }; struct vinu { uint4 a [[attribute(0)]]; }; struct vini { int4 a [[attribute(0)]]; };\n"
"vertex void vd_f(vinf in [[stage_in]], device uint4 *out [[buffer(1)]], constant uint &mode [[buffer(2)]], uint vid [[vertex_id]], uint iid [[instance_id]]) { out[mode ? iid : vid] = as_type<uint4>(in.a); }\n"
"vertex void vd_u(vinu in [[stage_in]], device uint4 *out [[buffer(1)]], constant uint &mode [[buffer(2)]], uint vid [[vertex_id]], uint iid [[instance_id]]) { out[mode ? iid : vid] = in.a; }\n"
"vertex void vd_i(vini in [[stage_in]], device uint4 *out [[buffer(1)]], constant uint &mode [[buffer(2)]], uint vid [[vertex_id]], uint iid [[instance_id]]) { out[mode ? iid : vid] = as_type<uint4>(in.a); }\n";

static MTLCompileOptions *opts(void) {   // 同出包的编法（-fmetal-math-mode=relaxed -fpreserve-invariance），宿主设备现编也是这一套（nvn_mtl.m dm_msl_opts）
    MTLCompileOptions *o = [MTLCompileOptions new]; o.preserveInvariance = YES; o.mathMode = MTLMathModeRelaxed; return o;
}
static id<MTLRenderPipelineState> rp(id<MTLLibrary> l, NSString *fn, MTLVertexDescriptor *vd, BOOL raster) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = [l newFunctionWithName:fn]; d.rasterizationEnabled = raster; d.vertexDescriptor = vd;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    if (raster) { id<MTLFunction> f = [l newFunctionWithName:@"t_frag"]; d.fragmentFunction = f; }
    if (!d.vertexFunction) { fprintf(stderr, "no function %s\n", fn.UTF8String); exit(1); }
    NSError *e = nil; id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    if (!ps) { fprintf(stderr, "pipeline %s: %s\n", fn.UTF8String, e.localizedDescription.UTF8String); exit(1); }
    return ps;
}
// bufs: (缓冲, 槽) 对；lay：布局块（槽 16），它引用的顶点缓冲另以 useResource 声明
static void run(id<MTLRenderPipelineState> ps, id<MTLBuffer> vb, int vd_slot, id<MTLBuffer> vb2, int vd_slot2, id<MTLBuffer> lay, id<MTLBuffer> out, uint32_t mode, int nvert, int ninst, int binst) {
    MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor new]; p.colorAttachments[0].texture = rt; p.colorAttachments[0].loadAction = MTLLoadActionDontCare; p.colorAttachments[0].storeAction = MTLStoreActionDontCare;
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:p];
    [e setRenderPipelineState:ps];
    if (vd_slot >= 0) [e setVertexBuffer:vb offset:0 atIndex:(NSUInteger)vd_slot];
    if (vb2 && vd_slot2 >= 0) [e setVertexBuffer:vb2 offset:0 atIndex:(NSUInteger)vd_slot2];
    if (lay) { [e setVertexBuffer:lay offset:0 atIndex:16]; [e useResource:vb usage:MTLResourceUsageRead stages:MTLRenderStageVertex]; if (vb2) [e useResource:vb2 usage:MTLResourceUsageRead stages:MTLRenderStageVertex]; }
    [e setVertexBuffer:out offset:0 atIndex:1]; [e setVertexBytes:&mode length:4 atIndex:2];
    [e drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:(NSUInteger)nvert instanceCount:(NSUInteger)ninst baseInstance:(NSUInteger)binst];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    EXPECT("command buffer without error", 0, cb.error != nil);
}
static int int_class(MTLVertexFormat f) {   // 1 无符号、2 有符号整数输入；0 浮点
    switch (f) {
        case MTLVertexFormatUChar: case MTLVertexFormatUChar2: case MTLVertexFormatUChar3: case MTLVertexFormatUChar4: case MTLVertexFormatUShort: case MTLVertexFormatUShort2:
        case MTLVertexFormatUShort3: case MTLVertexFormatUShort4: case MTLVertexFormatUInt: case MTLVertexFormatUInt2: case MTLVertexFormatUInt3: case MTLVertexFormatUInt4: return 1;
        case MTLVertexFormatChar: case MTLVertexFormatChar2: case MTLVertexFormatChar3: case MTLVertexFormatChar4: case MTLVertexFormatShort: case MTLVertexFormatShort2:
        case MTLVertexFormatShort3: case MTLVertexFormatShort4: case MTLVertexFormatInt: case MTLVertexFormatInt2: case MTLVertexFormatInt3: case MTLVertexFormatInt4: return 2;
        default: return 0;
    }
}
static int elem_size(MTLVertexFormat f) {   // Metal 格式一个元素的字节数（手写，按 Metal 格式定义）
    switch (f) {
        case MTLVertexFormatUCharNormalized: case MTLVertexFormatCharNormalized: case MTLVertexFormatUChar: case MTLVertexFormatChar: return 1;
        case MTLVertexFormatHalf: case MTLVertexFormatUShortNormalized: case MTLVertexFormatShortNormalized: case MTLVertexFormatUShort: case MTLVertexFormatShort:
        case MTLVertexFormatUChar2Normalized: case MTLVertexFormatChar2Normalized: case MTLVertexFormatUChar2: case MTLVertexFormatChar2: return 2;
        case MTLVertexFormatUChar3Normalized: case MTLVertexFormatChar3Normalized: case MTLVertexFormatUChar3: case MTLVertexFormatChar3: return 3;
        case MTLVertexFormatHalf3: case MTLVertexFormatUShort3Normalized: case MTLVertexFormatShort3Normalized: case MTLVertexFormatUShort3: case MTLVertexFormatShort3: return 6;
        case MTLVertexFormatHalf4: case MTLVertexFormatUShort4Normalized: case MTLVertexFormatShort4Normalized: case MTLVertexFormatUShort4: case MTLVertexFormatShort4:
        case MTLVertexFormatFloat2: case MTLVertexFormatUInt2: case MTLVertexFormatInt2: return 8;
        case MTLVertexFormatFloat3: case MTLVertexFormatUInt3: case MTLVertexFormatInt3: return 12;
        case MTLVertexFormatFloat4: case MTLVertexFormatUInt4: case MTLVertexFormatInt4: return 16;
        default: return 4;   // Float / UInt / Int / 4×8 位 / 2×16 位 / 10:10:10:2 / RG11B10F / BGRA8
    }
}
static int one_byte_comp(MTLVertexFormat f) {   // 8 位分量的格式（可放在任意地址）
    switch (f) {
        case MTLVertexFormatUCharNormalized: case MTLVertexFormatCharNormalized: case MTLVertexFormatUChar: case MTLVertexFormatChar: case MTLVertexFormatUChar2Normalized:
        case MTLVertexFormatChar2Normalized: case MTLVertexFormatUChar2: case MTLVertexFormatChar2: case MTLVertexFormatUChar3Normalized: case MTLVertexFormatChar3Normalized:
        case MTLVertexFormatUChar3: case MTLVertexFormatChar3: case MTLVertexFormatUChar4Normalized: case MTLVertexFormatChar4Normalized: case MTLVertexFormatUChar4:
        case MTLVertexFormatChar4: case MTLVertexFormatUChar4Normalized_BGRA: return 1;
        default: return 0;
    }
}
static int is_half(MTLVertexFormat f) { return f == MTLVertexFormatHalf || f == MTLVertexFormatHalf2 || f == MTLVertexFormatHalf3 || f == MTLVertexFormatHalf4; }
static int is_float(MTLVertexFormat f) { return f == MTLVertexFormatFloat || f == MTLVertexFormatFloat2 || f == MTLVertexFormatFloat3 || f == MTLVertexFormatFloat4; }

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 4) { fprintf(stderr, "usage: t_vs_pull_run <prelude.metal> <original.metal> <variant.metal>\n"); return 2; }
    dev = MTLCreateSystemDefaultDevice(); q = [dev newCommandQueue]; NSError *err = nil;
    NSString *fetch = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&err];
    if (!fetch) { fprintf(stderr, "%s: %s\n", argv[1], err.localizedDescription.UTF8String); return 1; }
    lib = [dev newLibraryWithSource:[NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n%@\n%@", fetch, k_test] options:opts() error:&err];
    if (!lib) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); return 1; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO]; td.usage = MTLTextureUsageRenderTarget; rt = [dev newTextureWithDescriptor:td];
    enum { NV = 512 };
    id<MTLBuffer> out = [dev newBufferWithLength:NV * 16 options:MTLResourceStorageModeShared], lay = [dev newBufferWithLength:sizeof(dm_vlayout_c) options:MTLResourceStorageModeShared];
    id<MTLRenderPipelineState> pull = rp(lib, @"pull_test", nil, NO);
    srand(12345);
    // ① 逐格式
    int nfmt = 0, nvd = 0, ni2f = 0;
    printf("FMT");
    for (int f = 1; f < 256; f++) {
        MTLVertexFormat mf = vfmt(f);
        if (mf == MTLVertexFormatInvalid) continue;
        printf(" %d", f); nfmt++;
        int ib, is, in = vconv_i2f(f, &ib, &is);
        int es = elem_size(mf), ic = int_class(mf), k8 = one_byte_comp(mf);
        for (int pass = 0; pass < (k8 ? 3 : 1); pass++) {   // 8 位格式：4 字节对齐、2 字节偏移、（1 字节的）跨距 1
            int stride = ((es + 3) & ~3) + 4, off = 4;
            if (pass == 1) off = 2;
            if (pass == 2) { if (es != 1) continue; stride = 1; off = 0; }
            id<MTLBuffer> vb = [dev newBufferWithLength:(NSUInteger)(NV * stride + 64) options:MTLResourceStorageModeShared];
            uint8_t *p = vb.contents; for (int i = 0; i < NV * stride + 64; i++) p[i] = (uint8_t)rand();
            for (int v = 0; v < NV && stride > 1; v++) {   // 端值
                uint8_t *e = p + v * stride + off;
                if (k8) for (int c = 0; c < es; c++) e[c] = (uint8_t)(v + 37 * c);   // 每个分量走遍 0–255（含 -128）
                if (is_half(mf) && v < 16) {
                    static const uint16_t H[16] = { 0x0000, 0x8000, 0x0001, 0x03ff, 0x0400, 0x7bff, 0x7c00, 0xfc00, 0x7e00, 0x7d01, 0xfe00, 0x3c00, 0xbc00, 0x8001, 0x7fff, 0xffff };
                    for (int c = 0; c < es / 2; c++) memcpy(e + 2 * c, &H[(v + c) & 15], 2); }
                if (is_float(mf) && v < 8) {
                    static const uint32_t F[8] = { 0x7fc12345, 0x7f800001, 0x00000001, 0x80000000, 0x7f800000, 0xff800000, 0x807fffff, 0x3f800000 };
                    for (int c = 0; c < es / 4; c++) memcpy(e + 4 * c, &F[(v + c) & 7], 4); }
                if ((mf == MTLVertexFormatInt1010102Normalized || mf == MTLVertexFormatUInt1010102Normalized) && v < 4) {
                    uint32_t w = v == 0 ? 0x80000000u | 0x200u | (0x200u << 10) | (0x200u << 20) : v == 1 ? 0x40000000u | 0x1ffu : v == 2 ? 0xc0000000u : 0x3fffffffu; memcpy(e, &w, 4); }
            }
            dm_vlayout_c L; memset(&L, 0, sizeof L); L.s[0].base = vb.gpuAddress; L.s[0].stride = (uint32_t)stride; L.attr[0] = attr_word((uint32_t)f, (uint32_t)off, 0); memcpy(lay.contents, &L, sizeof L);
            static uint32_t got[NV][4], want[NV][4];
            memset(out.contents, 0xcd, NV * 16); run(pull, vb, -1, nil, -1, lay, out, 0, NV, 1, 0); memcpy(got, out.contents, sizeof got);
            MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor]; vd.attributes[0].format = mf; vd.attributes[0].offset = (NSUInteger)off; vd.attributes[0].bufferIndex = 20;
            vd.layouts[20].stride = (NSUInteger)stride; vd.layouts[20].stepFunction = MTLVertexStepFunctionPerVertex;
            memset(out.contents, 0xcd, NV * 16); run(rp(lib, ic == 1 ? @"vd_u" : ic == 2 ? @"vd_i" : @"vd_f", vd, NO), vb, 20, nil, -1, nil, out, 0, NV, 1, 0); memcpy(want, out.contents, sizeof want); nvd++;
            if (in) {   // 整数读成浮点：Metal 抓到的整数逐分量转浮点（有符号按 int），缺的分量 0, 0, 0, 1.0
                ni2f++;
                for (int v = 0; v < NV; v++) for (int c = 0; c < 4; c++) {
                    float x = c < in ? (is ? (float)(int32_t)want[v][c] : (float)want[v][c]) : c == 3 ? 1.0f : 0.0f;
                    memcpy(&want[v][c], &x, 4);
                }
            }
            int bad = 0, ex = 0;
            for (int v = 0; v < NV; v++) for (int c = 0; c < 4; c++) if (got[v][c] != want[v][c]) { bad++; if (ex++ < 3) fprintf(stderr, "  format %#x stride %d offset %d vertex %d component %d: pulled %08x, Metal fetch%s %08x\n", f, stride, off, v, c, got[v][c], in ? " + float conversion" : "", want[v][c]); }
            char name[128]; snprintf(name, sizeof name, "format %#x (stride %d, offset %d): words differing", f, stride, off);
            EXPECT(name, 0, bad);
        }
    }
    printf("\nCHECK formats %d, Metal fetch comparisons %d, of them integer-as-float %d\n", nfmt, nvd, ni2f);
    // ② 跨距 0 与除数（起始实例 5、7 个实例）
    {
        id<MTLBuffer> vb = [dev newBufferWithLength:64 * 16 options:MTLResourceStorageModeShared];
        float *fp = vb.contents; for (int i = 0; i < 64 * 4; i++) fp[i] = (float)i;
        int nstep = 0;
        for (int t = 0; t < 4; t++) {
            int divisor = t, zero = t == 0, binst = 5, ninst = 7;
            dm_vlayout_c L; memset(&L, 0, sizeof L); L.s[0].base = vb.gpuAddress; L.s[0].stride = zero ? 0 : 16; L.s[0].divisor = (uint32_t)divisor; L.attr[0] = attr_word(0x2E, 0, 0); memcpy(lay.contents, &L, sizeof L);
            MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor]; vd.attributes[0].format = MTLVertexFormatFloat4; vd.attributes[0].bufferIndex = 20;
            vd.layouts[20].stride = zero ? 4 : 16; vd.layouts[20].stepFunction = zero ? MTLVertexStepFunctionConstant : MTLVertexStepFunctionPerInstance; vd.layouts[20].stepRate = zero ? 0 : (NSUInteger)divisor;
            uint32_t a[16][4], b[16][4];
            memset(out.contents, 0, NV * 16); run(rp(lib, @"vd_f", vd, NO), vb, 20, nil, -1, nil, out, 1, 1, ninst, binst); memcpy(a, out.contents, sizeof a);
            memset(out.contents, 0, NV * 16); run(pull, vb, -1, nil, -1, lay, out, 1, 1, ninst, binst); memcpy(b, out.contents, sizeof b);
            for (int i = binst; i < binst + ninst; i++) {
                char name[96]; snprintf(name, sizeof name, "%s, base instance 5: element instance %d reads", zero ? "stride 0" : divisor == 1 ? "divisor 1" : divisor == 2 ? "divisor 2" : "divisor 3", i);
                EXPECT(name, a[i][0], b[i][0]); nstep++;
                // 手写真值：跨距 0 读元素 0；除数 d 读元素 5 + (i − 5) / d（元素 k 的 x = 4k）
                uint32_t want_elem = zero ? 0 : 5 + (uint32_t)(i - 5) / (uint32_t)divisor; float wx = (float)(4 * want_elem); uint32_t wb; memcpy(&wb, &wx, 4);
                snprintf(name, sizeof name, "%s: instance %d reads element %u", zero ? "stride 0" : "divisor", i, want_elem);
                EXPECT(name, wb, b[i][0]);
            }
        }
        printf("CHECK step %d\n", nstep);
    }
    // ③ 基址不是 4 的倍数：低 2 位并进属性偏移（契约），对「元素拷到对齐处再用 Metal 抓取」
    {
        enum { ST = 24, NE = 32 };
        id<MTLBuffer> mem = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared]; uint8_t *mp = mem.contents; for (int i = 0; i < 4096; i++) mp[i] = (uint8_t)rand();
        id<MTLBuffer> ref = [dev newBufferWithLength:NE * 16 options:MTLResourceStorageModeShared];
        int fmts[5] = { 0x29, 0x69, 0x25, 0x0F, 0x01 };   // RGBA16F、RGB10A2 snorm、RGBA8 unorm、RG8UI、R8 unorm
        int nmis = 0;
        for (int mis = 1; mis < 4; mis++) {
            int offs[5] = { mis & 1, 12 - mis, 13, 17, 3 };   // 元素地址 = 基址 + mis + 偏移：偶数、4 的倍数、奇数、奇数、任意（分量保持 Metal 抓取要的对齐）
            uint64_t addr = mem.gpuAddress + 64 + (uint64_t)mis;   // 游戏给的流基址，不是 4 的倍数
            for (int a = 0; a < 5; a++) {
                MTLVertexFormat mf = vfmt(fmts[a]); int es = elem_size(mf), ic = int_class(mf);
                dm_vlayout_c L; memset(&L, 0, sizeof L); L.s[2].base = addr & ~3ull; L.s[2].stride = ST; L.attr[0] = attr_word((uint32_t)fmts[a], (uint32_t)offs[a] + (uint32_t)(addr & 3), 2);
                memcpy(lay.contents, &L, sizeof L);
                uint32_t got[NE][4], want[NE][4];
                memset(out.contents, 0, NV * 16); run(pull, mem, -1, nil, -1, lay, out, 0, NE, 1, 0); memcpy(got, out.contents, sizeof got);
                for (int v = 0; v < NE; v++) memcpy((uint8_t *)ref.contents + v * 16, mp + 64 + mis + v * ST + offs[a], (size_t)es);
                MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor]; vd.attributes[0].format = mf; vd.attributes[0].bufferIndex = 20; vd.layouts[20].stride = 16;
                memset(out.contents, 0, NV * 16); run(rp(lib, ic == 1 ? @"vd_u" : ic == 2 ? @"vd_i" : @"vd_f", vd, NO), ref, 20, nil, -1, nil, out, 0, NE, 1, 0); memcpy(want, out.contents, sizeof want);
                char name[128]; snprintf(name, sizeof name, "base +%d, format %#x at offset %d: words as Metal's fetch of an aligned copy", mis, fmts[a], offs[a]);
                EXPECT(name, 0, (uint64_t)(memcmp(got, want, sizeof got) != 0)); nmis++;
            }
        }
        printf("CHECK unaligned %d\n", nmis);
    }
    // ④ 端到端：原样（[[stage_in]] + 顶点描述）vs 变体（布局块）
    {
        NSString *orig = [NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:&err], *var = [NSString stringWithContentsOfFile:@(argv[3]) encoding:NSUTF8StringEncoding error:&err];
        NSString *frag = @"\nfragment float4 t_frag() { return float4(1.0); }\n";
        id<MTLLibrary> lo = [dev newLibraryWithSource:[orig stringByAppendingString:frag] options:opts() error:&err];
        if (!lo) { fprintf(stderr, "original: %s\n", err.localizedDescription.UTF8String); return 1; }
        id<MTLLibrary> lv = [dev newLibraryWithSource:[var stringByAppendingString:frag] options:opts() error:&err];
        if (!lv) { fprintf(stderr, "variant: %s\n", err.localizedDescription.UTF8String); return 1; }
        NSArray *names = [lv.functionNames sortedArrayUsingSelector:@selector(compare:)];
        printf("CHECK variant functions %s\n", [names componentsJoinedByString:@","].UTF8String);
        enum { N = 6, NI = 4, BI = 3, S0 = 20, S1 = 8 };
        id<MTLBuffer> v0 = [dev newBufferWithLength:N * S0 + 64 options:MTLResourceStorageModeShared], v1 = [dev newBufferWithLength:8 * S1 + 64 options:MTLResourceStorageModeShared];
        uint8_t *p0 = v0.contents, *p1 = v1.contents; for (int i = 0; i < N * S0 + 64; i++) p0[i] = (uint8_t)rand(); for (int i = 0; i < 8 * S1 + 64; i++) p1[i] = (uint8_t)rand();
        // 属性 0：RGBA8 unorm（流 0 偏移 0）→ float4；属性 5：RG8UI（流 0 偏移 6）→ uint4；属性 20：RGBA16 sint（流 1 偏移 0，逐实例除数 2）→ int4
        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        vd.attributes[0].format = vfmt(0x25); vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 21;
        vd.attributes[5].format = vfmt(0x0F); vd.attributes[5].offset = 6; vd.attributes[5].bufferIndex = 21;
        vd.attributes[20].format = vfmt(0x2D); vd.attributes[20].offset = 0; vd.attributes[20].bufferIndex = 22;
        vd.layouts[21].stride = S0; vd.layouts[21].stepFunction = MTLVertexStepFunctionPerVertex;
        vd.layouts[22].stride = S1; vd.layouts[22].stepFunction = MTLVertexStepFunctionPerInstance; vd.layouts[22].stepRate = 2;
        dm_vlayout_c L; memset(&L, 0, sizeof L);
        L.s[0].base = v0.gpuAddress; L.s[0].stride = S0; L.s[1].base = v1.gpuAddress; L.s[1].stride = S1; L.s[1].divisor = 2;
        L.attr[0] = attr_word(0x25, 0, 0); L.attr[5] = attr_word(0x0F, 6, 0); L.attr[20] = attr_word(0x2D, 0, 1); memcpy(lay.contents, &L, sizeof L);
        for (int z = 0; z < 2; z++) {
            NSString *fn = z ? @"main0_z" : @"main0";
            uint32_t a[NI * N * 3][4], b[NI * N * 3][4];
            memset(out.contents, 0xcd, NV * 16); run(rp(lo, fn, vd, YES), v0, 21, v1, 22, nil, out, 0, N, NI, BI); memcpy(a, out.contents, sizeof a);
            memset(out.contents, 0xab, NV * 16); run(rp(lv, fn, nil, YES), v0, -1, v1, -1, lay, out, 0, N, NI, BI); memcpy(b, out.contents, sizeof b);
            int bad = 0; for (int i = 0; i < NI * N * 3; i++) for (int c = 0; c < 4; c++) if (a[i][c] != b[i][c]) { if (bad++ < 3) fprintf(stderr, "  %s word %d.%d: stage_in %08x, pulled %08x\n", fn.UTF8String, i, c, a[i][c], b[i][c]); }
            int unwritten = 0; for (int i = 0; i < NI * N * 3; i++) if (a[i][0] == 0xcdcdcdcdu && a[i][1] == 0xcdcdcdcdu) unwritten++;
            char name[96]; snprintf(name, sizeof name, "end to end %s: inputs written by the shader differ", fn.UTF8String); EXPECT(name, 0, bad);
            snprintf(name, sizeof name, "end to end %s: every vertex of every instance wrote its inputs", fn.UTF8String); EXPECT(name, 0, unwritten);
            printf("CHECK e2e %s %d words, %d differ\n", fn.UTF8String, NI * N * 3 * 4, bad);
        }
    }
    printf("t_vs_pull_run: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
