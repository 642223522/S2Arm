#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：graphics/nvn/tools/romfs_list.py pack/romfs_img.py tests/romfs_map_memory_test.py tests/romfs_map_memory_test.sh
# 两路同时映射合成大成员：不允许读取首尾前先复制全文（#1648）；独立于 .NET 镜像生成套件。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
python3 "$H/tests/romfs_map_memory_test.py"
