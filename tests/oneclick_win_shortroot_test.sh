#!/bin/bash
# 门禁覆盖：pack/orch/oneclick_win.py pack/orch/shortroot.py pack/jobs/ipa.py
# Windows 一键出包 result 路径换回（不分大小写 / 分隔符）与拷 ipa 前的明确报错（诊断#0e3bd5）；见 tests/oneclick_win_shortroot_test.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
cd "$R" && PYTHONUTF8=1 PYTHONWARNINGS=ignore::ResourceWarning "$PY" tests/oneclick_win_shortroot_test.py
echo "✓ Windows 一键出包短路径换回单测全过"
