// 满屏自检自动退回（runtime/src/qprompt_host.c widen_auto_revert）：玩家手动开的我方通用满屏一次就记住（11-15 维护者「没补丁的游戏手动打开满屏就走咱们通用方案」，
//   失败下一局自动关）。只链 qprompt_host.c，判定 / 宽屏 / 记次数都打桩：判定这一帧回「局内满屏没铺满」，退回成功（1），这是第 1 次启动触发（两次规则下不持久）。
//   期望手写：
//   A 手动开（S2A_WIDEN_VERIFIED=1 + S2A_WIDESCREEN=1）、这款以前问过 → 自检照开（w = 1）、持久（persist 1）、S2A_DOCS 下留 widen_auto_off（Mac 启动器收局读）
//   B 没手动开（缺省口径）、没问过 → 自检开、第 1 次不持久（persist 0）、不留标记（两次启动规则不变）
//   旧实现：A 问过就不自检（w = 0），就算触发也要两次启动才记住、不留标记（红）
#include <stdint.h>
#include "s2a_qprompt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
static int g_w = -1, g_persist = -1, g_asked;
void s2a_qp_config(int f, int w) { (void)f; g_w = w; }
int s2a_qp_present(uint64_t t, uint32_t d, int v, int c, int u, int f, int fl, int gi) { (void)t; (void)d; (void)v; (void)c; (void)u; (void)f; (void)fl; (void)gi; return S2A_QP_FIT; }
int s2a_qp_secs(void) { return 20; }
int s2a_qp_game(void) { return 0; }
int s2a_qp_native60(void) { return -1; }
int s2a_qp_fit_wanted(void) { return 0; }
int s2a_qp_unfit_sample(int kind, int64_t errors_now, int64_t *last) { (void)kind; (void)errors_now; (void)last; return 0; }
uint64_t now_ns(void) { return 1000000000ull; }
int s2a_fps_effective(void) { return 0; }
int s2a_fps_real_source(void) { return 0; }
void s2a_ql_host_frame(uint64_t n, int g, uint64_t dt, int gi) { (void)n; (void)g; (void)dt; (void)gi; }
int s2a_ql_host_on(void) { return 0; }
void s2a_cpatch_frame(uint64_t n, int g, uint64_t dt) { (void)n; (void)g; (void)dt; }
int s2a_screen_w(void) { return 1920; }
int s2a_screen_h(void) { return 1080; }
int s2a_widen_full(void) { return 0; }
int s2a_widen_game(void) { return 0; }
int s2a_widen_force_native(int on) { (void)on; return 1; }
int s2a_wr_note(const char *p) { (void)p; return 1; }
int s2a_wr_load(const char *p) { (void)p; return 0; }
int s2a_wr_persist(int n) { return n >= 2; }
int s2a_ios_qp_asked(int kind) { (void)kind; return g_asked; }
void s2a_ios_widen_auto(int hot, int why, int persist) { (void)hot; (void)why; g_persist = persist; }
void s2a_qp_frame(uint32_t draws, int video, int cutscene, int game_itv);
static int one(int manual, int asked, const char *docs) {
    pid_t c = fork();
    if (c == 0) {
        setenv("S2A_DOCS", docs, 1); unsetenv("S2A_WIDEN_VERIFIED"); unsetenv("S2A_WIDESCREEN");
        if (manual) { setenv("S2A_WIDEN_VERIFIED", "1", 1); setenv("S2A_WIDESCREEN", "1", 1); }
        g_asked = asked; s2a_qp_frame(100, 0, 0, 1);
        char mk[600]; snprintf(mk, sizeof mk, "%s/widen_auto_off", docs); int has = access(mk, F_OK) == 0; unlink(mk);
        printf("%s：自检 %d、持久 %d、标记 %d\n", manual ? "A 手动开、问过" : "B 缺省、没问过", g_w, g_persist, has); fflush(stdout);
        _exit(manual ? !(g_w == 1 && g_persist == 1 && has) : !(g_w == 1 && g_persist == 0 && !has));
    }
    int st = 0; waitpid(c, &st, 0); return WIFEXITED(st) && WEXITSTATUS(st) == 0;
}
int main(void) {
    char dir[] = "/tmp/t_qprompt_host.XXXXXX"; if (!mkdtemp(dir)) return 2;
    int fails = !one(1, 1, dir) + !one(0, 0, dir);
    rmdir(dir);
    printf("%s t_qprompt_host：2 项，%d 项不符\n", fails ? "✗" : "✓", fails);
    return fails != 0;
}
