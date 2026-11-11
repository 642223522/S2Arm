#!/bin/bash
# 门禁覆盖：tools/run_token.sh tools/gate.sh
# 手工命令排步令牌的级（tools/run_token.sh → tools/gate.sh tok_get，11-10 门禁减压 C）：手工 = 级 3，排在热修 / 列车 / 预跑后面。期望由构造决定：
#   有活着的预跑（级 2）排队登记，令牌虽然空着，手工命令也不领；GATE_ROLE=热修 的包装照领；登记的进程没了 → 标记作废、手工照领
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'kill $(jobs -p) 2> /dev/null; rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export GATE_TOKEN_DIR=$T/tok GATE_STEP_PAR=1 GATE_TOK_POLL_S=0.2; unset GATE_NO_LOADQ GATE_IN_STEP GATE_ROLE
sleep 30 & PW=$!; mkdir -p "$T/tok"; touch "$T/tok/want.2.$(date +%s).$PW"; : > "$T/order"
timeout 3 bash "$H/tools/run_token.sh" bash -c 'echo low > "'"$T"'/order"' 2> /dev/null; rc=$?
ck "预跑在排队时手工命令让行：3 秒内没领到（rc=${rc}，输出「$(cat "$T/order")」）" '[ $rc = 124 ] && [ ! -s "$T/order" ]'
GATE_ROLE=热修 timeout 5 bash "$H/tools/run_token.sh" bash -c 'echo high > "'"$T"'/order"' 2> /dev/null
ck "GATE_ROLE=热修 的包装不让预跑、照领" '[ "$(cat "$T/order")" = high ]'
kill $PW 2> /dev/null; wait $PW 2> /dev/null
: > "$T/order3"; timeout 10 bash "$H/tools/run_token.sh" bash -c 'echo low3 > "'"$T"'/order3"' 2> /dev/null
ck "排队者进程已没 → 标记作废、手工命令照领（实为 $(cat "$T/order3")）、标记被清" '[ "$(cat "$T/order3")" = low3 ] && [ -z "$(ls "$T/tok"/want.2.* 2> /dev/null)" ]'
[ $bad = 0 ] && echo "步令牌级单测全过" || { echo "步令牌级单测有不通"; exit 1; }
