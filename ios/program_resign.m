// 起局时按款重签（0.6.0 通用壳，手机侧）：玩家起哪款就核哪款，程序库的签名身份和手机上现在的签名身份（电脑交来、已导入钥匙串，
//   identity/current.json）不是同一张证书 / 同一个团队，或程序包本来没签（.s2arm 导入、证书模式电脑不签），就在这里当场用手机上的身份签好再起。
//   维护者 0.6.0 总原则：不在后台批量重做全部游戏；玩家点了才做、只做这一款。100 MB 程序库签一次 0.1–0.2 秒（真机 11-17）。
// 写入规则（cmdr 通用壳方案）：每个写入方写自己的版本目录。手机签的放 program/v-<签后 sha256 前 16 位>-phone/：从清单指着的那一版用
//   APFS 克隆整份拷过来（瞬间、不占空间），只换掉程序库；最后改名换上 catalogue.json（dir / image_sha256 / signer / source_sha256）。
//   旧版本目录不删（这局可能还开着），由 s2a_program_gc 一小时后清。
// 做不了（钥匙串里没有身份、签不成、写不进）不拦：记一行原因，照旧用原来的程序库起局，系统真不认时由选游戏那一步标「需要在电脑上更新」。
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <string.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <unistd.h>

void s2a_log_line(const char *fmt, ...);
int s2a_identity_keychain(SecKeyRef *key, SecCertificateRef *cert);   // runtime/src/selfsign.c
CFArrayRef s2a_selfsign_chain_for(SecCertificateRef leaf);
int s2a_selfsign_macho(const uint8_t *in, size_t n, const char *ident, const char *team, const char *appid, SecKeyRef key, CFArrayRef chain, uint8_t **out, size_t *out_n, char *why, size_t why_n);
int s2a_prov_signing_ids_self(char *team, size_t team_n, char *appid, size_t appid_n);   // ios/prov_expiry.m
#define RLOG(...) s2a_log_line("[s2a] " __VA_ARGS__)

static int (*g_get_identity)(SecKeyRef *, SecCertificateRef *) = s2a_identity_keychain;
#ifdef S2A_UNIT_TEST
void s2a_program_resign_test_identity(int (*f)(SecKeyRef *, SecCertificateRef *)) { g_get_identity = f ? f : s2a_identity_keychain; }   // 单测换掉钥匙串
#endif

static NSString *hex(const uint8_t *d, size_t n) { NSMutableString *s = [NSMutableString stringWithCapacity:n * 2]; for (size_t i = 0; i < n; i++) [s appendFormat:@"%02x", d[i]]; return s; }
static NSDictionary *read_json(NSString *p) {
    NSData *d = [NSData dataWithContentsOfFile:p]; if (!d) return nil;
    id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil]; return [o isKindOfClass:NSDictionary.class] ? o : nil;
}
static int write_json(NSString *p, NSDictionary *o) {   // 临时名再改名（catalogue.json.<pid>.tmp：s2a_program_gc 认这个名字清残留）
    NSData *d = [NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil]; if (!d) return -1;
    NSString *t = [NSString stringWithFormat:@"%@.%d.tmp", p, (int)getpid()];
    if (![d writeToFile:t atomically:NO]) return -1;
    return rename(t.fileSystemRepresentation, p.fileSystemRepresentation) ? -1 : 0;
}
static NSString *str(id v) { return [v isKindOfClass:NSString.class] && [v length] ? v : nil; }

// 1 = 重签了（module_dir / images 改指新版本目录，各 n 字节）；0 = 不用签（没有手机身份、签名身份已是现在这张、电脑按同团队签好的）；
// -1 = 要签但没签成（why 写原因，调用方照旧用原程序库）
int s2a_program_resign_if_needed(const char *home, const char *game_data, const char *gid, char *module_dir, char *images, size_t n, char *why, size_t why_n) {
    @autoreleasepool {
        if (why && why_n) why[0] = 0;
        if (!home || !game_data || !gid || !module_dir || !images) return 0;
        NSString *idp = [@(home) stringByAppendingPathComponent:@"Library/Application Support/S2Arm/identity/current.json"];
        NSDictionary *cur = read_json(idp); NSString *cur_sha = str(cur[@"cert_sha1"]).lowercaseString, *cur_team = str(cur[@"team"]);
        if (!cur_sha) return 0;   // 手机上没有身份（电脑签好推上来的玩家）：不碰
        NSString *prog = [[@(game_data) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"program"];
        NSString *catp = [prog stringByAppendingPathComponent:@"catalogue.json"];
        NSDictionary *cat = read_json(catp); if (!cat) return 0;
        NSDictionary *signer = [cat[@"signer"] isKindOfClass:NSDictionary.class] ? cat[@"signer"] : nil;
        NSString *was_sha = str(signer[@"cert_sha1"]).lowercaseString, *team = str(cat[@"team"]);
        if (was_sha ? [was_sha isEqualToString:cur_sha] : (team && cur_team && [team isEqualToString:cur_team])) return 0;
        NSString *why_sign = was_sha ? @"程序库是另一张证书签的" : team ? @"程序库是别的团队签的" : @"程序库还没签名";
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#define FAIL(...) do { if (why && why_n) snprintf(why, why_n, __VA_ARGS__); RLOG("【黄】起局重签：游戏 %s %s，要用手机上的签名身份重签，没签成：%s；照旧用原来的程序库", gid, why_sign.UTF8String, why); return -1; } while (0)
        SecKeyRef key = NULL; SecCertificateRef leaf = NULL;
        if (g_get_identity(&key, &leaf) || !key || !leaf) { if (key) CFRelease(key); if (leaf) CFRelease(leaf); FAIL("钥匙串里没有签名身份（电脑交来的身份还没导入）"); }
        CFArrayRef chain = s2a_selfsign_chain_for(leaf);
        char pteam[64] = "", pappid[512] = ""; int pr = s2a_prov_signing_ids_self(pteam, sizeof pteam, pappid, sizeof pappid);
        const char *steam = pr >= 0 ? pteam : cur_team.UTF8String, *sappid = pr >= 0 ? pappid : NULL;
        NSData *in = [NSData dataWithContentsOfFile:@(images)];
        uint8_t *out = NULL; size_t on = 0; char w[256] = "";
        int rc = in ? s2a_selfsign_macho(in.bytes, in.length, NULL, steam, sappid, key, chain, &out, &on, w, sizeof w) : -1;
        CFRelease(key); CFRelease(leaf); if (chain) CFRelease(chain);
        if (!in) FAIL("程序库 %s 读不了", images);
        if (rc) FAIL("签名失败：%s", w);
        uint8_t h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(out, (CC_LONG)on, h); NSString *sha = hex(h, sizeof h);
        NSString *dir = [NSString stringWithFormat:@"v-%@-phone", [sha substringToIndex:16]], *dst = [prog stringByAppendingPathComponent:dir];
        NSString *img = @(images).lastPathComponent, *mrel = [NSString stringWithFormat:@"Games/%s", gid];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:dst error:nil];   // 同一份签名结果的残留（上次写了一半）
        if (![fm createDirectoryAtPath:[dst stringByAppendingPathComponent:@"Games"] withIntermediateDirectories:YES attributes:nil error:nil]) { free(out); FAIL("建不了版本目录 %s", dst.UTF8String); }
        NSString *mdst = [dst stringByAppendingPathComponent:mrel];
        if (clonefile(module_dir, mdst.fileSystemRepresentation, 0) && ![fm copyItemAtPath:@(module_dir) toPath:mdst error:nil]) { free(out); FAIL("随行目录拷不过去（errno %d）", errno); }
        NSString *idst = [dst stringByAppendingPathComponent:img], *itmp = [idst stringByAppendingString:@".tmp"];
        FILE *f = fopen(itmp.fileSystemRepresentation, "wb"); int ok = f && fwrite(out, 1, on, f) == on; if (f && fclose(f)) ok = 0; free(out);
        if (!ok || rename(itmp.fileSystemRepresentation, idst.fileSystemRepresentation)) FAIL("签好的程序库写不进 %s", idst.UTF8String);
        NSMutableDictionary *nc = [cat mutableCopy];
        if (!str(nc[@"source_sha256"]) && str(cat[@"image_sha256"])) nc[@"source_sha256"] = cat[@"image_sha256"];   // 未签名的那份（电脑判重按它）
        nc[@"dir"] = dir; nc[@"image_sha256"] = sha;
        nc[@"signer"] = @{@"by": @"phone", @"team": @(steam ? steam : ""), @"cert_sha1": cur_sha};
        if (write_json(catp, nc)) FAIL("程序包清单写不进 %s", catp.UTF8String);
        if (snprintf(module_dir, n, "%s", mdst.fileSystemRepresentation) >= (int)n || snprintf(images, n, "%s", idst.fileSystemRepresentation) >= (int)n) FAIL("路径太长");
        RLOG("起局重签：游戏 %s %s，已用手机上的签名身份（团队 %s）签好 → %s，%.0f ms", gid, why_sign.UTF8String, steam ? steam : "?", dir.UTF8String, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
        return 1;
#undef FAIL
    }
}
