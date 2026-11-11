#!/bin/bash
# 入队预检单测门禁每次跑的守卫（tools/gate_route.py precheck_test）：bash tests/gate_precheck_always_test.sh
# 期望（按规则手写，不跑被测实现推导）：改一个和这些单测毫无关系的文件（docs/坑记录.md），门禁路由出的单测里
#   仍含 shell_lint / shared_path / test_wired / shell_pyimports 与全部 tests/*lint*_test.sh——列车入队预检固定跑的同一组。
#   11-10：feat/img-read 改 pack/img.py 带进 os.walk，文本推导没路由到 romfs_walk_lint，合进 main 后所有支的入队预检被拒。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); cd "$H" || exit 1
want=$( { printf 'tests/%s.sh\n' shell_lint_test shared_path_test test_wired_test shell_pyimports_test; ls tests/*lint*_test.sh; } | sort -u)
got=$(python3 tools/gate_route.py tests docs/坑记录.md 2> /dev/null | sort -u)
miss=$(comm -23 <(printf '%s\n' "$want") <(printf '%s\n' "$got"))
if [ -z "$miss" ]; then echo "通 改 docs/坑记录.md 时预检组 $(wc -l <<< "$want" | tr -d ' ') 支单测全被路由"; echo "gate_precheck_always 单测全过"; exit 0; fi
echo "不通 预检组里这些单测没被门禁路由：$(tr '\n' ' ' <<< "$miss")"; exit 1
