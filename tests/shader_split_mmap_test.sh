#!/bin/bash
# shader_split 大文件走 mmap（Mapped：多字节包含按内容判、遍历同 bytes；超过 BIG 的普通文件不整读）合成字节单测
# 门禁覆盖：translator/shader_split.py
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-}}; [ -n "$PY" ] || { [ -x "$HOME/.s2arm/venv/bin/python3" ] && PY=$HOME/.s2arm/venv/bin/python3 || PY=$(command -v python3); }
exec "$PY" "$H/tests/shader_split_mmap_test.py"
