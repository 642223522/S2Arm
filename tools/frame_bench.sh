#!/bin/bash
# 帧回放测速（门禁外工具，graphics/nvn/docs/frame_replay.md「测速」节）：
#   bash tools/frame_bench.sh <款> <录像目录> [<树> …]
#   把同一份帧录像在每棵树编出的宿主上各回放 S2A_BENCH_RUNS 次（缺省 3），树之间交替跑（A B A B …，抵掉机器升温漂移）。
#   每次回放执行这一帧 S2A_BENCH_PASSES 遍（缺省 200），丢掉前 S2A_BENCH_WARM 遍（缺省 20：首遍现编管线、写回 GPU 贴图，前几十遍还在变快），
#   主读数 = 余下各遍提交线程周期数的最小值：本线程自己跑掉的 CPU 周期（不含被抢占），取最小 = 没被别的进程抢共享缓存 / 内存带宽时的开销。
#   11-11 实测（负载均值 15–18 的共用机器，同一宿主 3 次）：墙钟中位 ms 波动 9%–55%；周期中位 6.7%（40 遍时 21%）；周期最小值 1.0%。
#   另报指令数中位（确定性高，< 1%）、周期 5% 分位与墙钟中位 ms（参考）。
#   输出：每树每次的读数、每树 S2A_BENCH_RUNS 次之间的波动（(最大 − 最小) / 均值），以及各树相对第一棵树的差。
#   判据：同一棵树最小周期数波动 < 3% 才算这份录像能用来比；超了打 🔴 并退 3。只跑 1 次不判。
#   不给树 = 只测本仓库这棵树。录像 / 输出都在仓库外；输出目录 S2A_BENCH_OUT（缺省 <录像目录>/bench_<时间>）。
#   其余环境照 tools/frame_replay.sh（S2A_ROOTS / S2A_ROOT_TAG / S2A_REPLAY_TIMEOUT）。
set -u
G=${1:?款}; REC=${2:?录像目录}; shift 2
R=$(cd "$(dirname "$0")/.." && pwd)
[ $# -gt 0 ] || set -- "$R"
RUNS=${S2A_BENCH_RUNS:-3}; PASSES=${S2A_BENCH_PASSES:-200}; WARM=${S2A_BENCH_WARM:-20}
[ "$PASSES" -gt "$WARM" ] || { echo "🔴 S2A_BENCH_PASSES（${PASSES}）要大于 S2A_BENCH_WARM（${WARM}）"; exit 2; }
OUT=${S2A_BENCH_OUT:-$REC/bench_$(date +%m%d_%H%M%S)}; mkdir -p "$OUT" || exit 2; OUT=$(cd "$OUT" && pwd); : > "$OUT/runs.tsv"
TREES=(); for t in "$@"; do d=$(cd "$t" 2>/dev/null && pwd) || { echo "🔴 树 $t 不存在"; exit 2; }; [ -f "$d/tools/frame_replay.sh" ] || { echo "🔴 $d 没有 tools/frame_replay.sh"; exit 2; }; TREES+=("$d"); done
echo "树：${TREES[*]}；每树 $RUNS 次 × $PASSES 遍（丢前 $WARM 遍）；输出 $OUT"
for r in $(seq 1 "$RUNS"); do
  for i in "${!TREES[@]}"; do
    o="$OUT/t${i}_r$r"
    S2A_FRAME_REPLAY_N=$PASSES bash "${TREES[$i]}/tools/frame_replay.sh" "$G" "$REC" "$o" > "$o.log" 2>&1 || { echo "🔴 树 $i 第 $r 次回放失败（见 $o.log）"; tail -3 "$o.log"; exit 1; }
    python3 - "$o/host.log" "$WARM" "$PASSES" "$i" "$r" >> "$OUT/runs.tsv" <<'EOF' || { echo "🔴 树 $i 第 $r 次读数不全（见 $o/host.log）"; exit 1; }
import re, sys, statistics as st
p, warm, n, i, r = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
rx = re.compile(r'回放第 \d+ / \d+ 遍：.*提交线程 ([0-9.]+) ms、(\d+) 条指令、(\d+) 个周期')
rows = [m.groups() for m in map(rx.search, open(p, encoding='utf-8', errors='replace')) if m]
if len(rows) != n: sys.exit(f'读到 {len(rows)} 遍，期望 {n}（宿主不打周期数的是 11-11 之前的树）')
rows = rows[warm:]; cy = sorted(int(x[2]) for x in rows)
print(f'{i}\t{r}\t{cy[0]}\t{st.median(int(x[1]) for x in rows)}\t{st.median(float(x[0]) for x in rows):.3f}\t{cy[len(cy) // 20]}')
EOF
    tail -1 "$OUT/runs.tsv" | awk -F'\t' -v t="${TREES[$i]}" '{printf "  树 %s 第 %s 次：最小 %.2f M 周期（5%% 分位 %.2f）、%.2f M 指令、%s ms（%s）\n", $1, $2, $3 / 1e6, $6 / 1e6, $4 / 1e6, $5, t}'
  done
done
python3 - "$OUT/runs.tsv" "${TREES[@]}" <<'EOF'
import sys, statistics as st
rows = [l.rstrip('\n').split('\t') for l in open(sys.argv[1])]; trees = sys.argv[2:]; bad = 0; base = None
sp = lambda v: (max(v) - min(v)) / st.mean(v) * 100
for i, t in enumerate(trees):
    cy, ins, ms = ([float(x[k]) for x in rows if x[0] == str(i)] for k in (2, 3, 4))
    m = (st.mean(cy), st.mean(ins), st.mean(ms)); one = len(cy) < 2; ok = sp(cy) < 3; bad |= not one and not ok
    if base is None: base = m
    d = '' if i == 0 else '；相对树 0：周期 %+.1f%%、指令 %+.1f%%、ms %+.1f%%' % tuple((m[k] / base[k] - 1) * 100 for k in range(3))
    print(f"{'⚪ 只 1 次、不判波动' if one else '🟢' if ok else '🔴'} 树 {i} {t}：最小 {m[0] / 1e6:.2f} M 周期/遍（{len(cy)} 次波动 {sp(cy):.2f}%，判据 < 3%）、"
          f"{m[1] / 1e6:.2f} M 指令（波动 {sp(ins):.2f}%）、{m[2]:.3f} ms（参考，波动 {sp(ms):.2f}%）{d}")
sys.exit(3 if bad else 0)
EOF
