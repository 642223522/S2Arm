// 存档原子提交判定单测（runtime/include/s2a_direct_prompt.h s2a_save_atomic_poll）：期望值按口径手写。
// 服务层导出与会话状态换成桩；每例 fork 一个子进程，被测函数的静态量从零开始。
#include "../src/native.h"
#include "s2a_direct_prompt.h"
#include "s2a_session.h"
#include <sys/wait.h>
#include <unistd.h>

// 存档原子提交状态（审计 P2-45）：服务层导出 S2A_SaveAtomicState 的桩，被测代码按 dlsym 取到它；会话状态桩
static int g_atomic, g_atomic_calls, g_session = S2A_SESSION_RUNNING;
__attribute__((visibility("default"), used)) int S2A_SaveAtomicState(void) { g_atomic_calls++; return g_atomic; }
int s2a_host_session_state(void) { return g_session; }

// 画面没出来：直连层三个计数（被测代码按 dlsym 取）、图形模式、安全网的桩
static unsigned long long g_dsh_ok, g_dsh_fail, g_draws, g_presents; static int g_gfx = 1, g_settled = 1, g_evidence; static char g_why[160];
__attribute__((visibility("default"), used)) void s2a_dsh_stats(unsigned long long out[5]) { out[0] = g_dsh_ok; out[1] = g_dsh_fail; out[2] = out[3] = out[4] = 0; }
__attribute__((visibility("default"), used)) unsigned long long s2a_direct_draws(void) { return g_draws; }
__attribute__((visibility("default"), used)) unsigned long long mtl_present_count(void) { return g_presents; }
int s2a_gfx_mode(void) { return g_gfx; }
int s2a_gfx_mode_settled(void) { return g_settled; }
void s2a_dguard_evidence(const char *why, int stall) { (void)stall; g_evidence++; snprintf(g_why, sizeof g_why, "%s", why ? why : ""); }

static int fails;
#define CASE(name, body) do { pid_t p = fork(); if (!p) { body; _exit(0); } int st; waitpid(p, &st, 0); \
    if (!WIFEXITED(st) || WEXITSTATUS(st)) { fails++; printf("✗ %s\n", name); } else printf("  ✓ %s\n", name); } while (0)
#define WANT(cond) do { if (!(cond)) { printf("    不符：%s（行 %d）\n", #cond, __LINE__); _exit(1); } } while (0)

int main(void) {
    // 存档不能原子提交（审计 P2-45，Mac / iOS 同一判定）：会话没跑起来不问服务层；跑起来后一直是 0 不提示；第一次读到非 0 返回原因位，只返回一次
    CASE("存档原子：会话没跑起来不问", { g_session = S2A_SESSION_STARTING; g_atomic = 2; WANT(s2a_save_atomic_poll() == 0); WANT(g_atomic_calls == 0); });
    CASE("存档原子：一直原子不提示", { g_atomic = 0; for (int i = 0; i < 5; i++) WANT(s2a_save_atomic_poll() == 0); WANT(g_atomic_calls == 5); });
    CASE("存档原子：首次非 0 提示一次", { g_atomic = 0; WANT(s2a_save_atomic_poll() == 0); g_atomic = 2; WANT(s2a_save_atomic_poll() == 2);
        g_atomic = 6; WANT(s2a_save_atomic_poll() == 0); WANT(s2a_save_atomic_poll() == 0); });

    // 画面没出来（体验梳理线 11-14 口径，期望手写）：满 20 秒、在上屏、现编失败 > 0、绘制 0 → 提示；缺一条都不提示
    CASE("没画面：判据四条全满足才提示", { WANT(s2a_no_picture_decide(20, 3, 0, 10)); WANT(!s2a_no_picture_decide(19.9, 3, 0, 10));
        WANT(!s2a_no_picture_decide(20, 0, 0, 10)); WANT(!s2a_no_picture_decide(20, 3, 1, 10)); WANT(!s2a_no_picture_decide(20, 3, 0, 0)); });
    CASE("没画面：起局 20 秒内不提示、满 20 秒提示一次并计进安全网，之后恒 0", { g_dsh_fail = 7; g_draws = 0; g_presents = 300;
        WANT(s2a_no_picture_poll_at(1000) == 0); WANT(s2a_no_picture_poll_at(1019) == 0); WANT(s2a_no_picture_poll_at(1020) == 1);
        WANT(g_evidence == 1 && strstr(g_why, "画面没出来")); WANT(s2a_no_picture_poll_at(1021) == 0); WANT(g_evidence == 1); });
    CASE("没画面：画出过东西（部分材质缺）不提示", { g_dsh_fail = 7; g_presents = 300; g_draws = 0;
        WANT(s2a_no_picture_poll_at(0) == 0); g_draws = 5; WANT(s2a_no_picture_poll_at(10) == 0); g_draws = 0; WANT(s2a_no_picture_poll_at(30) == 0); WANT(g_evidence == 0); });
    CASE("没画面：现编没失败（直连库齐全）不提示", { g_dsh_fail = 0; g_draws = 0; g_presents = 300; WANT(s2a_no_picture_poll_at(0) == 0); WANT(s2a_no_picture_poll_at(60) == 0); });
    CASE("没画面：不是直连模式 / 模式未落定 / 会话没跑起来都不问", { g_dsh_fail = 7; g_draws = 0; g_presents = 300;
        g_gfx = 0; WANT(s2a_no_picture_poll_at(0) == 0 && s2a_no_picture_poll_at(60) == 0); g_gfx = 1; g_settled = 0; WANT(s2a_no_picture_poll_at(60) == 0);
        g_settled = 1; g_session = S2A_SESSION_STARTING; WANT(s2a_no_picture_poll_at(60) == 0); WANT(g_evidence == 0); });

    if (fails) { printf("✗ t_direct_prompt：%d 例不符\n", fails); return 1; }
    printf("✓ t_direct_prompt：8 例全符\n");
    return 0;
}
