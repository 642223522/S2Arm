#!/bin/bash
# 门禁覆盖：tools/gate.sh
# 远端结果按步认 + 退回上限 + 收尾限时（11-11 合入运维线：门禁机上推测批 154 步 13:24 前全出结论，远端主进程又等了 50 分钟到时限 rc=124、没写 done，
#   本机把 154 步整份当「门禁机不可用」扔掉重跑 74 分钟）。假仓库三个钩子 a b c 全派门禁机，私有工具目录里 remote.sh 桩：按 --pull 把前 K 步的结论写进拉回目录、不写 done、退出 124。
#   期望按规则手写：
#   派门禁机的共 4 步（语法 + a b c，远端编号 1–4）。① K=3：语法 a b 用远端结论（本机不跑），只 c 退回本机补跑；输出「3 步已有结论、照用，只 1 步没结论」
#   ② K=4：四步都用远端结论，本机一步不跑，门禁绿（退出 0）
#   ③ K=0、GATE_FALLBACK_MAX=1：要退回 4 步超过上限 → 本机一步不跑、退出 75（环境未就绪）
#   ⑤ 远端比本机步慢：桩 5 秒后才交出 4 步结论（写 done）、GATE_TAIL_WAIT_S=1 → 跑远端的子 shell 不被当拖尾收掉，结论照用、本机不跑、绿
#      （11-11 73d022d6b 首版把它收掉：远端被 TERM、每批环境未就绪）
#   ④ 收尾限时：主进程有个 30 秒不退的子进程、GATE_TAIL_WAIT_S=2 → tailwait 几秒内返回、日志点名它、它被收掉
# 反证：S2A_GATE_SH=<旧 gate.sh> 跑应红（① a b 也在本机重跑；② 整份本机跑；③ 本机补跑；④ 没有 tailwait）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); bad=0; GS=${S2A_GATE_SH:-$H/tools/gate.sh}
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
trap 'rm -rf "$T"' EXIT
unset GATE_TIER GATE_CHANGED GATE_PLAN GATE_OUT GATE_REV GATE_REMOTE_NAME GATE_SKIP GATE_ONLY GATE_HOOK_S GATE_LAYER GATE_TEST_CACHE GATE_RERUN GATE_LIST GATE_IN_STEP GATE_ROLE \
  S2A_REMOTE S2A_REMOTE_HOSTS S2A_REMOTE_DEFAULT S2A_MACHINE_NO_LOCAL GATE_FALLBACK_MAX GATE_TAIL_WAIT_S
export GATE_NO_LOADQ=1 HOME=$T/home GATE_NOSTALL_S=0 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
mkdir -p $T/home $T/p $T/m/tools $T/m/a $T/m/b $T/m/c; cd $T/m || exit 1; git init -q -b main
cp "$GS" tools/gate.sh; cp $H/tools/gate_decl.py $H/tools/machine.sh tools/
for x in a b c; do printf '#!/bin/bash\necho %s >> %s/trace; echo %s 过\n' $x "$T" $x > $x/gate.sh; done
printf 'tools/machine.local\n' > .gitignore; git add -A; git commit -qm base; git update-ref refs/remotes/origin/main HEAD
printf 'S2A_REMOTE_HOSTS=fakehost\n' > $T/p/machine.local
cat > $T/p/remote.sh <<'R'
#!/bin/bash
while [ $# -gt 0 ]; do case $1 in --pull) d=${2#*=}; shift 2;; --) break;; *) shift;; esac; done
sleep ${STUB_SLEEP:-0}; mkdir -p "$d"; [ -n "${STUB_DONE:-}" ] && cp "$d/../nonce" "$d/done" 2> /dev/null; for m in $(seq 1 ${STUB_K:-0}); do echo "0 1" > "$d/$m.rc"; echo "远端 第 $m 步 过" > "$d/$m.log"; done
echo "remote：rc=124；桩：远端主进程没退出、到时限" ; exit 124
R
export S2A_PRIVATE_TOOLS=$T/p S2A_MACHINE_LOCAL=$T/p/machine.local
run() { rm -f $T/trace; (GATE_HOST=gate-host timeout 120 bash tools/gate.sh > $T/out 2>&1); echo $?; }
r=$(STUB_K=3 run)
ck "① K=3：语法 a b 用远端、只 c 本机补跑（本机跑了：$(tr '\n' ' ' < $T/trace 2> /dev/null)，rc=${r}）" '[ "$(cat $T/trace 2> /dev/null)" = c ] && grep -q "3 步已有结论、照用，只 1 步没结论" $T/out'
r=$(STUB_K=4 run)
ck "② K=4：四步都用远端、本机不跑、绿（rc=${r}）" '[ "$r" = 0 ] && [ ! -e $T/trace ]'
r=$(STUB_K=0 GATE_FALLBACK_MAX=1 run)
ck "③ K=0、上限 1：本机不跑、退出 75（rc=${r}）" '[ "$r" = 75 ] && [ ! -e $T/trace ] && grep -q "超过上限 1" $T/out'
r=$(STUB_K=4 STUB_SLEEP=5 GATE_TAIL_WAIT_S=1 run)
ck "⑤ 远端慢 5 秒、收尾限时 1 秒：远端子 shell 不被收掉，结论照用、本机不跑、绿（rc=${r}）" '[ "$r" = 0 ] && [ ! -e $T/trace ] && ! grep -q "秒不退，收掉" $T/out'
# ④ tailwait 抽出来跑
eval "$(sed -n '/^tailwait() {/,/^  wait 2> \/dev\/null; }$/p' "$GS")"
o=$(bash -c "$(declare -f tailwait 2> /dev/null); sleep 30 & sp=\$!; echo \$sp > $T/sp; t0=\$SECONDS; GATE_TAIL_WAIT_S=2 tailwait; echo 用时 \$((SECONDS - t0))" 2>&1)
sp=$(cat $T/sp 2> /dev/null); u=$(sed -n 's/.*用时 \([0-9]*\).*/\1/p' <<< "$o")
ck "④ 收尾限时：${u:-?} 秒返回、点名并收掉 30 秒的子进程" '[ -n "$u" ] && [ "$u" -le 8 ] && grep -q "秒不退，收掉：.*sleep 30" <<< "$o" && ! kill -0 "$sp" 2> /dev/null'
[ $bad = 0 ] && echo "gate_remote_partial 单测全过" || { echo "gate_remote_partial 单测有不通"; tail -6 $T/out; exit 1; }
