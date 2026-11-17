#!/bin/bash
# 离线门禁：直连抽取降级表（translator/shader_split.py write_degrade）逐条写、程序块丢弃进表（#1122）；不需要私有输入。
set -euo pipefail
cd "$(dirname "$0")/.."
PY=${S2A_PYTHON:-${S2A_PY:-}}; [ -n "$PY" ] || { [ -x "$HOME/.s2arm/venv/bin/python3" ] && PY=$HOME/.s2arm/venv/bin/python3 || PY=$(command -v python3); }
"$PY" -B tests/shader_split_degrade_test.py
