// Present pacer (pure function, shared by Mac / iOS; unit test tests/t_pace.c).
// Semantics as vsync: present slot = previous present slot + period. Early → wait until the present slot; late by less than one period → present immediately and keep the original phase;
// behind by one period or more (stutter) → restart the cadence from the current time, no burst of presents to catch up. Period 0 = no wait (the present slot follows the current time).
#pragma once
#include <stdint.h>

typedef struct { uint64_t target; } nvn_pacer;

// now: monotonic clock (ns); period: this frame's period (ns, 0 = no wait). Returns the ns to wait (0 = present immediately) and updates the internal target time.
static inline uint64_t nvn_pace(nvn_pacer *p, uint64_t now, uint64_t period) {
    if (!period || !p->target) { p->target = now; return 0; }
    uint64_t next = p->target + period;
    if (now <= next) { p->target = next; return next - now; }
    p->target = now - next < period ? next : now;
    return 0;
}

// 这一帧的节奏不是本节拍器控的（显示链路的节拍控的，或者根本没控：period 0）：节拍跟着它，在这次上屏处重新起拍。
// 节拍器只在调用方真等它时才是时钟。对它没控的帧照样每帧走一个周期，上屏比周期快时（120 Hz 可变刷新率链路上 12.5 ms 一帧、周期 16.7 ms）
// 槽时间会无界地跑到真实时间前面（一款游戏 18,000 帧后领先 27.6 s），链路一沉默或等超时，兜底的「睡到槽时间」把这段领先一次睡完 = 冻帧
// （照上游参考实现（MIT）b010f2b8：那边 55 分钟冻 29 次共 120 s）。在这里重新起拍，兜底的第一次等待最多离上次上屏一个周期，之后照常按周期走；
// 真等节拍器的调用方照旧用 nvn_pace（交换链排了几张时可以领先几个周期，不能截断：截断后三张图 1 ms 活会跑到 87 fps）
static inline void nvn_pace_follow(nvn_pacer *p, uint64_t now) { p->target = now; }
