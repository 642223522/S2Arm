#!/bin/bash
# 门禁覆盖：launchers/windows/bundle_win.py
# Windows 发版组装先组装、后放壳（bundle_win --place-shell）；见 tests/bundle_win_place_shell_test.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-python3}}
cd "$R" && PYTHONUTF8=1 "$PY" tests/bundle_win_place_shell_test.py
echo "✓ Windows 组装后放壳单测全过"
