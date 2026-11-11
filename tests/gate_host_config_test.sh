#!/bin/bash
# 门禁覆盖：tools/gate.sh tools/machine.sh
# 派门禁机配置自找、找不到红停（11-11 合入运维线：只设 GATE_HOST=gate-host、漏带 S2A_PRIVATE_TOOLS / machine.local，原先悄悄退回本机跑——同一个坑一天三次）：
#   假主检出 M + 它的工作树 W（W 里没有 tools/machine.local），私有工具目录 P 里放 remote.sh 桩（记下 S2A_MACHINE_LOCAL、报不可用退出 125）。期望按规则手写：
#   ① 什么都不导出：从主检出 M/tools/machine.local 读到 S2A_PRIVATE_TOOLS=P，门禁机地址取 P/machine.local → 桩被调、带 S2A_MACHINE_LOCAL=P/machine.local；本机一步不跑
#   ② 主检出也没有 machine.local（找不到私有工具）→ 退出 2、「门禁机配置缺失」、桩没被调、本机一步不跑
#   ③ 找得到私有工具、但哪份 machine.local 都配不出门禁机地址 → 退出 2、点名「门禁机地址」、本机一步不跑
# 反证：S2A_GATE_SH=<旧 gate.sh> 跑应红（① 整份本机跑、桩没被调；② ③ 不是退出 2）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); bad=0; GS=${S2A_GATE_SH:-$H/tools/gate.sh}
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
trap 'git -C $T/m worktree remove --force $T/w > /dev/null 2>&1; rm -rf "$T"' EXIT
unset GATE_TIER GATE_CHANGED GATE_PLAN GATE_OUT GATE_REV GATE_REMOTE_NAME GATE_SKIP GATE_ONLY GATE_HOOK_S GATE_LAYER GATE_TEST_CACHE GATE_RERUN GATE_LIST GATE_IN_STEP GATE_ROLE \
  S2A_PRIVATE_TOOLS S2A_MACHINE_LOCAL S2A_REMOTE S2A_REMOTE_HOSTS S2A_REMOTE_DEFAULT S2A_MACHINE_NO_LOCAL
export GATE_NO_LOADQ=1 HOME=$T/home GATE_FALLBACK_LOCAL=0 GATE_NOSTALL_S=0 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
mkdir -p $T/home $T/p $T/m/tools $T/m/a; cd $T/m || exit 1; git init -q -b main
cp "$GS" tools/gate.sh; cp $H/tools/gate_decl.py $H/tools/machine.sh tools/
printf '#!/bin/bash\necho a >> %s/trace; echo a 过\n' "$T" > a/gate.sh
printf 'tools/machine.local\n' > .gitignore; git add -A; git commit -qm base
git update-ref refs/remotes/origin/main HEAD; git worktree add -q --detach $T/w HEAD
printf '#!/bin/bash\necho "${S2A_MACHINE_LOCAL:-没给}" >> %s/remote.called\necho "【红】remote：桩，报不可用" >&2; exit 125\n' "$T" > $T/p/remote.sh
printf 'S2A_REMOTE_HOSTS=fakehost\n' > $T/p/machine.local
run() { rm -f $T/trace $T/remote.called; (cd $T/w && GATE_HOST=gate-host timeout 120 bash tools/gate.sh > $T/out 2>&1); echo $?; }
# ①
printf "S2A_PRIVATE_TOOLS=%s\n" "$T/p" > $T/m/tools/machine.local
r=$(run)
ck "① 不导出也自找：桩被调（$(cat $T/remote.called 2> /dev/null || echo 没调)）、带 P/machine.local、本机一步不跑（rc=${r}）" '[ "$(cat $T/remote.called 2> /dev/null)" = "$T/p/machine.local" ] && [ ! -e $T/trace ]'
# ②
rm $T/m/tools/machine.local; r=$(run)
ck "② 找不到私有工具 → 退出 2、配置缺失、桩没调、本机不跑（rc=${r}）" '[ "$r" = 2 ] && grep -q "门禁机配置缺失" $T/out && [ ! -e $T/remote.called ] && [ ! -e $T/trace ]'
# ③
printf "S2A_PRIVATE_TOOLS=%s\n" "$T/p" > $T/m/tools/machine.local; : > $T/p/machine.local; r=$(run)
ck "③ 配不出门禁机地址 → 退出 2、点名门禁机地址、本机不跑（rc=${r}）" '[ "$r" = 2 ] && grep -q "门禁机地址" $T/out && [ ! -e $T/trace ]'
[ $bad = 0 ] && echo "gate_host_config 单测全过" || { echo "gate_host_config 单测有不通"; tail -5 $T/out; exit 1; }
