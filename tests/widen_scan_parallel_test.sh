#!/bin/bash
# 门禁只看：graphics/widen/scan/wide_scan.py tests/widen_scan_parallel_test.py
# 宽屏离线扫描：单进程 / fork / spawn（没有 fork 的平台走共享内存）三种跑法结果相同，热路径查表与原写法等价。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
python3 "$H/tests/widen_scan_parallel_test.py"
