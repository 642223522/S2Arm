// 手机上直接拿签名证书（0.6.0：买了开发者证书的玩家、SideStore 装的玩家都不经电脑）。三个入口，存法同电脑交来的身份（runtime/src/selfsign.c s2a_identity_import_p12：
//   存钥匙串同一标签、写 identity/current.json），之后导入的 .s2arm 起局时按这张证书签（ios/program_resign.m）：
//   ① 游戏库设置「签名证书」→「导入 .p12…」：文件选择器选 .p12，问一次密码（错了再问）；
//   ② 游戏库设置「签名证书」→「从 SideStore 获取」：打开 sidestore://certificate，SideStore 问玩家、点 Export 后回调 s2arm://sidestore-cert（ios/cert_callback.m）；
//   ③ 「放这里导入」文件夹里放 .p12 / .pfx：扫到就问密码，导好删掉这个文件。
//   证书的团队和这个 App 不同（包里描述文件的团队）：照样存（不拦），如实告诉玩家用它签的游戏系统不认、该怎么办
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "s2a_l10n.h"
#include "native.h"   // LOG
#include "s2a_docs.h"   // s2a_container_docs
extern const char *const s2a_img_import_dirs[2];   // pack_apply.c：「放这里导入」的两个名字（中 / 英）

int s2a_identity_import_p12(const char *home, const void *p12, size_t n, const char *password, const char *source, char *team, size_t team_n, char *why, size_t why_n);   // selfsign.c
int s2a_prov_signing_ids_self(char *team, size_t team_n, char *appid, size_t appid_n);   // prov_expiry.m
NSURL *s2a_cert_sidestore_request(void);   // cert_callback.m
int s2a_cert_callback_parse(NSString *url, NSData **p12, NSString **pw);

static UIViewController *top_vc(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState == UISceneActivationStateBackground) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow && w.rootViewController) {
            UIViewController *c = w.rootViewController; while (c.presentedViewController && !c.presentedViewController.isBeingDismissed) c = c.presentedViewController; return c; }
    }
    return nil;
}
static void say(NSString *title, NSString *message) {
    UIViewController *vc = top_vc(); if (!vc) { LOG("签名证书：没有可弹框的界面（%s）", title.UTF8String); return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:S2AL(@"common.gotIt") style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}
static void changed(void) { [NSNotificationCenter.defaultCenter postNotificationName:@"S2ASigningCertChanged" object:nil]; }

// 导入一份 .p12（主线程调、主线程回）。password nil = 先试空密码，不行再问；source 写进 current.json；done(YES) = 导好了
static void import_p12(NSData *p12, NSString *name, NSString *password, const char *source, void (^done)(BOOL ok)) {
    char team[64] = "", why[256] = "";
    int rc = s2a_identity_import_p12(getenv("HOME"), p12.bytes, p12.length, (password ?: @"").UTF8String, source, team, sizeof team, why, sizeof why);
    if (rc == 1) {   // 密码不对（或还没问）：问一次，错了带一句「密码不对」再问
        UIViewController *vc = top_vc(); if (!vc) { if (done) done(NO); return; }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:S2AL(@"cert.password.title")
            message:[NSString stringWithFormat:password ? S2AL(@"cert.password.wrong") : S2AL(@"cert.password.message"), name] preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.secureTextEntry = YES; f.textContentType = UITextContentTypePassword; }];
        [a addAction:[UIAlertAction actionWithTitle:S2AL(@"common.cancel") style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *x) { if (done) done(NO); }]];
        [a addAction:[UIAlertAction actionWithTitle:S2AL(@"cert.import") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {
            import_p12(p12, name, a.textFields.firstObject.text ?: @"", source, done); }]];
        [vc presentViewController:a animated:YES completion:nil];
        return;
    }
    if (rc) { LOG("【红】签名证书导入失败（%s）：%s", name.UTF8String, why); say(S2AL(@"cert.failed.title"), S2AL(@"cert.failed.message")); if (done) done(NO); return; }
    NSString *msg = [NSString stringWithFormat:S2AL(@"cert.done.message"), team[0] ? @(team) : @"?"];
    char pteam[64] = "", pappid[512] = "";
    if (team[0] && s2a_prov_signing_ids_self(pteam, sizeof pteam, pappid, sizeof pappid) >= 0 && strcmp(team, pteam)) {   // 团队和装这个 App 的不同：如实说，不拦
        LOG("【黄】签名证书团队 %s 与本 App 团队 %s 不同：用它签的游戏系统不认", team, pteam);
        msg = [msg stringByAppendingFormat:@"\n\n%@", [NSString stringWithFormat:S2AL(@"cert.teamMismatch"), @(team), @(pteam)]];
    }
    say(S2AL(@"cert.done.title"), msg); changed();
    if (done) done(YES);
}

// ---------- ① 选 .p12 文件 ----------
// tvOS 没有文件选择器（UIDocumentPicker 不可用）：Apple TV 壳上「导入 .p12…」是空操作，入口本来也只在 iOS 接线（S2ArmShellHostModel #if !os(tvOS)）
#if !TARGET_OS_TV
@interface S2ACertPicker : NSObject <UIDocumentPickerDelegate> @end
@implementation S2ACertPicker
- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *u = urls.firstObject; BOOL scoped = [u startAccessingSecurityScopedResource];
    NSData *d = u ? [NSData dataWithContentsOfURL:u] : nil; if (scoped) [u stopAccessingSecurityScopedResource];
    if (!d.length) { say(S2AL(@"cert.failed.title"), S2AL(@"cert.failed.message")); return; }
    LOG("签名证书：玩家选了 %s（%lu 字节）", u.lastPathComponent.UTF8String, (unsigned long)d.length);
    import_p12(d, u.lastPathComponent, nil, "p12", nil);
}
@end
void s2a_shell_cert_p12(void) {   // 游戏库设置「签名证书」→「导入 .p12…」（shell/Sources/S2ArmShellBridge/include/s2a_shell.h）
    static S2ACertPicker *delegate; if (!delegate) delegate = [S2ACertPicker new];
    UTType *p12 = [UTType typeWithIdentifier:@"com.rsa.pkcs-12"] ?: UTTypeData;
    // 任何文件都能选（AltStore / 别的工具导出的证书扩展名不一定是 .p12）：导入时按内容判，不是证书再说「不是能用的证书文件」
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[p12, UTTypeData] asCopy:YES];
    p.delegate = delegate; [top_vc() presentViewController:p animated:YES completion:nil];
}
#else
void s2a_shell_cert_p12(void) {}
#endif

// ---------- ② SideStore ----------
void s2a_shell_cert_sidestore(void) {   // 游戏库设置「签名证书」→「从 SideStore 获取」
    NSURL *u = s2a_cert_sidestore_request(); LOG("签名证书：打开 SideStore 取证书");
    [UIApplication.sharedApplication openURL:u options:@{} completionHandler:^(BOOL ok) {
        if (!ok) { LOG("签名证书：打不开 SideStore（这台手机上没有，或版本太老不认 sidestore://certificate）"); say(S2AL(@"cert.failed.title"), S2AL(@"cert.sidestore.missing")); }
    }];
}
// SideStore 的回调（app.m scene:openURLContexts: 先交给这里）：YES = 是这个回调（已处理）
BOOL s2a_cert_handle_url(NSURL *url) {
    NSData *p12 = nil; NSString *pw = nil; int r = s2a_cert_callback_parse(url.absoluteString, &p12, &pw);
    if (r == -1) return NO;
    if (r) { LOG("【红】签名证书：SideStore 回调里没有能解出的证书"); say(S2AL(@"cert.failed.title"), S2AL(@"cert.sidestore.empty")); return YES; }
    LOG("签名证书：SideStore 交回证书（%lu 字节）", (unsigned long)p12.length);
    import_p12(p12, @"SideStore", pw, "sidestore", nil);   // SideStore 的 .p12 不带 MAC、密码不起作用：带它给的密码直接导，系统接口导不进时 selfsign.c 按明文格式取
    return YES;
}

// ---------- ③ 「放这里导入」里的 .p12 ----------
void s2a_cert_scan_import_dirs(void) {   // 主线程，游戏库扫导入文件夹时一并调（app.m）
    static BOOL busy; if (busy) return;
    char d[1024]; s2a_container_docs(d, sizeof d);
    NSMutableArray<NSString *> *dirs = [NSMutableArray arrayWithObject:@(d)];
    for (int i = 0; i < 2; i++) [dirs addObject:[@(d) stringByAppendingPathComponent:@(s2a_img_import_dirs[i])]];
    for (NSString *dir in dirs) for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
        NSString *ext = f.pathExtension.lowercaseString; if (![ext isEqualToString:@"p12"] && ![ext isEqualToString:@"pfx"]) continue;
        NSString *path = [dir stringByAppendingPathComponent:f]; NSData *data = [NSData dataWithContentsOfFile:path]; if (!data.length) continue;
        LOG("签名证书：「放这里导入」里有 %s（%lu 字节）", f.UTF8String, (unsigned long)data.length);
        busy = YES;
        import_p12(data, f, nil, "p12", ^(BOOL ok) {
            busy = NO;
            if (ok && [NSFileManager.defaultManager removeItemAtPath:path error:nil]) LOG("签名证书：已导入、删掉 %s", f.UTF8String);
        });
        return;   // 一次一份，问完再看下一份（下次扫）
    }
}

// 游戏库设置里「签名证书」那一行的状态（主线程）：团队 + 来源；没有返回空串
NSString *s2a_cert_status_text(void) {
    NSString *p = [@(getenv("HOME") ?: "") stringByAppendingPathComponent:@"Library/Application Support/S2Arm/identity/current.json"];
    NSData *d = [NSData dataWithContentsOfFile:p]; id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    NSString *team = [j isKindOfClass:NSDictionary.class] && [j[@"team"] isKindOfClass:NSString.class] ? j[@"team"] : nil;
    if (![j isKindOfClass:NSDictionary.class] || ![j[@"cert_sha1"] isKindOfClass:NSString.class]) return @"";
    NSString *src = [j[@"source"] isKindOfClass:NSString.class] ? j[@"source"] : @"pc";
    NSString *from = [src isEqualToString:@"sidestore"] ? S2AL(@"cert.source.sidestore") : [src isEqualToString:@"p12"] ? S2AL(@"cert.source.p12") : S2AL(@"cert.source.pc");
    return [NSString stringWithFormat:S2AL(@"cert.status"), team.length ? team : @"?", from];
}
const char *s2a_shell_cert_status(void) { static char buf[256]; snprintf(buf, sizeof buf, "%s", s2a_cert_status_text().UTF8String); return buf; }
