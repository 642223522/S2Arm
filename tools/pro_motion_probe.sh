#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
set -euo pipefail
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  echo 'Usage: bash tools/pro_motion_probe.sh [seconds, default 20, maximum 30]'
  echo 'Close controller apps; connect Pro through its usual receiver. Tilt, dock, undock, and tilt. No manual i command.'
  echo 'Only builds the small native probe. Temporary binaries are removed; no game, shader or app build.'
  exit 0
fi
[ "$(uname -s)" = Darwin ] || { echo 'Requires macOS / GameController.' >&2; exit 75; }
if [ "$#" -gt 1 ] || ! [[ "${1:-20}" =~ ^[0-9]{1,2}$ ]]; then echo 'Duration must be 1..30 seconds.' >&2; exit 2; fi
seconds=$((10#${1:-20}))
[ "$seconds" -ge 1 ] && [ "$seconds" -le 30 ] || { echo 'Duration must be 1..30 seconds.' >&2; exit 2; }
R=$(cd "$(dirname "$0")/.." && pwd); cd "$R"
source tools/toolchain.sh > /dev/null
T=$(mktemp -d "${TMPDIR:-/tmp}/s2arm-pro-motion-probe.XXXXXX"); trap 'rm -rf "$T"' EXIT
xcrun clang -fobjc-arc -fno-modules -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
  macos/pro_motion_probe.m runtime/src/pad.c -Iruntime/include -o "$T/probe" \
  -framework AppKit -framework GameController -framework IOKit
"$T/probe" "$seconds"
