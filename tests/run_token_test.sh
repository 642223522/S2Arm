#!/bin/bash
# 门禁覆盖：tools/run_token.sh tools/gate.sh tools/flock_hold.py
# 手工命令占步令牌 + 门禁先拿令牌再起步（11-10 门禁减压 C：21:41 本机 2395 个 gate.sh 进程，一份预跑先把所有步 fork 出来各自排令牌；TERM 停不下）：bash tests/run_token_test.sh，约 30 秒
#   期望按规则手写（步令牌 GATE_STEP_PAR 个）：
#   ① 包装用法 bash tools/run_token.sh <命令>：令牌 2 个被两份包装占住 → 第三份 3 秒内领不到；持有者被 kill -9 → 新的一份立刻领到
#   ② 真门禁（假仓库 6 支单测各睡 60 秒，令牌 1 个且被外面占住）：排队时门禁整棵进程树 ≤ 6 个（主进程 + 排队 1 个及其 sleep/python + 心跳 2 个），没有一个步起来、排队登记恰 1 条
#   ④ 门禁自成一组跑着 2 步（令牌够）时整组 kill -9（gate_stop 兜底 / 外层按组 KILL 的情形；11-10 一份旧预跑因此留下 51 个孤儿占令牌 75 分钟）：
#      各步命令在 timeout 自立的组里、组 KILL 杀不到 → 收尸进程（tools/gate_reap.py）8 秒内把它们停掉，令牌全空
#   ③ 同一份门禁收到 TERM：5 秒内主进程退出、整棵树不留进程、它的排队登记 3 秒内作废（死标记，别人不再让它）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); PIDS=; bad=0
trap 'for q in $PIDS; do kill -KILL "$q" 2> /dev/null; done; rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
unset GATE_IN_STEP GATE_NO_LOADQ GATE_LAYER GATE_RERUN GATE_ONLY GATE_PLAN GATE_ROLE GATE_LEDGER
export GATE_TOKEN_DIR=$T/steptok GATE_STEP_PAR=2 GATE_TOK_POLL_S=0.2 GATE_FLOCK_PY=$H/tools/flock_hold.py
tree() { local c; for c in $(pgrep -P "$1"); do echo "$c"; tree "$c"; done; }
# ①
for i in 1 2; do bash "$H/tools/run_token.sh" sleep 20 & PIDS="$PIDS $!"; done
for i in $(seq 1 100); do [ "$(ls $T/steptok/lk.*.holder 2> /dev/null | wc -l | tr -d ' ')" = 2 ] && break; sleep 0.1; done; sleep 1
timeout 3 bash "$H/tools/run_token.sh" true; r1=$?
ck "① 两份包装占满 2 个令牌 → 第三份 3 秒内领不到（rc=${r1}）" '[ $r1 = 124 ]'
k1=${PIDS## }; k1=${k1%% *}; kill -KILL $k1; wait $k1 2> /dev/null; sleep 0.5
t0=$SECONDS; timeout 10 bash "$H/tools/run_token.sh" true; r2=$?; dt=$((SECONDS - t0))
ck "① 持有者被 kill -9 → 新的一份立刻领到（rc=${r2}，${dt} 秒）" '[ $r2 = 0 ] && [ $dt -lt 3 ]'
for q in $PIDS; do kill -KILL "$q" 2> /dev/null; done; PIDS=
# ②③
export GATE_STEP_PAR=1; mkdir -p $T/repo/tools $T/repo/tests; cp "$H/tools/gate.sh" "$H/tools/gate_plan.sh" "$H/tools/flock_hold.py" $T/repo/tools/
for i in 1 2 3 4 5 6; do printf '#!/bin/bash\nsleep 60\n' > $T/repo/tests/s${i}_test.sh; done; git init -q $T/repo
sleep 120 & hp=$!; PIDS="$PIDS $hp"; mkdir -p $T/steptok; python3 "$GATE_FLOCK_PY" "$T/steptok/lk.1" $hp take gate_tok > /dev/null
(cd $T/repo && exec env GATE_HOST=local GATE_TIER=tool GATE_CHANGED=tools/x.sh GATE_TEST_CACHE=0 GATE_LEDGER=- bash tools/gate.sh > $T/g.out 2>&1) & gp=$!; PIDS="$PIDS $gp"
for i in $(seq 1 150); do [ -n "$(ls $T/steptok/want.* 2> /dev/null)" ] && break; sleep 0.1; done; sleep 2
np=$(tree $gp | wc -l | tr -d ' '); nw=$(ls $T/steptok/want.* 2> /dev/null | wc -l | tr -d ' ')
ck "② 排队时门禁进程树 ${np} 个 ≤ 6、排队登记 ${nw} 条 = 1、没有步起来（g.out 无步结论）" '[ "$np" -le 6 ] && [ "$nw" = 1 ] && ! grep -q "单测 s" $T/g.out'
TR=$(tree $gp | tr '\n' ' '); t0=$(python3 -c 'import time; print(time.time())'); kill -TERM $gp
for i in $(seq 1 50); do kill -0 $gp 2> /dev/null || break; sleep 0.1; done; dt=$(python3 -c "import time; print(round(time.time() - $t0, 1))")
gone=$(kill -0 $gp 2> /dev/null && echo 没停 || echo 停了); sleep 1.5; left=0; for q in $TR; do kill -0 $q 2> /dev/null && left=$((left + 1)); done
live=0; for f in $T/steptok/want.*; do [ -e "$f" ] || continue; kill -0 "${f##*.}" 2> /dev/null && live=$((live + 1)); done
ck "③ TERM：${dt} 秒 ${gone}（≤ 5 秒）；原树 $(wc -w <<< "$TR" | tr -d ' ') 个进程 1.5 秒后剩 ${left} 个；活着的排队登记 ${live} 条" '[ $gone = 停了 ] && [ $left = 0 ] && [ $live = 0 ]'
# ④
kill -KILL $hp 2> /dev/null; export GATE_STEP_PAR=4; cp "$H/tools/gate_reap.py" "$H/tools/safe_killpg.sh" $T/repo/tools/; rm -f $T/repo/tests/s*_test.sh
for i in 1 2; do printf '#!/bin/bash\nexec sleep 617\n' > $T/repo/tests/k${i}_test.sh; done
(cd $T/repo && exec perl -e 'setpgrp(0, 0); exec @ARGV' env GATE_HOST=local GATE_TIER=tool GATE_CHANGED=tools/x.sh GATE_TEST_CACHE=0 GATE_LEDGER=- bash tools/gate.sh > $T/k.out 2>&1) & kp=$!
for i in $(seq 1 150); do [ "$(pgrep -fx 'sleep 617' | wc -l | tr -d ' ')" = 2 ] && break; sleep 0.1; done; n0=$(pgrep -fx 'sleep 617' | wc -l | tr -d ' ')
source "$H/tools/safe_killpg.sh"; safe_killpg KILL $kp tools/gate.sh 2> /dev/null; wait $kp 2> /dev/null   # 整组 KILL（进程组信号走 safe_killpg）
for i in $(seq 1 80); do [ -z "$(pgrep -fx 'sleep 617')" ] && break; sleep 0.1; done; n1=$(pgrep -fx 'sleep 617' | wc -l | tr -d ' ')
hl=0; for f in $T/steptok/lk.*; do case $f in *.holder) continue;; esac; python3 "$GATE_FLOCK_PY" "$f" $$ probe 2> /dev/null; [ $? = 1 ] && hl=$((hl + 1)); done
ck "④ 整组 kill -9：杀前 ${n0} 步在跑 = 2；8 秒内剩 ${n1} 个 = 0；令牌占着 ${hl} 个 = 0" '[ "$n0" = 2 ] && [ "$n1" = 0 ] && [ "$hl" = 0 ]'
pkill -fx 'sleep 617' 2> /dev/null
[ $bad = 0 ] && echo "步令牌 / 门禁排队单测全过" || { echo "步令牌 / 门禁排队单测有不通"; tail -20 $T/g.out; exit 1; }
