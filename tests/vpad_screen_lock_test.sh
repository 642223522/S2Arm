#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁只看：ios/vpad.m ios/vpad_screen_lock.h tests/vpad_screen_lock_test.c
# 门禁覆盖：ios/vpad.m ios/vpad_screen_lock.h
# 三次点按、超时、滑动、长按、多指、重新进入；错误改为两次解除必须被测试抓住。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
CC=${CC:-cc}
"$CC" -std=c11 -Wall -Wextra -Werror "$H/tests/vpad_screen_lock_test.c" -o "$T/test"
"$T/test"
# 在临时目录编译负对照，不修改工作区。
mkdir -p "$T/ios" "$T/tests"
cp "$H/tests/vpad_screen_lock_test.c" "$T/tests/"
sed 's/++s->taps == 3/++s->taps == 2/' "$H/ios/vpad_screen_lock.h" > "$T/ios/vpad_screen_lock.h"
"$CC" -std=c11 -Wall -Wextra -Werror "$T/tests/vpad_screen_lock_test.c" -o "$T/negative"
ulimit -c 0 || true
if "$T/negative" > "$T/negative.log" 2>&1; then
    echo 'FAIL: two-tap negative control escaped'
    exit 1
fi
echo 'PASS: two-tap negative control rejected'
