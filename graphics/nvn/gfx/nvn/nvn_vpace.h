// 视频按片源帧率出图（10-30 帧率能耗线，对照 SavageWindRecomp movie.c）：游戏放预渲染视频时，宿主视频解码器（Ryujinx Nvdec，每解一帧报一次 s2a_video_frame）
//   按片源帧率出帧；片源不超过 30 帧时出图封顶 30（显示链接降到 30 Hz），游戏这段 CPU / GPU 工作减半，画面没有损失（片源本身就只有这么多帧）。
// 判定（纯函数，graphics/nvn/tests/t_vpace.c 测）：
//   进入：最近 1 秒解了 VP_ON_MIN–VP_ON_MAX 帧（24 / 25 / 30 帧片源都在里面），这些帧最早一帧在 VP_SPAN 之前（真按这个速度放了约 1 秒：起播时解码器先灌缓冲的突发
//         不算，等它平稳），且最后一帧在 VP_GAP 内；
//   保持：最后一帧在 VP_GAP 内且最近 1 秒不超过 VP_KEEP_MAX 帧（60 帧片源退出，不封顶）；
//   退出：VP_GAP 内没有新帧（视频放完 / 暂停）。
//   片源时间戳（Switch 2 解码器交出帧时带的显示时刻，nvn_vpace_frame_pts）是片源帧率的真值：近来相邻帧时间戳间隔的中位数 < VP_PTS_FAST（> 40 帧片源）
//   时不进入、在放也退出。到达速度不可靠：游戏按出图节拍一帧帧取解码帧时，出图封到 30 解码也跟着变 30/秒，只看到达速度会自证一直封着
//   （#1571 时之笛 Switch 2 版 60 帧开场影片：时间戳 0 / 17 / 33 / 50 ms，却被封到 30、慢一半、音画不同步）。没带时间戳的帧（Switch 1 Nvdec）照旧只看到达速度。
//   只在「这段主要在放视频」时封顶（nvn_vpace_cap）：游戏每帧绘制数 ≤ VP_DRAW_MAX。11-02 奥德赛局内一直在解 480×272 的小视频（画面里的一块），
//   原先只看解码帧率就把整局压到 30 帧（维护者 实玩：菜单 60、进游戏 30）；全屏过场视频每帧只画视频面片 + 字幕 / 跳过提示，局内照常渲染场景每帧几千个。
#pragma once
#include <stdint.h>

#define VP_N 64                         // 记最近这么多帧的解码时刻（1 秒内最多看这么多）
#define VP_WIN 1000000000ull            // 数帧的窗口：1 秒
#define VP_GAP 500000000ull             // 最后一帧距今超过 0.5 秒 = 没在放
#define VP_ON_MIN 12                    // 进入：1 秒内至少这么多帧（零星几帧的缩略图 / 单帧解码不算放视频）
#define VP_ON_MAX 32                    // 进入：1 秒内至多这么多帧（≤ 30 帧片源，留 2 帧抖动）
#define VP_KEEP_MAX 40                  // 保持：超过这么多帧（片源 ≥ 50 帧）退出
#define VP_SPAN 900000000ull            // 进入：1 秒窗口内最早一帧至少这么久以前
#define VP_DRAW_MAX 200                 // 封顶要求每帧绘制数不超过这么多（纯放视频远低于此；奥德赛局内约 4000）
#define VP_PTS_FAST 25000000ll          // 相邻帧时间戳间隔中位数小于它（片源 > 40 帧）：不封顶
#define VP_PTS_MIN 4                    // 至少这么多个有效间隔才按时间戳判
#define VP_PTS_NONE INT64_MIN           // 这一帧没带时间戳

typedef struct { uint64_t t[VP_N]; int64_t p[VP_N]; int n, i, on; } nvn_vpace;

// 记一帧：now = 解码交出时刻，pts = 片源显示时刻（ns；VP_PTS_NONE = 没有）
static inline void nvn_vpace_frame_pts(nvn_vpace *v, uint64_t now, int64_t pts) {
    v->t[v->i] = now; v->p[v->i] = pts; v->i = (v->i + 1) % VP_N;
    if (v->n < VP_N) v->n++;
}
static inline void nvn_vpace_frame(nvn_vpace *v, uint64_t now) { nvn_vpace_frame_pts(v, now, VP_PTS_NONE); }
// 片源比 40 帧快：按交出次序相邻两帧都带时间戳、间隔在 (0, 1 秒) 内的算有效间隔（重复帧 / 倒退 / 跳转不算），中位数 < VP_PTS_FAST。有效间隔不足 VP_PTS_MIN 个回 0
static inline int nvn_vpace_src_fast(const nvn_vpace *v) {
    int64_t d[VP_N]; int m = 0, s = (v->i + VP_N - v->n) % VP_N;
    for (int k = 1; k < v->n; k++) {
        int64_t a = v->p[(s + k - 1) % VP_N], b = v->p[(s + k) % VP_N];
        if (a == VP_PTS_NONE || b == VP_PTS_NONE || b <= a || b - a >= (int64_t)VP_WIN) continue;
        int64_t x = b - a; int j = m++; while (j > 0 && d[j - 1] > x) { d[j] = d[j - 1]; j--; } d[j] = x;
    }
    return m >= VP_PTS_MIN && d[m / 2] < VP_PTS_FAST;
}

// 返回 1 = 正在放 ≤ 30 帧的视频，出图封顶 30
static inline int nvn_vpace_on(nvn_vpace *v, uint64_t now) {
    if (!v->n) return v->on = 0;
    uint64_t last = v->t[(v->i + VP_N - 1) % VP_N];
    if (now < last || now - last > VP_GAP || nvn_vpace_src_fast(v)) return v->on = 0;
    int c = 0; uint64_t oldest = now;
    for (int k = 0; k < v->n; k++) { uint64_t t = v->t[k]; if (t <= now && now - t <= VP_WIN) { c++; if (t < oldest) oldest = t; } }
    if (v->on) return v->on = c <= VP_KEEP_MAX;
    return v->on = c >= VP_ON_MIN && c <= VP_ON_MAX && now - oldest >= VP_SPAN;
}
// 返回 1 = 出图封顶 30：在放 ≤ 30 帧的视频，且游戏这段每帧绘制数 ≤ VP_DRAW_MAX（draws_per_frame 由调用方按最近一段的绘制数 ÷ 出图数算；< 0 = 还没量出，按不封顶）
static inline int nvn_vpace_cap(nvn_vpace *v, uint64_t now, double draws_per_frame) {
    return nvn_vpace_on(v, now) && draws_per_frame >= 0 && draws_per_frame <= VP_DRAW_MAX;
}
