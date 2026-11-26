#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# 跨平台 LDN 设置接线检查；由通用门禁调用，不代替 Apple 设置单测或双机联机。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
cd "$H"
exec python3 tests/ldn_manual_settings_test.py
