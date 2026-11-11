#!/bin/bash
# 门禁覆盖：tools/machine.sh tools/toolchain.sh
# machine.local 最后一条命令返回非 0（末行「[ -f 不存在的文件 ] && . 它」）时，set -e 的调用方照常往下走、前面的赋值读得到。
#   期望按规则手写：① source tools/machine.sh 后打印「继续」、S2A_TEAM_DEFAULT=甲队；② 执行模式 get 打印甲队、退出 0。
# 反证：S2A_MACHINE_SH=<旧 machine.sh> 跑应红（① 无声退出）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; MS=${S2A_MACHINE_SH:-$H/tools/machine.sh}
trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p $T/tools; cp "$MS" $T/tools/machine.sh
printf 'S2A_TEAM_DEFAULT=甲队\n[ -f "%s/没有这个文件.sh" ] && . "%s/没有这个文件.sh"\n' "$T" "$T" > $T/tools/machine.local
out=$(cd $T && unset S2A_MACHINE_NO_LOCAL S2A_MACHINE_LOCAL S2A_TEAM_DEFAULT; bash -c 'set -euo pipefail; . tools/machine.sh 2> /dev/null; echo "继续 ${S2A_TEAM_DEFAULT:-没读到}"' 2>&1)
ck "① set -e 调用方照常往下走、赋值读得到（真结果：${out:-无声退出}）" '[ "$out" = "继续 甲队" ]'
got=$(cd $T && unset S2A_MACHINE_NO_LOCAL S2A_MACHINE_LOCAL S2A_TEAM_DEFAULT; bash tools/machine.sh get S2A_TEAM_DEFAULT); rc=$?
ck "② 执行模式 get 取到值、退出 0（真结果：${got} rc=${rc}）" '[ "$got" = 甲队 ] && [ $rc = 0 ]'
[ $bad = 0 ] && echo "✓ machine_local_status：2 项全通" || { echo "✗ machine_local_status 有不通"; exit 1; }
