// 地址兜底（nvn_mtl.m addr_adhoc，宿主图形未实现清单 #5）：游戏给的缓冲 / 贴图地址不在任何已登记的池里时，客体地址窗口里、可读可写的内存
//   按 64 KB 对齐登记成一个池再用（原先顶点读 0、索引 / 存储读写替身、贴图退 CPU）。直接包含生产 nvn_mtl.m，调生产解析入口 nvn_be_addr / mtl_gpu_addr。
// 夹具：mmap 一段 1 MB 可读写内存当「客体内存」（不登记成池），本测把 g_adhoc_win 指到自己的窗口函数圈住它；另 mmap 一段只读、一段在窗口外。
// 期望手算，不跑被测实现：
//   ① 窗口内可读写、没登记的地址 base + 0x2468C（24 字节）：nvn_be_addr 返回 1，缓冲内容在偏移处 = 本测写进去的 24 字节；mtl_gpu_addr 也返回 1、GPU 地址非 0
//   ② 同一 64 KB 块里另一个地址 base + 0x2F000：命中同一个兜底池（同一个缓冲），不再登记
//   ③ 窗口外（另一段可读写内存）：返回 0
//   ④ 窗口内但只读：返回 0（GPU 写存储缓冲会改到只读页）
//   ⑤ 新提交开始（nvn_be_sub_begin）后兜底池注销：pool_find 查不到 ①的地址；再解析一次又能用（现登记）
//   负对照：换回 main 的 nvn_mtl.m（没有兜底）→ ①②⑤ 不通
#ifndef NVN_ADHOC_SOURCE
#define NVN_ADHOC_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_ADHOC_SOURCE
#include <sys/mman.h>

static uint64_t g_wb, g_ws;
static void test_window(uint64_t *base, uint64_t *size) { *base = g_wb; *size = g_ws; }   // 生产由原生层 vawin.c 的 s2a_window_get 给（g_adhoc_win 缺省）

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
        mtl_init(); g_adhoc_win = test_window;
        enum { SZ = 1 << 20 };
        uint8_t *g0 = mmap(NULL, 4 * SZ + 0x10000, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); REQUIRE(g0 != MAP_FAILED);
        uint8_t *g = (uint8_t *)(((uintptr_t)g0 + 0xFFFF) & ~(uintptr_t)0xFFFF);   // 基址 64 KB 对齐：① ② 两个地址都在 [g + 0x20000, g + 0x30000) 这一块
        REQUIRE(!mprotect(g, SZ, PROT_READ | PROT_WRITE));           // 窗口内可读写：[g, g + 1 MB)
        REQUIRE(!mprotect(g + 2 * SZ, SZ, PROT_READ | PROT_WRITE)); // 窗口内、之后改只读：[g + 2 MB, g + 3 MB)
        g_wb = (uint64_t)(uintptr_t)g; g_ws = 3 * SZ;                // 窗口 = 前 3 MB
        uint8_t *outside = mmap(NULL, SZ, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); REQUIRE(outside != MAP_FAILED);
        static const uint8_t pat[24] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24};
        memcpy(g + 0x2468C, pat, sizeof pat); memset(g + 2 * SZ, 0x5A, 64); REQUIRE(!mprotect(g + 2 * SZ, SZ, PROT_READ));
        uint64_t a1 = (uint64_t)(uintptr_t)(g + 0x2468C);

        nvn_be_sub_begin();
        void *mb = NULL; uint64_t mo = 0, gpu = 0;
        int ok = nvn_be_addr(a1, sizeof pat, &mb, &mo);
        int same = ok && mb && !memcmp((const uint8_t *)[(__bridge id<MTLBuffer>)mb contents] + mo, pat, sizeof pat);
        void *mb2 = NULL; uint64_t mo2 = 0; int okg = mtl_gpu_addr(a1, sizeof pat, &mb2, &mo2, &gpu);
        CHECK(ok && same && okg && gpu, "① 窗口内可读写的池外地址：nvn_be_addr %d、内容一致 %d、mtl_gpu_addr %d、GPU 地址 %s", ok, same, okg, gpu ? "非 0" : "0");
        void *mb3 = NULL; uint64_t mo3 = 0; int ok3 = nvn_be_addr((uint64_t)(uintptr_t)(g + 0x2F000), 16, &mb3, &mo3);
        CHECK(ok3 && mb3 == mb && mo3 == mo + (0x2F000 - 0x2468C), "② 同一 64 KB 块的另一地址：返回 %d、同一缓冲 %d、偏移差 %#llx（期望 %#x）", ok3, mb3 == mb, (unsigned long long)(mo3 - mo), 0x2F000 - 0x2468C);
        CHECK(!nvn_be_addr((uint64_t)(uintptr_t)(outside + 0x100), 16, &mb3, &mo3), "③ 窗口外的可读写内存：不兜底");
        CHECK(!nvn_be_addr((uint64_t)(uintptr_t)(g + 2 * SZ + 0x40), 16, &mb3, &mo3), "④ 窗口内但只读：不兜底");
        { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); }
        nvn_be_sub_begin();
        pthread_mutex_lock(&g_mu); int still = pool_find(a1, sizeof pat) >= 0; pthread_mutex_unlock(&g_mu);
        int again = nvn_be_addr(a1, sizeof pat, &mb, &mo);
        { uint64_t f = nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f, 10000000000ull)); }
        CHECK(!still && again, "⑤ 新提交开始后兜底池已注销（还在 %d，期望 0），再解析又能用（%d，期望 1）", still, again);
        printf("%s t_nvn_addr_adhoc: %u checks %u failures; backend Metal%d\n", failures ? "✗" : "✓", checks, failures, g_m3 ? 3 : 4);
        return failures != 0;
    }
}
