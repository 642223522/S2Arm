// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef S2A_MAC_MOTION_POWER_H
#define S2A_MAC_MOTION_POWER_H
#import <GameController/GameController.h>

// Main thread only. Sensor control is independent of usable calibrated samples.
// Request sensor power through the public API, not through another client's ACKs.
static inline void s2a_motion_power_select(GCMotion *__strong *current, GCMotion *next, GCMotion *keep_active) {
    if (*current != next) {
        if (*current != keep_active && (*current).sensorsRequireManualActivation) (*current).sensorsActive = NO;
        *current = next;
        if (next != keep_active && next.sensorsRequireManualActivation) next.sensorsActive = YES;
    } else if (next != keep_active && next.sensorsRequireManualActivation && !next.sensorsActive) {
        next.sensorsActive = YES;
    }
}
#endif
