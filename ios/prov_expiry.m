// 签名到期提示（免费签名分发，10-30）：免费账号的描述文件 7 天过期，过期后 App 直接打不开。起局读包里 embedded.mobileprovision 的 ExpirationDate，
//   剩不到 48 小时在画面顶部提示一次（横幅在 dprompt.m）。读不到（Xcode 以外的签法没嵌描述文件、ad-hoc 包、Mac）就不提示。
//   只用 Foundation，单测 runtime/tests/t_prov_expiry.m 在 Mac 上跑
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <math.h>

// 描述文件是 CMS 签名包着的一段 XML plist：取 <?xml … </plist> 那段解析。返回 ExpirationDate 距 now 的小时数（已过期为负），读不到返回 NAN
static NSDictionary *prov_read(const char *path) {   // 整份描述文件的 plist（读不到 nil）
    NSData *d = path ? [NSData dataWithContentsOfFile:@(path)] : nil; if (!d.length) return nil;
    NSData *a = [@"<?xml" dataUsingEncoding:NSASCIIStringEncoding], *b = [@"</plist>" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange r0 = [d rangeOfData:a options:0 range:NSMakeRange(0, d.length)]; if (r0.location == NSNotFound) return nil;
    NSRange r1 = [d rangeOfData:b options:0 range:NSMakeRange(r0.location, d.length - r0.location)]; if (r1.location == NSNotFound) return nil;
    NSData *x = [d subdataWithRange:NSMakeRange(r0.location, NSMaxRange(r1) - r0.location)];
    id pl = [NSPropertyListSerialization propertyListWithData:x options:NSPropertyListImmutable format:NULL error:nil];
    return [pl isKindOfClass:NSDictionary.class] ? pl : nil;
}
double s2a_prov_hours_left(const char *path, double now_unix) {
    @autoreleasepool {
        id e = prov_read(path)[@"ExpirationDate"];
        if (![e isKindOfClass:NSDate.class]) return NAN;
        return (((NSDate *)e).timeIntervalSince1970 - now_unix) / 3600.0;
    }
}
// 手机端自签要的团队号与 appid（0.6.0 通用壳，runtime/src/selfsign.c）：iOS SDK 没有读自身权限的公开接口（SecTaskCreateFromSelf 只在 macOS），
//   只能读包里的描述文件。团队号 = TeamIdentifier[0]（没有就取 Entitlements.application-identifier 第一个点之前）；
//   appid = 团队号.本包包名——不照抄描述文件的 application-identifier：付费团队可能是通配（团队号.*），装包工具也可能改过包名，
//   免费团队按「团队号.签名标识」核描述文件（真机 11-17），用实际包名才对得上。
//   返回 0 = 取到且描述文件的 application-identifier 与之相符（或是通配）；1 = 取到但描述文件写的是另一个 App ID（调用方打黄字照常用）；-1 = 读不到
int s2a_prov_signing_ids(const char *prov_path, const char *bundle_id, char *team, size_t team_n, char *appid, size_t appid_n) {
    @autoreleasepool {
        NSDictionary *pl = prov_read(prov_path); if (!pl || !bundle_id || !*bundle_id) return -1;
        id ents = pl[@"Entitlements"]; id aid = [ents isKindOfClass:NSDictionary.class] ? ents[@"application-identifier"] : nil;
        if (![aid isKindOfClass:NSString.class]) aid = nil;
        id ti = pl[@"TeamIdentifier"]; NSString *t = [ti isKindOfClass:NSArray.class] && [ti count] && [ti[0] isKindOfClass:NSString.class] ? ti[0] : nil;
        if (!t.length && aid) { NSRange dot = [aid rangeOfString:@"."]; if (dot.location != NSNotFound && dot.location) t = [aid substringToIndex:dot.location]; }
        if (!t.length) return -1;
        NSString *want = [NSString stringWithFormat:@"%@.%s", t, bundle_id];
        if (snprintf(team, team_n, "%s", t.UTF8String) >= (int)team_n || snprintf(appid, appid_n, "%s", want.UTF8String) >= (int)appid_n) return -1;
        if (!aid || [aid isEqualToString:want]) return 0;
        if ([aid hasSuffix:@"*"] && [want hasPrefix:[aid substringToIndex:[aid length] - 1]]) return 0;   // 通配 App ID：团队号.* / 团队号.前缀.*
        return 1;
    }
}
int s2a_prov_signing_ids_self(char *team, size_t team_n, char *appid, size_t appid_n) {
    @autoreleasepool {
        NSString *p = [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"];
        return s2a_prov_signing_ids(p.UTF8String, NSBundle.mainBundle.bundleIdentifier.UTF8String, team, team_n, appid, appid_n);
    }
}

// 本 App 的签名身份写给电脑读（0.6.0 通用壳，AltStore / SideStore 装的 App 也走手机自签）：Library/Application Support/S2Arm/identity/app.json =
//   {schema, bundle_id, team, app_id, expires（unix 秒）, cert_sha1: [描述文件 DeveloperCertificates 各张 DER 的 sha1]}，不含私钥。
//   侧载工具重签时会改包名、换团队（玩家在那边登录的 Apple ID）：电脑交身份 / 推游戏前读它，团队和启动器登录的不同就先告诉玩家，不推一份手机不认的。
//   读不到描述文件（ad-hoc / TrollStore 包）写 team 空串。内容没变不重写。返回 0 = 写了或没变；-1 = 写不进
int s2a_prov_app_json(const char *prov_path, const char *bundle_id, const char *out_path) {
    @autoreleasepool {
        if (!out_path) return -1;
        NSDictionary *pl = prov_read(prov_path);
        char team[64] = "", appid[512] = ""; s2a_prov_signing_ids(prov_path, bundle_id, team, sizeof team, appid, sizeof appid);
        NSMutableArray *shas = [NSMutableArray array];
        id certs = pl[@"DeveloperCertificates"];
        for (id c in [certs isKindOfClass:NSArray.class] ? certs : @[]) {
            if (![c isKindOfClass:NSData.class]) continue;
            uint8_t h[CC_SHA1_DIGEST_LENGTH]; CC_SHA1([c bytes], (CC_LONG)[c length], h);
            NSMutableString *x = [NSMutableString string]; for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [x appendFormat:@"%02x", h[i]];
            [shas addObject:x];
        }
        id e = pl[@"ExpirationDate"];
        NSDictionary *o = @{@"schema": @1, @"bundle_id": @(bundle_id ? bundle_id : ""), @"team": @(team), @"app_id": @(appid),
                            @"expires": [e isKindOfClass:NSDate.class] ? @((long long)((NSDate *)e).timeIntervalSince1970) : @0, @"cert_sha1": shas};
        NSData *d = [NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:nil]; if (!d) return -1;
        NSString *p = @(out_path);
        if ([[NSData dataWithContentsOfFile:p] isEqualToData:d]) return 0;
        [NSFileManager.defaultManager createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *t = [p stringByAppendingString:@".tmp"];
        if (![d writeToFile:t atomically:NO] || rename(t.fileSystemRepresentation, p.fileSystemRepresentation)) return -1;
        return 0;
    }
}
int s2a_prov_app_json_self(const char *home) {
    @autoreleasepool {
        if (!home) return -1;
        NSString *p = [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"];
        NSString *out = [@(home) stringByAppendingPathComponent:@"Library/Application Support/S2Arm/identity/app.json"];
        return s2a_prov_app_json(p.UTF8String, NSBundle.mainBundle.bundleIdentifier.UTF8String, out.fileSystemRepresentation);
    }
}

// 本包的描述文件剩几小时（读不到 NAN）
double s2a_prov_hours_left_self(void) {
    NSString *p = [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"];
    return s2a_prov_hours_left(p.UTF8String, NSDate.date.timeIntervalSince1970);
}
