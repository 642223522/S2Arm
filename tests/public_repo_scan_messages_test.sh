#!/bin/bash
# 门禁覆盖：tools/public_repo_scan.py tools/public_repo_scan_rules.json
# 提交信息扫描（tools/public_repo_scan.py --messages，列车入队预检用；11-09）：bash tests/public_repo_scan_messages_test.sh
#   期望按词表手写：提交信息里有内部线名 / 设备代号 → 退 1、报提交号 + 行号 + 规则、不回显那个词；通用说法 → 退 0；只扫 BASE..REF，BASE 之前的不管
#   内部称呼在本文件里用 Unicode 转义运行时拼出（本文件也受公开仓扫描）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
W1=$(python3 -c 'print("天眼")'); W2=$(python3 -c 'print("测试机")')
g() { git -C "$T/r" -c user.name=t -c user.email=t@t "$@"; }
git init -q -b main "$T/r"; echo a > "$T/r/a"; g add a; g commit -qm "old: ${W1} 之前的历史不管"; base=$(g rev-parse HEAD)
echo b > "$T/r/b"; g add b; g commit -qm "fix: Windows 实机验证通过"; clean=$(g rev-parse HEAD)
echo c > "$T/r/c"; g add c; g commit -qm "fix: 修复出包" -m "${W1} Windows 实跑：绿" -m "${W2}2 上复现"
S() { python3 "$H/tools/public_repo_scan.py" --repo "$T/r" --ref "$1" --path . --messages "$2"; }
o=$(S "$clean" "$base"); r=$?
ck "通用说法（Windows 实机）→ 退 0、命中 0（基线之前的提交不扫）（rc=${r}）" '[ $r = 0 ] && [[ "$o" == *"1 条提交，命中 0 处"* ]]'
o=$(S HEAD "$base"); r=$?
ck "内部线名 + 设备代号 → 退 1、两处命中（第 3、5 行）（rc=${r}）" '[ $r = 1 ] && [ "$(grep -c "^🔴 提交" <<< "$o")" = 2 ] && grep -q "信息第 3 行" <<< "$o" && grep -q "信息第 5 行" <<< "$o"'
ck "命中行不回显那个词、给出改法（rebase -i）" '! grep -q "${W1}\|${W2}" <<< "$o" && grep -q "rebase -i" <<< "$o"'
[ $bad = 0 ] && echo "提交信息扫描单测全过" || { echo "提交信息扫描单测有不通"; exit 1; }
