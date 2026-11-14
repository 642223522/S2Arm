// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// cc -std=c11 -Wall -Wextra -Werror tests/vpad_screen_lock_test.c -o /tmp/vpad_screen_lock_test && /tmp/vpad_screen_lock_test
#include <assert.h>
#include <stdio.h>
#include "../ios/vpad_screen_lock.h"

int main(void) {
    S2AVPadScreenLockState s = {0};
    assert(!S2AVPadScreenLockTap(&s, 1, .1, 0, 1));
    assert(!S2AVPadScreenLockTap(&s, 1.4, .1, 0, 1));
    assert(S2AVPadScreenLockTap(&s, 1.8, .1, 0, 1));
    assert(s.taps == 0); // 解除后重新进入不继承计数
    assert(!S2AVPadScreenLockTap(&s, 3, .1, 0, 1));
    assert(!S2AVPadScreenLockTap(&s, 4, .1, 0, 1)); // 超时从第一次计
    assert(s.taps == 1);
    assert(!S2AVPadScreenLockTap(&s, 4.2, .1, 11, 1)); // 滑动重置
    assert(s.taps == 0);
    assert(!S2AVPadScreenLockTap(&s, 5, .1, 0, 1));
    assert(!S2AVPadScreenLockTap(&s, 5.2, .3, 0, 1)); // 长按重置
    assert(s.taps == 0);
    assert(!S2AVPadScreenLockTap(&s, 6, .1, 0, 1));
    assert(!S2AVPadScreenLockTap(&s, 6.2, .1, 0, 2)); // 多指重置
    assert(s.taps == 0);
    assert(!S2AVPadScreenLockTap(&s, 7, .1, 10, 1));
    assert(!S2AVPadScreenLockTap(&s, 7.8, .25, 10, 1)); // 边界允许
    assert(S2AVPadScreenLockTap(&s, 8.5, .1, 0, 1));
    puts("vpad_screen_lock: PASS (triple tap, timeout, swipe, hold, multi-touch, re-entry)");
    return 0;
}
