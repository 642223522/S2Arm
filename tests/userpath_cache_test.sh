#!/bin/bash
# 门禁覆盖：pack/* pack/jobs/core.py pack/jobs/community.py pack/rewriter.py pack/fonts/* graphics/tools/* graphics/metal/tools/* graphics/widen/scan/* services/*.sh runtime/run_mac.sh runtime/rewriter/* launchers/macos/*.py launchers/macos/*.sh tools/machine.sh 维护方工具 tools/mac_save.sh 维护方工具 tools/gc.sh 维护方工具 tools/cores.sh tools/progress.sh tools/toolchain.sh tools/nospace.sh tools/mem_admit.sh tools/csproj_closure.py tools/doctor.sh tools/stage_deps.py tools/push_pack.py
# userpath_cache_test.py 的门禁壳（10-29 基础设施线：门禁只自动收 tests/*_test.sh，这支 .py 原先没人调）
H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$H/tests/userpath_cache_test.py"
