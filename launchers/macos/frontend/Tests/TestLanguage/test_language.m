// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 测试进程固定界面语言（只在测试里，不进 App）：测试包一加载（+load，早于任何用例、不管 swift test 过滤选了哪些）
//   就把系统首选语言固定成简体中文。所有测试不再跟着跑测试那台机器的系统语言走：
//   11-20 main 上 ShaderCacheImportTests 断言中文原文「不需要」，补上英文译文后在系统语言是英文的机器上就落空了。
//   用的是 NSUserDefaults 的参数域（同命令行 -AppleLanguages (zh-Hans)）：只在本进程内存里，不写盘、不改这台机器的设置。
//   只固定「系统首选语言」，不碰设置里的语言选择 appLanguage：参数域优先级最高，写死它会让测「选过就记住」的用例
//   （NXCoreTests.LauncherLanguageTests）自己写进去的选择读不出来（11-20 连跑实测红）
//   要测别的语言的用例照旧显式传语言（Loc(lang:)、language: 参数、detect(preferred:)），不受影响
#import <Foundation/Foundation.h>
#include "test_language.h"

@interface S2ATestLanguage : NSObject
@end
@implementation S2ATestLanguage
+ (void)load {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *args = [[d volatileDomainForName:NSArgumentDomain] mutableCopy] ?: [NSMutableDictionary new];
    args[@"AppleLanguages"] = @[@"zh-Hans"];
    [d setVolatileDomain:args forName:NSArgumentDomain];
}
@end
