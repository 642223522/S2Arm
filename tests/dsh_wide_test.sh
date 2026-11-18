#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/*.cs graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py graphics/tools/direct/tests/t_dsh_wide.py
# 存储缓冲逐字读合并（S2A.Dsh DshCompiler.WideLoads，照 nxnative dmsh_wide.py（MIT）；经 dsh_cmp --fn wide_loads 调）
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/graphics/tools/direct/tests/t_dsh_wide.py"
