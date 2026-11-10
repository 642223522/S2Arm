#!/bin/bash
# 本机预跑令牌优先级（tools/run_token.sh，11-10 维护方）：令牌被占时，门禁（高）与手工命令（低）都在排队，令牌一放先给门禁；
#   没有高优先级排队时低优先级照常领；高优先级排队者的进程没了，标记作废、不卡低优先级。期望由构造决定。
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'kill $(jobs -p) 2> /dev/null; rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export GATE_RUN_TOKEN_DIR=$T/tok GATE_RUN_PAR=1 GATE_RUN_POLL_S=0.2; unset GATE_NO_LOADQ GATE_IN_STEP
# 有活着的门禁在排队（want.<活进程>），令牌虽然空着，手工命令也不领、继续等（确定性：不靠轮询时机）
sleep 30 & PW=$!; mkdir -p "$T/tok"; touch "$T/tok/want.$PW"; : > "$T/order"
timeout 3 bash "$H/tools/run_token.sh" bash -c 'echo low > "'"$T"'/order"' 2> /dev/null; rc=$?
ck "门禁在排队时手工命令让行：3 秒内没领到（rc=${rc}，输出「$(cat "$T/order")」）" '[ $rc = 124 ] && [ ! -s "$T/order" ]'
kill $PW 2> /dev/null; wait $PW 2> /dev/null; rm -f "$T/tok/want.$PW"   # 死标记的处理由最后一项专门测
# 门禁本身照领，领到后清掉自己的标记
( source "$H/tools/run_token.sh"; runtok_take $BASHPID && echo high > "$T/order" ) 2> /dev/null
ck "门禁照常领到" '[ "$(cat "$T/order")" = high ]'
ck "领到后标记清掉" '[ -z "$(ls "$T/tok"/want.* 2> /dev/null)" ]'
# 没有高优先级排队：低优先级直接领
: > "$T/order2"; bash "$H/tools/run_token.sh" bash -c 'echo low2 > "'"$T"'/order2"' 2> /dev/null
ck "没人排队时手工命令直接领到" '[ "$(cat "$T/order2")" = low2 ]'
# 死标记：want.<不存在的 pid> 不卡低优先级
touch "$T/tok/want.999999"; : > "$T/order3"; timeout 10 bash "$H/tools/run_token.sh" bash -c 'echo low3 > "'"$T"'/order3"' 2> /dev/null
ck "高优先级排队者进程已没 → 标记作废、手工命令照领（实为 $(cat "$T/order3")）" '[ "$(cat "$T/order3")" = low3 ] && [ ! -e "$T/tok/want.999999" ]'
[ $bad = 0 ] && echo "本机预跑令牌优先级单测全过" || { echo "本机预跑令牌优先级单测有不通"; exit 1; }
