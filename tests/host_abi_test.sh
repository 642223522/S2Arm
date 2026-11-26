#!/bin/bash
# 宿主约定号表态门禁（tools/host_abi_lint.py）：bash tests/host_abi_test.sh
# A 段（合成仓库，期望按规则手写）：
#   ① 只改约定清单外的文件 → 退出 0
#   ② 改了 runtime/src/loader.c、号没动、提交信息没表态 → 退出 1，点名 loader.c
#   ③ 同 ②，提交信息有「host-abi: unchanged 只修宿主自身的 bug」→ 退出 0
#   ④ 同 ②，S2A_HOST_ABI 1 → 2 → 退出 0
#   ⑤ 表态只写「host-abi: unchanged」没写原因 → 退出 1
#   ⑥ 表态写在本支更早的一条提交里（之后又改了约定文件）→ 退出 0（按整支看）
#   ⑦ 基点还没有 s2a_host_abi.h、本支新加且值仍是 1 → 不算改了号（没头按 1），没表态退出 1
# B 段：真仓库对 GATE_SCAN_BASE（缺省 origin/main）跑一遍，退出 0 才过
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
L="python3 $H/tools/host_abi_lint.py"
G() { git -C "$R" -c user.name=t -c user.email=t@t "$@" > /dev/null; }
init() {   # 新合成仓库：基线一笔（约定号 1、loader.c、README）
    R=$T/$1; mkdir -p $R/runtime/include $R/runtime/src; git init -q -b main $R
    printf '#define S2A_HOST_ABI 1\n' > $R/runtime/include/s2a_host_abi.h; echo a > $R/runtime/src/loader.c; echo a > $R/README.md
    G add -A; G commit -qm base; G checkout -qb topic
}
edit() { echo "$2" >> "$R/$1"; G add -A; G commit -qm "$3"; }

init r1; edit README.md b "docs"
o=$($L --repo $R --base main --ref HEAD); r=$?; ck "① 只改清单外的文件：退出 ${r}（期望 0）" '[ $r = 0 ]'
init r2; edit runtime/src/loader.c b "fix loader"
o=$($L --repo $R --base main --ref HEAD); r=$?; ck "② 改 loader.c、号没动、没表态：退出 ${r}（期望 1）、点名 loader.c" '[ $r = 1 ] && grep -q "runtime/src/loader.c" <<< "$o"'
init r3; edit runtime/src/loader.c b $'fix loader\n\nhost-abi: unchanged 只修宿主自身的 bug'
o=$($L --repo $R --base main --ref HEAD); r=$?; ck "③ 提交信息表态带原因：退出 ${r}（期望 0）" '[ $r = 0 ]'
init r4; edit runtime/src/loader.c b "new table"; printf '#define S2A_HOST_ABI 2\n' > $R/runtime/include/s2a_host_abi.h; G add -A; G commit -qm bump
o=$($L --repo $R --base main --ref HEAD); r=$?; ck "④ 约定号 1 → 2：退出 ${r}（期望 0）" '[ $r = 0 ]'
init r5; edit runtime/src/loader.c b $'fix\n\nhost-abi: unchanged'
o=$($L --repo $R --base main --ref HEAD); r=$?; ck "⑤ 表态没写原因：退出 ${r}（期望 1）" '[ $r = 1 ]'
init r6; edit runtime/src/loader.c b $'first\n\nhost-abi: unchanged 只加日志'; edit runtime/src/loader.c c "second"
o=$($L --repo $R --base main --ref HEAD); r=$?; ck "⑥ 表态在本支更早一条提交里：退出 ${r}（期望 0）" '[ $r = 0 ]'
R=$T/r7; mkdir -p $R/runtime/src; git init -q -b main $R; echo a > $R/runtime/src/loader.c; G add -A; G commit -qm base; G checkout -qb topic
mkdir -p $R/runtime/include; printf '#define S2A_HOST_ABI 1\n' > $R/runtime/include/s2a_host_abi.h; edit runtime/src/loader.c b "add header"
o=$($L --repo $R --base main --ref HEAD); r=$?; ck "⑦ 基点还没有约定号头、本支新加且仍是 1、没表态：退出 ${r}（期望 1，没头按 1 算，不算改了号）" '[ $r = 1 ]'

o=$($L --repo "$H" --base "${GATE_SCAN_BASE:-origin/main}" --ref "${GATE_REV:-HEAD}"); r=$?; echo "$o"
ck "B 真仓库对 ${GATE_SCAN_BASE:-origin/main}：退出 ${r}（期望 0）" '[ $r = 0 ]'
[ $bad = 0 ] && echo "✓ host_abi_test" || echo "✗ host_abi_test"
exit $bad
