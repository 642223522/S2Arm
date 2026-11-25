#pragma once
#include <stdint.h>

#define NVN_FPS_MIN_HZ 24
#define NVN_FPS_MAX_HZ 1000
int nvn_fps_parse(const char *value);   // "0" → 0；24–1000 的十进制整数 → 该值；其它 → -1（纯函数，单测直接调）
int nvn_fps_limit(void);   // 生效上限：帧率没被补丁抬高时为 0（不压游戏原生出图率）
int nvn_fps_limit_set(void);   // S2A_FPS：0 / 未设（不额外限帧）或 24–1000，进程启动读一次；坏值起局退出
double nvn_fps_period(double period);   // 秒；取原周期与用户上限周期的较大值
uint64_t nvn_fps_period_ns(uint64_t period);   // 纳秒；0 上限逐值保持输入
