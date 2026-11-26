// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 上下分屏折痕暗带（11-17 去掉下区倒影后只剩它）：什么时候画，期望按「分屏且有真折痕才画」手写；no game assets or UIKit.
#import "../../ios/play_reflection.h"
#include <stdio.h>
static int bad, checks;
#define CK(c, msg) do { checks++; if (!(c)) { bad++; printf("✗ %s\n", msg); } } while (0)
int main(void) { @autoreleasepool {
    CGRect b=CGRectMake(0,0,600,800);
    CK(S2APlayFoldBandWanted(S2APlayLayoutMake(b,b,S2APlaySplitOn,NO,CGRectMake(0,380,600,40))),"有横向折痕的分屏：画暗带");
    CK(S2APlayFoldBandWanted(S2APlayLayoutMake(b,b,S2APlaySplitOn,NO,CGRectMake(290,0,20,800))),"有竖向折痕的分屏：画暗带");
    CK(!S2APlayFoldBandWanted(S2APlayLayoutMake(b,b,S2APlaySplitOn,NO,CGRectNull)),"没有折痕（普通 iPhone 强制分屏，#979）：不画");
    CK(!S2APlayFoldBandWanted(S2APlayLayoutMake(b,b,S2APlaySplitOff,NO,CGRectMake(0,380,600,40))),"不分屏：不画");
    printf("%s t_play_reflection：%d/%d 项符合\n",bad?"✗":"✓",checks-bad,checks);
    return bad?1:0;
} }
