// 提交线程实时声明的判定（纯函数；hle_nvn.c submit_rt_tick 每 120 帧调一次，单测 runtime/tests/t_nvn_submit_rt.c）。
// 输入：最近一窗里本线程每帧 CPU 时间、每帧花在提交里的 CPU 时间（都已升序排好，毫秒），出图周期（毫秒），当前声明的计算量（毫秒，没声明为 0）。
// 规则：提交里的 CPU 中位不到周期的十分之一 → 不是以提交为主的线程：没声明就不声明，声明着就撤回。
//   否则计算量 = max(1.25 × p90, 1.1 × 峰值)，夹在 [1 ms, 0.9 × 周期]；没声明、或与当前声明差 15% 以上才（重新）声明。
#pragma once
enum { SUBMIT_RT_KEEP = 0, SUBMIT_RT_DECLARE = 1, SUBMIT_RT_WITHDRAW = 2 };
static inline int nvn_submit_rt_decide(const double *cpu_sorted, const double *sub_sorted, int n, double period_ms, double declared_ms, double *comp_ms) {
    if (n < 2 || period_ms <= 0) return SUBMIT_RT_KEEP;
    if (sub_sorted[n / 2] < period_ms * 0.1) return declared_ms > 0 ? SUBMIT_RT_WITHDRAW : SUBMIT_RT_KEEP;
    double p90 = cpu_sorted[(n * 9) / 10 - 1], peak = cpu_sorted[n - 1], cap = period_ms * 0.9;
    double comp = p90 * 1.25 > peak * 1.1 ? p90 * 1.25 : peak * 1.1;
    if (comp > cap) comp = cap;
    if (comp < 1) comp = 1;
    if (declared_ms > 0 && comp <= declared_ms * 1.15 && comp >= declared_ms * 0.85) return SUBMIT_RT_KEEP;
    *comp_ms = comp; return SUBMIT_RT_DECLARE;
}
