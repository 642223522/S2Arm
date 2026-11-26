// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 回收贴图堆（马车世界缺口 ③，nvn_mtl.m rh_texture / rh_place / rh_wait / rh_trim，照上游参考实现（MIT）707cac95）。期望按语义手写：
//   ① GPU 专用池里的 RGBA8 1480×832 目标：放进自己的堆，新建 1 个，堆 ≥ 贴图所需 + 1/8；驻留集收堆、不收贴图
//   ② 贴图放掉：堆进等待表（1 个），仍在驻留集
//   ③ 长大一档 1544×868（面积 ×1.088 < 1.125）：放进刚等着的那个堆，复用 1、新建仍 1、等待 0
//   ④ 块压缩（DXT1）、CPU 可见池：不进回收内存（nil）
//   ⑤ 面积 ×4 的 2960×1664：等着的堆装不下 → 新建第 2 个，旧堆继续等
//   ⑥ 等待超时：rh_trim 全放掉（等待 0），commit 后堆不在驻留集
//   ⑦ 经 tex_mtl 整条建贴图路径：GPU 专用池目标建在堆里
//   Metal 3 / DM_NVN_RT_RECYCLE=0：一律不进堆（rh_texture nil，tex_mtl 的贴图没有堆）
//   反证：新堆不留 1/8 余量（hd.size = size）→ ③ 红（长大一档放不进旧堆）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failures += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static void make(tex_t *t, pool_t *pool, size_t off, unsigned w, unsigned h, uint32_t fmt) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T','E','X',0); t->serial = nvn_new_serial();
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = fmt, .flags = 0, .width = w, .height = h, .depth = 1, .levels = 1};
    t->pool = pool; t->off = off; t->mem = pool->mem + off; nvn_tex_layout(&t->d, &t->L); nvn_be_tex_init(t);
}
static unsigned waiting(void) { os_unfair_lock_lock(&g_rh_lk); unsigned n = g_rh_n; os_unfair_lock_unlock(&g_rh_lk); return n; }
static int tracked(id o) { pthread_mutex_lock(&g_res_mu); int r = [g_res_objects containsObject:o]; pthread_mutex_unlock(&g_res_mu); return r; }

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
    mtl_init(); const char *sw = getenv("DM_NVN_RT_RECYCLE"); int off = sw && *sw == '0';
    printf("BACKEND %s%s\n", g_m3 ? "Metal3" : "Metal4", off ? "，DM_NVN_RT_RECYCLE=0" : "");
    size_t psz = 64u << 20; uint8_t *mem = NULL; REQUIRE(!posix_memalign((void **)&mem, 65536, psz)); memset(mem, 0, psz);
    pool_t *gpu = calloc(1, sizeof *gpu), *cpu = calloc(1, sizeof *cpu); REQUIRE(gpu && cpu);
    *gpu = (pool_t){.magic = MAGIC('P','O','O','L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = mem, .size = psz};
    *cpu = (pool_t){.magic = MAGIC('P','O','O','L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = mem, .size = psz};
    nvn_be_pool_add(mem, psz);
    nvn_be_sub_begin();
    if (g_m3 || off) {
        tex_t a; make(&a, gpu, 0, 1480, 832, NVN_FORMAT_RGBA8);
        CHECK(rh_texture(&a, tex_desc(&a, 0)) == nil, "Metal 3 / 开关关：rh_texture 不进堆");
        id<MTLTexture> m = tex_mtl(&a); CHECK(m && !m.heap && g_rh_made == 0, "经 tex_mtl 建的目标自己一次分配（有贴图 %d、没有堆 %d、新建堆 %llu）", m != nil, m && !m.heap, (unsigned long long)g_rh_made);
        printf("%s t_nvn_rt_recycle: %u checks %u failures\n", failures ? "✗" : "✓", checks, failures); return failures != 0;
    }
    void *first = NULL; uint64_t need0 = 0, hsz0 = 0;
    @autoreleasepool {   // ① ②
        tex_t a; make(&a, gpu, 0, 1480, 832, NVN_FORMAT_RGBA8); MTLTextureDescriptor *d = tex_desc(&a, 0); REQUIRE(d);
        need0 = [g_dev heapTextureSizeAndAlignWithDescriptor:d].size;
        id<MTLTexture> m = rh_texture(&a, d); REQUIRE(m && m.heap);
        first = (__bridge void *)m.heap; hsz0 = m.heap.size;
        res_add(m); res_commit();
        CHECK(g_rh_made == 1 && hsz0 >= need0 + need0 / 8, "① 1480×832 进自己的堆：新建 %llu（期望 1），堆 %llu B ≥ 所需 %llu + 1/8", (unsigned long long)g_rh_made, (unsigned long long)hsz0, (unsigned long long)need0);
        CHECK([g_res containsAllocation:m.heap] && !tracked(m), "① 驻留集收堆、不收贴图（堆在集里 %d、贴图登记 %d）", (int)[g_res containsAllocation:m.heap], tracked(m));
        res_remove(m); m = nil;
    }
    id<MTLHeap> fh = (__bridge id<MTLHeap>)first;
    CHECK(waiting() == 1 && [g_res containsAllocation:fh], "② 贴图放掉：等待 %u（期望 1），堆仍在驻留集 %d", waiting(), (int)[g_res containsAllocation:fh]);
    id<MTLTexture> keep;
    {   // ③
        tex_t b; make(&b, gpu, 8u << 20, 1544, 868, NVN_FORMAT_RGBA8); MTLTextureDescriptor *d = tex_desc(&b, 0);
        keep = rh_texture(&b, d);
        CHECK(keep && (__bridge void *)keep.heap == first && g_rh_reused == 1 && g_rh_made == 1 && waiting() == 0,
              "③ 长大一档 1544×868：放进等着的堆 %d（期望 1），复用 %llu 新建 %llu 等待 %u（期望 1 1 0）", keep && (__bridge void *)keep.heap == first, (unsigned long long)g_rh_reused, (unsigned long long)g_rh_made, waiting());
    }
    {   // ④
        tex_t c; make(&c, gpu, 16u << 20, 256, 256, NVN_FORMAT_RGBA_DXT1); tex_t e; make(&e, cpu, 24u << 20, 256, 256, NVN_FORMAT_RGBA8);
        CHECK(rh_texture(&c, tex_desc(&c, 0)) == nil && rh_texture(&e, tex_desc(&e, 0)) == nil && g_rh_made == 1, "④ 块压缩、CPU 可见池：不进回收内存（新建仍 %llu）", (unsigned long long)g_rh_made);
    }
    @autoreleasepool { keep = nil; }
    REQUIRE(waiting() == 1);
    id<MTLTexture> big;
    {   // ⑤
        tex_t g; make(&g, gpu, 32u << 20, 2960, 1664, NVN_FORMAT_RGBA8);
        big = rh_texture(&g, tex_desc(&g, 0));
        CHECK(big && (__bridge void *)big.heap != first && g_rh_made == 2 && waiting() == 1, "⑤ 面积 ×4：新建第 2 个堆（新建 %llu、等待 %u，期望 2、1）", (unsigned long long)g_rh_made, waiting());
    }
    {   // ⑥
        os_unfair_lock_lock(&g_rh_lk); for (unsigned i = 0; i < g_rh_n; i++) g_rh[i].t = 0; os_unfair_lock_unlock(&g_rh_lk);
        rh_trim(); res_commit();
        CHECK(waiting() == 0 && g_rh_trimmed == 1 && ![g_res containsAllocation:fh], "⑥ 等待超时：放掉 %llu（期望 1）、等待 %u（期望 0），堆出驻留集 %d", (unsigned long long)g_rh_trimmed, waiting(), ![g_res containsAllocation:fh]);
    }
    {   // ⑦
        tex_t h; make(&h, gpu, 48u << 20, 640, 360, NVN_FORMAT_RGBA8);
        id<MTLTexture> m = tex_mtl(&h);
        CHECK(m && m.heap && g_rh_made == 3, "⑦ 经 tex_mtl：GPU 专用池目标建在堆里（有堆 %d、新建 %llu，期望 1、3）", m && m.heap, (unsigned long long)g_rh_made);
    }
    printf("%s t_nvn_rt_recycle: %u checks %u failures\n", failures ? "✗" : "✓", checks, failures);
    return failures != 0;
} }
