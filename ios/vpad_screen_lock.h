// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 模拟锁屏点按判据：UIKit 与可移植单测共用，不依赖位置（允许三次点在不同位置）。
#pragma once

typedef struct { unsigned taps; double last; } S2AVPadScreenLockState;
static inline int S2AVPadScreenLockTap(S2AVPadScreenLockState *s, double now,
                                      double duration, double movement, unsigned fingers) {
    if (fingers != 1 || duration < 0 || duration > 0.25 || movement > 10) {
        *s = (S2AVPadScreenLockState){0}; return 0;
    }
    if (!s->taps || now < s->last || now - s->last > 0.8) s->taps = 0;
    s->last = now;
    if (++s->taps == 3) { *s = (S2AVPadScreenLockState){0}; return 1; }
    return 0;
}
