// 远端别名区里的内存池影子不连续（nvn_mtl.m pool_host，#450：一款第一方 RPG 在 iPhone 上首帧前中止，61 MB 的池影子在 2 MiB 边界处断开）。
// 影子按 2 MiB 一块、按游戏映射的先后分（runtime/src/far.c），跨多次映射拼起来的池，相邻游戏块不一定落在相邻影子块。原先遇到就 FATAL 退出。
// 用生产 runtime/src/far.c（S2A_FAR_LINEAR=0：同 iOS 按 2 MiB 分块；Mac 有 #419 线性影子不会遇到）：按游戏地址递增先映射 [G, G+2M)、再映射 [G+2M, G+4M)（影子从堆区顶往下切：后一次落在前一次下面），两块影子倒过来不相邻；
//   [H, H+4M) 一次映射，影子连续。期望（按语义手写，不由被测实现推出）：
//   ① 跨两次映射的池建得出（进程不退出），池的宿主地址既不是 G 也不是 G+2M 的影子（一段新的连续视图）
//   ② 视图与影子是同一份内存：往两块影子写的字节从视图对应偏移读得到；从视图写的字节在影子里看得到
//   ③ GPU 读的也是同一份：经池的缓冲把第 2 块开头 16 字节拷出来，读到的是写进第 2 块影子的字节
//   ④ 一次映射的池照旧直接用影子（宿主地址 = H 的影子），不另建视图
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failures += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
enum { MB2 = 2 << 20 };
static const uint64_t G = 0x8000000000ull, H = 0x8001000000ull;
void s2a_far_set(uint64_t lo, uint64_t hi, uint64_t sh_lo, uint64_t sh_hi); int s2a_far_map(uint64_t a, uint64_t n);   // runtime/src/far.c
static uintptr_t host_of(uint64_t g) { pthread_mutex_lock(&g_mu); uintptr_t h = 0; for (int i = 0; i < g_npool; i++) if (g_pools[i].lo == g) h = g_pools[i].host; pthread_mutex_unlock(&g_mu); return h; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
    mtl_init(); printf("BACKEND %s\n", g_m3 ? "Metal3" : "Metal4");
    setenv("S2A_FAR_LINEAR", "0", 1);
    void *sh = mmap(NULL, 64u << 20, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); REQUIRE(sh != MAP_FAILED);
    uint64_t shl = ((uint64_t)(uintptr_t)sh + MB2 - 1) & ~(uint64_t)(MB2 - 1);
    s2a_far_set(G, G + (32u << 20), shl, shl + (48u << 20));
    REQUIRE(!s2a_far_map(G, MB2) && !s2a_far_map(G + MB2, MB2) && !s2a_far_map(H, 2 * MB2));
    uint8_t *A = s2a_far_g2h(G), *B = s2a_far_g2h(G + MB2), *C = s2a_far_g2h(H);
    printf("影子 A %p B %p C %p C2 %p\n", A, B, C, s2a_far_g2h(H + MB2));
    REQUIRE(A && B && C && B != A + MB2 && s2a_far_g2h(H + MB2) == C + MB2);   // 前提：两次映射的影子不相邻、一次映射的相邻
    nvn_be_pool_add((const void *)(uintptr_t)G, 2 * MB2);
    uint8_t *v = (uint8_t *)host_of(G);
    CHECK(v && v != A && v != B, "① 影子断开的池建得出，宿主地址是一段新的视图（%p；A %p、B %p）", v, A, B);
    A[100] = 0x11; B[200] = 0x22;
    int same = v && v[100] == 0x11 && v[MB2 + 200] == 0x22;
    if (v) { v[300] = 0x33; v[MB2 + 400] = 0x44; }
    CHECK(same && A[300] == 0x33 && B[400] == 0x44, "② 视图与影子是同一份内存（双向读写都看得到）");
    for (int i = 0; i < 16; i++) B[i] = (uint8_t)(0xa0 + i);
    id<MTLBuffer> src = nil; pthread_mutex_lock(&g_mu); for (int i = 0; i < g_npool; i++) if (g_pools[i].lo == G) src = g_pools[i].buf; pthread_mutex_unlock(&g_mu);
    id<MTLBuffer> dst = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; memset(dst.contents, 0, 16);
    id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromBuffer:src sourceOffset:MB2 toBuffer:dst destinationOffset:0 size:16]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    int gpu_ok = 1; for (int i = 0; i < 16; i++) gpu_ok &= ((uint8_t *)dst.contents)[i] == (uint8_t)(0xa0 + i);
    CHECK(src && gpu_ok, "③ GPU 经池的缓冲读第 2 块开头，读到写进 B 的字节");
    nvn_be_pool_add((const void *)(uintptr_t)H, 2 * MB2);
    CHECK(host_of(H) == (uintptr_t)C, "④ 影子连续的池照旧直接用影子（%#lx）", (unsigned long)host_of(H));
    printf("%s t_nvn_far_pool: %u checks %u failures; backend %s\n", failures ? "✗" : "✓", checks, failures, g_m3 ? "Metal3" : "Metal4");
    return failures != 0;
} }
