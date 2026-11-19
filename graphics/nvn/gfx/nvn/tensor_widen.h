// 张量核网络顶替遇上满屏放宽（#726，11-17 一款 Switch 2 游戏（0400486024DEC000）Mac：玩家手动开满屏、窗口拉成 16:10，运行中换屏把通用满屏切到加高，
//   一部分画面图放高到 2048x1284 / 1920x1204、另一部分没放）：出口层按宽高比挑不出输入，这一遍不写，输出图留着旧内容或空白——发白、人物破碎、粉青条带、整屏忽明忽暗。
//   满屏放宽时在 S2A_TENSOR_WIDEN_FRAMES 个不同的帧里都挑不出输入 → 本局退回原生 16:9（runtime/src/widen.c s2a_widen_force_native，下一个渲染遍前热切、放宽的目标交回原尺寸），
//   宁可两侧留黑也不出没写的画面。只数不同的帧：换屏那一帧放宽的目标按需重建，同一帧里新旧尺寸混着是暂时的，一帧挑不出不算。
//   纯函数，单测 graphics/nvn/tests/t_nvn_tensor_widen.c
#pragma once
#include <stdint.h>
#define S2A_TENSOR_WIDEN_FRAMES 8
typedef struct { uint64_t last; unsigned frames; int done; } s2a_tensor_widen_t;
// 每次挑不出输入时调：frame = 当前帧号，widened = 屏幕不是原生 16:9（满屏放宽在跑）。该退回 16:9 时回 1（一局只回一次）
static inline int s2a_tensor_widen_revert_due(s2a_tensor_widen_t *s, uint64_t frame, int widened) {
    if (!widened || s->done) return 0;
    if (!s->frames || frame != s->last) { s->last = frame; s->frames++; }
    if (s->frames < S2A_TENSOR_WIDEN_FRAMES) return 0;
    s->done = 1; return 1;
}
