// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 窗口没占到时的 FATAL 文字（vawin.c s2a_window_fatal_msg）：按本款实际的跨度、空洞上界与找过的地方说。
// 背景（#1419）：36 位款 01007EF00011E000，macOS 27.3 beta 26C5047e 上 2^36 以下最大能放 0 MB；原 FATAL 写死「首选位置整块 64 GB 与退路
//   （2^39 以下 ≥ 32 GB 的空洞）」，与实际判据对不上。#1419 的修复后，36 位款 2^36 以下放不下会再到 2^36 以上按 2^36 对齐的块里找，两处都没占到才到 FATAL。
// 期望按规则手写：① 36 位、找过 2^36 以上、要 32768 MB、能放 0 MB → 说「36 位」「2^36 以下与 2^36 以上按 2^36 对齐的一块都没占到」「32768 MB」「0 MB」，
//   不出现「2^39」「与退路」「重装或补权限」  ② 没找过 2^36 以上、上界 2^39、要 64768 MB、能放 49152 MB → 说「0x8000000000」「64768 MB」「49152 MB」，不说「36 位」
//   ③ 36 位、没找过 2^36 以上（2^36 以下有一段但不够）、上界 2^36 → 说「0x1000000000」，不说「2^36 以上」  ④ 跨度 0 → 说「不知道本款要多大」
#include "../src/native.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
__attribute__((constructor(100))) static void noreserve(void) { setenv("S2A_VAWIN_NORESERVE", "1", 1); }   // 先于 vawin.c 的构造函数（101）：不占窗口
static int bad;
#define CHECK(c, ...) do { if (c) { printf("✓ "); } else { printf("✗ "); bad++; } printf(__VA_ARGS__); putchar('\n'); } while (0)
#define MB (1ull << 20)
int main(void) {
    char m[512];
    s2a_window_fatal_msg(m, sizeof m, 32768 * MB, 0, 1ull << 36, 1);
    CHECK(strstr(m, "36 位") && strstr(m, "2^36 以下与 2^36 以上按 2^36 对齐的一块都没占到") && strstr(m, "要 32768 MB") && strstr(m, "一块 0 MB")
          && !strstr(m, "2^39") && !strstr(m, "与退路") && !strstr(m, "重装或补权限"), "① 36 位款两处都没占到：%s", m);
    s2a_window_fatal_msg(m, sizeof m, 64768 * MB, 49152 * MB, 1ull << 39, 0);
    CHECK(strstr(m, "0x8000000000") && strstr(m, "要 64768 MB") && strstr(m, "一块 49152 MB") && !strstr(m, "36 位"), "② 39 位款：%s", m);
    s2a_window_fatal_msg(m, sizeof m, 32768 * MB, 4096 * MB, 1ull << 36, 0);
    CHECK(strstr(m, "0x1000000000") && strstr(m, "一块 4096 MB") && !strstr(m, "2^36 以上"), "③ 36 位款没找 2^36 以上：%s", m);
    s2a_window_fatal_msg(m, sizeof m, 0, 0, 0, 0);
    CHECK(strstr(m, "不知道本款要多大") != NULL, "④ 跨度读不到：%s", m);
    printf("%s t_vawin_fatal：%d 处不符\n", bad ? "✗" : "✓", bad);
    return bad ? 1 : 0;
}
