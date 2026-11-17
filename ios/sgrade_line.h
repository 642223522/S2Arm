// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// S 级优化每一类此刻的那一句（iPhone 设置页；同 Mac launchers/macos/frontend/Sources/NX2Apple/SGradeStateText.swift、
//   三端状态与文案对照定稿）。纯 Foundation，宿主单测 runtime/tests/t_sgrade_line.m 直接调
#pragma once
#import <Foundation/Foundation.h>

// 版本号按段比较（1.10 > 1.9；段数不同短的补 0）：-1 / 0 / 1
int s2a_sgrade_version_cmp(NSString *a, NSString *b);
// cat = widescreen / fps；s = s2a_ios_sgrade_state 里这一类；catName = 这一类给玩家看的名字；fpsTarget = 帧率补丁的最高档（0 = 不写档）；
//   date = 自动关日期的写法；文案走 S2AL（S2ArmHost 表）。→ 那一句；没有可说的 = nil（pending / unknown / 没这一类）
NSString *s2a_sgrade_line(NSString *cat, NSDictionary *s, NSString *catName, NSInteger fpsTarget, NSString *(^date)(NSDate *when));

// 齿轮菜单一级三行的副标题（11-15 维护者定：满屏 / 帧率解锁 / 金手指挪到一级；副标题只写「现在用的是什么」一句）。
//   自动关 / 没生效 / 没打入等状态照 s2a_sgrade_line；其余按来源写：满屏 patch（自适应 / 定画幅）或 S2Arm 通用满屏；
//   帧率 patch「最高 n 帧」或补帧（这款有没有社区补丁两种写法）。*disabled 置真 = 这一行真用不了（没补丁且设备不支持补帧）。
//   hasFpsPatch = 这款有社区帧率补丁；fpsPatchOn = 帧率开关开着；fiSupported = 设备能补帧（机上判，底料里是出包机的值不能信）。作业层给了 fps.source 就以它为准；fps.state = unsupported 置灰
NSString *s2a_sgrade_row_note(NSString *cat, NSDictionary *s, NSInteger fpsTarget, BOOL hasFpsPatch, BOOL fpsPatchOn, BOOL fiSupported,
                              NSString *(^date)(NSDate *when), BOOL *disabled);
