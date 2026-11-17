// 游玩时间（11-15 维护者「增加一个游玩时间统计功能，针对游戏生效」）：按游戏记累计游玩秒数 + 最近一次玩的时刻，记在玩的那台设备本地。
//   只算真在玩：相邻两次上屏间隔 ≤ S2A_PLAYTIME_GAP_NS 且宿主有焦点的那段才计——首帧前、后台 / 锁屏（不上屏）、S2Arm 暂停、出图停住、
//   Mac 窗口失焦都不算。累计在内存，平台壳的 10 秒心跳与进后台时 s2a_playtime_flush 落盘：闪退 / 被杀最多丢最后一次落盘之后那 ≤10 秒。
//   文件：S2A_PLAYTIME（起局方给；Mac 局 = 游戏库里这款文件夹的 playtime.json，pack/jobs/build.py）；没给 = <文档根>/playtime.json
//   （iPhone 多款容器 = Documents/games/<游戏号>，App 更新 / 换壳都在）。内容一行 JSON：{"schema":1,"seconds":N,"lastPlayed":<Unix 秒>}
//   读方：iPhone 游戏库（ios/library.m）、Mac 作业层 pack/jobs/library.py catalog（字段 playtime）。纯 C，单测 runtime/tests/t_playtime.c
#pragma once
#include <stdint.h>

#define S2A_PLAYTIME_GAP_NS 1000000000ull   // 两次上屏间隔超过 1 秒的那段不算（后台 / 暂停 / 停住 / 长加载黑屏）

// 每上屏一帧调（ap_host.c s2a_frame_presented）：now = 单调纳秒，focused = 宿主焦点（os.c s2a_host_focused）
void s2a_playtime_frame(uint64_t now, int focused);
// 把内存里攒的整秒加进文件（读-加-原子替换），并记 lastPlayed = now_wall（Unix 秒）；没攒满 1 秒不写。返回 0 = 成功或没东西可写
int s2a_playtime_flush_at(int64_t now_wall);
// 同上，now_wall 取当前时刻（平台壳心跳 / iOS 进后台 / 优雅收局 lifecycle.c s2a_host_shutdown 调；收局走 _exit，不靠 atexit）
int s2a_playtime_flush(void);
// 读文件：秒数与最近一次时刻（没有 / 读不出 → 0、0，返回 -1）
int s2a_playtime_read(const char *path, uint64_t *seconds, int64_t *last);
