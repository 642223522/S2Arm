#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁只看：macos/joycon_imu.* macos/motion_power.h macos/pro_motion_probe.m macos/tests/t_pro_motion.m tools/pro_motion_probe.sh
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo 'pro_motion：需要 macOS / GameController'; exit 75; }
R=$(cd "$(dirname "$0")/.." && pwd); cd "$R"
source tools/toolchain.sh > /dev/null
T=$(mktemp -d "${TMPDIR:-/tmp}/s2arm-pro-motion-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
xcrun clang -fobjc-arc -fno-modules -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
  macos/tests/t_pro_motion.m runtime/src/pad.c -Iruntime/include -o "$T/test" \
  -framework Foundation -framework GameController -framework IOKit
"$T/test"
xcrun clang -fobjc-arc -fno-modules -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
  macos/pro_motion_probe.m runtime/src/pad.c -Iruntime/include -o "$T/probe" \
  -framework AppKit -framework GameController -framework IOKit
"$T/probe" --help
rc=0; "$T/probe" 31 > /dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "Probe duration validation: expected 2, got $rc"; exit 1; }
