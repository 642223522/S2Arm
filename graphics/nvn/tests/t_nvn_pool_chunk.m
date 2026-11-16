// 超过单个 Metal buffer 上限的内存池按重叠块登记（nvn_mtl.m nvn_be_pool_add_body，#1196：大池 newBufferWithBytesNoCopy 回 nil、开局退出）。
// S2A_POOL_MAXLEN_MB=64 把上限压到 64 MB，登记一个 160 MB 的池。期望全部按区间算术手写，不由被测实现推出：
//   块长 L = 64 MB、步长 = L / 2 = 32 MB、块数 = (160 − 64 + 31) / 32 + 1 = 4，起点 0 / 32 / 64 / 96 MB
//   ① 池表里恰好 4 条、同一个 key、起点如上、终点 = min(起点 + 64, 160) MB
//   ② 1 MB 网格上每个起点、长度 1 / 32 / 40 / 64 / 65 MB 的区间：「有某块 [32k, 32k + 64) 整个装下它」⇔ nvn_be_addr 查得到；
//      查得到时 buffer 内容 + 偏移 = 原地址（读到预先写下的标记字节）
//   ③ 注销后池表空；④ 16 MB 的池（< 上限）只登记 1 条；⑤ 直接建零拷贝失败 → 重映射视图上建、同一份内存；⑥ 视图也失败 → 不登记、不中止（诊断#36fc20）
#include "../gfx/nvn/nvn_mtl.m"
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failures += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { MB = 1 << 20 };
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
    setenv("S2A_POOL_MAXLEN_MB", "64", 1);
    mtl_init(); printf("BACKEND %s\n", g_m3 ? "Metal3" : "Metal4");
    const uint64_t N = 160ull * MB;
    uint8_t *base = mmap(NULL, N, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); REQUIRE(base != MAP_FAILED);
    for (uint64_t o = 0; o < N; o += MB) memcpy(base + o, &o, sizeof o);   // 每 MB 开头写自己的偏移
    nvn_be_pool_add(base, N);
    pthread_mutex_lock(&g_mu);
    int n = g_npool, keys = 1, starts = 1, ends = 1;
    for (int i = 0; i < n; i++) {
        keys &= g_pools[i].key == base;
        uint64_t st = (uint64_t)(g_pools[i].lo - (uintptr_t)base), want_end = st + 64ull * MB < N ? st + 64ull * MB : N;
        starts &= st % (32ull * MB) == 0 && st <= 96ull * MB; ends &= g_pools[i].hi - (uintptr_t)base == want_end;
    }
    pthread_mutex_unlock(&g_mu);
    CHECK(n == 4 && keys && starts && ends, "① 160 MB 池按 64 MB 上限登记成 4 块（实 %d 块；同 key %d、起点对 %d、终点对 %d）", n, keys, starts, ends);
    const uint64_t lens[] = {1ull * MB, 32ull * MB, 40ull * MB, 64ull * MB, 65ull * MB};
    int mism = 0, badbytes = 0, tried = 0;
    for (size_t li = 0; li < sizeof lens / sizeof *lens; li++)
        for (uint64_t off = 0; off + lens[li] <= N; off += MB) {
            int want = 0; for (uint64_t k = 0; k < 4; k++) { uint64_t cs = 32ull * MB * k, ce = cs + 64ull * MB < N ? cs + 64ull * MB : N; if (off >= cs && off + lens[li] <= ce) want = 1; }
            void *b = NULL; uint64_t o2 = 0; int got = nvn_be_addr((uint64_t)(uintptr_t)(base + off), lens[li], &b, &o2); tried++;
            if (got != want) mism++;
            else if (got) { id<MTLBuffer> mb = (__bridge id<MTLBuffer>)b; uint64_t v = 0; memcpy(&v, (uint8_t *)mb.contents + o2, sizeof v); if (v != off || o2 + lens[li] > mb.length) badbytes++; }
        }
    CHECK(mism == 0 && badbytes == 0, "② %d 个区间：查得到与否全按区间算术（不符 %d）、查到的 buffer + 偏移读到原地址的标记（不符 %d）", tried, mism, badbytes);
    nvn_be_pool_del(base);
    pthread_mutex_lock(&g_mu); n = g_npool; pthread_mutex_unlock(&g_mu);
    CHECK(n == 0, "③ 注销后 4 块都不在（剩 %d 条）", n);
    uint8_t *small = mmap(NULL, 16ull * MB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); REQUIRE(small != MAP_FAILED);
    nvn_be_pool_add(small, 16ull * MB);
    pthread_mutex_lock(&g_mu); n = g_npool; int whole = n == 1 && g_pools[0].lo == (uintptr_t)small && g_pools[0].hi == (uintptr_t)small + 16ull * MB; pthread_mutex_unlock(&g_mu);
    CHECK(whole, "④ 16 MB 池（< 上限）只登记 1 条、覆盖整池（实 %d 条）", n);
    nvn_be_pool_del(small);
    // ⑤ 直接建零拷贝失败（诊断#36fc20）：改在重映射视图上建，仍是同一份内存——池里写、buffer 读到；buffer 里写、池里读到
    g_pool_refuse = 1; memset(small, 0x11, 16ull * MB);
    nvn_be_pool_add(small, 16ull * MB);
    pthread_mutex_lock(&g_mu); n = g_npool; id<MTLBuffer> vb = n == 1 ? g_pools[0].buf : nil; pthread_mutex_unlock(&g_mu);
    int same = 0, view = 0;
    if (vb) { uint8_t *c = (uint8_t *)vb.contents; view = c != small; small[12345] = 0x5a; c[777] = 0xa5; same = c[12345] == 0x5a && small[777] == 0xa5 && vb.length == 16ull * MB; }
    void *b5 = NULL; uint64_t o5 = 0; int got5 = nvn_be_addr((uint64_t)(uintptr_t)(small + MB), 4096, &b5, &o5);
    CHECK(n == 1 && view && same && got5 && o5 == MB, "⑤ 直接建失败 → 视图上建：登记 %d 条、buffer 在另一地址 %d、两边互见写入 %d、按池地址查到偏移 %llu（应 1 MB）", n, view, same, (unsigned long long)o5);
    nvn_be_pool_del(small);
    // ⑥ 视图也失败：不登记、不中止（走到这里本身就是没中止）
    g_pool_refuse = 2;
    nvn_be_pool_add(small, 16ull * MB);
    pthread_mutex_lock(&g_mu); n = g_npool; pthread_mutex_unlock(&g_mu);
    int got6 = nvn_be_addr((uint64_t)(uintptr_t)small, 4096, &b5, &o5);
    CHECK(n == 0 && !got6, "⑥ 视图也建不出：不登记（%d 条）、查不到（%d）、进程照跑", n, got6);
    nvn_be_pool_del(small); g_pool_refuse = 0;
    printf("%s t_nvn_pool_chunk：%u 项，%u 项不符\n", failures ? "✗" : "✓", checks, failures);
    return failures != 0;
} }
