// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef S2A_MAC_MOTION_POWER_H
#define S2A_MAC_MOTION_POWER_H
#import <GameController/GameController.h>
#include <time.h>
#include "../runtime/include/s2a_pad.h"
#include "../runtime/include/phone_axes.h"

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
// 一份 GCMotion → 一份六轴样本（主线程读）；返回 0 没有、2 带分离重力的校准样本、1 只有总加速度的样本。只要系统给角速度就收（同 iOS slot_feedback.m 的 motion_acceleration）：
//   DualSense / DualShock 4 只给总加速度 acceleration（含重力），hasGravityAndUserAcceleration = NO、gravity / userAcceleration 恒 0。
//   以前要求两项都有，DualSense 整路样本被丢、游戏里体感完全不动。总加速度数学上就是 gravity + userAcceleration，换算一样。
//   分 1 / 2 是给读的一方排先后：Switch Pro 在 Mac 上也是 1，它原来走 HID 原始样本（joycon_imu.m），HID 有数据时仍让 HID 先。
static inline int s2a_gc_motion_sample(GCMotion *m, s2a_pad_motion *out) {
    if (!m.hasRotationRate) return 0;
    double gravity[3] = {0}, user[3] = {0};
    int calibrated = 0;
    if (m.hasGravityAndUserAcceleration) {
        gravity[0] = m.gravity.x; gravity[1] = m.gravity.y; gravity[2] = m.gravity.z;
        user[0] = m.userAcceleration.x; user[1] = m.userAcceleration.y; user[2] = m.userAcceleration.z;
        calibrated = 1;
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"   // acceleration 已标弃用，但 DualSense 上它是唯一的加速度来源
        gravity[0] = m.acceleration.x; gravity[1] = m.acceleration.y; gravity[2] = m.acceleration.z;
#pragma clang diagnostic pop
    }
    double rotation[3] = {m.rotationRate.x, m.rotationRate.y, m.rotationRate.z};
    float acceleration[3], gyro[3];
    s2a_gc_motion_axes(gravity, user, rotation, acceleration, gyro);
    *out = (s2a_pad_motion){clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000, acceleration[0], acceleration[1], acceleration[2], gyro[0], gyro[1], gyro[2]};
    return calibrated ? 2 : 1;
}
// 给服务层的反馈会话号（front_mac.m s2a_pad_rumble_session）：服务层只在会话号非 0 时建反馈对象（services/S2A.Services/InputPump.cs RefreshFeedback），
//   体感也挂在这个对象上。rumble = 能震的那一路会话号；0（玩家关了「手柄震动」/ 没有能震的手柄）时回只给体感的会话号，体感照开（#1671），
//   震动按会话号对不上丢掉（front_mac.m rumble_submit，同 iOS ios/controller.m MOTION_ONLY_SESSION）
#define S2A_MAC_MOTION_ONLY_SESSION 0x534d0000fffffffeull   // MAC_RUMBLE_BASE | 0xfffffffe：不是任何震动代次，也不是 GEN1_P1_SESSION
static inline uint64_t s2a_mac_feedback_session(uint64_t rumble) { return rumble ? rumble : S2A_MAC_MOTION_ONLY_SESSION; }
#endif
