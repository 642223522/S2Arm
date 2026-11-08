#!/bin/bash
# 门禁层：合入后
# 门禁路由：launchers/macos/ pack/jobs/
# Mac frontend gate: local checks only; no runtime building or dependency install.
set -euo pipefail
bash launchers/macos/test.sh
echo 'Mac 任务、Swift 交互与原生输入 → 全部通过'
