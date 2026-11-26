#!/bin/bash
# 重录直连图形层的剖析数据 graphics/nvn/pgo/nvn.prof.txt（PGO，graphics/nvn/pgo/README.md）：
#   bash tools/pgo_record.sh <款> <录像目录> [<款> <录像目录> …]
#   在 HEAD 的临时工作树里编插桩版宿主（S2A_PGO_GEN=1；回放时也要带，frame_replay.sh 会先 make host，不带就编回普通版），把每份帧录像回放 S2A_PGO_PASSES 遍（缺省 200），合并计数写回本树的 nvn.prof.txt（文本格式）。
#   不在本树编插桩版：同树别的局 / 测速用的是本树 build/s2arm-host，插桩版会把它们的读数拖慢。录像与产物根同 tools/frame_replay.sh（S2A_ROOTS / S2A_ROOT_TAG）。
#   什么时候重录：回放层热路径（每笔绘制走的那几个函数）改过以后。不重录也不出错，只是改过的函数按无剖析编（clang 按函数核对源码指纹）。
set -u
[ $# -ge 2 ] && [ $(($# % 2)) = 0 ] || { echo "用法：bash tools/pgo_record.sh <款> <录像目录> [<款> <录像目录> …]"; exit 2; }
R=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/s2a-pgo.XXXXXX") || exit 2
trap 'git -C "$R" worktree remove --force "$W/tree" > /dev/null 2>&1; rm -rf "$W"' EXIT
fail() { trap - EXIT; echo "🔴 $1（临时目录留着看日志：${W}；看完 git -C $R worktree remove --force ${W}/tree && rm -rf ${W}）"; exit 1; }
git -C "$R" worktree add --detach "$W/tree" HEAD > /dev/null || fail "建临时工作树失败"
echo "插桩版：$(git -C "$R" rev-parse --short HEAD)（$W/tree）"
S2A_PGO_GEN=1 bash "$W/tree/tools/host_build.sh" > "$W/build.log" 2>&1 || { tail -5 "$W/build.log"; fail "插桩版宿主编不过（见 $W/build.log）"; }
mkdir -p "$W/prof"
while [ $# -gt 0 ]; do
  G=$1; REC=$2; shift 2; o="$W/out_$(basename "$REC")"
  S2A_PGO_GEN=1 LLVM_PROFILE_FILE="$W/prof/%p.profraw" S2A_FRAME_REPLAY_N=${S2A_PGO_PASSES:-200} bash "$W/tree/tools/frame_replay.sh" "$G" "$REC" "$o" | tail -1
  [ "${PIPESTATUS[0]}" = 0 ] || fail "$G $REC 回放失败（见 $o/host.log）"
done
n=$(ls "$W/prof"/*.profraw 2> /dev/null | wc -l | tr -d ' '); [ "$n" -gt 0 ] || fail "没写出剖析数据（宿主没走正常退出？）"
mkdir -p "$R/graphics/nvn/pgo"
xcrun llvm-profdata merge --text -o "$R/graphics/nvn/pgo/nvn.prof.txt" "$W/prof"/*.profraw || fail "合并剖析数据失败"
echo "🟢 $n 份剖析数据合并进 graphics/nvn/pgo/nvn.prof.txt（$(grep -c '^# Func Hash' "$R/graphics/nvn/pgo/nvn.prof.txt") 个函数）"
