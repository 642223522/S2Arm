#!/bin/bash
# Switch 1 着色器键第 2 代（两段易变字段置零）在离线 / 出包各算键处的口径单测（合成字节，约 1 秒）：bash tests/shader_key_v2_test.sh
# 门禁覆盖：translator/nvn_key.py translator/shader_split.py translator/rt_dump_merge.py graphics/tools/direct/merge_extract.py graphics/tools/shbake/nxsh_extract.py android/tools/direct_prepare.py
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-${S2A_PY:-}}; [ -n "$PY" ] || { [ -x "$HOME/.s2arm/venv/bin/python3" ] && PY=$HOME/.s2arm/venv/bin/python3 || PY=$(command -v python3); }
exec "$PY" "$H/tests/shader_key_v2_test.py"
