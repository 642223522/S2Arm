// 存档不能原子提交的判定（接口见 runtime/include/s2a_direct_prompt.h；iOS 壳与 Mac 游戏窗口共用）。只在前端主线程上调。
#include "native.h"
#include "s2a_direct_prompt.h"
#include "s2a_session.h"
#include <dlfcn.h>

int s2a_save_atomic_poll(void) {
    static int looked, warned; static int (*state)(void);
    if (warned || s2a_host_session_state() != S2A_SESSION_RUNNING) return 0;
    if (!looked) { looked = 1; state = (int (*)(void))dlsym(RTLD_DEFAULT, "S2A_SaveAtomicState"); }
    int bits = state ? state() : 0;
    if (!bits) return 0;
    warned = 1;
    LOG("存档：不能原子提交（原因位 %d：1 没登记原语 / 2 卷不能克隆或原子交换 / 4 工作目录准备失败），提示玩家", bits);
    return bits;
}
