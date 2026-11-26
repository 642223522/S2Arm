// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 真编译器整链用例共用：定位 DirectCompiler CLI 产物。
// 不写死绝对路径（写死 /src/... 只在原作者的容器里成立，CI / 别的检出位置必失败、回放全 0）：
// 优先环境变量 S2A_DIRECT_COMPILER_CLI；默认按 run.sh 的约定 case_dir=<repo>/build/<用例目录>
// 上溯两级定位仓库根，再拼出 `dotnet run -c Release --project graphics/tools/direct/compiler/cli` 落产物的固定相对路径。
#ifndef S2A_TESTS_VK_COMPILER_CLI_H
#define S2A_TESTS_VK_COMPILER_CLI_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int s2a_test_compiler_cli(const char *case_dir, char *cli, size_t cap) {
    const char *env = getenv("S2A_DIRECT_COMPILER_CLI");
    int n;
    if (env && *env) {
        n = snprintf(cli, cap, "%s", env);
    } else {
        char repo[1024];
        if (snprintf(repo, sizeof repo, "%s", case_dir) >= (int)sizeof repo) return -1;
        for (int i = 0; i < 2; i++) { char *slash = strrchr(repo, '/'); if (!slash) return -1; *slash = 0; }
        n = snprintf(cli, cap, "%s/graphics/tools/direct/compiler/cli/bin/Release/net10.0/S2A.DirectCompiler.Cli.dll", repo);
    }
    if (n < 0 || (size_t)n >= cap) return -1;
    if (access(cli, R_OK) != 0) {
        fprintf(stderr, "FAIL: 找不到编译器 CLI 产物 %s（先跑对应的 *_compiler_chain_test.py 出产物，或用环境变量 S2A_DIRECT_COMPILER_CLI 指路）\n", cli);
        return -1;
    }
    return 0;
}
#endif
