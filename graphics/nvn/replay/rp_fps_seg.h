// rp_fps_seg.h — 「分时」窗口按游戏申请的交换间隔分段评估帧率（只打日志，不改上屏节拍）
// 游戏中途改交换间隔（如过场 60 → 30 帧）时，整个 5 秒窗口只给一个平均帧率分不出「是没跑满，还是游戏本来就要 30」。
// 这里把窗口按切换时刻拆成几段，每段给：目标帧率（= 60 / 交换间隔）、实际上屏帧数、实际帧率、达标比例（实际 / 目标）、
// 帧间隔超过「目标帧间隔 × 1.5」与超过 100 毫秒的帧数。0 值也打。
// 纯函数、不取时钟：调用方（rp_present.c 上屏成功那一刻）给单调时钟与此刻的间隔；宿主单测直接喂时间序列。
#pragma once
#include <stdint.h>
#include <stdio.h>

enum { FSEG_MAX = 16 };   // 一个 5 秒窗口最多分几段；再切换就并进最后一段（行里标「混合」）
struct fseg { int itv; uint64_t t0, frames, over_15, over_100; };
struct fseg_win { int n, mixed; uint64_t last_ns; struct fseg s[FSEG_MAX]; };

// 交换间隔 → 目标帧间隔 / 目标帧率。Switch 输出 60 Hz：间隔 k = 每 k 个垂直同步出一帧；0（不等垂直同步）与 1 一样按 60 帧算。
static inline uint64_t fseg_target_ns(int itv) { return (uint64_t)(itv > 1 ? itv : 1) * 1000000000ull / 60; }
static inline double fseg_target_fps(int itv) { return 60.0 / (double)(itv > 1 ? itv : 1); }

// 开一个新窗口：一段，从 now 起，间隔沿用 itv。last_ns 保留（新窗口第一帧的间隔从上一窗口最后一帧算起）。
static inline void fseg_begin(struct fseg_win *w, uint64_t now, int itv) {
    w->n = 1; w->mixed = 0;
    w->s[0] = (struct fseg){itv, now, 0, 0, 0};
}

// 一帧上屏：now = 上屏时刻；itv = 游戏此刻申请的间隔；set_ns = 游戏设这个间隔的时刻（同一单调时钟，0 = 不知道）。
// 间隔变了就在切换时刻断段：设的时刻落在当前段里就用它，不然（设在窗口开始前 / 时钟对不上）用这一帧的时刻。
static inline void fseg_frame(struct fseg_win *w, uint64_t now, int itv, uint64_t set_ns) {
    if (!w->n) fseg_begin(w, now, itv);
    struct fseg *c = &w->s[w->n - 1];
    if (itv != c->itv) {
        const uint64_t t = set_ns > c->t0 && set_ns <= now ? set_ns : now;
        if (w->n < FSEG_MAX) { c = &w->s[w->n++]; *c = (struct fseg){itv, t, 0, 0, 0}; }
        else { w->mixed = 1; c->itv = itv; }
    }
    c->frames++;
    if (w->last_ns && now > w->last_ns) {
        const uint64_t g = now - w->last_ns;
        if (g * 2 > fseg_target_ns(c->itv) * 3) c->over_15++;   // 超过本段目标帧间隔的 1.5 倍
        if (g > 100000000ull) c->over_100++;
    }
    w->last_ns = now;
}

// 窗口收尾：每段一行交给 out（0 值也打），然后以最后一段的间隔开下一个窗口。时刻按单调时钟秒打，可直接对「the game sets present interval」那行。
static inline void fseg_emit(struct fseg_win *w, uint64_t now, void (*out)(const char *line)) {
    if (!w->n) return;
    for (int k = 0; k < w->n; k++) {
        const struct fseg *c = &w->s[k];
        const uint64_t t1 = k + 1 < w->n ? w->s[k + 1].t0 : now, dur = t1 > c->t0 ? t1 - c->t0 : 0;
        const double tf = fseg_target_fps(c->itv), af = dur ? (double)c->frames * 1e9 / (double)dur : 0.0;
        char b[400];
        snprintf(b, sizeof b, "分时（目标帧率）：第 %d/%d 段 %.3f–%.3f 秒（%.2f 秒）：游戏申请交换间隔 %d（目标 %.1f 帧/秒、帧间隔 %.1f 毫秒）；上屏 %llu 帧、实际 %.1f 帧/秒、达标 %.0f%%；超过目标间隔 1.5 倍 %llu 帧、超过 100 毫秒 %llu 帧%s",
                 k + 1, w->n, (double)c->t0 / 1e9, (double)t1 / 1e9, (double)dur / 1e9, c->itv, tf, (double)fseg_target_ns(c->itv) / 1e6,
                 (unsigned long long)c->frames, af, af / tf * 100.0, (unsigned long long)c->over_15, (unsigned long long)c->over_100,
                 w->mixed && k + 1 == w->n ? "；本窗口切换超过 16 段，这一段混了几种间隔（目标按最后一种算）" : "");
        out(b);
    }
    fseg_begin(w, now, w->s[w->n - 1].itv);
}
