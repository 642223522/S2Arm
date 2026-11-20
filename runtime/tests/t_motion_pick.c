// 玩家 1 六轴来源仲裁（runtime/src/motion_pick.c）：期望按「谁在操作 + 谁有样本」手算，不复述实现。
//   输入来源用 s2a_pad_source 原值（0 触屏 / 1 NS2 Pro BLE / 2 系统手柄）；known 非 0 = 那一路这一帧有样本。
#include "motion_pick.h"
#include <stdio.h>

static int bad;
static void expect(const char *what, int got, int want) {
    if (got != want) { printf("✗ %s：期望 %d → 实际 %d\n", what, want, got); bad++; }
}
// 反向检查：返回的那一路必须真的有样本（没有就拿 NONE）
static void expect_never_missing(const char *what, int got, int ns2, int gc, int phone) {
    int ok = got == S2A_MOTION_NONE || (got == S2A_MOTION_NS2 && ns2) || (got == S2A_MOTION_GC && gc) || (got == S2A_MOTION_PHONE && phone);
    if (!ok) { printf("✗ %s：返回 %d，但那一路没有样本（ns2=%d gc=%d phone=%d）\n", what, got, ns2, gc, phone); bad++; }
}

int main(void) {
    // ① 11-15 维护者改规则：接了有体感的手柄就用手柄，不管触屏在不在操作
    expect("① 触屏在操作 + 系统手柄有体感 → 用手柄（不再切手机）", s2a_motion_pick(0, 0, 1, 1), S2A_MOTION_GC);
    expect("① 触屏在操作 + 只有 NS2 有体感 → NS2", s2a_motion_pick(0, 1, 0, 1), S2A_MOTION_NS2);
    expect("① 触屏在操作 + 没接手柄 → 手机", s2a_motion_pick(0, 0, 0, 1), S2A_MOTION_PHONE);
    expect("① 触屏 + 都没有", s2a_motion_pick(0, 0, 0, 0), S2A_MOTION_NONE);
    // ② 系统手柄在驱动输入
    expect("② 系统 + 三路都有 → 手柄", s2a_motion_pick(2, 1, 1, 1), S2A_MOTION_GC);
    expect("② 系统手柄无体感（Xbox / Joy-Con 一代 / 夹手机的手柄）、没 NS2 → 手机", s2a_motion_pick(2, 0, 0, 1), S2A_MOTION_PHONE);
    expect("② 系统手柄无体感、NS2 有 → NS2", s2a_motion_pick(2, 1, 0, 1), S2A_MOTION_NS2);
    expect("② 系统 + 都没有", s2a_motion_pick(2, 0, 0, 0), S2A_MOTION_NONE);
    // ③ NS2 Pro 在驱动输入：两只手柄都在时先读 NS2（不读错刚体）
    expect("③ NS2 + 三路都有 → NS2", s2a_motion_pick(1, 1, 1, 1), S2A_MOTION_NS2);
    expect("③ NS2 还没出样本 → 系统手柄", s2a_motion_pick(1, 0, 1, 1), S2A_MOTION_GC);
    expect("③ 两只手柄都没样本 → 手机", s2a_motion_pick(1, 0, 0, 1), S2A_MOTION_PHONE);
    // ④ 负对照：手机陀螺仪关掉（phone=0）时不许返回手机；有手柄体感时任何输入来源都不许返回手机
    expect("④ 手机陀螺仪关、没接手柄 → NONE", s2a_motion_pick(0, 0, 0, 0), S2A_MOTION_NONE);
    for (int sel = 0; sel <= 3; sel++) { char w[64]; snprintf(w, sizeof w, "④ sel=%d 有手柄体感时不用手机", sel);
        expect(w, s2a_motion_pick(sel, 0, 1, 1) == S2A_MOTION_PHONE || s2a_motion_pick(sel, 1, 0, 1) == S2A_MOTION_PHONE, 0); }
    // ⑤ 全表：任何组合都不许返回「没有样本」的那一路
    for (int sel = 0; sel <= 3; sel++)
        for (int ns2 = 0; ns2 <= 1; ns2++)
            for (int gc = 0; gc <= 1; gc++)
                for (int phone = 0; phone <= 1; phone++) {
                    char what[96];
                    snprintf(what, sizeof what, "⑤ 全表 sel=%d ns2=%d gc=%d phone=%d", sel, ns2, gc, phone);
                    int got = s2a_motion_pick(sel, ns2, gc, phone);
                    expect_never_missing(what, got, ns2, gc, phone);
                    if (!ns2 && !gc && !phone) expect(what, got, S2A_MOTION_NONE);
                }
    if (bad) { printf("✗ t_motion_pick：%d 处不符\n", bad); return 1; }
    printf("✓ t_motion_pick：%d 组手算 + 全表 64 组一致性全符（有手柄体感就用手柄、不看触屏；手柄都没样本才用手机；无样本→NONE）\n", 17);
    return 0;
}
