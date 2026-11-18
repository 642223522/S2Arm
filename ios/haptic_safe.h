// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// CoreHaptics 播放器 / 引擎调用的防抛包装（Mac 前端手柄震动、iOS 手柄震动 / 每位玩家反馈 / 手机马达共用）。
//   引擎被系统停掉（stoppedHandler / resetHandler 刚到、或与之赛跑）时，对播放器调 stopAtTime / startAtTime / sendParameters，
//   CoreHaptics 不走 error 返回，而是 -[CHHapticEngine checkEngineRunning:] 里抛 ObjC 异常，未捕获即整局 abort
//   （诊断 D-APX8 / D-6BCX Mac 0.4.3、D-E8HZ / D-HCS5 iOS 0.3.8：rumbler_reset ← stoppedHandler → PatternPlayer stopAtTime 抛异常）。
//   这里接住：停止类忽略（引擎已停，本来就不响），播放 / 调强度按失败返回，交调用方已有的复位 / 退避重试。
#pragma once
#import <CoreHaptics/CoreHaptics.h>

static inline NSError *s2a_hp_exc_error(NSException *e) {
    return [NSError errorWithDomain:@"S2AHapticException" code:-1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""]}];
}
static inline void s2a_hp_stop(id<CHHapticPatternPlayer> p) {
    if (!p) return;
    @try { [p stopAtTime:CHHapticTimeImmediate error:nil]; } @catch (NSException *e) { (void)e; }
}
static inline BOOL s2a_hp_start(id<CHHapticPatternPlayer> p, NSError **err) {
    @try { return [p startAtTime:CHHapticTimeImmediate error:err]; }
    @catch (NSException *e) { if (err) *err = s2a_hp_exc_error(e); return NO; }
}
static inline BOOL s2a_hp_send(id<CHHapticPatternPlayer> p, NSArray<CHHapticDynamicParameter *> *params, NSError **err) {
    @try { return [p sendParameters:params atTime:CHHapticTimeImmediate error:err]; }
    @catch (NSException *e) { if (err) *err = s2a_hp_exc_error(e); return NO; }
}
static inline void s2a_hp_engine_stop(CHHapticEngine *e) {
    if (!e) return;
    @try { [e stopWithCompletionHandler:nil]; } @catch (NSException *x) { (void)x; }
}
