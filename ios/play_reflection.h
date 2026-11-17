// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#import "play_layout.h"

// 游戏层的容器与上下分屏时的折痕暗带（原先下区还有一份游戏画面的倒影，11-17 维护者定：去掉倒影、不加开关，折痕处画纯色暗带）。
// Whether the fold gets the dark band: only on a device with a real fold (layout.division from the hinge), while split.
BOOL S2APlayFoldBandWanted(S2APlayLayout layout);
#if TARGET_OS_IPHONE
@class CALayer;
// Main thread; the host retains one game layer per root. Both renderers keep their own frame / drawable size.
void s2a_ios_attach_game_layer(UIView *root, CALayer *game);
void S2APlayBackgroundLayout(UIView *root, S2APlayLayout layout);
#endif
