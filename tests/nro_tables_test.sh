#!/bin/bash
# 门禁覆盖：pack/ship_ext.py
# 装到手机的程序包里 NRO 随行表合成一份（tests/nro_tables_test.py）；宿主读法见 runtime/tests/t_nro_many.c 合并表档
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${PY:-python3}
"$PY" "$H/tests/nro_tables_test.py" && echo "nro_tables 自测 通过" || { echo "nro_tables 自测 失败"; exit 1; }
