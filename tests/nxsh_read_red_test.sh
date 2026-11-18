#!/bin/bash
# 门禁覆盖：graphics/tools/shbake/nxsh_extract.py tests/nxsh_read_red_test.py
# S2Arm 抽取读不了的文件计红、进降级表（不再只计统计行悄悄跳过）：约 2 秒，见 tests/nxsh_read_red_test.py
set -eu
cd "$(dirname "$0")/.." && python3 tests/nxsh_read_red_test.py
