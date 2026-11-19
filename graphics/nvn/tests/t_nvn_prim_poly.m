// 多边形（NVN_DRAW_PRIMITIVE_POLYGON = 9）与四边形条带（QUAD_STRIP = 8）：Metal 没有这两种图元，nvn_mtl.m draw() 按顶点顺序换成三角扇 / 三角条带（同 OpenGL 定义）。
//   真实 Metal 管线、生产回放入口 nvn_be_exec、GPU 读回。期望手算：4 个顶点围出 NDC [-0.5, 0.5]² 的方块，128x128 目标上像素中心落在 [32, 96)² 的 64 × 64 = 4096 个点亮，
//   方块外一个不亮（数总数，再查方块四角内侧与外侧各一点）。
//   ① 多边形 4 顶点（非索引）② 多边形 4 顶点（索引，16 位索引 0 1 2 3）③ 四边形条带 4 顶点（非索引）
//   负对照：换回 main 的 nvn_mtl.m（没有换算）→ 三例都走到「primitive type … not implemented」整笔跳过、0 个像素
#ifndef NVN_PRIM_SOURCE
#define NVN_PRIM_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_PRIM_SOURCE

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { W = 128, POOL = 1 << 20 };
static NSString *const source = @"#include <metal_stdlib>\nusing namespace metal;\n"
// poly：凸多边形的顶点顺序（左下、右下、右上、左上）；strip：四边形条带的顶点顺序（左下、右下、左上、右上）。两者都围出 NDC [-0.5, 0.5]² 的方块
"vertex float4 poly(uint v [[vertex_id]]) { const float2 p[4] = {float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.5, 0.5), float2(-0.5, 0.5)}; return float4(p[v & 3u], 0, 1); }\n"
"vertex float4 strip(uint v [[vertex_id]]) { const float2 p[4] = {float2(-0.5, -0.5), float2(0.5, -0.5), float2(-0.5, 0.5), float2(0.5, 0.5)}; return float4(p[v & 3u], 0, 1); }\n"
"fragment float4 white() { return float4(1); }\n";
static NvShader *shader(id<MTLLibrary> library, NSString *name, int stage) {
    NvShader *s = [NvShader new]; s->stage = stage;
    s->fn = [library newFunctionWithName:name]; REQUIRE(s->fn);
    strlcpy(s->key, stage ? "dddddddddddddddd_b" : "cccccccccccccccc_b", sizeof s->key);
    s->rf.pos_attr = -1; s->rf.has_user = stage ? 2 : 1;
    if (stage) { s->rf.color_known = 1; s->rf.color_mask = 1; }
    return s;
}
static uint8_t *g_mem; static tex_t g_rt;
static void clear_rt(void) { p_clear_tex c = {.tex = &g_rt, .value_type = CLEAR_TEX_FLOAT, .r = {0, 0, 0, W, W, 1}, .mask = 15}; clear_tex(&c); }
static void finish(void) { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error()); }
static int g_flip = 0;
static int white_pixels(uint8_t *lit) {   // GPU 读回（不经生产读回路径），lit[i]：第 i 号像素（行优先，按 g_flip 把行序对回顶点着色器的排法）
    id<MTLTexture> image = tex_mtl(&g_rt); REQUIRE(image);
    id<MTLBuffer> buffer = [g_dev newBufferWithLength:W * W * 4 options:MTLResourceStorageModeShared]; REQUIRE(buffer);
    id<MTLCommandQueue> queue = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [queue commandBuffer]; id<MTLBlitCommandEncoder> enc = [cb blitCommandEncoder];
    [enc copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:buffer destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
    [enc endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status == MTLCommandBufferStatusCompleted);
    const uint8_t *b = buffer.contents; int n = 0;
    for (int y = 0; y < W; y++) for (int x = 0; x < W; x++) { int on = b[(y * W + x) * 4] > 128; n += on; if (lit) lit[(g_flip > 0 ? W - 1 - y : y) * W + x] = (uint8_t)on; }
    return n;
}
enum { IDX_OFF = 0x40000 };
static int run(int prim, int indexed) {
    nvn_be_sub_begin(); clear_rt();
    if (!indexed) {
        struct { op_hdr h; p_draw d; op_hdr end; } cmd = {.h = {OP_DRAW, sizeof(op_hdr) + sizeof(p_draw)}, .d = {.prim = prim, .first = 0, .count = 4, .instances = 1}, .end = {OP_END, sizeof(op_hdr)}};
        nvn_be_exec((const uint8_t *)&cmd);
    } else {
        struct { op_hdr h; p_draw_idx d; op_hdr end; } cmd = {.h = {OP_DRAW_IDX, sizeof(op_hdr) + sizeof(p_draw_idx)},
            .d = {.prim = prim, .itype = NVN_INDEX_TYPE_UNSIGNED_SHORT, .count = 4, .instances = 1, .ibuf = (uint64_t)(uintptr_t)(g_mem + IDX_OFF)}, .end = {OP_END, sizeof(op_hdr)}};
        nvn_be_exec((const uint8_t *)&cmd);
    }
    finish();
    static uint8_t lit[W * W]; int n = white_pixels(lit);
    int inside = lit[32 * W + 32] && lit[32 * W + 95] && lit[95 * W + 32] && lit[95 * W + 95], outside = !lit[31 * W + 31] && !lit[31 * W + 96] && !lit[96 * W + 31] && !lit[96 * W + 96];
    return n == 4096 && inside && outside ? n : -n - 1;
}
int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
        char map[] = "/tmp/t_prim_poly_map_XXXXXX"; int fd = mkstemp(map); REQUIRE(fd >= 0); close(fd);
        char user[] = "/tmp/t_prim_poly_user_XXXXXX"; fd = mkstemp(user); REQUIRE(fd >= 0); close(fd);
        setenv("DM_NVN_SHMAP", map, 1); setenv("DM_PSO_USER", user, 1); setenv("DM_PSO_ARCHIVE", "0", 1);
        mtl_init(); printf("DEVICE %s backend=Metal%d\n", g_dev.name.UTF8String, g_m3 ? 3 : 4);
        const op_hdr empty = {OP_END, sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
        NSError *error = nil; id<MTLLibrary> library = [g_dev newLibraryWithSource:source options:nil error:&error];
        if (!library) fprintf(stderr, "MSL: %s\n", error.localizedDescription.UTF8String); REQUIRE(library);
        NvProg *pp = [NvProg new]; pp->sh[0] = shader(library, @"poly", 0); pp->sh[1] = shader(library, @"white", 1);
        NvProg *ps = [NvProg new]; ps->sh[0] = shader(library, @"strip", 0); ps->sh[1] = shader(library, @"white", 1);
        strlcpy(ps->sh[0]->key, "eeeeeeeeeeeeeeee_b", sizeof ps->sh[0]->key);
        prog_t gp = {.magic = MAGIC('P', 'R', 'O', 'G'), .serial = nvn_new_serial()}; serial_put(gp.serial, pp);
        prog_t gs = {.magic = MAGIC('P', 'R', 'O', 'G'), .serial = nvn_new_serial()}; serial_put(gs.serial, ps);
        REQUIRE(!posix_memalign((void **)&g_mem, 65536, POOL)); memset(g_mem, 0, POOL);
        { uint16_t ix[4] = {0, 1, 2, 3}; memcpy(g_mem + IDX_OFF, ix, sizeof ix); }
        pool_t *pool = calloc(1, sizeof *pool); REQUIRE(pool);
        *pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = g_mem, .size = POOL};
        nvn_be_pool_add(g_mem, POOL);
        memset(&g_rt, 0, sizeof g_rt); g_rt.magic = MAGIC('T', 'E', 'X', 0); g_rt.serial = nvn_new_serial();
        g_rt.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = W, .height = W, .depth = 1, .levels = 1, .samples = 1};
        g_rt.pool = pool; g_rt.off = 0; g_rt.mem = g_mem; nvn_tex_layout(&g_rt.d, &g_rt.L); nvn_be_tex_init(&g_rt);
        nvn_be_sub_begin(); state_reset(); S.prog = &gp;
        memset(&R.rt, 0, sizeof R.rt); R.rt.n = 1; R.rt.color[0] = &g_rt; R.has_rt = 1; g_pso_dirty = 1; args_dirty_all();
        finish();
        int n = run(NVN_DRAW_PRIMITIVE_POLYGON, 0); CHECK(n == 4096, "① 多边形 4 顶点（非索引）：%d 个像素（期望 4096，方块内四角亮、外侧四点不亮；负数 = −(像素数 + 1) 且位置不对）", n);
        S.prog = &gp; g_pso_dirty = 1; args_dirty_all();   // 每例前重绑程序（回放的提交收尾会清当前程序）
        n = run(NVN_DRAW_PRIMITIVE_POLYGON, 1); CHECK(n == 4096, "② 多边形 4 顶点（16 位索引 0 1 2 3）：%d 个像素（期望 4096）", n);
        S.prog = &gs; g_pso_dirty = 1; args_dirty_all();
        n = run(NVN_DRAW_PRIMITIVE_QUAD_STRIP, 0); CHECK(n == 4096, "③ 四边形条带 4 顶点（非索引）：%d 个像素（期望 4096）", n);
        unlink(map); unlink(user);
        printf("%s t_nvn_prim_poly: %u checks %u failures; backend Metal%d\n", failures ? "✗" : "✓", checks, failures, g_m3 ? 3 : 4);
        return failures != 0;
    }
}
