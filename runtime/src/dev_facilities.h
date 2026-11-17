// 开发设施总开关（11-07 质量线；方案与盘点见 cmdr/壳内开发设施盘点.md）。单独成头：native.h 在抽取阶段键里（pack/stage_inputs/extract.tsv），
//   这里的改动不该让全库冷重出。实现 runtime/src/os.c s2a_dev_on；用到的 ap_host.c / host_main.c / 单测各自包含本头
#pragma once
int s2a_dev_on(void);   // 0 = 玩家口径（缺省）：停住现场 / 地址走势 / C# 内存与音频周期账 / 录手柄不起；1 = 显式打开的开发包 / 开发局
// 判定本体（单测直接测）：环境变量 > Info.plist > 缺省关。11-17 改缺省关（玩家手机 padrec 一小时长 3 GB：原先「缺省开、玩家包写 0 才关」，
//   哪条出包路径漏写就漏开）：只有我们自己的测试包 / 开发局显式打开（Info.plist 写 "1" 或起局环境 S2A_DEV_FACILITIES=1）
static inline int s2a_dev_decide(const char *env, int plist_has, int plist_on) {
    if (env && *env) return *env != '0';
    if (plist_has) return plist_on;
    return 0;
}
