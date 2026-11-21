// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iPad 外接键盘（妙控键盘等，#1869）：ios/keyboard.m 采键（GCKeyboard），ios/controller.m 照 Mac 选源发布，
//   ios/keyboard_settings.m 是改键页（同 Mac 启动器：点按键位后按新键录入，Esc 取消，另有常用键）。映射规则在 ios/keyboard_map.h。
#pragma once
#include <stdint.h>
#include <dispatch/dispatch.h>

// controller.m 提供
dispatch_queue_t s2a_ios_input_queue(void);   // 手柄回调的串行输入队列；键盘回调也挂它，键态只在它上面动
// 键盘这一份按键 / 摇杆变了（只在输入队列上调）。pressed：这次有新按下的键（吸附键盘、抬键不触发接管）
void s2a_ios_keyboard_publish(uint32_t buttons, const int32_t sticks[4], int pressed);
void s2a_ios_keyboard_end(void);              // 键盘断开：结束接管、虚拟按键显示回来（只在输入队列上调）

// keyboard.m 提供
void s2a_ios_keyboard_attach(void);           // 主线程，controller.m 建好输入队列后调一次
void s2a_ios_keyboard_background(void);       // 切后台：按着的键放开，接管保留（任意线程）
void s2a_ios_keyboard_foreground(void);       // 回前台：键盘已不在就结束接管（主线程）
int s2a_ios_keyboard_connected(void);         // 现在接着外接键盘（任意线程）
// 改键页用（主线程）
#define S2AKeyboardMapKey @"S2AKeyboardMap"   // 按款存（s2a_ios_per_game_keys）：schema 1 JSON，同 Mac 启动器 input.json 格式
void s2a_ios_keyboard_reload(void);           // 存了新键位：当场生效
void s2a_ios_keyboard_set_muted(int muted);   // 改键页开着：键盘不进游戏
// 录一个键：下一次按下的键交回（Mac 键码 + 修饰键位 Shift 1 / Control 2 / Option 4），Esc 交回 code = -1；
//   单按修饰键录成那个键（同 Mac 启动器录键规则），⌘ 组合不收。回调在主线程。传 NULL 取消录键
void s2a_ios_keyboard_record(void (^done)(int code, unsigned modifiers));

// keyboard_settings.m 提供（主线程）
int s2a_ios_keyboard_customized(void);        // 这款在改键页存过键位
#ifdef __OBJC__
@class UIViewController;
// 改键页（带导航栏，模态呈现）；关掉后调 closed
UIViewController *s2a_ios_keyboard_settings(void (^closed)(void));
#endif
