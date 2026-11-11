#!/bin/bash
# 手工命令占一个门禁步令牌：bash tools/run_token.sh <命令…>（手工跑的单测循环、回放等本机重活包这一层）
#   11-09 起原是「本机预跑整份令牌」（run.<号>，GATE_RUN_PAR 份）；11-10 门禁减压 C 撤掉整份令牌（门禁拿着它再排步令牌 = 持有并等待），
#   手工命令改为和门禁的步排同一池步令牌（tools/gate.sh tok_get，GATE_STEP_PAR 个、GATE_TOKEN_DIR），级 3 手工：热修 / 列车 / 预跑在排就让它们先领，同级先来先领。
#   GATE_ROLE 可改级（热修 / 列车 / 预跑 / 手工）。领到后 exec 成该命令：持锁者就是命令本身，命令结束（含 kill -9）内核即放。门禁步里嵌套（GATE_IN_STEP）不排、直接跑
[ $# -gt 0 ] || { echo "用法：bash tools/run_token.sh <命令…>"; exit 1; }
[ -n "${GATE_IN_STEP:-}" ] && exec "$@"
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(sed -n '/^# >>> step_par/,/^# <<< step_par/p' "$H/gate.sh")"   # 与门禁同一份排队代码，不另写
export GATE_FLOCK_PY=${GATE_FLOCK_PY:-$H/flock_hold.py}
case ${GATE_ROLE:-手工} in 热修) p=0;; 列车) p=1;; 预跑) p=2;; *) p=3;; esac
tk=$(tok_get $$ $p) || { echo "环境未就绪：拿不到门禁步令牌（tools/flock_hold.py 起不来）" >&2; exit 75; }
exec "$@"
