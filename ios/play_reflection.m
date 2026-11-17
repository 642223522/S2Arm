// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import "play_reflection.h"
#import "tv_compat.h"

// 折痕暗带只给有真折痕的设备（Duo 半折，layout.division 来自铰链保留区）。#979：普通 iPhone 强制上下分屏没有折痕，不画
BOOL S2APlayFoldBandWanted(S2APlayLayout l) { return l.split && !CGRectIsNull(l.division) && !CGRectIsEmpty(l.division); }

#if TARGET_OS_IPHONE
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// The game layer sits alone in a plain container, under a solid dark band over the fold while split.
// 11-17：下区的倒影（第二个 CAMetalLayer，渲染器每次上屏同画一份，上面盖模糊与渐暗）连同模糊 / 渐暗一起去掉，玩家觉得下半屏多一份画面干扰；
//   折痕处原先是黑→半透明的渐变过渡，改成纯色暗带（下区本来是黑底，手柄按钮画在上面）
@interface S2APlayBackground : UIView
@property(nonatomic,strong) CALayer *game;
- (void)update:(S2APlayLayout)layout;
@end
@implementation S2APlayBackground {
    CALayer *_host, *_fold;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self=[super initWithFrame:frame])) return nil;
    self.userInteractionEnabled=NO; self.clipsToBounds=YES;
    self.accessibilityElementsHidden=YES;
    _host=[CALayer layer]; [self.layer addSublayer:_host];
    _fold=[CALayer layer]; _fold.backgroundColor=[UIColor colorWithWhite:0 alpha:.85].CGColor; _fold.hidden=YES;
    [self.layer addSublayer:_fold];
    return self;
}
- (void)setGame:(CALayer *)game {
    if (_game==game && game.superlayer==_host) return;   // 同一个层但被挪走过（外接屏来回）：照样放回容器
    [_game removeFromSuperlayer]; _game=game; [_host addSublayer:game];
}
- (void)update:(S2APlayLayout)layout {
    CGRect fold=CGRectIntersection(layout.division,self.bounds);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _host.frame=self.bounds;
    _fold.hidden=!S2APlayFoldBandWanted(layout) || CGRectIsNull(fold) || CGRectIsEmpty(fold);
    if (!_fold.hidden) _fold.frame=fold;
    [CATransaction commit];
}
@end

static char backgroundKey;
void S2APlayBackgroundLayout(UIView *root, S2APlayLayout layout) {
    S2APlayBackground *background=objc_getAssociatedObject(root,&backgroundKey);
    if (!background) return;
    background.frame=root.bounds; background.bounds=root.bounds;
    [background update:layout];
}
void s2a_ios_attach_game_layer(UIView *root, CALayer *game) {
    NSCAssert(NSThread.isMainThread,@"Game layer attachment requires the main thread");
    S2APlayBackground *background=objc_getAssociatedObject(root,&backgroundKey);
    if (!background) {
        background=[S2APlayBackground new];
        objc_setAssociatedObject(root,&backgroundKey,background,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [root insertSubview:background atIndex:0];
    }
    background.game=game;
    S2APlayBackgroundLayout(root,s2a_ios_play_layout());
}
#endif
