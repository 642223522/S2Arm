#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/*.cs graphics/tools/direct/tests/dsh_cmp/* graphics/tools/direct/tests/dshfn.py graphics/tools/direct/tests/t_vs_pull.py graphics/tools/direct/tests/t_vs_pull_run.m
# 拉取式顶点输入变体 _bp（S2A.Dsh DshPull）出包那条路接上了：合成顶点着色器按出包翻译（PackOut）出 _bp.json / _bp.metal，反射与源码形状对手写期望、Mac 编译参数编得过；
#   形状与 GPU 逐格式一致那几项同一次一起跑（t_vs_pull.py，门禁 graphics/gate.sh vs_pull 也跑它们，但不带 libdsx 不跑出包这一项）。用法：bash tests/vs_pull_pack_test.sh
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
make -s -C "$H/graphics/dsx" -j"${S2A_CPU_GATE:-6}" "$H/build/dsx/libdsx.dylib" > /dev/null
PYTHONDONTWRITEBYTECODE=1 "${S2A_PY:-python3}" "$H/graphics/tools/direct/tests/t_vs_pull.py" --dsx "$H/build/dsx/libdsx.dylib"
