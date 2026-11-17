// 写跟踪「列脏页」单测（graphics/nvn/gfx/nvn/nvn_dirty.c nvn_dirty_written_pages）：真的写保护、真的缺页，期望值按页号手算，不由被测实现推出。
// 场景照马车8 的误判：主机页 16 KB、贴图只按 4 KB 对齐，贴图首页还装着别的数据；只写别的数据也会把贴图那一页标脏（这正是重传前要按字节核对的原因）。
#include "../gfx/nvn/nvn_dirty.h"
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int (*g_hook)(void *, int, void *);
void dm_fault_hook_register(int (*fn)(void *addr, int is_write, void *uc)) { g_hook = fn; }
void dm_guest_write_prep_register(void (*fn)(void *addr, size_t len)) { (void)fn; }
void dm_log(const char *fmt, ...) { (void)fmt; }
static void on_sig(int s, siginfo_t *si, void *uc) { if (g_hook && g_hook(si->si_addr, 1, uc)) return; signal(s, SIG_DFL); }

// 远端别名区替身（真身 runtime/src/far.c）：[g_far_lo, g_far_hi) 算远端
static uintptr_t g_far_lo, g_far_hi;
static int far_stub(uint64_t a, uint64_t n) { return g_far_hi && a >= g_far_lo && a + n <= g_far_hi; }
extern int (*nvn_dirty_mp_hook)(void *addr, size_t len, int prot);
static int g_mp_calls;
static int count_mp(void *addr, size_t len, int prot) { (void)addr; (void)len; (void)prot; g_mp_calls++; return 0; }
static int fails;
#define CK(c, ...) do { if (!(c)) { fails++; printf("✗ "); printf(__VA_ARGS__); printf("\n"); } } while (0)

int main(void) {
    struct sigaction sa = {0}; sa.sa_sigaction = on_sig; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
    size_t pg = (size_t)getpagesize();
    uint8_t *m = mmap(NULL, 8 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    nvn_dirty_add_range(m + pg / 4, 6 * pg - pg / 2);           // 池：4 KB 对齐的一段，跨主机页 0–5（按 pg 表示，Linux 4 KB / macOS 16 KB 同构）
    CK(nvn_dirty_page_size() == pg, "页大小 %zu，期望 %zu", nvn_dirty_page_size(), pg);
    uint8_t *tex = m + pg - pg / 4; size_t len = 2 * pg + pg / 2;   // 贴图：从第 0 页末尾 1/4 页起，到第 3 页开头 1/4 页，共占主机页 0–3
    const void *span = nvn_dirty_span(tex, len);
    nvn_dirty_protect(tex, len); uint64_t st = nvn_dirty_now();
    uint64_t bits[1];
    long n = nvn_dirty_written_pages(span, tex, len, st, bits, 64);
    CK(n == 4 && bits[0] == 0, "刚保护完：4 页、都没写（实得 %ld 页、位 %#llx）", n, (unsigned long long)bits[0]);
    tex[pg + pg / 4 + 5] = 1;                                       // 写贴图自己的字节：第 2 页
    n = nvn_dirty_written_pages(span, tex, len, st, bits, 64);
    CK(n == 4 && bits[0] == 1u << 2, "写第 2 页：只有位 2（实得 %ld、%#llx）", n, (unsigned long long)bits[0]);
    m[pg / 4 + 8] = 1;                                              // 只写同页上的别的数据：第 0 页里贴图之前的那段（池内、贴图外）
    n = nvn_dirty_written_pages(span, tex, len, st, bits, 64);
    CK(n == 4 && bits[0] == ((1u << 2) | 1u), "再写第 0 页贴图外的字节：第 0 页也算写过（实得 %#llx）", (unsigned long long)bits[0]);
    uint64_t st2 = nvn_dirty_now();
    n = nvn_dirty_written_pages(span, tex, len, st2, bits, 64);
    CK(n == 4 && bits[0] == 0, "新时间戳之后没再写：位全 0（实得 %#llx）", (unsigned long long)bits[0]);
    CK(nvn_dirty_written_pages(span, tex, len, st, bits, 3) == -1, "位数不够（3 < 4 页）：返回 -1");
    uint8_t *other = mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    CK(nvn_dirty_written_pages(NULL, other, 64, st, bits, 64) == -1, "没登记的内存：返回 -1（调用方按全写过处理）");
    if (fails) { printf("✗ t_dirty_pages：%d 处不符\n", fails); return 1; }
    {   // 第 7 组（11-14 D-GCMY）：远端别名区里的内存池不登记、不加保护——iPhone 上对它 mprotect 回 ENOMEM，一次失败就把全局「跟踪不可靠」置位、
        //   此后所有纹理一律当脏重传。期望手写：远端池查跟踪 0（未登记）、加保护不调 mprotect、跟踪不可靠仍 0、判写过 = 1（未跟踪按脏，用到时重传）；
        //   反证：去掉 nvn_dirty_add_range 的远端跳过，远端池被登记（查跟踪 1）、加保护调了 mprotect
        uint8_t *f = mmap(NULL, 4 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        g_far_lo = (uintptr_t)f; g_far_hi = (uintptr_t)f + 4 * pg; nvn_dirty_far_fn = far_stub;
        nvn_dirty_add_range(f, 4 * pg);
        g_mp_calls = 0; nvn_dirty_mp_hook = count_mp;
        nvn_dirty_protect(f, 2 * pg);
        nvn_dirty_mp_hook = NULL;
        int tr = nvn_dirty_tracked(f, pg), un = nvn_dirty_tracking_unreliable(), si = nvn_dirty_since(f, pg, nvn_dirty_now());
        CK(tr == 0 && g_mp_calls == 0 && un == 0 && si == 1, "远端池：查跟踪 %d（期望 0）、mprotect %d 次（期望 0）、跟踪不可靠 %d（期望 0）、判写过 %d（期望 1）", tr, g_mp_calls, un, si);
        CK(nvn_dirty_tracked(tex, len) == 1, "普通池照常跟踪");
        g_far_hi = 0; nvn_dirty_far_fn = NULL;
    }
    if (fails) { printf("✗ t_dirty_pages：%d 处不符\n", fails); return 1; }   // 原先有不符也照打 ✓、退出 0
    printf("✓ t_dirty_pages：7 组用例全符（真写保护缺页；同页别的数据写过也标脏；远端池不登记不加保护）\n");
    return 0;
}
