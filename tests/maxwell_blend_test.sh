#!/bin/bash
# Maxwell 浮点混合参考模型自检 + 矩阵（#674 通用根修：0 × 任何数 = 0，期望由模型算；固定混合一路是负对照、必须红）。
# 门禁只看：graphics/nvn/tests/maxwell_blend_ref.py graphics/nvn/tests/maxwell_blend_matrix_test.py
# 门禁覆盖：graphics/nvn/tests/maxwell_blend_ref.py graphics/nvn/tests/maxwell_blend_matrix_test.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
python3 -I "$H/graphics/nvn/tests/maxwell_blend_ref.py"
python3 -I "$H/graphics/nvn/tests/maxwell_blend_matrix_test.py"
