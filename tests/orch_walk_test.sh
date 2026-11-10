#!/bin/bash
# 门禁覆盖：pack/orch/stages.py pack/orch/roots.py
# v0.2.3 遍历清理（出包编排）行为单测：期望按规则手写
#   ① 没设 S2A_GAME_SRC → 原件列表为空，不扫 ~/Downloads（HOME 指到放了 .nsp 的临时目录也不认）；② 设了 → 认 Game.nsp、跳过 exFAT 留下的 ._Game.nsp；
#   ③ 玩家选的字体目录里多一个软链 / .DS_Store → 照用（只认 *.bfttf），不报 75
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p "$T/home/Downloads" "$T/src" "$T/fonts"; : > "$T/home/Downloads/Dl.nsp"; : > "$T/src/Game.nsp"; : > "$T/src/._Game.nsp"
: > "$T/fonts/a.bfttf"; : > "$T/fonts/.DS_Store"; ln -s /etc/hosts "$T/fonts/link"
o=$(cd "$H" && env -u S2A_GAME_SRC HOME="$T/home" python3 -c 'import sys; sys.path.insert(0, "."); from pack.orch.stages import Stages; print(" ".join(p.name for p in Stages._source_files()) or "-")' 2>&1)
ck "① 没设 S2A_GAME_SRC → 空、不扫 ~/Downloads（${o}）" '[ "$o" = "-" ]'
o=$(cd "$H" && S2A_GAME_SRC="$T/src" python3 -c 'import sys; sys.path.insert(0, "."); from pack.orch.stages import Stages; print(" ".join(p.name for p in Stages._source_files()) or "-")' 2>&1)
ck "② 设了 → 只认 Game.nsp、跳过 ._Game.nsp（${o}）" '[ "$o" = "Game.nsp" ]'
o=$(cd "$H" && S2A_FONTS="$T/fonts" python3 -c 'import sys; sys.path.insert(0, "."); from pack.orch.stages import Stages; print(Stages._fonts().name)' 2>&1)
ck "③ 字体目录有软链 / .DS_Store 照用（${o}）" '[ "$o" = fonts ]'
[ $bad = 0 ] && echo "orch_walk 单测全过" || { echo "orch_walk 单测有不通"; exit 1; }
