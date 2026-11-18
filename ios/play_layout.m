// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import "play_layout.h"
#import "play_reflection.h"
#include <math.h>
#include <stdatomic.h>

static _Atomic int g_split_active;
void S2APlayPublishSplit(BOOL split) { atomic_store(&g_split_active,split ? 1 : 0); }
int s2a_ios_split_active(void) { return atomic_load(&g_split_active); }
// 游戏区域（graphics/nvn/host_adapt.m、graphics/metal/gal_ios_layer.m 弱引用）：iOS 上由下面的分屏布局给（#301）；
//   非 iOS 编译（Mac 单测 t_play_layout 也编本文件）没有分屏，回空矩形 = 调用方用视图自身
#if !TARGET_OS_IPHONE
CGRect s2a_ios_game_area(void) { return CGRectNull; }
int s2a_ios_game_top(void) { return 0; }
#endif

NSString *const S2APlaySplitKey=@"splitScreen", *const S2APlayOrientationKey=@"screenOrientation", *const S2APlayLayoutChanged=@"S2APlayLayoutChanged";
// app scope 沿用共享表 padFace 的存法：NSUserDefaults 的键就是表 id。
// 生产入口不注册这两项缺省，未保存时 objectForKey 为 nil；缺省由读取逻辑返回。
// 此约束下旧键只在规范键不存在时迁移，随后删除。
static NSString *play_choice(NSUserDefaults *d, NSString *key, NSString *legacy, NSArray<NSString *> *values) {
    id value=[d objectForKey:key], old=[d objectForKey:legacy];
    if (!value && [values containsObject:old]) { value=old; [d setObject:value forKey:key]; }
    if (old) [d removeObjectForKey:legacy];
    if (value && ![values containsObject:value]) { [d removeObjectForKey:key]; value=nil; }
    return value ?: @"auto";
}
S2APlaySplitMode S2APlayReadSplit(NSUserDefaults *d) {
    NSString *v=play_choice(d,S2APlaySplitKey,@"S2ASplitScreen",@[@"auto",@"on",@"off"]);
    return [v isEqual:@"on"] ? S2APlaySplitOn : [v isEqual:@"off"] ? S2APlaySplitOff : S2APlaySplitAuto;
}
S2APlayOrientation S2APlayReadOrientation(NSUserDefaults *d) {
    NSString *v=play_choice(d,S2APlayOrientationKey,@"S2AScreenOrientation",@[@"auto",@"landscape",@"portrait"]);
    return [v isEqual:@"portrait"] ? S2APlayOrientationPortrait : [v isEqual:@"landscape"] ? S2APlayOrientationLandscape : S2APlayOrientationAuto;
}
BOOL S2APlaySplitEnabled(S2APlaySplitMode mode, BOOL partiallyOpen) { return mode==S2APlaySplitOn || (mode==S2APlaySplitAuto && partiallyOpen); }
BOOL S2APlayPortrait(S2APlayOrientation orientation, BOOL split) { return orientation==S2APlayOrientationPortrait || (orientation==S2APlayOrientationAuto && split); }
static BOOL finite_rect(CGRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y) && isfinite(r.size.width) && isfinite(r.size.height) && r.size.width>=0 && r.size.height>=0;
}
S2APlayLayout S2APlayLayoutMake(CGRect b, CGRect safe, S2APlaySplitMode mode, BOOL half, CGRect division) {
    BOOL split=S2APlaySplitEnabled(mode,half);
    S2APlayLayout l={b,CGRectIntersection(b,safe),CGRectNull,split,NO};
    if (!finite_rect(b) || CGRectIsEmpty(b)) return (S2APlayLayout){CGRectZero,CGRectZero,CGRectNull,split,NO};
    if (!finite_rect(division)) division=CGRectNull;
    if (!CGRectIsNull(division)) l.division=CGRectIntersection(b,division);
    if (!split) return l;
    CGFloat top=CGRectGetMidY(b), bottom=top; BOOL hinge=NO;
    if (!CGRectIsNull(l.division) && division.size.width>division.size.height &&
        l.division.size.width>=b.size.width*.9 && CGRectGetMinY(division)>CGRectGetMinY(b) && CGRectGetMaxY(division)<CGRectGetMaxY(b)) {
        top=CGRectGetMinY(division); bottom=CGRectGetMaxY(division); hinge=YES;
    }
    l.game=CGRectIntersection(safe,CGRectMake(b.origin.x,b.origin.y,b.size.width,top-b.origin.y));
    // 竖屏分屏、上区没有折痕可依（手动分屏）、安全区左右有缩进（iPhone Duo 外屏竖着用：系统报右 84 点，11-15 真机读数 视图 466×678、安全区 右 84 下 34）：
    //   原先取安全区 ∩ 上半屏只有 382 点宽，16:9 画面再上下居中，外屏左上一小块、右边和顶上空着。改成横向按整屏宽、竖向仍按安全区，画面贴顶放
    //   （上面没有要躲的东西；手柄在下半区）。别的机型竖屏左右缩进都是 0、半折内屏走折痕分支，区域不变
    CGRect sg=CGRectIntersection(b,safe);
    if (!hinge && b.size.height>b.size.width && !CGRectIsNull(sg) &&
        (CGRectGetMinX(sg)>CGRectGetMinX(b) || CGRectGetMaxX(sg)<CGRectGetMaxX(b))) {
        CGFloat y=MAX(CGRectGetMinY(sg),b.origin.y);
        l.game=top>y ? CGRectMake(b.origin.x,y,b.size.width,top-y) : CGRectNull; l.top=YES;
    }
    l.controls=CGRectIntersection(safe,CGRectMake(b.origin.x,bottom,b.size.width,CGRectGetMaxY(b)-bottom));
    if (CGRectIsNull(l.game)) l.game=CGRectZero;
    if (CGRectIsNull(l.controls)) l.controls=CGRectZero;
    return l;
}
CGSize S2APlayTargetSize(CGSize a) {
    if (!(a.width>0 && a.height>0) || !isfinite(a.width) || !isfinite(a.height)) return CGSizeMake(1920,1080);
    double r=a.width/a.height;
    // 与 runtime/src/widen.c 的范围一致：只扩展一边，保持偶数像素。
    return r>=16.0/9 ? CGSizeMake(((int)fmin(8192,1080*r))&~1,1080) : CGSizeMake(1920,((int)fmin(8192,1920/r))&~1);
}
CGRect S2APlayControlsRect(S2APlayLayout l, CGRect b) {
    CGRect margin=CGRectMake(b.origin.x+16,b.origin.y,MAX(0,b.size.width-32),MAX(0,b.size.height-8));
    CGRect r=CGRectIntersection(l.controls,margin);
    return CGRectIsNull(r) ? CGRectZero : r;
}

#if TARGET_OS_IPHONE
#include <unistd.h>
static S2APlayLayout g_layout;
static _Atomic BOOL g_half;
static _Atomic double g_view_ratio;
static _Atomic int g_max_fps;   // 屏幕最高刷新率（帧率补丁按档默认取不超过它的最高一档，runtime/src/cpatch.c fps_pick；布局时在主线程记）
S2APlayLayout s2a_ios_play_layout(void) { return g_layout; }
CGRect s2a_ios_game_area(void) { return g_layout.game; }
int s2a_ios_game_top(void) { return g_layout.top; }
// 可自由缩放的窗口（尺寸类 regular/regular：Duo 内屏、iPad）：方向不干预，哪端朝上画面就朝哪端（#1364 维护者拍板），设置里的横 / 竖只管普通 iPhone。
//   游戏页每次排版按自己窗口的尺寸类记（主线程写，各处读）
static _Atomic int g_resizable;
int s2a_ios_play_resizable(void) { return atomic_load(&g_resizable); }
#if !TARGET_OS_TV
UIInterfaceOrientationMask s2a_ios_play_orientations(void) {
    if (atomic_load(&g_resizable)) return UIInterfaceOrientationMaskAll;
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    BOOL split=S2APlaySplitEnabled(S2APlayReadSplit(d),g_half);
    return S2APlayPortrait(S2APlayReadOrientation(d),split) ? UIInterfaceOrientationMaskPortrait : UIInterfaceOrientationMaskLandscape;
}
#endif
// 玩家选的方向是竖屏吗（电视只有横屏，11-15 Apple TV 版）
static BOOL play_wants_portrait(void) {
#if TARGET_OS_TV
    return NO;
#else
    return s2a_ios_play_orientations()==UIInterfaceOrientationMaskPortrait;
#endif
}
// 外接屏（ios/extdisplay.m）：画面出在外接屏上时比例按外接屏。这里给弱的缺省实现（没有外接屏 = 0）：
//   输入工作台（ios/lab）只编本文件、不编 extdisplay.m，App 里 extdisplay.m 的正式实现链接时盖过它
__attribute__((weak)) double s2a_ios_ext_ratio(void) { return 0; }
static double screen_ratio(void) {
    double x = s2a_ios_ext_ratio(); if (x > 0) return x;
    double r=atomic_load(&g_view_ratio);
    if (!(r>0) && !NSThread.isMainThread) for (int i=0;i<500 && !((r=atomic_load(&g_view_ratio))>0);i++) usleep(10000);
    if (r>0) return r;
    // 还没排过版：按当前前台场景所在的那块屏算。不用 UIScreen.mainScreen——iPhone Duo 内屏亮着时它仍报外屏 1398×2034（11-13 真机读数）
    CGSize s=CGSizeZero;
    if (NSThread.isMainThread) for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:UIWindowScene.class] && sc.activationState==UISceneActivationStateForegroundActive) { s=((UIWindowScene *)sc).coordinateSpace.bounds.size; break; }
    if (!(s.width>0 && s.height>0)) s=UIScreen.mainScreen.nativeBounds.size;
    BOOL portrait=atomic_load(&g_resizable) ? s.height>s.width : play_wants_portrait();   // 自由窗口按实际方向；电视只有横屏（play_wants_portrait）
    CGRect b=CGRectMake(0,0,portrait?fmin(s.width,s.height):fmax(s.width,s.height),portrait?fmax(s.width,s.height):fmin(s.width,s.height));
    CGRect a=S2APlayLayoutMake(b,b,S2APlayReadSplit(NSUserDefaults.standardUserDefaults),g_half,CGRectNull).game;
    return a.size.width>0 && a.size.height>0 ? a.size.width/a.size.height : 16.0/9;
}
int s2a_ios_screen_known(void) { return atomic_load(&g_view_ratio)>0; }
// 屏幕最高刷新率（Hz；Info.plist 有 CADisableMinimumFrameDurationOnPhone，ProMotion 机回 120）：主线程布局时记下；还没记（游戏线程早问）等最多 5 秒，仍没有回 60
int s2a_ios_screen_max_fps(void) {
    int v=atomic_load(&g_max_fps);
    if (!v && NSThread.isMainThread) { v=(int)UIScreen.mainScreen.maximumFramesPerSecond; atomic_store(&g_max_fps,v); }
    for (int i=0;!v && i<500;i++) { usleep(10000); v=atomic_load(&g_max_fps); }
    return v>0 ? v : 60;
}
int s2a_ios_screen_w(void) { return S2APlayTargetSize(CGSizeMake(screen_ratio(),1)).width; }
int s2a_ios_screen_h(void) { return S2APlayTargetSize(CGSizeMake(screen_ratio(),1)).height; }

CGRect S2APlayDivision(UIView *view) {
#if defined(__IPHONE_27_1) && __IPHONE_OS_VERSION_MAX_ALLOWED>=__IPHONE_27_1
    if (@available(iOS 27.1,*)) {
        Class kindClass=NSClassFromString(@"UIViewReservedRegionKind");
        if (![kindClass respondsToSelector:@selector(divisionRegionKind)] || ![view respondsToSelector:@selector(reservedRegionsOfKind:)]) return CGRectNull;
        for (UIViewReservedRegion *r in [view reservedRegionsOfKind:[kindClass divisionRegionKind]]) {
            CGRect f=r.frame, b=view.bounds;
            if (finite_rect(f) && ((f.size.width>=b.size.width*.9 && f.size.width>f.size.height) ||
                                  (f.size.height>=b.size.height*.9 && f.size.height>f.size.width))) return f;
        }
    }
#endif
    return CGRectNull;
}
@interface S2APlaySurface : UIView
@property(nonatomic) CGRect division;
@property(nonatomic) BOOL partiallyOpen;
@property(nonatomic,copy) void (^changed)(void);
@end
@implementation S2APlaySurface
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self=[super initWithFrame:frame])) return nil;
    _division=CGRectNull;
#if __has_include(<UIKit/UIHingeInteraction.h>)
    if (@available(iOS 27.1,*)) {
        __weak S2APlaySurface *weakSelf=self;
        UIHingeInteraction *interaction=[[NSClassFromString(@"UIHingeInteraction") alloc] initWithUpdateHandler:^(UIHingeInteraction *interaction, UIHingeInteractionUpdate *update) {
            S2APlaySurface *s=weakSelf; if (!s) return;
            BOOL half=update.hinge.status==UIHingeStatusPartiallyOpen;
            if (half==s.partiallyOpen) return;
            s.partiallyOpen=half; [s setNeedsUpdateConstraints]; if (s.changed) s.changed();
        }];
        if (interaction) [self addInteraction:interaction];
    }
#endif
    [self setNeedsUpdateConstraints]; return self;
}
- (void)setBounds:(CGRect)b { BOOL changed=!CGRectEqualToRect(b,self.bounds); [super setBounds:b]; if (changed) [self setNeedsUpdateConstraints]; }
- (void)updateConstraints {
    CGRect r=S2APlayDivision(self);
    if (!CGRectEqualToRect(r,_division)) { _division=r; [self setNeedsLayout]; }
    [super updateConstraints];
}
@end

@implementation S2APlayViewController {
#if !TARGET_OS_TV
    UIInterfaceOrientationMask _requested;
#endif
    BOOL _transitioning, _orientationRefused, _waitingOrientation;
    S2APlaySplitMode _lastSplit;
    S2APlayOrientation _lastOrientation;
}
- (void)loadView {
    S2APlaySurface *surface=[[S2APlaySurface alloc] initWithFrame:CGRectZero]; self.view=surface;
    __weak S2APlayViewController *weakSelf=self;
    surface.changed=^{ [weakSelf updatePlayPreferences]; };
}
- (void)viewDidLoad {
    [super viewDidLoad];
    NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(updatePlayPreferences) name:NSUserDefaultsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(updatePlayPreferences) name:UIApplicationDidBecomeActiveNotification object:nil];
    [self updatePlayPreferences];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (BOOL)resizable {
#if TARGET_OS_TV   // 电视窗口固定横屏，不算自由缩放
    return NO;
#else
    UITraitCollection *t=self.view.window.windowScene.traitCollection; return t.horizontalSizeClass==UIUserInterfaceSizeClassRegular && t.verticalSizeClass==UIUserInterfaceSizeClassRegular;
#endif
}
S2A_VERTICAL_BAR_OFF
#if !TARGET_OS_TV
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return self.resizable ? UIInterfaceOrientationMaskAll : s2a_ios_play_orientations(); }   // 自由窗口：全部方向、不申请
#endif
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self updatePlayPreferences]; }
- (void)updatePlayPreferences {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{ [self updatePlayPreferences]; }); return; }
    g_half=((S2APlaySurface *)self.view).partiallyOpen;
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    S2APlaySplitMode split=S2APlayReadSplit(d); S2APlayOrientation orientation=S2APlayReadOrientation(d);
#if TARGET_OS_TV   // 电视只有横屏：不发方向请求，只按偏好重排
    _lastSplit=split; _lastOrientation=orientation;
    [self.view setNeedsUpdateConstraints]; [self.view setNeedsLayout];
    return;
#else
    UIInterfaceOrientationMask mask=s2a_ios_play_orientations();
    if (_lastSplit!=split || _lastOrientation!=orientation) { _requested=0; _orientationRefused=NO; }
    _lastSplit=split; _lastOrientation=orientation;
    atomic_store(&g_resizable, self.resizable);
    [self setNeedsUpdateOfSupportedInterfaceOrientations];
    [self.view setNeedsUpdateConstraints]; [self.view setNeedsLayout];
    UIWindowScene *scene=self.view.window.windowScene;
    if (self.resizable) { _requested=0; return; }   // 自由窗口不申请方向：交给系统跟着手机转（#1364）
    mask=s2a_ios_play_orientations();
    if (!scene || mask==_requested) return;
    _requested=mask; _orientationRefused=NO;
    [NSNotificationCenter.defaultCenter postNotificationName:S2APlayLayoutChanged object:nil];
    UIViewController *top=self; while (top.presentedViewController) top=top.presentedViewController;
    [top setNeedsUpdateOfSupportedInterfaceOrientations];
    [scene requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask] errorHandler:^(NSError *error) {
        // 系统在后台队列调这个回调（7 份「后台线程改自动布局」闪退崩前都有下面这行、4181 份没有这行的 0 崩）：改界面派回主线程
        fprintf(stderr,"[S2A 布局] 系统未接受方向请求，按实际窗口布局：%s（回调在%s线程）\n",error.localizedDescription.UTF8String,NSThread.isMainThread?"主":"后台");
        dispatch_async(dispatch_get_main_queue(), ^{ self->_orientationRefused=YES; [self.view setNeedsLayout]; });
    }];
#endif
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    _transitioning=YES;
    [NSNotificationCenter.defaultCenter postNotificationName:S2APlayLayoutChanged object:nil];
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        self->_transitioning=NO; [self.view setNeedsUpdateConstraints]; [self.view setNeedsLayout];
    }];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_transitioning || UIApplication.sharedApplication.applicationState==UIApplicationStateBackground) return;
    S2APlaySurface *s=(S2APlaySurface *)self.view;
    S2APlayLayout l=S2APlayLayoutMake(s.bounds,s.safeAreaLayoutGuide.layoutFrame,S2APlayReadSplit(NSUserDefaults.standardUserDefaults),s.partiallyOpen,s.division);
    BOOL changed=!CGRectEqualToRect(l.game,g_layout.game) || !CGRectEqualToRect(l.controls,g_layout.controls) || !CGRectEqualToRect(l.division,g_layout.division) || l.split!=g_layout.split;
    g_layout=l;
    S2APlayPublishSplit(l.split);
    S2APlayBackgroundLayout(s,l);
    BOOL portrait=s.bounds.size.height>s.bounds.size.width;
    if (atomic_exchange(&g_resizable, self.resizable) != self.resizable) [self updatePlayPreferences];   // 换窗口类型（Duo 合上 / 展开）：重新定要不要申请方向
    BOOL expectedPortrait=self.resizable ? portrait : play_wants_portrait();   // 自由窗口按实际方向（不再等转到玩家选的方向）
    // 屏幕比例（宽屏静态改写装载时按它写死，起局后跟不上）只认玩家选的方向：可自由缩放的窗口（Duo 内屏 / iPad，尺寸类 regular/regular）也先等系统转到位。
    //   11-13 Duo 内屏：原先 resizable 时不等，起局那一刻手机横着就按横屏比例 2.84 定了屏幕宽 3070，随后转成竖屏分屏，静态表还按 3070 画、画面右侧和上下被裁。
    //   只管第一次：系统拒绝方向请求，或 1 秒内没转过来（iPad 自由窗口接受请求却转不了），按实际窗口记
    BOOL settled=portrait==expectedPortrait || _orientationRefused || (self.resizable && atomic_load(&g_view_ratio)>0);   // 起局后自由窗口照旧跟实际窗口（运行中换屏）
    if (!settled && self.resizable && !_waitingOrientation) {
        _waitingOrientation=YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
            self->_waitingOrientation=NO;
            if (!(atomic_load(&g_view_ratio)>0)) { self->_orientationRefused=YES; [self.view setNeedsLayout]; }
        });
    }
    if (l.game.size.width>0 && l.game.size.height>0 && settled) atomic_store(&g_view_ratio,l.game.size.width/l.game.size.height);
    { UIScreen *sc=s.window.windowScene.screen; if (sc) atomic_store(&g_max_fps,(int)sc.maximumFramesPerSecond); }
    if (changed) {
        fprintf(stderr,"[S2A 布局] 分屏 %s，游戏 %.1f,%.1f %.1fx%.1f，按键 %.1f,%.1f %.1fx%.1f\n",l.split?"开":"关",l.game.origin.x,l.game.origin.y,l.game.size.width,l.game.size.height,l.controls.origin.x,l.controls.origin.y,l.controls.size.width,l.controls.size.height);
        [NSNotificationCenter.defaultCenter postNotificationName:S2APlayLayoutChanged object:nil];
    }
}
@end
#endif
