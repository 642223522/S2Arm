// 缓冲纹理按 2D 行读（wrapped 1D fetch → tbuf_as_2d）时池内偏移不满足线性贴图对齐：11-09 #309 火焰纹章 风花雪月，iPhone 17 Pro Max 光照逐帧亮暗交替。
//   玩家日志「texture buffer (texture ID 315, 512 elements of format 0x2e at pool offset 89890080) has no 2D-row form … the slot reads 0」：89890080 % 64 = 32，
//   iPhone 线性贴图要 64 字节对齐（Mac 16），原先回 nil、这一槽读 0。现在取同一段字节的对齐副本（帧暂存）建视图。
// 期望（按上面的语义手写，与被测实现无关）：对齐按 iPhone 抬到 64（DM_NVN_LINEAR_ALIGN=64）
//   ① 偏移 0x10020（差 32 不对齐）的 512 个 R32F 元素：返回非空视图；视图的缓冲偏移是 64 的倍数（不是池缓冲上的 0x10020）
//   ② 提交完成后视图背后的字节 = 源数据逐元素（第 i 个 = 1000 + i）
//   ③ 对照：偏移 0x20000（对齐）的同样纹理照旧原地建视图（视图的缓冲就是池缓冲、偏移 0x20000）
// 反证（修前）：同一单测编改前的 nvn_mtl.m → ① 返回 nil（「has no 2D-row form … the slot reads 0」）
// ④ #309 复发（v0.2.2 仍闪）：同样不对齐、但 4 MiB（1,052,640 个 R32UI）且本次提交里由 GPU 拷贝写入（游戏的计算遍写光照列表即如此）。期望（按语义手写）：
//   tba_copy 在 GPU 上拷 1 次；视图不在池缓冲上、缓冲偏移是 64 的倍数；提交后视图背后的字节 = GPU 写进去的源数据（第 i 个 = 7000000 + i）
//   反证：同一用例编修前源码（tba_copy 桩成「不拷」）→ CPU 副本（ubp_get）因 > 64 KiB / GPU 写过拒绝，视图为 nil
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, fails;
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL setup %s:%d %s\n", __FILE__, __LINE__, #x); exit(2); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) fails++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { MEM = 16 << 20, N = 512, BIG = 1052640 };   // BIG：#309 复发现场的元素数（R32UI，4,210,560 字节）
static uint8_t *memory; static pool_t *pool;

static void buffer_texture(tex_t *t, int id, size_t off) {
    float *v = (float *)(memory + off); for (int i = 0; i < N; i++) v[i] = 1000.0f + (float)i;
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32F, .width = N, .height = 1, .depth = 1, .levels = 1};
    t->pool = pool; t->off = off; t->mem = pool->mem + off; nvn_tex_layout(&t->d, &t->L); nvn_be_tex_init(t);
    nvn_be_reg_tex(id, t, NULL);
}

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0);
    setenv("DM_NVN_LINEAR_ALIGN", "64", 1);   // iPhone 的线性贴图对齐
    mtl_init();
    REQUIRE(!posix_memalign((void **)&memory, 65536, MEM)); memset(memory, 0, MEM);
    pool = calloc(1, sizeof *pool); REQUIRE(pool);
    *pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = memory, .size = MEM};
    nvn_be_pool_add(memory, MEM);
    static tex_t a, b;
    buffer_texture(&a, 7, 0x10020); buffer_texture(&b, 8, 0x20000);
    REQUIRE(linear_align(MTLPixelFormatR32Float) == 64);
    nvn_be_sub_begin();
    id<MTLTexture> ta = tex_mtl(&a), tb = tex_mtl(&b); REQUIRE(ta && tb);
    REQUIRE(ta.textureType == MTLTextureTypeTextureBuffer && ta.bufferOffset == 0x10020);
    uint64_t ra = 0, rb = 0;
    id<MTLTexture> va = tbuf_as_2d(7, ta, 0, &ra), vb = tbuf_as_2d(8, tb, 0, &rb);
    VERIFY(va != nil && va.buffer != nil && va.bufferOffset % 64 == 0 && va.buffer != ta.buffer,
           "① 不对齐偏移 0x10020：视图 %s、缓冲偏移 %lu（期望 64 的倍数、不是池缓冲）", va ? "非空" : "空", (unsigned long)va.bufferOffset);
    VERIFY(vb != nil && vb.buffer == tb.buffer && vb.bufferOffset == 0x20000, "③ 对齐偏移 0x20000：原地视图（缓冲偏移 %lu，期望 131072、池缓冲本身）", (unsigned long)vb.bufferOffset);
    uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
    int bad = -1;
    if (va) { const float *got = (const float *)((const uint8_t *)va.buffer.contents + va.bufferOffset); for (int i = 0; i < N; i++) if (got[i] != 1000.0f + (float)i) { bad = i; break; } }
    VERIFY(va && bad < 0, "② 副本逐元素 = 源数据（%d 个；第一处不符 %d）", N, bad);
    {   // ④ 4 MiB、GPU 写入
        const size_t src = 0x800000, dst = 0x10020, len = (size_t)BIG * 4;
        uint32_t *sv = (uint32_t *)(memory + src); for (uint32_t i = 0; i < BIG; i++) sv[i] = 7000000u + i;
        memset(memory + dst, 0xcd, len);   // CPU 看见的是旧字节：只有 GPU 拷贝之后才是对的
        static tex_t g; memset(&g, 0, sizeof g); g.magic = MAGIC('T', 'E', 'X', 0); g.serial = nvn_new_serial();
        g.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32UI, .width = BIG, .height = 1, .depth = 1, .levels = 1};
        g.pool = pool; g.off = dst; g.mem = pool->mem + dst; nvn_tex_layout(&g.d, &g.L); nvn_be_tex_init(&g); nvn_be_reg_tex(9, &g, NULL);
        nvn_be_sub_begin();
        mtl_sub_copy((uint64_t)(uintptr_t)(memory + src), (uint64_t)(uintptr_t)(memory + dst), len);   // 本次提交里的 GPU 写入
        id<MTLTexture> tg = tex_mtl(&g); REQUIRE(tg && tg.textureType == MTLTextureTypeTextureBuffer && tg.bufferOffset % 64);
        uint64_t c0 = g_tba_copies; int made = tba_copy(9, 0); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
        uint64_t rg = 0; id<MTLTexture> vg = tbuf_as_2d(9, tg, 0, &rg);
        VERIFY(made == 1 && g_tba_copies - c0 == 1, "④ 4 MiB、GPU 写入的不对齐缓冲纹理：GPU 上拷 1 次（made %d，拷贝 %llu 次）", made, (unsigned long long)(g_tba_copies - c0));
        VERIFY(vg != nil && vg.buffer != tg.buffer && vg.bufferOffset % 64 == 0, "④ 视图%s、不在池缓冲上、缓冲偏移 %lu 是 64 的倍数", vg ? "非空" : "为空", vg ? (unsigned long)vg.bufferOffset : 0ul);
        uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); REQUIRE(!mtl_last_commit_error());
        long bad = -1; uint32_t got0 = 0;
        if (vg) { const uint32_t *gv = (const uint32_t *)((const uint8_t *)vg.buffer.contents + vg.bufferOffset); got0 = gv[0]; for (uint32_t i = 0; i < BIG; i++) if (gv[i] != 7000000u + i) { bad = i; break; } }
        VERIFY(vg && bad < 0, "④ 副本逐元素 = GPU 写入的源数据（%u 个；第一处不符 %ld，第 0 个 %u）", BIG, bad, got0);
    }
    printf("%s t_nvn_tbuf_align：%u 项，%u 项失败（不对齐池偏移的缓冲纹理按 2D 行读取对齐副本，#309）\n", fails ? "✗" : "✓", checks, fails);
    return fails != 0;
} }
