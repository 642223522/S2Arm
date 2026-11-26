// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 退出探针（只在测试里，不进 App）：测试进程跑到一半自己退出时，把「在哪条用例里」和调用栈写进标准错误。
//   11-17：高负载下 S2ArmAppleTests 进程在一条快照用例中途正常退出（系统日志有退出收尾，没被杀、没有崩溃报告），
//   后面的用例没跑，单跑、重跑都复现不了。登记的回调在 exit 里面执行，调用栈里就有调 exit 的那一处。
//   +load 在测试包加载时就跑，不管 swift test 过滤选了哪些用例；整个测试包正常跑完、没跑 XCTest 的那一遍都不出声
#import <Foundation/Foundation.h>
#import <XCTest/XCTest.h>
#include <execinfo.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "xctest_exit_probe.h"

static char g_current[512];
static volatile int g_armed;   // XCTest 测试包开跑后才置 1、跑完清 0：swift test 另起的 Swift Testing 那一遍（同一测试包、不跑 XCTest 用例）不出声

static void probe_at_exit(void) {
    if (!g_armed) return;
    char head[640];
    int n = g_current[0] ? snprintf(head, sizeof head, "[退出探针] 测试进程在用例 %s 中途退出，调用栈：\n", g_current)
                         : snprintf(head, sizeof head, "[退出探针] 测试进程在两条用例之间退出，调用栈：\n");
    write(STDERR_FILENO, head, (size_t)n);
    void *frames[128];
    backtrace_symbols_fd(frames, backtrace(frames, 128), STDERR_FILENO);
}

@interface S2AXCTestExitProbe : NSObject <XCTestObservation>
@end
@implementation S2AXCTestExitProbe
+ (void)load {
    static S2AXCTestExitProbe *probe;
    probe = [S2AXCTestExitProbe new];
    dispatch_async(dispatch_get_main_queue(), ^{ [[XCTestObservationCenter sharedTestObservationCenter] addTestObserver:probe]; });
    atexit(probe_at_exit);
}
- (void)testCaseWillStart:(XCTestCase *)testCase { strlcpy(g_current, testCase.name.UTF8String ?: "?", sizeof g_current); }
- (void)testCaseDidFinish:(XCTestCase *)testCase { g_current[0] = 0; }
- (void)testBundleWillStart:(NSBundle *)testBundle { g_armed = 1; }
- (void)testBundleDidFinish:(NSBundle *)testBundle { g_armed = 0; }
@end
