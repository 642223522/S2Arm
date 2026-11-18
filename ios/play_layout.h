// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <TargetConditionals.h>

typedef NS_ENUM(NSInteger, S2APlaySplitMode) { S2APlaySplitAuto, S2APlaySplitOn, S2APlaySplitOff };
typedef NS_ENUM(NSInteger, S2APlayOrientation) { S2APlayOrientationAuto, S2APlayOrientationLandscape, S2APlayOrientationPortrait };
extern NSString *const S2APlaySplitKey, *const S2APlayOrientationKey, *const S2APlayLayoutChanged;
// top：画面贴游戏区顶部放（不上下居中）。只在竖屏分屏、游戏区横向放宽到整屏（安全区左右有缩进，iPhone Duo 外屏）时为真，见 S2APlayLayoutMake
typedef struct { CGRect game, controls, division; BOOL split, top; } S2APlayLayout;
S2APlaySplitMode S2APlayReadSplit(NSUserDefaults *defaults);
S2APlayOrientation S2APlayReadOrientation(NSUserDefaults *defaults);
BOOL S2APlaySplitEnabled(S2APlaySplitMode mode, BOOL partiallyOpen);
BOOL S2APlayPortrait(S2APlayOrientation orientation, BOOL split);
// game 是可用目标区域，不是等比放入后的画面；宽屏目标必须由这个区域算，避免循环依赖。
S2APlayLayout S2APlayLayoutMake(CGRect bounds, CGRect safe, S2APlaySplitMode mode, BOOL partiallyOpen, CGRect division);
CGRect S2APlayControlsRect(S2APlayLayout layout, CGRect bounds);
CGSize S2APlayTargetSize(CGSize area);
// 只发布实际应用到窗口的模式；偏好尚未应用时不提前改变运行时策略。
void S2APlayPublishSplit(BOOL split);
int s2a_ios_split_active(void);
CGRect s2a_ios_game_area(void);
int s2a_ios_game_top(void);

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
// 仅主线程。画面 / 手柄 / 编辑器读取同一套区域；CGRectZero 表示游戏视口尚未布局。
S2APlayLayout s2a_ios_play_layout(void);
CGRect s2a_ios_game_area(void);
int s2a_ios_screen_known(void);
int s2a_ios_screen_w(void);
int s2a_ios_screen_h(void);
int s2a_ios_screen_max_fps(void);   // 屏幕最高刷新率（Hz），帧率补丁档位默认值用
#if !TARGET_OS_TV   // 电视只有横屏，没有方向这一族（11-15 Apple TV 版）
UIInterfaceOrientationMask s2a_ios_play_orientations(void);
#endif
// iPhone Duo 外屏：系统缺省给竖向状态栏留一整列（iOS 27.1 UIViewController.preferredVerticalBarBehavior = Automatic，安全区右 84 / 下 34），
//   游戏和各全屏页都不用竖栏，关掉后状态栏回到顶部横放、那一列还给画面（外屏右侧和底部黑边的根因）。各全屏页的视图控制器在 @implementation 里写这一行；
//   没有竖栏的机型系统不问这个属性，行为不变
#if defined(__IPHONE_27_1) && __IPHONE_OS_VERSION_MAX_ALLOWED>=__IPHONE_27_1
#define S2A_VERTICAL_BAR_OFF - (UIVerticalBarBehavior)preferredVerticalBarBehavior API_AVAILABLE(ios(27.1)) { return UIVerticalBarBehaviorDisabled; }
#else
#define S2A_VERTICAL_BAR_OFF
#endif
int s2a_ios_play_resizable(void);   // 游戏窗口可自由缩放（Duo 内屏 / iPad）：方向交给系统，设置里的横 / 竖不起作用
CGRect S2APlayDivision(UIView *view);
// 游戏壳和无商业资源的输入工作台共用铰链、方向和区域生命周期。
@interface S2APlayViewController : UIViewController
@end
#endif
