#!/bin/bash
# 列目录按扩展名收文件时跳过 AppleDouble「._<名>」附属文件（#1529 同类全仓审查）：dsx_win 链接、共享字体计数、程序包配方、管线种子
# 门禁覆盖：graphics/dsx/dsx_win.py pack/orch/stages.py pack/jobs/programs.py graphics/tools/direct/pso_seed.py tests/appledouble_scan_test.py
set -eu
R=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-${PY:-$HOME/.s2arm/venv/bin/python3}}
exec "$PY" "$R/tests/appledouble_scan_test.py"
