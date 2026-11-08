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

    if (fails) { printf("✗ t_direct_prompt：%d 例不符\n", fails); return 1; }
    printf("✓ t_direct_prompt：3 例全符\n");
    return 0;
}
