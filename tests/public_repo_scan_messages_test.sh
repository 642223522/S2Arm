#!/bin/bash
# 门禁覆盖：tools/public_repo_scan.py tools/public_repo_scan_rules.json
# 提交信息扫描（tools/public_repo_scan.py --messages，列车入队预检用；11-09）：bash tests/public_repo_scan_messages_test.sh
#   期望按词表手写：提交信息里有内部线名（整词：某某线）/ 设备代号 → 退 1、报提交号 + 行号 + 规则、不回显那个词；通用说法 → 退 0；只扫 BASE..REF，BASE 之前的不管
#   内部称呼在本文件里按码位运行时拼出（扫描器会还原转义，转义写法也会被拦）（本文件也受公开仓扫描）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
W1=$(python3 -c 'print(chr(0x5929) + chr(0x773c))'); W2=$(python3 -c 'print(chr(0x6d4b) + chr(0x8bd5) + chr(0x673a))')
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
# 内部线名（11-09 维护方：整词匹配；普通「主线 / 线程 / 线性」不误伤）
W3=$(python3 -c 'print(chr(0x4e3b) + chr(0x7ebf) * 2)'); W4=$(python3 -c 'print(chr(0x80fd) + chr(0x8017) + chr(0x7ebf))')
base2=$(g rev-parse HEAD); echo d > "$T/r/d"; g add d; g commit -qm "feat: 主线任务进度、线程池、线性贴图" -m "主线 全过"; plain=$(g rev-parse HEAD)
o=$(S "$plain" "$base2"); r=$?
ck "普通「主线 / 线程 / 线性」→ 退 0、命中 0（rc=${r}）" '[ $r = 0 ] && [[ "$o" == *"命中 0 处"* ]]'
echo e > "$T/r/e"; g add e; g commit -qm "fix: 收尾" -m "${W3}：已入车" -m "交 ${W4} 复核"
o=$(S HEAD "$plain"); r=$?
ck "内部线名 → 退 1、两处命中（第 3、5 行）（rc=${r}）" '[ $r = 1 ] && grep -q "信息第 3 行.*internal_line_name" <<< "$o" && grep -q "信息第 5 行.*internal_line_name" <<< "$o"'
printf '交 %s 复核\n' "$W4" > "$T/r/g.md"; g add g.md; g commit -qm "docs: x"
o=$(python3 "$H/tools/public_repo_scan.py" --repo "$T/r" --ref HEAD --path g.md --base HEAD~1 --format gate); r=$?
ck "文件扫描暂不启用线名规则（messages_only；存量清完再开）→ 退 0（rc=${r}）" '[ $r = 0 ] && [[ "$o" == *"增量命中 0"* ]]'
# 任天堂第一方游戏名（11-09 晚：#350 写进坑记录、#371 写进提交标题都没被拦）：提交信息与 docs/ 下 Markdown 新增行都拦；docs 存量行不改不报
G1=$(python3 -c 'print(chr(0x65f6) + chr(0x4e4b) + chr(0x7b1b))'); G2=$(python3 -c 'print(chr(0x5854) + chr(0x5c14) + chr(0x8fbe))')
base3=$(g rev-parse HEAD); echo h > "$T/r/h"; g add h; g commit -qm "docs(验证账): ${G1} 首批 Mac 实测入账"; gm=$(g rev-parse HEAD)
o=$(S "$gm" "$base3"); r=$?
ck "提交标题写第一方游戏名 → 退 1、报「任天堂第一方游戏名」、不回显（rc=${r}）" '[ $r = 1 ] && grep -q "信息第 1 行：任天堂第一方游戏名（规则 compliance_first_party_titles）" <<< "$o" && ! grep -q "${G1}" <<< "$o"'
echo i > "$T/r/i"; g add i; g commit -qm "docs(验证账): 0400486024DEC000 首批 Mac 实测入账"
o=$(S HEAD "$gm"); r=$?
ck "改成程序号 → 退 0（rc=${r}）" '[ $r = 0 ] && [[ "$o" == *"命中 0 处"* ]]'
mkdir -p "$T/r/docs"; printf '# 坑\n旧条目：%s 存量\n' "$G2" > "$T/r/docs/pit.md"; g add docs/pit.md; g commit -qm "docs: 存量"
printf '新条目：一款大型开放世界游戏在第二存放位置\n' >> "$T/r/docs/pit.md"; g add docs/pit.md; g commit -qm "docs: 泛指"
o=$(python3 "$H/tools/public_repo_scan.py" --repo "$T/r" --ref HEAD --path docs --base HEAD~1 --format gate); r=$?
ck "docs/*.md 只加泛指行、存量行不动 → 退 0（rc=${r}）" '[ $r = 0 ] && [[ "$o" == *"增量命中 0"* ]]'
printf '又一条：%s 在第二存放位置\n' "$G1" >> "$T/r/docs/pit.md"; g add docs/pit.md; g commit -qm "docs: 又一条"
o=$(python3 "$H/tools/public_repo_scan.py" --repo "$T/r" --ref HEAD --path docs --base HEAD~1 --format gate); r=$?
ck "docs/*.md 新增行写第一方游戏名 → 退 1、报 compliance_copy（rc=${r}）" '[ $r = 1 ] && grep -q "docs/pit.md.*compliance_copy" <<< "$o"'
[ $bad = 0 ] && echo "提交信息扫描单测全过" || { echo "提交信息扫描单测有不通"; exit 1; }
