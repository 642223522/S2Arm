#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/*.cs graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py graphics/tools/direct/tests/t_dsh_mulext.py
# 标量宽乘法离开 SPIRV-Cross 的 optnone 模板（S2A.Dsh DshCompiler.MulExtended，照 nxnative（MIT）；经 dsh_cmp --fn mul_extended 调，GPU 对拍 64 位乘积）
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/graphics/tools/direct/tests/t_dsh_mulext.py"
