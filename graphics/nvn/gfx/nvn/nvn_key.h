// Switch 1（NVN1）着色器键的控制段口径，宿主唯一一处（hle_nvn.c keys_hash、安卓 android/native/direct/source_store.c 共用；
//   Python 同口径在 translator/nvn_key.py，两边由各自单测按手算期望值对拍）。Switch 2（NVN2）的键规则在 nvn2.h nvn2_key，与这里无关。
//
// 键 = sha256(控制段前 nctl 字节 ‖ 代码区)[:8]，nctl = 0x880；控制段 +0x20 记的自身长度 own 落在 [0x760, 0x880) 时 nctl = own（SDK 10 起的短控制段）。
// 第 2 代（键 v2）：哈希前把控制段的 [0x790, 0x798) 与 [0x7d0, 0x7e8) 置零（只置落在 nctl 之内的部分；own < 0x7e8 时第二段只置零到 own）。
//   来由：这两段在「同一份代码」的着色器之间会不同——前者是编译器写的散列，后者是运行时写的字段——而翻译结果逐字节一样（维护者核过 383 对样本）。
//   第 1 代键把它们算进去，一款 Unity 游戏的库里七到八成是只差这两段的重复，玩家运行时还会撞上「代码相同、只差这两段」的缺键。
// 第 1 代键（不置零）只在宿主运行时兜底用：玩家手上旧包的着色器表与设备兜底目录里旧版本现编的产物都是第 1 代键（hle_nvn.c keys_hash）。离线 / 出包一律只出第 2 代。
#pragma once
#include <stdint.h>
#include <string.h>

enum { NVN_KEY_CTL_MAX = 0x880u, NVN_KEY_CTL_MIN = 0x760u };

// 键哈希取控制段的字节数（control 至少可读 0x24 字节）
static inline uint32_t nvn_key_ctl_len(const void *control) {
    uint32_t own; memcpy(&own, (const uint8_t *)control + 0x20, 4);
    return own >= NVN_KEY_CTL_MIN && own < NVN_KEY_CTL_MAX ? own : NVN_KEY_CTL_MAX;
}
static const uint32_t nvn_key_ctl_volatile[2][2] = { { 0x790u, 0x798u }, { 0x7d0u, 0x7e8u } };   // 第 2 代置零的两段 [起, 止)
// 第 2 代置零：把 ctl[0, n) 里落在两段易变字段内的字节清零（就地改调用方自己的拷贝）
static inline void nvn_key_ctl_zero(uint8_t *ctl, uint32_t n) {
    for (int i = 0; i < 2; i++) {
        uint32_t a = nvn_key_ctl_volatile[i][0], b = nvn_key_ctl_volatile[i][1];
        if (a < n) memset(ctl + a, 0, (n < b ? n : b) - a);
    }
}
// 两段在 ctl[0, n) 内全是 0：第 1、2 代键相同，不用另算第 1 代
static inline int nvn_key_ctl_stable(const void *control, uint32_t n) {
    const uint8_t *c = (const uint8_t *)control;
    for (int i = 0; i < 2; i++)
        for (uint32_t o = nvn_key_ctl_volatile[i][0]; o < nvn_key_ctl_volatile[i][1] && o < n; o++) if (c[o]) return 0;
    return 1;
}
