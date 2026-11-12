#!/bin/bash
# 阶段缓存键「产物等价」单测外壳（tests/stage_equiv_test.py 文件头）
# 门禁覆盖：pack/stage_keyfiles.sh tools/stage_deps.py tools/stage_equiv.py pack/stage_inputs/equiv.tsv tests/stage_equiv_test.py tests/stage_equiv_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); exec python3 "$H/tests/stage_equiv_test.py"
