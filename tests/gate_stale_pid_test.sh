#!/bin/bash
# 门禁覆盖：tools/gate.sh tools/gate_reap.py
# 门禁不对「已经跑完的步」记下的进程号发信号（11-11 合入运维线：入队预检里 cores_lanes_test 本机 1 秒全通，却被不知谁的 SIGTERM 杀成 rc=143、误撤一支）。
#   根因：本机每秒新建约 1250 个进程，进程号约 80 秒转一圈；门禁每步把 timeout 的进程号写进 $L/<步>.tp，步跑完不删——
#   门禁收到 TERM（gate_stop / 外层时限 / 单测停假门禁）时 trap 对所有 *.tp 逐个 kill -TERM，收尸进程 gate_reap.py 对 *.tp 里命令行带 bash / timeout / sleep 的也发，
#   早跑完那些步的进程号此刻已分给别的进程（别的单测、别的会话），就被打中。
# 期望按规则手写（不调被测函数推）：
#   ① 快步 a 跑完后它的 .tp 不在（只留活着的步的进程号）；慢步 b 在跑时它的 .tp 在
#   ② TERM 门禁主进程：在跑的 b 被停；冒充「跑完的步、进程号被复用」的诱饵进程（bash -c sleep）不受影响
#   ③ 收尸：门禁主进程被 KILL、结果目录留着，诱饵 pid 写进一份 .tp（模拟陈旧记录）→ 诱饵仍活（命令行里没有本份结果目录）；在跑的 b 被收掉
# 反证：S2A_GATE_SH=<旧 gate.sh> S2A_GATE_REAP=<旧 gate_reap.py> 跑应红（① a 的 .tp 留着、③ 诱饵被杀）
set -u; A= LD= AI= BI=; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); bad=0; GS=${S2A_GATE_SH:-$H/tools/gate.sh}; GR=${S2A_GATE_REAP:-$H/tools/gate_reap.py}; PIDS=
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
trap 'cat $T/g.out 2> /dev/null | tail -5 >&2; for q in $PIDS; do kill -KILL "$q" 2> /dev/null; done; pkill -KILL -f "$T/" 2> /dev/null; rm -rf "$T"' EXIT
unset GATE_TIER GATE_CHANGED GATE_PLAN GATE_OUT GATE_HOST GATE_REV GATE_REMOTE_NAME GATE_SKIP GATE_ONLY GATE_HOOK_S GATE_LAYER GATE_TEST_CACHE GATE_RERUN GATE_LIST GATE_IN_STEP GATE_ROLE
export GATE_NO_LOADQ=1 HOME=$T/home TMPDIR=$T/tmp PATH="$H/tools/bin:$PATH" GATE_NOSTALL_S=0 GATE_DET_STOP=0
mkdir -p $T/home $T/tmp $T/repo/tools $T/repo/a $T/repo/b; cd $T/repo || exit 1
git init -q; git config user.email t@t; git config user.name t
cp "$GS" tools/gate.sh; cp $H/tools/gate_decl.py $H/tools/safe_killpg.sh tools/; cp "$GR" tools/gate_reap.py
printf '#!/bin/bash\necho a 过\n' > a/gate.sh
printf '#!/bin/bash\necho b 起; ps -ww -o command= -p $PPID | grep -o "/[^ ]*[.]pg" | head -1 > %s/b.pg; touch %s/b.up; exec sleep 120\n' "$T" "$T" > b/gate.sh   # 结果目录 = 步命令行里 .pg 所在目录（mktemp -d 在 macOS 不认 TMPDIR）
git add -A; git commit -qm 1
decoy() { bash -c 'exec -a "bash -c sleep 300" sleep 300' > /dev/null 2>&1 < /dev/null & d=$!; PIDS="$PIDS $d"; }
up() {   # 起一份门禁，等 a 出结论、b 起来；回显结果目录
  rm -f $T/b.up $T/b.pg; (exec bash tools/gate.sh > $T/g.out 2>&1) & G=$!; PIDS="$PIDS $G"
  for _ in $(seq 150); do
    if [ -e $T/b.up ]; then LD=$(dirname "$(cat $T/b.pg)"); A=$(grep -l '^a 过' "$LD"/*.log 2> /dev/null | head -1); [ -n "$A" ] && [ -f "${A%.log}.rc" ] && break; fi; sleep 0.2; done
  AI=${A##*/}; AI=${AI%.log}; BI=$(grep -l '^b 起' "$LD"/*.log | head -1); BI=${BI##*/}; BI=${BI%.log}; }
# ①②
up; bt=$(cat "$LD/$BI.tp" 2> /dev/null)
ck "① 快步 a 跑完后 .tp 不在（a=${AI}，目录 $(ls "$LD" | grep '\.tp$' | tr '\n' ' ')）" '[ -n "$AI" ] && [ ! -e "$LD/$AI.tp" ]'
ck "① 慢步 b 在跑、它的 .tp 在（b=${BI}，pid ${bt}）" '[ -n "$bt" ] && kill -0 "$bt" 2> /dev/null'
decoy; sleep 0.3; [ -e "$LD/$AI.tp" ] && echo $d > "$LD/$AI.tp"   # a 的进程号被复用给诱饵：a 的 .tp 还在就指向它
kill -TERM $G; for _ in $(seq 50); do kill -0 $G 2> /dev/null || break; sleep 0.2; done
ck "② TERM 门禁：在跑的 b 被停" '! kill -0 "$bt" 2> /dev/null'
ck "② 诱饵（假装复用了跑完步的进程号）不受影响" 'kill -0 $d 2> /dev/null'
kill -KILL $d 2> /dev/null; rm -rf "$LD"
# ③ 收尸：主进程被 KILL、结果目录留着；诱饵 pid 写进陈旧 .tp
up; bt=$(cat "$LD/$BI.tp" 2> /dev/null); decoy; sleep 0.3; echo $d > "$LD/99.tp"
kill -KILL $G; for _ in $(seq 75); do kill -0 "$bt" 2> /dev/null || break; sleep 0.2; done; sleep 1
ck "③ 收尸：在跑的 b（pid ${bt}）被收掉" '[ -n "$bt" ] && ! kill -0 "$bt" 2> /dev/null'
ck "③ 收尸：陈旧 .tp 指向的诱饵（命令行没有本份结果目录）仍活" 'kill -0 $d 2> /dev/null'
[ $bad = 0 ] && echo "gate_stale_pid 单测全过" || { echo "gate_stale_pid 单测有不通"; exit 1; }
