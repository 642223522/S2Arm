// S2A_DIAG_STAMP 重叠开窗（runtime/src/diag_brk.c，#f1ad1e）：开窗时别的线程的窗还开着要记一次、带两边线程号；收局汇总带总次数与此刻开着窗的线程。
//   期望按调用顺序手算（不由被测实现反推）：A 开 → B 开（重叠 1，已在窗里的是 A）→ A 收 → B 收 → A 再单独开、收（不重叠）→ 共 1 次；
//   C 开着不收时出汇总：汇总里列出 C 的窗还开着。直接调 stamp_hit（brk 陷入只是它的入口，命中逻辑与陷入无关）
#include "../src/diag_brk.c"
#include <stdio.h>
#include <string.h>
module_t *g_mod; int g_nmod, g_mod_cap;   // 模块表：本单测不装钩子、不按模块认地址
int s2a_thread_svc_stat(uint64_t *n) { *n = 0; return 0; }
uint64_t s2a_gate_svc_stat(int *last) { *last = 0; return 0; }
uint64_t s2a_touch_stat(uint64_t *mach) { *mach = 0; return 0; }
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t cv = PTHREAD_COND_INITIALIZER; static int stepn;
static void go(int s) { pthread_mutex_lock(&mu); stepn = s; pthread_cond_broadcast(&cv); pthread_mutex_unlock(&mu); }
static void await(int s) { pthread_mutex_lock(&mu); while (stepn < s) pthread_cond_wait(&cv, &mu); pthread_mutex_unlock(&mu); }
static unsigned tid_a, tid_c;
static void *ta(void *x) { (void)x; tid_a = pthread_mach_thread_np(pthread_self());
    await(1); stamp_hit(1); go(2); await(3); stamp_hit(2); go(4); await(5); stamp_hit(1); stamp_hit(2); go(6); return NULL; }
static void *tb(void *x) { (void)x; await(2); stamp_hit(1); go(3); await(4); stamp_hit(2); go(5); return NULL; }
static void *tc(void *x) { (void)x; tid_c = pthread_mach_thread_np(pthread_self()); await(6); stamp_hit(1); go(7); await(8); stamp_hit(2); return NULL; }
int main(void) {
    mach_timebase_info(&g_tb); g_nst = 2;
    pthread_t a, b, c; pthread_create(&a, NULL, ta, NULL); pthread_create(&b, NULL, tb, NULL); pthread_create(&c, NULL, tc, NULL);
    go(1); await(6);
    CHECK(atomic_load(&g_ovl_n) == 1, "A 开 → B 开算 1 次重叠、A 单独再开收不算：实得 %llu 次（应 1）", (unsigned long long)atomic_load(&g_ovl_n));
    CHECK(atomic_load(&g_win_n) == 3, "走完的窗 %llu 个（应 3：A 两次、B 一次）", (unsigned long long)atomic_load(&g_win_n));
    await(7);   // C 开着窗
    int open = 0; for (int i = 0; i < NSLOT; i++) if (atomic_load(&g_ts[i].who) && (atomic_load(&g_ts[i].seen) & 1)) { open++; CHECK(g_ts[i].mtid == tid_c, "开着窗的应是 C（%u），实为 %u", tid_c, g_ts[i].mtid); }
    CHECK(open == 1, "此刻开着窗的线程 %d 个（应 1 = C）", open);
    stamp_report("单测");
    go(8); pthread_join(a, NULL); pthread_join(b, NULL); pthread_join(c, NULL);
    CHECK(atomic_load(&g_ovl_n) == 1, "C 单独开窗不算重叠：实得 %llu 次（应 1）", (unsigned long long)atomic_load(&g_ovl_n));
    printf("%s t_diag_stamp：重叠开窗计数 / 两边线程号 / 汇总列出开着的窗 → %s（A 线程 %u）\n", bad ? "✗" : "✓", bad ? "有不符合项" : "通过", tid_a);
    return bad != 0;
}
