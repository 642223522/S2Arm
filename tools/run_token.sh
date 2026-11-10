#!/bin/bash
# 本机预跑整份令牌（11-09 维护方：中午几条线同时在本机预跑，负载冲到 200 多，偶发单测被挤红、读数不可信）：
#   全机同时在跑的本机预跑不超过 GATE_RUN_PAR 份（缺省 2；按本机核数 / 内存调）。tools/gate.sh 的每步令牌只限「步」，管不住几份门禁各自把步排满；
#   CPU 空闲排队只在开跑那一刻看一眼，几份同时看见空闲就一起起。这里在整份层面互斥。
#   令牌 = 内核文件锁 $GATE_RUN_TOKEN_DIR/run.<号>（缺省 ~/.s2a/gate_tokens；tools/flock_hold.py take-any）：持有者退出（含 kill -9）锁即放，不会漏。
#   领不到就排队并打「本机预跑排队中」，不硬跑。豁免：列车起的门禁（GATE_NO_LOADQ=1，优先级最高、直接跑）、门禁步里嵌套的门禁（GATE_IN_STEP，外层已占）。
#   两种用法：tools/gate.sh source 后调 runtok_take <持有者 pid>；手工跑的单测循环等：bash tools/run_token.sh <命令…>（领到后 exec 成该命令，命令结束即放）
#   优先级（11-10 维护方：入车预跑排在手工单测循环后面干等十几分钟）：门禁（tools/gate.sh 调 runtok_take）为高，排队时留 want.<pid> 标记；
#   手工命令（本文件直接运行）为低：只要有活着的高优先级在排队，空出来的令牌先让给它，低的继续等。标记的持有进程没了就作废（不会卡死低优先级）
runtok_exempt() { [ -n "${GATE_NO_LOADQ:-}" ] || [ -n "${GATE_IN_STEP:-}" ]; }
runtok_high_waiting() {   # runtok_high_waiting <令牌目录>：退 0 = 有活着的高优先级在排队（want.<pid> 且该进程还在）；死标记顺手删
  local f p hit=1; for f in "$1"/want.*; do [ -e "$f" ] || continue; p=${f##*/want.}
    if kill -0 "$p" 2> /dev/null; then hit=0; else rm -f "$f"; fi; done; return $hit; }
runtok_take() {   # runtok_take <持有者 pid> [low]：0 领到；2 持锁小进程起不来（报红，不空等）。第二参数 low = 低优先级（手工命令）
  local me=$1 low=${2:-} d=${GATE_RUN_TOKEN_DIR:-$HOME/.s2a/gate_tokens} n=${GATE_RUN_PAR:-2} i ls= r rc w0=$SECONDS lw= py
  py=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/flock_hold.py
  mkdir -p "$d" || return 2
  for i in $(seq 1 "$n"); do ls="$ls${ls:+:}$d/run.$i"; done
  [ -n "$low" ] || : > "$d/want.$me"
  while :; do
    if [ -n "$low" ] && runtok_high_waiting "$d"; then rc=1
    else r=$(python3 "$py" "$ls" "$me" take-any gate_run 2> /dev/null); rc=$?; fi
    if [ $rc = 0 ]; then
      rm -f "$d/want.$me"
      printf '%s\n' "$me" > "${r#*$'\t'}.holder" 2> /dev/null
      [ -n "$lw" ] && echo "本机预跑排队结束：等了 $((SECONDS - w0)) 秒" >&2
      return 0
    fi
    [ $rc = 1 ] || { rm -f "$d/want.$me"; echo "【红】本机预跑令牌：持锁小进程起不来（flock_hold.py 返回 ${rc}）" >&2; return 2; }
    if [ -z "$lw" ] || [ $((SECONDS - lw)) -ge 60 ]; then lw=$SECONDS; echo "本机预跑排队中：${n} 个令牌全被占（${d}），已等 $((SECONDS - w0)) 秒" >&2; fi
    sleep "${GATE_RUN_POLL_S:-2}"
  done; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -gt 0 ] || { echo "用法：bash tools/run_token.sh <命令…>"; exit 1; }
  runtok_exempt || runtok_take $$ low || exit 75   # 手工命令 = 低优先级：有入车预跑在排队就让它先领
  exec "$@"
fi
