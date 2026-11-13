// 提交线程实时声明的判定（graphics/nvn/gfx/nvn/nvn_submit_rt.h）。期望全部手算：周期 16.667 ms，门槛 = 1.667 ms，上限 = 15.0 ms。
#include "nvn_submit_rt.h"
#include <stdio.h>
#include <math.h>
static int fails;
static void expect(const char *what, long want, long got) { printf("%s 期望 %ld → 真结果 %ld\n", what, want, got); if (want != got) fails++; }
static void fill(double *v, int n, double lo, double hi) { for (int i = 0; i < n; i++) v[i] = lo + (hi - lo) * i / (n - 1); }   // 升序等差
int main(void) {
    double cpu[120], sub[120], c = -1; const double P = 1000.0 / 60;
    // 轻线程：提交里每帧 0.2–0.6 ms（中位 0.4 < 1.667）
    fill(cpu, 120, 0.5, 1.0); fill(sub, 120, 0.2, 0.6);
    expect("轻线程、没声明：不动", SUBMIT_RT_KEEP, nvn_submit_rt_decide(cpu, sub, 120, P, 0, &c));
    expect("轻线程、声明着：撤回", SUBMIT_RT_WITHDRAW, nvn_submit_rt_decide(cpu, sub, 120, P, 4.0, &c));
    // 重线程：线程 CPU 4.0–6.0 ms 等差（p90 = 第 108 个 = 4 + 2 × 107 / 119 = 5.798，峰值 6.0）→ max(7.248, 6.6) = 7.248
    fill(cpu, 120, 4.0, 6.0); fill(sub, 120, 3.0, 5.0);
    expect("重线程、没声明：声明", SUBMIT_RT_DECLARE, nvn_submit_rt_decide(cpu, sub, 120, P, 0, &c));
    expect("计算量 7.248 ms（×1000）", 7248, lround(c * 1000));
    expect("已声明 7.0（差 3.5%）：不动", SUBMIT_RT_KEEP, nvn_submit_rt_decide(cpu, sub, 120, P, 7.0, &c));
    expect("已声明 5.0（要的高出 45%）：重设", SUBMIT_RT_DECLARE, nvn_submit_rt_decide(cpu, sub, 120, P, 5.0, &c));
    expect("已声明 12.0（要的低了 40%）：重设", SUBMIT_RT_DECLARE, nvn_submit_rt_decide(cpu, sub, 120, P, 12.0, &c));
    // 峰值主导：119 帧都是 4.0、一帧 9.0 → p90 × 1.25 = 5.0，峰值 × 1.1 = 9.9
    for (int i = 0; i < 119; i++) cpu[i] = 4.0; cpu[119] = 9.0;
    expect("一帧尖峰：声明", SUBMIT_RT_DECLARE, nvn_submit_rt_decide(cpu, sub, 120, P, 0, &c)); expect("计算量按峰值 9.9 ms（×1000）", 9900, lround(c * 1000));
    // 超过上限：线程 CPU 14–18 ms → 夹到 15.0
    fill(cpu, 120, 14.0, 18.0); fill(sub, 120, 12.0, 16.0);
    expect("超过上限：声明", SUBMIT_RT_DECLARE, nvn_submit_rt_decide(cpu, sub, 120, P, 0, &c)); expect("计算量夹到 15.000 ms（×1000）", 15000, lround(c * 1000));
    // 门槛边界：提交中位正好 1.667 → 算重；1.6 → 算轻
    fill(cpu, 120, 2.0, 2.0001); for (int i = 0; i < 120; i++) sub[i] = P * 0.1;
    expect("提交中位正好是周期十分之一：声明", SUBMIT_RT_DECLARE, nvn_submit_rt_decide(cpu, sub, 120, P, 0, &c));
    for (int i = 0; i < 120; i++) sub[i] = 1.6;
    expect("提交中位 1.6 ms：不动", SUBMIT_RT_KEEP, nvn_submit_rt_decide(cpu, sub, 120, P, 0, &c));
    // 下限：线程 CPU 很小但提交过门槛（不现实，核夹值）：cpu 0.1 → 1.0
    fill(cpu, 120, 0.1, 0.2); for (int i = 0; i < 120; i++) sub[i] = 2.0;
    expect("计算量下限：声明", SUBMIT_RT_DECLARE, nvn_submit_rt_decide(cpu, sub, 120, P, 0, &c)); expect("夹到 1.000 ms（×1000）", 1000, lround(c * 1000));
    expect("周期为 0：不动", SUBMIT_RT_KEEP, nvn_submit_rt_decide(cpu, sub, 120, 0, 0, &c));
    if (fails) printf("✗ t_nvn_submit_rt：%d 项不符\n", fails); else printf("✓ t_nvn_submit_rt：门槛、计算量、上下限、重设与撤回\n");
    return fails != 0;
}
