// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iPhone 设置页 S 级状态句（ios/sgrade_line.m）：文案取真的 zh-Hans 字符串表（mk 把 zh-Hans.lproj 拷在可执行文件旁，S2AL 经主 bundle 读到），期望按定稿模板手写（三端状态与文案对照定稿），
//   与 Mac SGradeStateTextTests 同一组输入同一句
#import <Foundation/Foundation.h>
#import "../../ios/sgrade_line.h"
#include <stdio.h>

static int fails;
#define CK(c, ...) do { if (c) printf("通 "); else { printf("红 "); fails++; } printf(__VA_ARGS__); printf("\n"); } while (0)

int main(int argc, char **argv) {
    @autoreleasepool {
        (void)argc; (void)argv;
        NSString *(^d)(NSDate *) = ^NSString *(NSDate *w) { (void)w; return @"11-15"; };
        #define L(cat, dict, name, target) s2a_sgrade_line(cat, dict, name, target, d)
        #define EQ(got, want, what) do { NSString *g_ = (got); CK([g_ ?: @"(nil)" isEqual:(want)], "%s：%s", what, (g_ ?: @"(nil)").UTF8String); } while (0)

        EQ(L(@"widescreen", (@{@"state": @"on", @"source": @"patch", @"active": @"adaptive"}), @"满屏", 0), @"在用：社区满屏补丁（按屏幕比例自动选）", "在用自适应补丁");
        EQ(L(@"widescreen", (@{@"state": @"on", @"source": @"patch", @"active": @"fixed"}), @"满屏", 0), @"在用：社区满屏补丁（固定画幅）", "在用定画幅补丁");
        EQ(L(@"widescreen", (@{@"state": @"on", @"source": @"own", @"active": @"own"}), @"满屏", 0), @"在用：S2Arm 通用满屏（这款没有社区满屏补丁，S2Arm 验过能铺满）", "在用通用满屏");
        EQ(L(@"fps", (@{@"state": @"on"}), @"帧率", 120), @"在用：最高 120 帧", "帧率在用写最高档");
        CK(L(@"fps", (@{@"state": @"on"}), @"帧率", 0) == nil, "帧率在用但不知道档：不写");
        EQ(L(@"widescreen", (@{@"state": @"ineffective", @"lastRun": @"没生效：补丁与这个版本的游戏不配套"}), @"满屏", 0), @"没生效：补丁与这个版本的游戏不配套", "没生效照原句");
        EQ(L(@"widescreen", (@{@"state": @"off_auto", @"autoOff": @{@"cause": @"crash", @"at": @1794740000}}), @"满屏", 0), @"已自动关：11-15 游戏崩溃时它开着", "崩溃自动关");
        EQ(L(@"fps", (@{@"state": @"off_auto", @"autoOff": @{@"cause": @"stall", @"at": @1794740000}}), @"帧率", 60), @"已自动关：11-15 画面停住时它开着", "停帧救场自动关");
        EQ(L(@"fps", (@{@"state": @"off_user"}), @"帧率", 0), @"已关", "玩家关的");
        EQ(L(@"fps", (@{@"state": @"version", @"versions": @{@"mine": @"1.0.2", @"available": @[@"1.0.0", @"1.1.0", @"1.0.4"]}}), @"帧率", 0),
           @"补丁库里是 1.0.4 版的，你这份是 1.0.2。把游戏更新到 1.0.4 后重新出包就能用。", "版本：取离你最近的新版本");
        EQ(L(@"fps", (@{@"state": @"version", @"versions": @{@"mine": @"1.3.0", @"available": @[@"1.0.0", @"1.2.0"]}}), @"帧率", 0),
           @"补丁只有旧版本 1.2.0 的，你这个版本暂时没有。", "版本：全是旧的写最新的旧版本、不劝降级");
        EQ(L(@"fps", (@{@"state": @"version", @"versions": @{@"mine": @"1.9", @"available": @[@"1.10"]}}), @"帧率", 0),
           @"补丁库里是 1.10 版的，你这份是 1.9。把游戏更新到 1.10 后重新出包就能用。", "版本按段比：1.10 比 1.9 新");
        EQ(L(@"widescreen", (@{@"state": @"version", @"versions": @{@"mine": @"1.0.2", @"available": @[@"1.0.4"], @"port": @"failed"}}), @"满屏", 0),
           @"补丁库里是 1.0.4 版的，你这份是 1.0.2。把游戏更新到 1.0.4 后重新出包就能用。已试过移植到你这份，没成功。", "满屏移植没成加一句");
        CK(L(@"fps", (@{@"state": @"version", @"versions": @{@"mine": @"1.0", @"available": @[]}}), @"帧率", 0) == nil, "没有别的版本可说：不写");
        EQ(L(@"widescreen", (@{@"state": @"none"}), @"满屏", 0), @"补丁库里还没有这款游戏的满屏补丁。", "补丁库里没有");
        EQ(L(@"fps", (@{@"state": @"opted_out"}), @"帧率", 0), @"没打入：出包时取消了「出包时打入」。重新出包时勾上就有。", "出包时没打入");
        EQ(L(@"widescreen", (@{@"state": @"pending"}), @"满屏", 0), @"电脑上有可用的新补丁：在电脑的 S2Arm 点「S 级优化升级」装进来。", "iPhone 待补：回电脑升级");
        CK(L(@"widescreen", (@{@"state": @"unknown"}), @"满屏", 0) == nil && L(@"widescreen", nil, @"满屏", 0) == nil, "不知道 / 没这一类：不写");
        // 齿轮菜单一级三行的副标题（11-15）：写现在用的是什么；只有真用不了才置灰
        #define R(cat, dict, target, hasP, pOn, fiOk, dis) s2a_sgrade_row_note(cat, dict, target, hasP, pOn, fiOk, d, dis)
        BOOL dis = YES;
        EQ(R(@"widescreen", (@{@"state": @"on", @"source": @"patch", @"active": @"adaptive"}), 0, NO, NO, YES, &dis), @"社区补丁 · 按屏幕比例自动选", "满屏：自适应补丁");
        CK(!dis, "满屏：不置灰");
        EQ(R(@"widescreen", (@{@"state": @"on", @"source": @"patch", @"active": @"fixed"}), 0, NO, NO, YES, NULL), @"社区补丁 · 固定画幅", "满屏：定画幅补丁");
        EQ(R(@"widescreen", (@{@"state": @"off_user", @"source": @"own"}), 0, NO, NO, YES, NULL), @"S2Arm 通用满屏（这款没有社区补丁）", "满屏：没补丁走通用满屏（关着也写开了用什么）");
        EQ(R(@"widescreen", nil, 0, NO, NO, YES, NULL), @"S2Arm 通用满屏（这款没有社区补丁）", "满屏：作业层还没给状态也写通用满屏");
        EQ(R(@"widescreen", (@{@"state": @"off_auto", @"source": @"own", @"autoOff": @{@"cause": @"crash", @"at": @1794740000}}), 0, NO, NO, YES, NULL),
           @"已自动关：11-15 游戏崩溃时它开着", "满屏：自动关的写状态句");
        EQ(R(@"fps", (@{@"state": @"on", @"source": @"patch"}), 120, YES, YES, YES, NULL), @"社区补丁 · 最高 120 帧", "帧率：补丁在用");
        EQ(R(@"fps", (@{@"state": @"off_user", @"source": @"fi"}), 120, YES, NO, YES, NULL), @"补帧：30 帧补到 60 帧", "帧率：有补丁但补丁关着、补帧在跑");
        EQ(R(@"fps", (@{@"source": @"fi"}), 0, NO, NO, YES, NULL), @"补帧：30 帧补到 60 帧（这款没有社区补丁）", "帧率：没补丁用补帧");
        EQ(R(@"fps", (@{@"source": @"none", @"fiSupported": @NO}), 0, NO, NO, YES, &dis), @"这台设备不支持补帧", "帧率：没补丁且设备不支持补帧");
        CK(dis, "帧率：真用不了才置灰");
        EQ(R(@"fps", (@{@"source": @"none", @"fiSupported": @NO}), 60, YES, NO, YES, &dis), @"社区补丁 · 最高 60 帧", "帧率：关着但有补丁：写开了用补丁");
        CK(!dis, "帧率：有补丁不置灰");
        EQ(R(@"fps", nil, 0, NO, NO, YES, NULL), @"补帧：30 帧补到 60 帧（这款没有社区补丁）", "帧率：作业层没给来源，按本机能补帧写补帧");
        EQ(R(@"fps", (@{@"state": @"unsupported", @"source": @"fi"}), 0, NO, NO, YES, &dis), @"这台设备不支持补帧", "帧率：作业层判 unsupported");
        CK(dis, "帧率：unsupported 置灰");
        EQ(R(@"widescreen", (@{@"state": @"off_auto", @"source": @"own", @"autoOff": @{@"cause": @"widen_fit", @"at": @1794740000}}), 0, NO, NO, YES, NULL),
           @"已自动关：11-15 满屏没铺满或画面被拉伸", "满屏：手动开的通用满屏局内没铺满，自动关");
        EQ(R(@"fps", nil, 120, YES, YES, YES, NULL), @"社区补丁 · 最高 120 帧", "帧率：没给来源、有补丁且开着写补丁");
        CK(s2a_sgrade_version_cmp(@"1.10", @"1.9") == 1 && s2a_sgrade_version_cmp(@"1.0", @"1.0.0") == 0 && s2a_sgrade_version_cmp(@"1.2", @"1.10") == -1, "版本按段比较");
    }
    printf("%s t_sgrade_line：%d 项红\n", fails ? "✗" : "✓", fails);
    return fails != 0;
}
