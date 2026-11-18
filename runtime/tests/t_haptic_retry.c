// 系统手柄震动失败后的退避 / 判死：真机 61,341 次重试的回归护栏（iPhone 15 Pro / iOS 27.0.1，一局 35 分钟）。
// 只测纯决策函数 ios/haptic_retry.h，再对 controller.m 做接线断言——CoreHaptics / GameController
//   在 Mac 宿主上编不了，行为靠决策表覆盖，接线靠文本断言钉住（旧写法一旦回来就红）。
#include "../../ios/haptic_retry.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static int failures, checks;
static void check(int ok, const char *what) {
    checks++;
    if (!ok) { failures++; fprintf(stderr, "✗ %s\n", what); }
}

static int count_in(const char *text, const char *needle) {
    int n = 0; size_t len = strlen(needle);
    for (const char *p = text; (p = strstr(p, needle)) != NULL; p += len) n++;
    return n;
}

// controller.m 里 needle 是否出现在 key 之后（接线顺序断言用）。
static int after(const char *text, const char *key, const char *needle) {
    const char *k = strstr(text, key);
    return k && strstr(k, needle) != NULL;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "用法：t_haptic_retry <controller.m 路径>\n"); return 2; }
    FILE *file = fopen(argv[1], "rb");
    if (!file) { perror(argv[1]); return 2; }
    static char source[1 << 20];
    size_t size = fread(source, 1, sizeof source - 1, file);
    fclose(file);
    source[size] = 0;

    const uint64_t MS = 1000000ull;
    const uint64_t T0 = 5000ull * MS;   // CLOCK_UPTIME_RAW 的任意起点

    // ---- 左右马达（11-16）：分不分侧、单侧 / 合成的强度与锐度。期望手算：强度 = 最大振幅；锐度 = (按振幅加权的频率 − 160) / 160 × 0.5 + 0.3，夹在 0–1 ----
    check(s2a_hp_split(true, true), "同时支持左右 → 分两路");
    check(!s2a_hp_split(true, false) && !s2a_hp_split(false, true) && !s2a_hp_split(false, false), "缺一侧 → 合成一路（退回）");
    {   float a, sh;
        const float lo[2] = {0.2f, 0}, hi[2] = {0, 0.8f}, lz[2] = {160, 160}, hz[2] = {320, 320};
        s2a_hp_mix(2, lo, hi, lz, hz, &a, &sh);   // 合成：强度 0.8；频率 (0.2×160 + 0.8×320) / 1.0 = 288 → (128/160)×0.5 + 0.3 = 0.7
        check(fabsf(a - 0.8f) < 1e-6f && fabsf(sh - 0.7f) < 1e-5f, "合成一路：强度 0.8、锐度 0.7");
        s2a_hp_mix(1, &lo[0], &hi[0], &lz[0], &hz[0], &a, &sh);   // 左：0.2 @ 160 → 锐度 0.3
        check(fabsf(a - 0.2f) < 1e-6f && fabsf(sh - 0.3f) < 1e-5f, "左侧：强度 0.2、锐度 0.3（不被右侧带高）");
        s2a_hp_mix(1, &lo[1], &hi[1], &lz[1], &hz[1], &a, &sh);   // 右：0.8 @ 320 → (160/160)×0.5 + 0.3 = 0.8
        check(fabsf(a - 0.8f) < 1e-6f && fabsf(sh - 0.8f) < 1e-5f, "右侧：强度 0.8、锐度 0.8（不被左侧拉低）");
        const float z[2] = {0, 0}; s2a_hp_mix(2, z, z, lz, hz, &a, &sh);
        check(a == 0 && fabsf(sh - 0.3f) < 1e-6f, "全 0：强度 0、锐度按 160 Hz 取 0.3");
        const float nan[1] = {NAN}, big[1] = {9999}; s2a_hp_mix(1, nan, z, big, big, &a, &sh);
        check(a == 0 && fabsf(sh - 0.3f) < 1e-6f, "NaN 振幅按 0、频率夹 1250 不影响（没有振幅就不加权）");
    }

    // ---- 行为：正常路径 ----
    s2a_hp_state st = {0};
    check(s2a_hp_should_try(&st, T0) == S2A_HP_TRY, "初始状态允许尝试");
    s2a_hp_on_ok(&st);
    check(s2a_hp_should_try(&st, T0) == S2A_HP_TRY && st.fails == 0, "成功一次后仍然允许尝试");

    // ---- 行为：失败后退避，不是每帧重来（真机 29 次/秒的根源）----
    memset(&st, 0, sizeof st);
    check(!s2a_hp_on_fail(&st, T0), "第 1 次失败不判死");
    check(st.fails == 1 && st.retry_at_ns == T0 + 1000ull * MS, "第 1 次失败后 1000 ms 退避");
    check(s2a_hp_should_try(&st, T0 + 999ull * MS) == S2A_HP_SKIP, "退避期内（999 ms）跳过，不碰 CoreHaptics");
    check(s2a_hp_should_try(&st, T0 + 1000ull * MS) == S2A_HP_TRY, "退避到期后允许再试一次");

    check(!s2a_hp_on_fail(&st, T0 + 1000ull * MS), "第 2 次失败不判死");
    check(st.fails == 2 && st.retry_at_ns == T0 + 5000ull * MS, "第 2 次失败后 4000 ms 退避");
    check(s2a_hp_should_try(&st, T0 + 4999ull * MS) == S2A_HP_SKIP, "第 2 次退避期内跳过");

    // ---- 行为：第 3 次失败判死，之后无论过多久都不再试 ----
    check(s2a_hp_on_fail(&st, T0 + 5000ull * MS), "第 3 次失败判死");
    check(st.disabled && st.fails == S2A_HP_MAX_FAILS, "判死后 disabled 置位、次数到上限");
    check(s2a_hp_should_try(&st, T0 + 5000ull * MS) == S2A_HP_SKIP, "判死后立刻跳过");
    check(s2a_hp_should_try(&st, T0 + 1000000ull * MS) == S2A_HP_SKIP, "判死后一天也不重试（不再逐帧重建引擎）");
    check(s2a_hp_on_fail(&st, T0) == 1, "已判死再记失败仍然回「判死」");

    // ---- 行为：判死之后成功一次会复位（引擎自愈的路径）----
    s2a_hp_on_ok(&st);
    check(!st.disabled && st.fails == 0 && s2a_hp_should_try(&st, T0) == S2A_HP_TRY, "成功一次后判死撤销");

    // ---- 行为：换手柄 / 重新接入重新发牌，但已报过的红不重复刷 ----
    memset(&st, 0, sizeof st);
    st.reported = true;
    s2a_hp_on_fail(&st, T0); s2a_hp_on_fail(&st, T0); s2a_hp_on_fail(&st, T0);
    check(st.disabled, "连续三次失败判死");
    s2a_hp_rearm(&st);
    check(!st.disabled && st.fails == 0 && st.retry_at_ns == 0, "rearm 后允许重新尝试");
    check(s2a_hp_should_try(&st, T0) == S2A_HP_TRY, "rearm 后立刻可试");
    check(st.reported, "rearm 不清 reported：同一局已报过的红不再刷屏");
    check(S2A_HP_BACKOFF_MS(1) == 1000 && S2A_HP_BACKOFF_MS(2) == 4000 && S2A_HP_BACKOFF_MS(3) == 4000,
          "退避表：1000 / 4000 / 4000 ms");

    // ---- 接线：controller.m 真的按这套决策走 ----
    check(count_in(source, "#include \"haptic_retry.h\"") == 1, "controller.m 引入 haptic_retry.h");
    check(count_in(source, "s2a_hp_should_try(") == 1, "只在 system_play_on_queue 里判一次（唯一入口）");
    check(after(source, "static void system_play_on_queue", "s2a_hp_should_try("), "退避检查在震动播放路径里");
    check(after(source, "s2a_hp_should_try(", "system_channel_on_queue(k,"), "退避检查在逐路建引擎 / 播放（system_channel_on_queue）之前（跳过时不碰 CoreHaptics）");
    check(count_in(source, "s2a_hp_on_fail(") == 1, "失败只从 system_fail_on_queue 归档一次");
    check(count_in(source, "system_fail_on_queue(") == 6, "system_fail_on_queue：1 处定义 + 5 个失败点（建引擎 / 起引擎 / 建播放器 / 播放 / 更新）");
    check(count_in(source, "s2a_hp_on_ok(") == 1, "成功后清零只在播放成功那一处");
    check(count_in(source, "s2a_hp_rearm(") == 1, "换设备时 rearm 只有一处（system_select_device）");
    check(count_in(source, "g_haptic_retry.reported") == 2, "第一行红只报一次（判一次 + 置位一次）");

    // 旧写法：每条失败都无条件 LOG，而且每帧重建 —— 这两条必须都消失。
    check(count_in(source, "【红】系统手柄震动：创建播放器失败 %s") == 0, "不再逐次刷「创建播放器失败」");
    check(count_in(source, "【红】系统手柄震动：启动失败 %s") == 0, "不再逐次刷「启动失败」");
    check(count_in(source, "【红】系统手柄震动：播放失败 %s") == 0, "不再逐次刷「播放失败」");
    check(count_in(source, "error.localizedDescription.UTF8String ?: \"unknown\"") == 1,
          "只剩 system_fail_on_queue 里那一处描述拼接");

    // 诊断：下一次真机日志用这一行区分「引擎没建起来 / 玩家关了手柄震动 / locality 不对」。
    check(count_in(source, "supportedLocalities") == 1, "建引擎后打一次 locality 集合");
    check(count_in(source, "g_haptic_retry.diagnosed") == 2, "诊断行只打一次（判断 + 置位）");
    check(strstr(source, "%s/%ld") != NULL, "失败行带 NSError domain/code（4097 = NSXPCConnectionInvalid）");
    check(count_in(source, "(feel ? s2a_hp_feel(amp) : amp) * atomic_load(&g_rumble_gain)") == 1, "震动强度：先过 s2a_hp_feel 再乘档位倍率（同 Mac）");
    check(count_in(source, "rumble_feel(session)") == 2, "两个提交入口（整对 / 单侧）都按会话类型选换算：手机马达 / 系统手柄过曲线，NS2 Pro 原样");
    check(count_in(source, "gains[6] = {0.35f, 0.7f, 1, 1.4f, 1.8f, 5}") == 1, "六档倍率同定义表 rumbleLevel.scale（第 6 档「震爆我」×5）");

    if (failures) { fprintf(stderr, "t_haptic_retry：%d/%d 项不符\n", failures, checks); return 1; }
    printf("✓ t_haptic_retry：%d 项（退避 1000/4000 ms；连续 3 次判死；换手柄 rearm；红行只报一次；失败点全部走同一归档）\n", checks);
    return 0;
}
