// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Apple TV（tvOS）宿主专用实现（11-15 Apple TV 版；只在 S2A_APPLE_OS=tvos 时编，runtime/build.mk TVOS_EXCLUDE）。
//   电视上没有的 iPhone 界面整文件不编：触屏虚拟手柄与它的设置 / 金手指 / Mod 页（vpad*.m、app_settings.m、cpatch_settings.m、touch_config.m）、
//   「文件」App 存档导入导出（save_transfer.m）、外接屏（extdisplay.m）、手机当手柄（phone_motion.m，tvOS 没有 CoreMotion）。
//   其余宿主文件仍调到的入口在这里给电视版：触屏 / 文件选择类为空操作，存档导入导出与设置在电脑端做（Mac 启动器），游戏库界面走 shell/。
#import <UIKit/UIKit.h>
#include <stdint.h>
#import "app_settings.h"
#include "s2a_pad.h"

#if !TARGET_OS_TV
#error "ios/tv_host.m 只给 Apple TV 编（runtime/build.mk 按 S2A_APPLE_OS 选源）"
#endif

// 触屏虚拟手柄（vpad.m）：电视没有触屏，只用扩展手柄
void s2a_vpad_attach(UIView *root) { (void)root; }

// 游戏内设置页（app_settings.m）：电视上设置在电脑端改、随包带过去；诊断页里的「设置」入口不出
@implementation S2ASettingsRuntime   // 宿主照常登记能力（app.m），电视上没有游戏内设置页来用它
@end
void s2a_settings_set_runtime(S2ASettingsRuntime *runtime) { (void)runtime; }
void s2a_settings_present(UIViewController *presenter) { (void)presenter; }

// 「文件」App 选文件（vpad_cheats.m / save_transfer.m）：tvOS 没有文件选择器；金手指与存档在电脑端导入、装机时推过来
id s2a_cheats_import_picker(void) { return nil; }
int s2a_ios_save_management_requested(void) { return 0; }
UIViewController *s2a_ios_save_manager(void (^start_game)(void)) { (void)start_game; return nil; }
void s2a_ios_save_present(UIViewController *presenter) { (void)presenter; }
void s2a_ios_test_save_op(void) {}   // 测试开关 S2A_TEST_SAVE_OP（save_transfer.m）：电视上没有存档导入导出

// 外接屏场景配件（extdisplay.m）：电视本身就是那块屏
id s2a_ios_ext_register(UIViewController *vc) { (void)vc; return nil; }
UIView *s2a_ios_root_view(void);   // app.m
UIView *s2a_ios_present_view(void) { return s2a_ios_root_view(); }   // 出图层挂哪块视图（graphics/nvn/host_adapt.m）：电视就挂宿主根视图

// 手机当掌机（phone_motion.m）：电视没有陀螺仪 / 加速度、没有机身马达；六轴与震动只走外接手柄（controller.m 其余路径照旧）
int s2a_phone_motion_available(void) { return 0; }
void s2a_phone_motion_enable(int on) { (void)on; }
int s2a_phone_motion_read(s2a_pad_motion *out) { (void)out; return 0; }
uint64_t s2a_phone_rumble_session(void) { return 0; }
void s2a_phone_rumble_pair(const s2a_pad_vibration v[2]) { (void)v; }
void s2a_phone_rumble_stop(void) {}
