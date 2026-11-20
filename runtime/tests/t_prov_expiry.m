// prov_expiry.m 单测：合成「CMS 头 + XML plist + CMS 尾」的描述文件判剩余小时；缺日期 / 坏文件 / 没文件读成 NAN；
//   手机端自签取团队号与 appid（精确 / 通配 / 缺 TeamIdentifier / App ID 不符 / 读不到）。
//   identity/app.json（给电脑读的本 App 签名身份）：侧载工具改过的包名、团队、到期、两张证书的 sha1（期望 sha1 由单测按写进去的原始字节自己算）；内容没变不重写；没有描述文件写空团队。
//   用法：t_prov_expiry [<真描述文件> <期望到期 unix 秒>]——期望值由 mk 用系统 security cms -D + plutil 算，不经被测解析
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <math.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
double s2a_prov_hours_left(const char *path, double now_unix);
int s2a_prov_signing_ids(const char *prov_path, const char *bundle_id, char *team, size_t team_n, char *appid, size_t appid_n);
int s2a_prov_app_json(const char *prov_path, const char *bundle_id, const char *out_path);
static int bad;
static void ck(int ok, const char *what) { printf("%s %s\n", ok ? "  ok" : "  ✗", what); if (!ok) bad++; }
static NSString *put(NSString *name, NSString *plist) {
    NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:name]; NSMutableData *d = [NSMutableData data];
    const uint8_t head[] = {0x30, 0x82, 0x1f, 0x3c, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x00, 0xff}, tail[] = {0xa0, 0x82, 0x0d, 0x00, 0x30, 0x3c};
    [d appendBytes:head length:sizeof head]; if (plist) [d appendData:[plist dataUsingEncoding:NSUTF8StringEncoding]]; [d appendBytes:tail length:sizeof tail];
    [d writeToFile:p atomically:YES]; return p;
}
int main(int argc, char **argv) { @autoreleasepool {
    const double now = 1793300000;   // 2026-10-29 某时刻；合成文件的到期日 = now + 10 小时 = 1793336000 = 2026-10-30T04:53:20Z
    NSString *pl = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict><key>Name</key><string>x</string>"
                    "<key>ExpirationDate</key><date>2026-10-30T04:53:20Z</date></dict></plist>";
    double h = s2a_prov_hours_left(put(@"t_prov_ok.mobileprovision", pl).UTF8String, now);
    ck(fabs(h - 10.0) < 1e-6, [NSString stringWithFormat:@"合成描述文件：剩 10 小时（读到 %.4f）", h].UTF8String);
    h = s2a_prov_hours_left(put(@"t_prov_old.mobileprovision", pl).UTF8String, now + 11 * 3600);
    ck(fabs(h + 1.0) < 1e-6, "过了到期时间：负数（-1 小时）");
    ck(isnan(s2a_prov_hours_left(put(@"t_prov_nodate.mobileprovision", @"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>").UTF8String, now)), "没有 ExpirationDate → NAN");
    ck(isnan(s2a_prov_hours_left(put(@"t_prov_trunc.mobileprovision", @"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>").UTF8String, now)), "plist 截断（没有 </plist>）→ NAN");
    ck(isnan(s2a_prov_hours_left("/nonexistent/embedded.mobileprovision", now)), "没有文件 → NAN");
    ck(isnan(s2a_prov_hours_left(NULL, now)), "路径为空 → NAN");
    // 手机端自签的团队号 / appid（s2a_prov_signing_ids）：期望按描述文件写法手算——团队号取 TeamIdentifier[0]（缺了取 application-identifier 点前），appid = 团队号.本包包名
    {   static const char *const head = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>";
        NSString *(^prof)(NSString *, NSString *) = ^NSString *(NSString *aid, NSString *team) {
            NSMutableString *m = [NSMutableString stringWithUTF8String:head];
            if (aid) [m appendFormat:@"<key>Entitlements</key><dict><key>application-identifier</key><string>%@</string></dict>", aid];
            if (team) [m appendFormat:@"<key>TeamIdentifier</key><array><string>%@</string></array>", team];
            [m appendString:@"</dict></plist>"]; return m; };
        char t[64], a[512]; int r;
        r = s2a_prov_signing_ids(put(@"t_ids_exact.mobileprovision", prof(@"ABCDE12345.io.example.free", @"ABCDE12345")).UTF8String, "io.example.free", t, sizeof t, a, sizeof a);
        ck(r == 0 && !strcmp(t, "ABCDE12345") && !strcmp(a, "ABCDE12345.io.example.free"), [NSString stringWithFormat:@"免费团队（App ID 与包名一致）：0 / ABCDE12345 / ABCDE12345.io.example.free（读到 %d / %s / %s）", r, t, a].UTF8String);
        r = s2a_prov_signing_ids(put(@"t_ids_wild.mobileprovision", prof(@"ABCDE12345.*", @"ABCDE12345")).UTF8String, "io.example.paid", t, sizeof t, a, sizeof a);
        ck(r == 0 && !strcmp(a, "ABCDE12345.io.example.paid"), [NSString stringWithFormat:@"通配 App ID（团队号.*）：appid 用本包包名拼 ABCDE12345.io.example.paid、返回 0（读到 %d / %s）", r, a].UTF8String);
        r = s2a_prov_signing_ids(put(@"t_ids_noteam.mobileprovision", prof(@"ABCDE12345.io.example.free", nil)).UTF8String, "io.example.free", t, sizeof t, a, sizeof a);
        ck(r == 0 && !strcmp(t, "ABCDE12345"), [NSString stringWithFormat:@"没有 TeamIdentifier：团队号取 application-identifier 点前 ABCDE12345（读到 %d / %s）", r, t].UTF8String);
        r = s2a_prov_signing_ids(put(@"t_ids_other.mobileprovision", prof(@"ABCDE12345.io.example.other", @"ABCDE12345")).UTF8String, "io.example.free", t, sizeof t, a, sizeof a);
        ck(r == 1 && !strcmp(a, "ABCDE12345.io.example.free"), [NSString stringWithFormat:@"描述文件写的是别的 App ID：返回 1、appid 仍按本包包名 ABCDE12345.io.example.free（读到 %d / %s）", r, a].UTF8String);
        ck(s2a_prov_signing_ids("/nonexistent/embedded.mobileprovision", "io.example.free", t, sizeof t, a, sizeof a) == -1, "没有描述文件 → -1");
        ck(s2a_prov_signing_ids(put(@"t_ids_exact2.mobileprovision", prof(@"ABCDE12345.io.example.free", @"ABCDE12345")).UTF8String, "", t, sizeof t, a, sizeof a) == -1, "包名为空 → -1");
        ck(s2a_prov_signing_ids(put(@"t_ids_none.mobileprovision", prof(nil, nil)).UTF8String, "io.example.free", t, sizeof t, a, sizeof a) == -1, "既没有 TeamIdentifier 也没有 application-identifier → -1");
    }
    {   // identity/app.json：侧载工具（AltStore / SideStore）装的包，包名带团队号后缀
        const uint8_t c1[] = {0x30, 0x03, 0x02, 0x01, 0x01}, c2[] = {0x30, 0x03, 0x02, 0x01, 0x02};
        NSData *d1 = [NSData dataWithBytes:c1 length:sizeof c1], *d2 = [NSData dataWithBytes:c2 length:sizeof c2];
        NSString *pl2 = [NSString stringWithFormat:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>"
            "<key>ExpirationDate</key><date>2026-10-30T04:53:20Z</date><key>TeamIdentifier</key><array><string>FGHIJ67890</string></array>"
            "<key>Entitlements</key><dict><key>application-identifier</key><string>FGHIJ67890.io.s2arm.games.FGHIJ67890</string></dict>"
            "<key>DeveloperCertificates</key><array><data>%@</data><data>%@</data></array></dict></plist>", [d1 base64EncodedStringWithOptions:0], [d2 base64EncodedStringWithOptions:0]];
        NSString *(^sha1)(NSData *) = ^NSString *(NSData *d) { uint8_t h[20]; CC_SHA1(d.bytes, (CC_LONG)d.length, h); NSMutableString *x = [NSMutableString string]; for (int i = 0; i < 20; i++) [x appendFormat:@"%02x", h[i]]; return x; };
        NSString *out = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_prov_app.%d/identity/app.json", getpid()]];
        int r = s2a_prov_app_json(put(@"t_prov_app.mobileprovision", pl2).UTF8String, "io.s2arm.games.FGHIJ67890", out.fileSystemRepresentation);
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:out] ?: [NSData data] options:0 error:nil];
        NSArray *want = @[sha1(d1), sha1(d2)];
        ck(r == 0 && [j[@"team"] isEqual:@"FGHIJ67890"] && [j[@"bundle_id"] isEqual:@"io.s2arm.games.FGHIJ67890"] && [j[@"app_id"] isEqual:@"FGHIJ67890.io.s2arm.games.FGHIJ67890"]
           && [j[@"expires"] longLongValue] == 1793336000 && [j[@"cert_sha1"] isEqual:want] && [j[@"schema"] isEqual:@1],
           [NSString stringWithFormat:@"app.json：团队 FGHIJ67890、包名 / appid 带团队号后缀、到期 1793336000、两张证书 sha1 %@（读到 %d / %@）", want, r, j].UTF8String);
        struct stat a, b; stat(out.fileSystemRepresentation, &a); sleep(1);
        r = s2a_prov_app_json(put(@"t_prov_app.mobileprovision", pl2).UTF8String, "io.s2arm.games.FGHIJ67890", out.fileSystemRepresentation); stat(out.fileSystemRepresentation, &b);
        ck(r == 0 && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_ino == b.st_ino, "app.json 内容没变：不重写（修改时刻、inode 不变）");
        r = s2a_prov_app_json("/nonexistent/embedded.mobileprovision", "io.example.adhoc", out.fileSystemRepresentation);
        j = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:out] ?: [NSData data] options:0 error:nil];
        ck(r == 0 && [j[@"team"] isEqual:@""] && [j[@"bundle_id"] isEqual:@"io.example.adhoc"] && [j[@"cert_sha1"] count] == 0, "没有描述文件（ad-hoc 包）：team 空串、cert_sha1 空表、包名照写");
        [NSFileManager.defaultManager removeItemAtPath:[[out stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] error:nil];
    }
    if (argc == 3) {
        double want = atof(argv[2]); h = s2a_prov_hours_left(argv[1], want);
        ck(fabs(h) < 1e-6, [NSString stringWithFormat:@"真描述文件 %s：到期日与 security cms + plutil 读到的一致（差 %.6f 小时）", argv[1], h].UTF8String);
    } else printf("  （本机没有真描述文件，跳过真文件一项）\n");
    if (bad) { printf("prov_expiry 单测 %d 项不通\n", bad); return 1; }
    printf("✓ t_prov_expiry 单测全过\n"); return 0;
} }
