// 池注销按回放顺序（nvn_mtl.m pool_reap，宿主图形未实现清单 #5 根修）：游戏 Finalize 一个池后，之前录好、之后才提交的命令仍可能引用它
//   （马车 8 Mac 局取证：池外地址落在刚释放的池里）。Finalize 只标记，等释放之后又完整回放过一次提交才真正注销。直接包含生产 nvn_mtl.m，调生产入口。
// 期望手算（提交序号 s 在 nvn_be_sub_begin 里加 1；Finalize 时标记 dead = s + 2，第 s + 2 次提交开始时收割）：
//   ① 第 1 次提交里登记池 A、能解析 → 释放 A → 本次提交里仍能解析（同一个缓冲）
//   ② 下一次提交（释放后紧接着的那次，回放之前录好的命令）里仍能解析
//   ③ 再下一次提交开始时已注销：解析不到
//   ④ 释放池 B 后立刻在同一段内存重建 B'：解析到新缓冲（不是 B 的），池表里覆盖这个地址的只有一条
//   负对照：换回 main 的 nvn_mtl.m（释放即注销）→ ①② 不通
#ifndef NVN_PDEF_SOURCE
#define NVN_PDEF_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_PDEF_SOURCE

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static void commit(void) { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); }
static int resolves(const void *p, void **buf) { uint64_t off = 0; *buf = NULL; return nvn_be_addr((uint64_t)(uintptr_t)p, 16, buf, &off); }
static int covering(const void *p) { int n = 0; pthread_mutex_lock(&g_mu); for (int i = 0; i < g_npool; i++) if ((uintptr_t)p >= g_pools[i].lo && (uintptr_t)p < g_pools[i].hi) n++; pthread_mutex_unlock(&g_mu); return n; }

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
        mtl_init();
        enum { SZ = 1 << 20 };
        uint8_t *a = NULL, *b = NULL; REQUIRE(!posix_memalign((void **)&a, 65536, SZ)); REQUIRE(!posix_memalign((void **)&b, 65536, SZ));
        memset(a, 1, SZ); memset(b, 2, SZ);
        void *ba = NULL, *bx = NULL;
        nvn_be_sub_begin();
        nvn_be_pool_add(a, SZ); REQUIRE(resolves(a + 0x100, &ba));
        nvn_be_pool_del(a);
        int r1 = resolves(a + 0x100, &bx);
        CHECK(r1 && bx == ba, "① 释放后本次提交里仍能解析（%d）、同一个缓冲（%d）", r1, bx == ba);
        commit(); nvn_be_sub_begin();
        int r2 = resolves(a + 0x100, &bx);
        CHECK(r2 && bx == ba, "② 释放后紧接着的那次提交里仍能解析（%d）、同一个缓冲（%d）", r2, bx == ba);
        commit(); nvn_be_sub_begin();
        int r3 = resolves(a + 0x100, &bx);
        CHECK(!r3 && covering(a + 0x100) == 0, "③ 再下一次提交开始时已注销：解析 %d（期望 0），池表覆盖条数 %d（期望 0）", r3, covering(a + 0x100));
        void *bb = NULL, *bn = NULL;
        nvn_be_pool_add(b, SZ); REQUIRE(resolves(b + 0x200, &bb));
        nvn_be_pool_del(b); nvn_be_pool_add(b, SZ);
        int r4 = resolves(b + 0x200, &bn);
        CHECK(r4 && bn && bn != bb && covering(b + 0x200) == 1, "④ 释放后立刻在同一段重建：解析 %d、是新缓冲 %d、覆盖条数 %d（期望 1）", r4, bn && bn != bb, covering(b + 0x200));
        commit();
        printf("%s t_nvn_pool_defer: %u checks %u failures; backend Metal%d\n", failures ? "✗" : "✓", checks, failures, g_m3 ? 3 : 4);
        return failures != 0;
    }
}
