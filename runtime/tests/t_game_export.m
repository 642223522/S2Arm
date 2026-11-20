// 手机上导出这一款（ios/game_export.m s2a_game_export）往返单测，Mac 上跑。期望值全按单测自己造的输入算，不跑被测实现推期望：
//   造一个已装好的源容器（程序版本目录 + 随行文件、清单带 dir / signer / image_sha256；资源包有 pack/img.py 造的合法 game.img、
//   着色器库、覆盖层等白名单派生件，以及一堆机上状态 / 解出件 / 点开头临时目录这类不该带的）→ 导出 →
//   ① 文件名按游戏名去非法字符；.img 是 game.img 的硬链接（同一个 inode）；另一套解压器（zstd 命令行 / Python）校验帧与内容校验通过，
//      tar 条目顺序 s2arm.json → program/catalogue.json → program/… → pack/…，s2arm.json 字段对、bytes = 其余条目内容合计
//   ② 导进另一个空容器（s2a_s2arm_import）：程序文件逐字节相同、旧版本目录没带；清单只有一个 dir 且 = v-<image_sha256 前 16 位>-s2arm，
//      其余字段与源清单相同；白名单派生件逐字节在、黑名单一个没带
//   ③ .img 放进「放这里导入」（s2a_img_scan）认领成功、game.img 逐字节相同、index.tsv 留着着色器库行；再解开（s2a_pack_apply）成功
//   负对照：④ .s2arm 末尾内容校验改一个字节 → 导入失败；⑤ 不去清单的 dir → 导入后能查出重复的 dir 键
//   具名失败：⑥ 有 .partial → S2A_GEXP_PARTIAL ⑦ 没有 game.img → S2A_GEXP_NO_IMG ⑧ 没有程序包清单 → S2A_GEXP_NO_PROGRAM
//   ⑨ XXH64 规范已知值（空串、"abc"、0..99、0..36 各字节）
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "game_export.h"
#include "s2a_t_result.h"

int s2a_s2arm_import(const char *proc_docs, const char *src, char *gid_out, size_t gid_n);
int s2a_img_scan(const char *proc_docs); const char *s2a_img_scan_code(void); const char *s2a_img_scan_failure(void);
int s2a_pack_apply(const char *docs); const char *s2a_pack_apply_failure(void);
uint64_t s2a_xxh64_digest(const void *data, size_t n);
extern int s2a_game_export_test_keep_dir;
uint64_t now_ns(void) { return 0; }   // pack_apply.c 计时用

static int bad;
static void ck(int ok, NSString *what) { printf("%s %s\n", ok ? "  通" : "  【红】", what.UTF8String); if (!ok) bad++; }
static int sh(NSString *cmd) { return system(cmd.UTF8String); }
static NSString *sh_out(NSString *cmd) { NSTask *t = [NSTask new]; t.launchPath = @"/bin/sh"; t.arguments = @[@"-c", cmd]; NSPipe *p = [NSPipe pipe]; t.standardOutput = p;
    [t launch]; NSData *d = [p.fileHandleForReading readDataToEndOfFile]; [t waitUntilExit]; return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @""; }
static NSFileManager *fm;
static void put(NSString *p, NSData *d) { [fm createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]; [d writeToFile:p atomically:NO]; }
static void puts_(NSString *p, NSString *s) { put(p, [s dataUsingEncoding:NSUTF8StringEncoding]); }
static NSData *rnd(size_t n, unsigned seed) { NSMutableData *d = [NSMutableData dataWithLength:n]; uint8_t *b = d.mutableBytes; for (size_t i = 0; i < n; i++) { seed = seed * 1103515245u + 12345u; b[i] = (uint8_t)(seed >> 16); } return d; }
static BOOL same(NSString *a, NSString *b) { return [fm contentsEqualAtPath:a andPath:b]; }
static NSUInteger count_of(NSString *s, NSString *k) { return [s componentsSeparatedByString:k].count - 1; }

int main(void) { @autoreleasepool {
    fm = NSFileManager.defaultManager;
    // ⑨ XXH64：规范已知值（xxHash 参考实现 / xxhsum 给的，与被测无关）
    { uint8_t b[100]; for (int i = 0; i < 100; i++) b[i] = (uint8_t)i;
      ck(s2a_xxh64_digest("", 0) == 0xEF46DB3751D8E999ULL && s2a_xxh64_digest("abc", 3) == 0x44BC2CF5AD770999ULL
         && s2a_xxh64_digest(b, 100) == 0x6AC1E58032166597ULL && s2a_xxh64_digest(b, 37) == 0xD93FA2DFEE5C24C9ULL, @"⑨ XXH64 四个已知值（空串、abc、0..99、0..36）"); }
    NSString *R = @(__FILE__); NSRange cut = [R rangeOfString:@"runtime/tests/"]; R = cut.location == NSNotFound ? @"." : [R substringToIndex:cut.location];
    if (!R.length) R = @".";
    NSString *T = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"t_game_export.%d", getpid()]];
    [fm removeItemAtPath:T error:nil];
    NSString *G = @"0100ABCDE0001000", *sha = @"abcdef0123456789aaaabbbbccccdddd00001111222233334444555566667777", *vd = @"v-1111222233334444-phone";
    // ---- 源容器 ----
    NSString *S = [T stringByAppendingPathComponent:@"src/Documents"], *SB = [T stringByAppendingPathComponent:[@"src/Library/Application Support/S2Arm/games" stringByAppendingPathComponent:G]];
    NSString *prog = [SB stringByAppendingPathComponent:@"program"], *pk = [SB stringByAppendingPathComponent:@"资源包"], *V = [prog stringByAppendingPathComponent:vd];
    NSString *img = [NSString stringWithFormat:@"S2AImages-%@.dylib", G];
    NSDictionary<NSString *, NSData *> *progFiles = @{   // 版本目录里的程序文件（相对路径 → 内容）；程序库 300 KB 跨几个 128 KB 块
        img: rnd(300 * 1024 + 77, 1),
        [NSString stringWithFormat:@"Games/%@/s2a_caps.tsv", G]: [@"caps\n" dataUsingEncoding:NSUTF8StringEncoding],
        [NSString stringWithFormat:@"Games/%@/sub/blob.bin", G]: rnd(5000, 2) };
    for (NSString *k in progFiles) put([V stringByAppendingPathComponent:k], progFiles[k]);
    put([prog stringByAppendingPathComponent:@"v-9999999999999999-pc/old.dylib"], rnd(100, 3));   // 清单没指着的旧版本：不该带
    NSDictionary *cat = @{@"dir": vd, @"schema": @1, @"title_id": G, @"name": @"Test: Game?", @"display_version": @"1.0.2", @"host_abi": @3,
                          @"chain": @"chain-x", @"rewriter_id": @"rw-y", @"image": img, @"image_sha256": sha, @"source_sha256": @"5555",
                          @"team": NSNull.null, @"signer": @{@"by": @"phone", @"team": @"ABCDE12345", @"cert_sha1": @"c0ffee"}};
    put([prog stringByAppendingPathComponent:@"catalogue.json"], [NSJSONSerialization dataWithJSONObject:cat options:NSJSONWritingSortedKeys error:nil]);
    // 资源包：合法 game.img（pack/img.py，带 exefs/main.npdm 才认领）+ 白名单派生件 + 不该带的
    NSString *src = [T stringByAppendingPathComponent:@"imgsrc"];
    puts_([src stringByAppendingPathComponent:@"npdm"], @"npdm"); puts_([src stringByAppendingPathComponent:@"nacp"], @"NACP");
    puts_([src stringByAppendingPathComponent:@"others.tsv"], [NSString stringWithFormat:@"exefs/main.npdm\t%@/npdm\nctl/control.nacp\t%@/nacp\n", src, src]);
    [fm createDirectoryAtPath:pk withIntermediateDirectories:YES attributes:nil error:nil];
    ck(sh([NSString stringWithFormat:@"python3 '%@/pack/img.py' build - '%@/others.tsv' '%@/game.img' --gid %@ --pack-id imgT1 > /dev/null", R, src, pk, G.lowercaseString]) == 0, @"造合法 game.img");
    NSDictionary<NSString *, NSData *> *white = @{
        @"shaders/a.metallib": rnd(1234, 4), @"shaders/sub/b.bin": rnd(10, 5), @"romfs_overlay/x/o.txt": rnd(7, 6),
        @"romfs.s2aidx": rnd(64, 7), @"game.imgmap": rnd(20, 8),
        @"index.tsv": [@"game.img\t1\timgT1\nshaders/a.metallib\t1234\t-\nshaders/sub/b.bin\t10\t-\n" dataUsingEncoding:NSUTF8StringEncoding],
        @"manifest.json": [@"{\"version\": 3, \"format\": \"img\", \"imgFile\": \"game.img\", \"index_sha256\": \"imgT1\"}\n" dataUsingEncoding:NSUTF8StringEncoding] };
    for (NSString *k in white) put([pk stringByAppendingPathComponent:k], white[k]);
    NSArray<NSString *> *black = @[@".applied", @".applied.bak", @".imported", @".transfer", @".pushed", @"index.applied.tsv", @"exefs/main.npdm", @"ctl/control.nacp",
                                   @"junk.txt", @"shaders/.direct-new/x.metallib", @".incoming/1_000.tar"];
    for (NSString *k in black) puts_([pk stringByAppendingPathComponent:k], @"no");
    NSString *out = [S stringByAppendingPathComponent:[NSString stringWithFormat:@"games/%@/game-exports/a", G]];
    [fm createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];
    char s2p[2400], imp[2400], why[600];
    int rc = s2a_game_export(S.fileSystemRepresentation, G.lowercaseString.UTF8String, out.fileSystemRepresentation, s2p, sizeof s2p, imp, sizeof imp, why, sizeof why);
    NSString *wantS = [out stringByAppendingPathComponent:@"Test  Game.s2arm"], *wantI = [out stringByAppendingPathComponent:@"Test  Game.img"];
    ck(rc == 0 && [@(s2p) isEqualToString:wantS] && [@(imp) isEqualToString:wantI], [NSString stringWithFormat:@"① 导出：返回 %d（期望 0）、%@ / %@（期望「Test  Game」.s2arm / .img）%@", rc, @(s2p), @(imp), @(why)]);
    struct stat a, b; ck(!stat(imp, &a) && !stat([pk stringByAppendingPathComponent:@"game.img"].fileSystemRepresentation, &b) && a.st_ino == b.st_ino, @"① .img 是资源包 game.img 的硬链接（同一个 inode）");
    ck(![fm fileExistsAtPath:[wantS stringByAppendingString:@".part"]], @"① 不留 .part");
    // 另一套解压器核帧 + 内容校验；Python tarfile 列条目、读 s2arm.json
    NSString *tarp = [T stringByAppendingPathComponent:@"x.tar"];
    int dec = sh([NSString stringWithFormat:@"command -v zstd >/dev/null 2>&1 && zstd -q -d -f --check -o '%@' '%@' || python3 -c \"import sys\nfrom compression import zstd\nopen(sys.argv[2],'wb').write(zstd.decompress(open(sys.argv[1],'rb').read()))\" '%@' '%@'", tarp, wantS, wantS, tarp]);
    ck(dec == 0, @"① 另一套解压器（zstd 命令行 / Python）解得开、内容校验通过");
    NSString *ls = sh_out([NSString stringWithFormat:@"python3 -c \"import sys,tarfile,json\nt=tarfile.open(sys.argv[1],format=tarfile.USTAR_FORMAT)\nm=t.getmembers()\nprint('\\n'.join(x.name+'|'+str(x.size)+'|'+oct(x.mode)+'|'+str(x.mtime)+'|'+str(int(x.isfile())) for x in m))\nprint('JSON '+json.dumps(json.load(t.extractfile(m[0])),sort_keys=True))\" '%@'", tarp]);
    NSArray<NSString *> *lines = [ls componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *names = [NSMutableArray array]; NSUInteger other = 0, catn = 0; BOOL modes = YES; NSDictionary *head = nil;
    for (NSString *l in lines) {
        if ([l hasPrefix:@"JSON "]) { head = [NSJSONSerialization JSONObjectWithData:[[l substringFromIndex:5] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]; continue; }
        NSArray *f = [l componentsSeparatedByString:@"|"]; if (f.count != 5) continue;
        [names addObject:f[0]]; modes &= [f[2] isEqual:@"0o644"] && [f[3] isEqual:@"0"] && [f[4] isEqual:@"1"];
        if ([f[0] isEqual:@"program/catalogue.json"]) catn = [f[1] integerValue];
        if (![f[0] isEqual:@"s2arm.json"]) other += [f[1] integerValue];
    }
    NSMutableArray *want = [NSMutableArray arrayWithObjects:@"s2arm.json", @"program/catalogue.json", nil];
    for (NSString *k in [progFiles.allKeys sortedArrayUsingSelector:@selector(compare:)]) [want addObject:[@"program/" stringByAppendingString:k]];
    for (NSString *k in [white.allKeys sortedArrayUsingSelector:@selector(compare:)]) [want addObject:[@"pack/" stringByAppendingString:k]];
    ck([names isEqualToArray:want], [NSString stringWithFormat:@"① 条目与次序：%@（期望 %@）", [names componentsJoinedByString:@" "], [want componentsJoinedByString:@" "]]);
    ck(modes, @"① 条目全是普通文件、0644、mtime 0");
    NSUInteger inbytes = catn; for (NSString *k in progFiles) inbytes += progFiles[k].length; for (NSString *k in white) inbytes += white[k].length;
    ck([head[@"format"] isEqual:@"s2arm"] && [head[@"schema"] isEqual:@1] && [head[@"title_id"] isEqual:G] && [head[@"image_sha256"] isEqual:sha]
       && [head[@"name"] isEqual:cat[@"name"]] && [head[@"display_version"] isEqual:@"1.0.2"] && [head[@"host_abi"] isEqual:@3] && [head[@"chain"] isEqual:@"chain-x"]
       && [head[@"rewriter_id"] isEqual:@"rw-y"] && [head[@"image"] isEqual:img] && [head[@"source_sha256"] isEqual:@"5555"] && [head[@"pack"] isEqual:@"imgT1"]
       && [head[@"signer"] isEqual:cat[@"signer"]] && [head[@"exported_by"] isEqual:@"phone"] && [head[@"bytes"] unsignedIntegerValue] == inbytes,
       [NSString stringWithFormat:@"① s2arm.json 字段（bytes 期望 %lu）：%@", (unsigned long)inbytes, head]);
    // ---- ② 导进另一个空容器 ----
    NSString *D = [T stringByAppendingPathComponent:@"dst/Documents"], *DB = [T stringByAppendingPathComponent:[@"dst/Library/Application Support/S2Arm/games" stringByAppendingPathComponent:G]];
    [fm createDirectoryAtPath:[D stringByAppendingPathComponent:@"放这里导入"] withIntermediateDirectories:YES attributes:nil error:nil];
    char g[17] = ""; rc = s2a_s2arm_import(D.fileSystemRepresentation, wantS.fileSystemRepresentation, g, sizeof g);
    ck(rc == 0 && !strcmp(g, G.UTF8String), [NSString stringWithFormat:@"② 导入：返回 %d、游戏号 %@（期望 0、%@）", rc, @(g), G]);
    NSString *nvd = [NSString stringWithFormat:@"v-%@-s2arm", [sha substringToIndex:16]], *DV = [DB stringByAppendingPathComponent:[@"program" stringByAppendingPathComponent:nvd]];
    BOOL allp = YES; for (NSString *k in progFiles) allp &= same([V stringByAppendingPathComponent:k], [DV stringByAppendingPathComponent:k]);
    ck(allp, [NSString stringWithFormat:@"② 程序文件逐字节进了 %@", nvd]);
    NSArray *pdirs = [fm contentsOfDirectoryAtPath:[DB stringByAppendingPathComponent:@"program"] error:nil];
    ck(![sh_out([NSString stringWithFormat:@"find '%@/program' -name old.dylib", DB]) length] && [[pdirs filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'v-'"]] isEqualToArray:@[nvd]],
       [NSString stringWithFormat:@"② 只有一个版本目录、旧版本没带（%@）", pdirs]);
    NSString *dcat = [NSString stringWithContentsOfFile:[DB stringByAppendingPathComponent:@"program/catalogue.json"] encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *dc = dcat ? [NSJSONSerialization JSONObjectWithData:[dcat dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
    NSMutableDictionary *wantc = [cat mutableCopy]; wantc[@"dir"] = nvd;
    ck(count_of(dcat ?: @"", @"\"dir\"") == 1 && [dc isEqualToDictionary:wantc], [NSString stringWithFormat:@"② 清单只有一个 dir = %@、其余字段同源清单（%@）", nvd, dcat]);
    NSString *DP = [DB stringByAppendingPathComponent:@"资源包"];
    BOOL allw = YES; for (NSString *k in white) allw &= same([pk stringByAppendingPathComponent:k], [DP stringByAppendingPathComponent:k]);
    ck(allw, @"② 白名单派生件逐字节都在");
    NSMutableArray *leaked = [NSMutableArray array]; for (NSString *k in black) if ([fm fileExistsAtPath:[DP stringByAppendingPathComponent:k]]) [leaked addObject:k];
    ck(!leaked.count, [NSString stringWithFormat:@"② 黑名单一个没带（带了：%@）", leaked]);
    // ---- ③ .img 放进导入文件夹认领、再解开 ----
    NSString *dimg = [D stringByAppendingPathComponent:@"放这里导入/Test  Game.img"];
    ck([fm copyItemAtPath:wantI toPath:dimg error:nil], @"③ .img 拷进「放这里导入」");
    int placed = s2a_img_scan(D.fileSystemRepresentation);
    ck(placed == 1 && !*s2a_img_scan_code() && same([DP stringByAppendingPathComponent:@"game.img"], [pk stringByAppendingPathComponent:@"game.img"]),
       [NSString stringWithFormat:@"③ 认领 %d 个（期望 1）、码「%@」、game.img 逐字节相同", placed, @(s2a_img_scan_code())]);
    NSString *idx = [NSString stringWithContentsOfFile:[DP stringByAppendingPathComponent:@"index.tsv"] encoding:NSUTF8StringEncoding error:nil];
    ck([idx containsString:@"shaders/a.metallib\t1234"] && [idx containsString:@"shaders/sub/b.bin\t10"], [NSString stringWithFormat:@"③ index.tsv 留着着色器库行（%@）", idx]);
    rc = s2a_pack_apply([D stringByAppendingPathComponent:[@"games" stringByAppendingPathComponent:G]].fileSystemRepresentation);
    ck(rc == 0 && same([DP stringByAppendingPathComponent:@"exefs/main.npdm"], [src stringByAppendingPathComponent:@"npdm"]),
       [NSString stringWithFormat:@"③ 解开成功（返回 %d：%@）、exefs/main.npdm 从 game.img 解出", rc, @(s2a_pack_apply_failure())]);
    // ---- ④ 负对照：内容校验改一个字节 → 导入失败 ----
    { NSString *bad4 = [T stringByAppendingPathComponent:@"bad.s2arm"]; NSMutableData *d = [NSMutableData dataWithContentsOfFile:wantS];
      ((uint8_t *)d.mutableBytes)[d.length - 1] ^= 0x01; [d writeToFile:bad4 atomically:NO];
      NSString *D4 = [T stringByAppendingPathComponent:@"dst4/Documents"]; [fm createDirectoryAtPath:D4 withIntermediateDirectories:YES attributes:nil error:nil];
      rc = s2a_s2arm_import(D4.fileSystemRepresentation, bad4.fileSystemRepresentation, g, sizeof g);
      ck(rc < 0, [NSString stringWithFormat:@"④ 内容校验改一个字节：导入返回 %d（期望 < 0）", rc]); }
    // ---- ⑤ 负对照：不去清单的 dir → 导入后有两个 dir（②的判据能抓到）----
    { NSString *o5 = [S stringByAppendingPathComponent:[NSString stringWithFormat:@"games/%@/game-exports/b", G]]; [fm createDirectoryAtPath:o5 withIntermediateDirectories:YES attributes:nil error:nil];
      s2a_game_export_test_keep_dir = 1;
      rc = s2a_game_export(S.fileSystemRepresentation, G.UTF8String, o5.fileSystemRepresentation, s2p, sizeof s2p, imp, sizeof imp, why, sizeof why);
      s2a_game_export_test_keep_dir = 0;
      NSString *D5 = [T stringByAppendingPathComponent:@"dst5/Documents"]; [fm createDirectoryAtPath:D5 withIntermediateDirectories:YES attributes:nil error:nil];
      int r5 = rc ? rc : s2a_s2arm_import(D5.fileSystemRepresentation, s2p, g, sizeof g);
      NSString *c5 = [NSString stringWithContentsOfFile:[T stringByAppendingPathComponent:[NSString stringWithFormat:@"dst5/Library/Application Support/S2Arm/games/%@/program/catalogue.json", G]] encoding:NSUTF8StringEncoding error:nil];
      ck(r5 == 0 && count_of(c5 ?: @"", @"\"dir\"") == 2, [NSString stringWithFormat:@"⑤ 不去 dir：导入后清单里 dir 出现 %lu 次（期望 2，② 的「只有一个」判据会红）", (unsigned long)count_of(c5 ?: @"", @"\"dir\"")]); }
    // ---- ⑥⑦⑧ 具名失败 ----
    NSString *o6 = [S stringByAppendingPathComponent:[NSString stringWithFormat:@"games/%@/game-exports/c", G]]; [fm createDirectoryAtPath:o6 withIntermediateDirectories:YES attributes:nil error:nil];
    puts_([pk stringByAppendingPathComponent:@".partial"], @"x\n1\n");
    rc = s2a_game_export(S.fileSystemRepresentation, G.UTF8String, o6.fileSystemRepresentation, s2p, sizeof s2p, imp, sizeof imp, why, sizeof why);
    ck(rc == S2A_GEXP_PARTIAL && ![fm contentsOfDirectoryAtPath:o6 error:nil].count, [NSString stringWithFormat:@"⑥ 有 .partial：返回 %d（期望 %d）、导出文件夹空着（%@）", rc, S2A_GEXP_PARTIAL, @(why)]);
    [fm removeItemAtPath:[pk stringByAppendingPathComponent:@".partial"] error:nil];
    [fm moveItemAtPath:[pk stringByAppendingPathComponent:@"game.img"] toPath:[T stringByAppendingPathComponent:@"game.img.aside"] error:nil];
    rc = s2a_game_export(S.fileSystemRepresentation, G.UTF8String, o6.fileSystemRepresentation, s2p, sizeof s2p, imp, sizeof imp, why, sizeof why);
    ck(rc == S2A_GEXP_NO_IMG, [NSString stringWithFormat:@"⑦ 没有 game.img：返回 %d（期望 %d）（%@）", rc, S2A_GEXP_NO_IMG, @(why)]);
    [fm moveItemAtPath:[T stringByAppendingPathComponent:@"game.img.aside"] toPath:[pk stringByAppendingPathComponent:@"game.img"] error:nil];
    [fm removeItemAtPath:[prog stringByAppendingPathComponent:@"catalogue.json"] error:nil];
    rc = s2a_game_export(S.fileSystemRepresentation, G.UTF8String, o6.fileSystemRepresentation, s2p, sizeof s2p, imp, sizeof imp, why, sizeof why);
    ck(rc == S2A_GEXP_NO_PROGRAM, [NSString stringWithFormat:@"⑧ 没有程序包清单：返回 %d（期望 %d）（%@）", rc, S2A_GEXP_NO_PROGRAM, @(why)]);
    [fm removeItemAtPath:T error:nil];
    return S2A_T_RESULT("t_game_export", bad);
} }
