// ios/haptic_safe.h：引擎被系统停掉时 CoreHaptics 对播放器调用抛 ObjC 异常（诊断 D-APX8 等，rumbler_reset ← stoppedHandler → stopAtTime 抛异常整局 abort）。
//   用一个每个方法都抛 NSInternalInconsistencyException 的假播放器 / 假引擎：四个包装都不得把异常放出去；停止类静默，播放 / 调强度回 NO 且带出错误。
//   另核四个调用文件里不再有直接的 stopAtTime / startAtTime / sendParameters / stopWithCompletionHandler（新加的调用点不经包装就红）。
#import <Foundation/Foundation.h>
#include "haptic_safe.h"
#include <stdio.h>
#include <string.h>

@interface ThrowingPlayer : NSObject <CHHapticPatternPlayer>
@property BOOL isMuted;
@end
@implementation ThrowingPlayer
static void boom(void) { @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"engine is not running" userInfo:nil]; }
- (BOOL)startAtTime:(NSTimeInterval)t error:(NSError **)e { (void)t; (void)e; boom(); return YES; }
- (BOOL)stopAtTime:(NSTimeInterval)t error:(NSError **)e { (void)t; (void)e; boom(); return YES; }
- (BOOL)sendParameters:(NSArray<CHHapticDynamicParameter *> *)p atTime:(NSTimeInterval)t error:(NSError **)e { (void)p; (void)t; (void)e; boom(); return YES; }
- (BOOL)scheduleParameterCurve:(CHHapticParameterCurve *)c atTime:(NSTimeInterval)t error:(NSError **)e { (void)c; (void)t; (void)e; boom(); return YES; }
- (BOOL)cancelAndReturnError:(NSError **)e { (void)e; boom(); return YES; }
@end
@interface ThrowingEngine : CHHapticEngine @end
@implementation ThrowingEngine
- (void)stopWithCompletionHandler:(CHHapticCompletionHandler)h { (void)h; boom(); }
@end

static int bad;
#define CHECK(c, ...) do { if (!(c)) { bad++; printf("✗ " __VA_ARGS__); printf("\n"); } else { printf("✓ " __VA_ARGS__); printf("\n"); } } while (0)

int main(int argc, char **argv) { @autoreleasepool {
    ThrowingPlayer *p = [ThrowingPlayer new];
    int leaked = 0;
    @try { s2a_hp_stop(p); } @catch (NSException *e) { leaked++; }
    CHECK(!leaked, "① 引擎已停时 stopAtTime 抛异常：s2a_hp_stop 接住、不外抛");
    NSError *err = nil; BOOL ok = YES; leaked = 0;
    @try { ok = s2a_hp_start(p, &err); } @catch (NSException *e) { leaked++; }
    CHECK(!leaked && !ok && [err.domain isEqualToString:@"S2AHapticException"] && [err.localizedDescription containsString:@"engine is not running"], "② startAtTime 抛异常：回 NO、错误带出异常原因（%s）", err.localizedDescription.UTF8String ?: "-");
    err = nil; ok = YES; leaked = 0;
    @try { ok = s2a_hp_send(p, @[], &err); } @catch (NSException *e) { leaked++; }
    CHECK(!leaked && !ok && err, "③ sendParameters 抛异常：回 NO、有错误");
    leaked = 0;
    @try { ok = s2a_hp_send(p, @[], NULL); } @catch (NSException *e) { leaked++; }
    CHECK(!leaked && !ok, "④ 错误出参给 NULL 也不崩");
    leaked = 0;
    ThrowingEngine *eng = (ThrowingEngine *)[ThrowingEngine alloc];   // 不 init：只用它的 stopWithCompletionHandler 覆写
    @try { s2a_hp_engine_stop(eng); } @catch (NSException *e) { leaked++; }
    CHECK(!leaked, "⑤ 引擎 stopWithCompletionHandler 抛异常：s2a_hp_engine_stop 接住");
    s2a_hp_stop(nil); s2a_hp_engine_stop(nil);
    CHECK(1, "⑥ nil 播放器 / 引擎直接返回");
    for (int i = 1; i < argc; i++) {   // 调用文件里不得再有直接调用（新调用点必须经包装）
        NSString *src = [NSString stringWithContentsOfFile:@(argv[i]) encoding:NSUTF8StringEncoding error:nil];
        int n = 0; for (NSString *sel in @[@" stopAtTime:", @" startAtTime:", @" sendParameters:", @" stopWithCompletionHandler:"]) {
            NSRange r = NSMakeRange(0, src.length);
            while ((r = [src rangeOfString:sel options:0 range:r]).location != NSNotFound) {
                NSRange line = [src lineRangeForRange:r];
                if (![[src substringWithRange:line] containsString:@"haptic_safe"] ) n++;
                r = NSMakeRange(NSMaxRange(r), src.length - NSMaxRange(r)); }
        }
        CHECK(src && n == 0, "⑦ %s 没有绕过包装的直接调用（%d 处）", argv[i], n);
    }
    printf("%s t_haptic_safe：%d 项不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
} }
