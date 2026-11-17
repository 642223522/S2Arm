#!/bin/bash
# 门禁覆盖：pack/dev_sign.py tests/test_dev_sign_pick.py
# dev_sign 挑描述文件（逐项核过的里取到期最晚的，11-17 #1447 / #1448）：bash tests/dev_sign_pick_test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
"${S2A_PY:-python3}" -B tests/test_dev_sign_pick.py
