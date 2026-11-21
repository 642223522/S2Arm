#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/*.cs graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py graphics/tools/direct/tests/t_dsh_tess_doms.py
# 外壳着色器出齐 isolines / triangles / quads 三个域的曲面核（S2A.Dsh DshCompiler.Ctx.TessDomains；经 dsh_cmp --fn tess_domains 调）
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
PYTHONDONTWRITEBYTECODE=1 "$PY" "$H/graphics/tools/direct/tests/t_dsh_tess_doms.py"
