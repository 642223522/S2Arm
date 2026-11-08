#!/bin/bash
# x16/x17 跳转表单测（runtime/rewriter/rewriter.c 的 brrel 借 x9–x15 路径，形态取自 DQB2，合成 NSO，走真 CLI）：bash tests/rewriter_jt_x16_test.sh
# 门禁覆盖：runtime/rewriter/*
# 用例：真实形态借 x9/x10；下标在 x9 时改借 x10/x11 且落点写回表项；表项出函数仍记缺口。
# 反证：把 brrel 里挑寄存器的循环改回固定 tmp1=9/tmp2=10 后，test_tmp_avoids_index 必须红。
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
PY=${PY:-${S2A_PY:-$HOME/.s2arm/venv/bin/python3}}
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}
[ -x "$REW" ] || { echo "🔴 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
exec "$PY" "$H/tests/rewriter_jt_x16_test.py" "$REW" "$@"
