// 混合管线（nvn_hybrid.inc）：首遇没有精确管线、又不能跳过的绘制，用这对着色器的拉取管线先画。直接包含生产 nvn_mtl.m 调 pso_get_，着色器是现编的真 Metal 函数（拉取版手写，
//   读的就是 nvn_hybrid.inc 的布局块）。期望按规则手写，不由被测实现推出：
//   ① 第一次首遇、这对的拉取基础管线还没有：照旧拿精确管线（不是拉取的，g_pso_pull 0），后台踢出 1 条基础管线
//   ② 基础管线建好后，同一对换一种画布格式（新管线键）首遇：拿到拉取管线（g_pso_pull 1，不是精确那条），精确那条已在后台表里（状态 1 / 2）；特化计数 +1
//   ③ 同一键再取：精确那条编好前给同一条拉取管线（不再特化），编好后给精确的（g_pso_pull 0）
//   ④ 布局块：流 0 基址 0x...2（不按 4 对齐）→ 填的基址是它按 4 下取整、属性偏移 + 2；步长、除数原样；没登记的流（流 1 指向池外）不填、它的属性字 0
//   ⑤ 拉取管线真能画：用 Metal 4 命令编码器、槽 16 绑布局块画一个三角形，读回像素 = 精确管线在同样顶点数据上画的（片元输出顶点属性）
//   反证：DM_PSO_HYBRID=0（子进程）→ ② 拿到的是精确管线、g_pso_pull 0
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/wait.h>

static unsigned failures, checks;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\n"
"struct VO { float4 p [[position]]; float4 a [[user(locn0)]]; };\n"
"struct VI { float4 m_0 [[attribute(0)]]; };\n"
"vertex VO main0(VI in [[stage_in]]) { VO o; o.p = float4(in.m_0.xy, 0, 1); o.a = in.m_0; return o; }\n"
// 拉取版：布局块与 nvn_hybrid.inc pull_layout 同（属性字 = 格式 8 位、偏移 19 位、流 5 位）；这里只解 RGBA32F
"struct dm_vstream { device const uchar *base; uint stride; uint divisor; };\n"
"struct dm_vlayout { dm_vstream s[16]; uint attr[32]; };\n"
"vertex VO main0_p(constant dm_vlayout& L [[buffer(16)]], uint vid [[vertex_id]]) {\n"
"  uint w = L.attr[0], off = (w >> 8) & 0x7ffffu, st = w >> 27;\n"
"  float4 m = *(device const packed_float4 *)(L.s[st].base + off + vid * L.s[st].stride);\n"
"  VO o; o.p = float4(m.xy, 0, 1); o.a = m; return o; }\n"
"struct F0 { float4 a [[user(locn0)]]; };\n"
"fragment float4 fa(F0 i [[stage_in]]) { return i.a; }\n";

static NvShader *shader(id<MTLLibrary> lib, NSString *fn, const char *key, int stage) {
    NvShader *s = [NvShader new]; s->stage = stage; s->fn = [lib newFunctionWithName:fn]; REQUIRE(s->fn); s->plib = lib; strlcpy(s->key, key, sizeof s->key);
    s->rf.has_user = stage == 0 ? 1 : 2; if (stage == 0) s->rf.user_out = 1u; else s->rf.user_in = 1u;
    if (stage == 0) { s->rf.nv = 1; s->rf.v[0].loc = 0; s->rf.v[0].nvn = 0; s->rf.v[0].ct = NVN_CT_FLOAT; s->ventry = @"main0"; }
    return s;
}
static int wait_bases(uint64_t want) { for (int i = 0; i < 500 && g_hy_bases < want; i++) usleep(10000); return g_hy_bases >= want; }

static int run(int hybrid) {
    setenv("DM_NVN_FIRST_SKIP", "0", 1);   // 测的是不能跳的首遇（跳过那条路另有单测）
    if (!hybrid) setenv("DM_PSO_HYBRID", "0", 1);
    char user[] = "/tmp/t_nvn_hybrid_XXXXXX"; int fd = mkstemp(user); REQUIRE(fd >= 0); close(fd); setenv("DM_PSO_USER", user, 1);
    char map[] = "/tmp/t_nvn_hybrid_map_XXXXXX"; fd = mkstemp(map); REQUIRE(fd >= 0); close(fd); setenv("DM_NVN_SHMAP", map, 1);
    setenv("DM_NVN_PSO_FRAME_MS", "0", 1);
    mtl_init();
    if (hybrid && !hybrid_on()) { printf("SKIP 本机不是 Metal 4 后端（macOS 26 以下或 NXGAL_BE=mtl3）：混合管线不适用\n"); return 0; }
    NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&e]; REQUIRE(lib);
    NvShader *vs = shader(lib, @"main0", "aaaaaaaaaaaaaaaa_b", 0), *fs = shader(lib, @"fa", "cccccccccccccccc_b", 1);
    vs->has_pull = 1; vs->pfn = [lib newFunctionWithName:@"main0_p"]; vs->pull_lib = lib; vs->pfn_state = 1; REQUIRE(vs->pfn);
    NvProg *pr = [NvProg new]; pr->sh[0] = vs; pr->sh[1] = fs;
    // 顶点数据：池里 3 个 RGBA32F 顶点，流 0 基址故意不按 4 对齐（+2）
    static uint8_t *pool; REQUIRE(!posix_memalign((void **)&pool, 16384, 65536)); memset(pool, 0, 65536); nvn_be_pool_add(pool, 65536);
    const float verts[3][4] = {{-1, -1, 0.25f, 1}, {3, -1, 0.25f, 1}, {-1, 3, 0.25f, 1}};
    uint8_t *vb = pool + 4096 + 2; memcpy(vb, verts, sizeof verts);
    memset(&S, 0, sizeof S); S.nattr = 1; S.attr[0].fmt = 0x2E; S.attr[0].offset = 0; S.attr[0].stream = 0;
    S.stream[0].stride = 16; S.vbuf[0].address = (uint64_t)(uintptr_t)vb; S.vbuf[0].size = sizeof verts;
    memset(&g_pass, 0, sizeof g_pass); g_pass.cfmt[0] = (uint32_t)MTLPixelFormatRGBA32Float; g_pass.samples = 1;

    // ① 第一次首遇：基础管线还没有
    uint64_t kick0 = g_hy_kicked; id ps1 = pso_get_(pr, nil); int pull1 = g_pso_pull;
    if (hybrid) VERIFY(ps1 && !pull1 && g_hy_kicked - kick0 == 1, "① 第一次首遇：拿到精确管线 %d、g_pso_pull %d（期望 0）、后台踢出基础管线 %llu 条（期望 1）", ps1 != nil, pull1, (unsigned long long)(g_hy_kicked - kick0));
    if (hybrid) REQUIRE(wait_bases(1));
    // ② 同一对、换画布格式：新键
    g_pass.cfmt[0] = (uint32_t)MTLPixelFormatRGBA16Float;
    pso_key k2; pso_key_fill(&k2, vs, fs, g_pass.cfmt, 0, 0, 1, 0);
    uint64_t made0 = g_hy_made; id ps2 = pso_get_(pr, nil); int pull2 = g_pso_pull, st2 = pso_pend_state(&k2);
    if (!hybrid) { VERIFY(ps2 && !pull2, "反证 DM_PSO_HYBRID=0：② 拿到精确管线 %d、g_pso_pull %d（期望 0）", ps2 != nil, pull2); return 0; }
    VERIFY(ps2 && pull2 && ps2 != ps1 && (st2 == 1 || st2 == 2) && g_hy_made - made0 == 1, "② 基础管线已建好的首遇：拉取管线 g_pso_pull %d（期望 1）、精确那条在后台表里（状态 %d，期望 1 / 2）、特化 +%llu（期望 1）",
           pull2, st2, (unsigned long long)(g_hy_made - made0));
    // ③ 同键再取：精确那条编好前同一条拉取管线、编好后精确的
    id ps3 = pso_get_(pr, nil); int pull3 = g_pso_pull;
    if (pull3) VERIFY(ps3 == ps2 && g_hy_made - made0 == 1, "③ 精确那条还在编：同一条拉取管线、不再特化（特化 +%llu）", (unsigned long long)(g_hy_made - made0));
    for (int i = 0; i < 500 && pso_pend_state(&k2) != 2; i++) usleep(10000);
    id ps4 = pso_get_(pr, nil);
    VERIFY(ps4 && !g_pso_pull && ps4 != ps2, "③ 精确那条编好后：给精确管线（g_pso_pull %d，期望 0）", g_pso_pull);
    // ④ 布局块（手算）
    pull_layout L; pull_layout_fill(&L, vs);
    uint64_t gpu = 0; void *mb; uint64_t mo; REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)vb, sizeof verts, &mb, &mo, &gpu));
    va_st w; memcpy(&w, &L.attr[0], 4);
    VERIFY(L.s[0].base == (gpu & ~3ull) && L.s[0].stride == 16 && L.s[0].divisor == 0 && w.fmt == 0x2E && w.offset == (gpu & 3) && w.stream == 0,
           "④ 流 0 基址 %#llx（期望 %#llx = 按 4 下取整）、步长 %u、除数 %u；属性 0 格式 %#x、偏移 %u（期望 %llu）、流 %u",
           (unsigned long long)L.s[0].base, (unsigned long long)(gpu & ~3ull), L.s[0].stride, L.s[0].divisor, w.fmt, w.offset, (unsigned long long)(gpu & 3), w.stream);
    S.vbuf[1].address = 0x1234560; S.vbuf[1].size = 64; S.nattr = 2; S.attr[1].fmt = 0x2E; S.attr[1].stream = 1; pull_layout_fill(&L, vs);
    VERIFY(L.s[1].base == 0 && L.attr[1] == 0, "④ 池外的流 1：基址 %#llx、属性 1 字 %#x（期望都 0：读 0）", (unsigned long long)L.s[1].base, L.attr[1]);
    S.nattr = 1; S.vbuf[1].address = 0;
    // ⑤ 真画：拉取管线（Metal 4 编码器、槽 16 布局块）与精确管线（同一份顶点数据经顶点描述）画出的像素一致
    if (@available(macOS 26.0, iOS 26.0, *)) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
        uint16_t px[2][4]; id<MTLRenderPipelineState> pss[2] = {ps2, ps4};
        id<MTLBuffer> lb = [g_dev newBufferWithLength:sizeof L options:MTLResourceStorageModeShared]; pull_layout_fill(&L, vs); memcpy(lb.contents, &L, sizeof L);
        id<MTLBuffer> poolb = [g_dev newBufferWithBytesNoCopy:pool length:65536 options:MTLResourceStorageModeShared deallocator:nil];
        id<MTL4CommandQueue> q = [g_dev newMTL4CommandQueue]; id<MTL4CommandAllocator> ca = [g_dev newCommandAllocator];
        id<MTLResidencySet> rs = [g_dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&e]; REQUIRE(rs);
        for (int i = 0; i < 2; i++) {
            id<MTLTexture> t = [g_dev newTextureWithDescriptor:td];
            [rs addAllocation:t]; [rs addAllocation:lb]; [rs addAllocation:poolb]; [rs commit];
            id<MTL4CommandBuffer> cb = [g_dev newCommandBuffer]; [cb beginCommandBufferWithAllocator:ca]; [cb useResidencySet:rs];
            MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new]; rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTL4RenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
            id<MTL4ArgumentTable> at; MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 31; at = [g_dev newArgumentTableWithDescriptor:ad error:&e]; REQUIRE(at);
            [at setAddress:(i == 0 ? lb.gpuAddress : gpu) atIndex:16];   // 拉取：布局块；精确：流 0 = VB_SLOT(0) = 16
            [en setArgumentTable:at atStages:MTLRenderStageVertex]; [en setRenderPipelineState:pss[i]];
            [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding]; [cb endCommandBuffer];
            id<MTLSharedEvent> ev = [g_dev newSharedEvent]; [q commit:&cb count:1]; [q signalEvent:ev value:1]; [ev waitUntilSignaledValue:1 timeoutMS:5000];
            [t getBytes:px[i] bytesPerRow:32 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
        }
        // 片元输出顶点属性 (?, ?, 0.25, 1) 插值：z、w 恒定；两条管线逐位相同、且 z = 0.25（half 0x3400）、w = 1（0x3c00）
        VERIFY(!memcmp(px[0], px[1], sizeof px[0]) && px[0][2] == 0x3400 && px[0][3] == 0x3c00, "⑤ 拉取管线与精确管线画出的像素：%04x %04x %04x %04x / %04x %04x %04x %04x（期望逐位相同、z 0x3400、w 0x3c00）",
               px[0][0], px[0][1], px[0][2], px[0][3], px[1][0], px[1][1], px[1][2], px[1][3]);
    }
    return 0;
}
int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc == 3 && !strcmp(argv[1], "--child")) { run(atoi(argv[2])); printf("%s t_nvn_hybrid 子进程（DM_PSO_HYBRID=%s）：%u 项，%u 项不符\n", failures ? "✗" : "✓", argv[2], checks, failures); return failures != 0; }
    unsigned bad = 0; static const char *const modes[2] = {"1", "0"};
    for (int m = 0; m < 2; m++) {
        fflush(NULL); pid_t pid = fork(); REQUIRE(pid >= 0);
        if (!pid) { execl(argv[0], argv[0], "--child", modes[m], (char *)NULL); _exit(127); }
        int st = 0; pid_t w; do { w = waitpid(pid, &st, 0); } while (w < 0 && errno == EINTR); REQUIRE(w == pid);
        bad += !(WIFEXITED(st) && WEXITSTATUS(st) == 0);
    }
    printf("%s t_nvn_hybrid：缺省 / DM_PSO_HYBRID=0 两个子进程，%u 个不过（混合管线：首遇不能跳的绘制用拉取管线先画）\n", bad ? "✗" : "✓", bad);
    return bad != 0;
} }
