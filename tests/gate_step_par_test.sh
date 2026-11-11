#!/bin/bash
# 门禁覆盖：tools/gate.sh
# tools/gate.sh 全机步数上限 + 超时未判 单测（11-04 合入运维线）。期望值按规则手写：
#   ① 令牌 2 个、6 步各停住等放行 → 只有 2 步报到、账本 2 个活持有者、4 步排队；排队步 .rc 秒数只算拿到令牌后，不含排队（按时刻比：.rc 写入时刻 − 秒数 ≥ 放行时刻 − 1）
#   ② 负对照：令牌 100 个 → 不放行 6 步也全部报到（证明 ① 的 2 是令牌限的）
#   ③ 持有者被 kill -9 → 内核放锁，照常拿到
#   ⑧ 持有令牌的步被 kill -9：3 秒内令牌空出，别人立刻拿到（11-04 gate-host 漏令牌回归）
#   ④ 排队期间本份早停（$L/stop 在）→ 不开跑，.rc 记 143，命令没执行
#   ⑥ 不设 GATE_STEP_PAR：缺省 = 核数 × 2/3（12 核 → 8）
#   ⑦ 嵌套：步里（GATE_IN_STEP 在）再起的步不拿令牌——令牌池被活进程占满时照样立刻开跑；开跑的步里能看到 GATE_IN_STEP
#   11-10 门禁减压 C：令牌改由调用者（门禁主进程）逐步排、拿到才起步子 shell，持锁者 = 调用者；① 改判「只起 2 步、排队者只有 1 个」，④ 早停不靠放令牌，
#   ⑧ 拆成「持锁者（门禁主进程）被 kill -9 → 3 秒内空出」与「步被 kill -9 → 收尾 tok_putall 放」；⑨ 级与先来后到
#   ⑤ show：跑满上限的 124 → 🟡 超时未判、返回 3、记进 $L/timeouts；没到上限的 124、普通失败 → 🔴 返回 1；0 → 🟢 返回 0
set -u; unset GATE_IN_STEP   # 本单测自己就在门禁的一步里跑：先清掉外层带进来的「在步里」标记
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/t_gate_par.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
chk() { if [ "$2" = "$3" ]; then echo "🟢 $1"; else echo "🔴 $1：期望「$2」→ 真结果「$3」"; bad=1; fi; }
export GATE_FLOCK_PY=$H/tools/flock_hold.py   # 令牌 = 内核文件锁（tools/flock_hold.py）；单测不在仓库根跑，给绝对路径
held() { local i o=; for i in $(seq 1 "${2:-8}"); do python3 "$GATE_FLOCK_PY" "$1/lk.$i" $$ probe 2> /dev/null; [ $? = 1 ] && o="$o lk.$i"; done; echo "${o# }"; }   # 被持有的锁
occupy() { mkdir -p "$1"; python3 "$GATE_FLOCK_PY" "$1/lk.$2" "$3" take gate_tok > /dev/null; }   # occupy <令牌目录> <号> <持有者 pid>：替它占一把
eval "$(sed -n '/^# >>> step_par/,/^# <<< step_par/p;/^# >>> show/,/^# <<< show/p' "$H/tools/gate.sh")"
# ①② 按事件判，不靠时间重叠（11-05 维护者：机器忙时「同时跑了几步」会抖）：每步开跑先报到 in.<号>，停住直到放行文件 go.<号>（最多 60 秒）。
#   ① 令牌 2：等报到满 2 个后再看 5 秒，报到数仍是 2、令牌账本恰好 t.1 t.2 两个活持有者、其余 4 步活着在排队；令牌坏了 6 步会全部报到 → 红。
#      计时口径按时刻比、不按秒数阈值（11-05 合入运维线：原判据「排队步秒数 < 4」是墙钟，负载高时开跑后的步本身就可能跑过 4 秒）：
#      排队步只能在放行（记下时刻 tr）之后拿到令牌，故计时起点 s0 ≥ tr；.rc 秒数 = $SECONDS 整数差 < 真耗时 + 1 → 「.rc 写入时刻 − 秒数」> s0 − 1 ≥ tr − 1，任何负载都成立。
#      若把排队算进去（s0 = 起步时刻，在报到满 2 个、再等 5 秒之前），推出的起点 < tr − 4 → 红
#   ② 令牌 100：6 步不放行也能全部报到（30 秒内）= 6 步同时持有
holdjob() { GATE_STEP_PAR=$1 GATE_TOKEN_DIR=$T/tok.$2 job "s$3" ": > $L/in.$3; n=0; while [ ! -e $L/go.$3 ] && [ \$n -lt 600 ]; do sleep 0.1; n=\$((n + 1)); done" 60; }
cnt() { ls $L/in.* 2> /dev/null | wc -l | tr -d ' '; }
waitc() { local i; for i in $(seq 1 300); do [ "$(cnt)" -ge "$1" ] && return 0; sleep 0.1; done; return 1; }
L=$T/a; mkdir -p "$L"; ( LJ=(); TKS=(); for i in 1 2 3 4 5 6; do holdjob 2 a $i; done; wait "${LJ[@]}" ) & DP=$!
waitc 2; sleep 3; c1=$(cnt); hl=$(held $T/tok.a 2); nw=$(ls $T/tok.a/want.* 2> /dev/null | wc -l | tr -d ' '); ns=$(ls $L/*.started 2> /dev/null | wc -l | tr -d ' ')
first=$(ls $L/in.* | sed 's/.*in\.//' | tr '\n' ' '); tr=$(python3 -c 'import time; print(time.time())'); for i in 1 2 3 4 5 6; do : > $L/go.$i; done
wait $DP; qf=(); for i in 1 2 3 4 5 6; do case " $first " in *" $i "*) ;; *) qf+=("$L/s$i.rc");; esac; done   # 不在 $(…) 里写 case：bash 3.2（语法门禁）解析不了
#   每个排队步：起点 = .rc 写入时刻 − .rc 秒数，须 > 放行时刻 − 1；不满足的列「步:起点−放行时刻」
qs=$(python3 -c 'import os, sys
tr = float(sys.argv[1]); bad = []
for f in sys.argv[2:]:
    st = os.stat(f).st_mtime - int(open(f).read().split()[1])
    if st <= tr - 1: bad.append("%s:%+.1f" % (os.path.basename(f), st - tr))
print("是" if len(sys.argv) > 2 and not bad else "否:" + (",".join(bad) or "没有排队步"))' "$tr" ${qf[@]+"${qf[@]}"})
chk "① 令牌 2：报到 2 个、再等 3 秒仍 2 个；账本 2 个活持有者；只起了 2 步、排队者只有 1 个（不是每步一个）；排队步计时起点不早于放行时刻" "2|lk.1 lk.2|2|1|是" "$c1|$hl|$ns|$nw|$qs"
L=$T/b; mkdir -p "$L"; LJ=(); for i in 1 2 3 4 5 6; do holdjob 100 b $i; done; waitc 6; c2=$(cnt); for i in 1 2 3 4 5 6; do : > $L/go.$i; done; wait "${LJ[@]}"
chk "② 负对照：令牌 100 → 不放行 6 步也全部报到（同时持有）" 6 "$c2"
L=$T/c; mkdir -p "$L"; sleep 30 & hp=$!; occupy $T/tok.c 1 $hp; kill -9 $hp; wait $hp 2> /dev/null; LJ=()
GATE_STEP_PAR=1 GATE_TOKEN_DIR=$T/tok.c job x "echo ran > $L/ran" 30; wait "${LJ[@]}"
chk "③ 持有者被 kill -9 → 锁随之放：步照常跑完、事后令牌空闲" "ran 0 空" "$(cat $L/ran 2> /dev/null) $(cut -d' ' -f1 $L/x.rc) $(h=$(held $T/tok.c 1); echo ${h:-空})"
L=$T/d; mkdir -p "$L"; sleep 30 & hp=$!; occupy $T/tok.d 1 $hp
( LJ=(); GATE_TOK_POLL_S=0.2 GATE_STEP_PAR=1 GATE_TOKEN_DIR=$T/tok.d job y "echo ran > $L/ran" 30; wait ${LJ[@]+"${LJ[@]}"} ) & DP=$!; sleep 1.5; : > "$L/stop"
for i in $(seq 1 50); do kill -0 $DP 2> /dev/null || break; sleep 0.1; done; dw=$(kill -0 $DP 2> /dev/null && echo 还在排 || echo 已收); kill $hp; wait $hp 2> /dev/null; wait $DP 2> /dev/null
chk "④ 排队期间早停 → 令牌仍被占也 5 秒内收手、不开跑、记 143" "已收 143 没跑" "$dw $(cut -d' ' -f1 $L/y.rc) $([ -e $L/ran ] && echo 跑了 || echo 没跑)"
L=$T/e; mkdir -p "$L"; for k in to:124\ 600 own:124\ 30 fail:1\ 5 ok:0\ 3; do n=${k%%:*}; echo "${k#*:}" > $L/$n.rc; echo "末行 $n" > $L/$n.log; done
CUR=测; r() { show "" "$1" "单测 $1" 600 > $L/$1.out; echo "$? $(python3 -c 'import sys; print(open(sys.argv[1], encoding="utf-8").read()[:1])' $L/$1.out)"; }
chk "⑤ show：用满上限 124 → 超时未判 3；没到上限 124 / 失败 → 红 1；0 → 绿 0；timeouts 只记超时那步" \
  "3 🟡|1 🔴|1 🔴|0 🟢|单测 to|有" "$(r to)|$(r own)|$(r fail)|$(r ok)|$(cat $L/timeouts)|$(grep -q 超时未判 $L/to.out && echo 有)"
# ⑥ 缺省令牌数 = 核数 × 2/3：假 sysctl 报 12 核 → 前 8 个令牌立刻拿到，第 9 个排队（3 秒内拿不到）
mkdir -p $T/bin; printf '#!/bin/bash\necho 12\n' > $T/bin/sysctl; chmod +x $T/bin/sysctl; got=0
for i in $(seq 1 8); do PATH=$T/bin:$PATH GATE_TOKEN_DIR=$T/tok.f tok_get $$ > /dev/null && got=$((got + 1)); done
( PATH=$T/bin:$PATH; GATE_TOKEN_DIR=$T/tok.f; export PATH GATE_TOKEN_DIR; timeout 3 bash -c "$(declare -f tok_get tok_ahead); tok_get $$" > /dev/null ); r9=$?
chk "⑥ 缺省（12 核）→ 8 个令牌，第 9 个排队" "8 124" "$got $r9"
# ⑦ 嵌套不占令牌（11-04 首次自检：外层占满令牌、单测里的门禁等内层令牌 → 互等到超时）
L=$T/g; mkdir -p "$L"; sleep 30 & hp=$!; occupy $T/tok.g 1 $hp; LJ=()
( export GATE_IN_STEP=1; GATE_STEP_PAR=1 GATE_TOKEN_DIR=$T/tok.g job n 'echo "$GATE_IN_STEP" > '"$L"'/seen' 10; wait "${LJ[@]}" ); hg=$(held $T/tok.g 1); kill $hp; wait $hp 2> /dev/null
chk "⑦ 步里再起的步：令牌占满仍立刻跑完、步内可见标记、占用者的锁仍被持有" "0 1 lk.1" "$(cut -d' ' -f1 $L/n.rc 2> /dev/null) $(cat $L/seen 2> /dev/null) $hg"
# ⑧ 令牌不漏（11-04 18:0x gate-host：mkdir 到写 pid 之间被杀的步留下空令牌目录永远收不回，8 个漏 4 个）
#   a 持锁者（调用 job 的门禁主进程）被 kill -9：3 秒内锁空出来、别人立刻拿得到
L=$T/h; mkdir -p "$L"; ( LJ=(); GATE_STEP_PAR=1 GATE_TOKEN_DIR=$T/tok.h job z "sleep 30" 40; wait "${LJ[@]}" ) & DP=$!
for i in $(seq 1 100); do [ "$(held $T/tok.h 1)" = lk.1 ] && [ -s $L/z.tp ] && break; sleep 0.1; done; h1=$(held $T/tok.h 1)
disown $DP 2> /dev/null; kill -9 $DP; tp=$(cat $L/z.tp 2> /dev/null); [ -n "$tp" ] && { pkill -9 -P "$tp" 2> /dev/null; kill -9 "$tp" 2> /dev/null; }
for i in $(seq 1 30); do [ -z "$(held $T/tok.h 1)" ] && break; sleep 0.1; done
r8=$( ( GATE_STEP_PAR=1 GATE_TOKEN_DIR=$T/tok.h; export GATE_STEP_PAR GATE_TOKEN_DIR; timeout 3 bash -c "$(declare -f tok_get tok_ahead); tok_get \$\$" > /dev/null ); echo $? )
chk "⑧a 持锁者被 kill -9：杀前锁被持有、杀后 3 秒内空出、别人立刻拿到" "lk.1 空 0" "${h1:-空} $(h=$(held $T/tok.h 1); echo ${h:-空}) $r8"
#   b 步子 shell 被 kill -9（没走到自己的放令牌）：门禁主进程还在时令牌仍占着，收尾 tok_putall 后 3 秒内空出
L=$T/i; mkdir -p "$L"; LJ=(); TKS=(); GATE_STEP_PAR=1 GATE_TOKEN_DIR=$T/tok.i job z "sleep 30" 40; zp=${LJ[0]}
for i in $(seq 1 100); do [ -s $L/z.tp ] && break; sleep 0.1; done
disown "$zp" 2> /dev/null; kill -9 "$zp"; tp=$(cat $L/z.tp 2> /dev/null); [ -n "$tp" ] && { pkill -9 -P "$tp" 2> /dev/null; kill -9 "$tp" 2> /dev/null; }; sleep 0.5
hb=$(held $T/tok.i 1); tok_putall; for i in $(seq 1 30); do [ -z "$(held $T/tok.i 1)" ] && break; sleep 0.1; done
chk "⑧b 步被 kill -9：令牌仍在 → tok_putall 后空出" "lk.1 空" "${hb:-空} $(h=$(held $T/tok.i 1); echo ${h:-空})"
# ⑨ 级与先来后到（11-10 门禁减压 C：热修只绕过外层排队、步令牌照样被预跑占满）：唯一令牌被占，依次起 手工(3)、预跑(2)甲、预跑(2)乙、热修(0) 四个排队者
#   （各隔 1.1 秒，开始秒不同），放令牌后各领到即记名、占 0.3 秒再放 → 领到顺序 热修 甲 乙 手工；活着的高级排队者没了（死标记）不挡低级
L=$T/j; mkdir -p "$L"; sleep 60 & hp=$!; occupy $T/tok.j 1 $hp; : > $L/order; WP=()
for w in 3:手工 2:甲 2:乙 0:热修; do ( GATE_STEP_PAR=1 GATE_TOKEN_DIR=$T/tok.j GATE_TOK_POLL_S=0.2; export GATE_STEP_PAR GATE_TOKEN_DIR GATE_TOK_POLL_S
  tok_get $BASHPID ${w%%:*} > /dev/null && { echo "${w#*:}" >> $L/order; sleep 0.3; } ) & WP+=($!)
  k=${#WP[@]}; for i in $(seq 1 300); do [ "$(ls $T/tok.j/want.* 2> /dev/null | wc -l | tr -d ' ')" -ge $k ] && break; sleep 0.1; done; sleep 1.1; done   # 等它登记好再起下一个（负载高时登记会晚）
kill $hp; wait $hp 2> /dev/null; wait "${WP[@]}"
touch $T/tok.j/want.0.1.999999; r9=$( ( GATE_STEP_PAR=1 GATE_TOKEN_DIR=$T/tok.j; export GATE_STEP_PAR GATE_TOKEN_DIR; timeout 5 bash -c "$(declare -f tok_get tok_ahead); tok_get \$\$ 3" > /dev/null ); echo $? )
chk "⑨ 领到顺序按级、同级先来先领；死的高级标记不挡、且被清掉" "热修 甲 乙 手工|0|清了" "$(tr '\n' ' ' < $L/order | sed 's/ $//')|$r9|$([ -e $T/tok.j/want.0.1.999999 ] && echo 还在 || echo 清了)"
# ⑩ detwait 不被复用的进程号拖住（11-10 启动器线：步结论都落盘了，主进程因进程号被别的进程复用空等约 10 分钟）：
#   LJ 里放一个活着但不是步的进程（本单测自己），该步 .rc 已落盘 → detwait 3 秒内返回
L=$T/k; mkdir -p "$L"; eval "$(sed -n '/^detcheck() {/,/tok_putall; }$/p' "$H/tools/gate.sh")"; N=1; STEPS=("单测 x	true	10"); DET='语法'; LJ=($$); LJN=(1); TKS=(); echo "0 1" > $L/1.rc
( detwait; echo 正常返回 > $L/dw ) & dwp=$!; for i in $(seq 1 30); do kill -0 $dwp 2> /dev/null || break; sleep 0.1; done; dw=$(kill -0 $dwp 2> /dev/null && echo 还在等 || cat $L/dw 2> /dev/null || echo 出错退出); kill $dwp 2> /dev/null; wait $dwp 2> /dev/null
chk "⑩ 步结论已落盘、进程号被别的活进程占着 → detwait 3 秒内正常返回" 正常返回 "$dw"
# ⑬ 步的进程组组长命令行里始终带着 .pg 路径（收尸进程按它认组；bash 5 会把 -c 串最后一条命令 exec 掉，11-11 门禁机上列车红）：用 PATH 上的 bash
L=$T/n; mkdir -p "$L"; LJ=(); TKS=(); GATE_STEP_PAR=4 GATE_TOKEN_DIR=$T/tok.n job lead "sleep 5" 30
for i in $(seq 1 50); do [ -s $L/lead.pg ] && break; sleep 0.1; done; sleep 0.3; lc=$(ps -ww -o command= -p "$(cat $L/lead.pg 2> /dev/null)" 2> /dev/null); wait "${LJ[@]}"
chk "⑬ 组长命令行带 .pg 路径（$(bash --version | head -1 | cut -c1-30)；组长：${lc:0:60}）" 有 "$([[ "$lc" == *"$L/lead.pg"* ]] && echo 有)"
[ $bad = 0 ] && echo "门禁步数上限 / 超时未判单测全绿" || { echo "门禁步数上限 / 超时未判单测有红"; exit 1; }
