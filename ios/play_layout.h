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
// 倒着拿（维护者 11-17 拍板：其余方向跟随系统，系统不给倒置竖屏时 App 自己补这一种）。纯函数，Mac 单测 t_play_layout：
//   dev = UIDeviceOrientation（1 竖、2 倒竖、3 横左、4 横右；其余平放 / 未知）；ui = UIInterfaceOrientation（1 竖、2 倒竖、3 横右、4 横左）；
//   k = 这块屏「界面角度 − 设备角度」（0 / 90 / 180 / 270；外屏和普通手机 0，iPhone Duo 内屏面板与机身差 90° 的倍数）
// 学差值：界面是横屏时（横屏系统一定照转）才学，返回 k；其余 −1（竖屏可能是系统拒了倒置、停在原来的正竖屏，学了会错 180°）
int S2APlayLearnK(int dev, int ui);
// 该怎么做：−1 判不了（平放 / 未知，保持原样）；0 正常（跟随系统）；1 整窗转 180°（该倒置竖屏、系统停在正竖屏）；2 先申请正竖屏（该倒置竖屏、系统停在横屏），转好再进来
int S2APlayHoldAction(int dev, int ui, int k);

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
#if !TARGET_OS_TV
// 挂上 / 刷新这个窗口的倒握跟随（S2APlayHoldAction）：倒着拿而系统不给倒置竖屏时整窗转 180°（游戏画面、触控、弹出的设置页一起转），
//   根视图控制器的安全区上下 / 左右对调；换了根视图控制器再调一次。仅主线程，重复调用只刷新
void S2APlayFollowHold(UIWindow *window);
#endif
// 游戏壳和无商业资源的输入工作台共用铰链、方向和区域生命周期。
@interface S2APlayViewController : UIViewController
@end
#endif
