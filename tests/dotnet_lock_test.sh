#!/bin/bash
# 门禁覆盖：tools/dotnet_lock.sh tools/flock_hold.py
# 同一棵树 C# 编译串行（tools/dotnet_lock.sh，11-10）：假 dotnet（记开始 / 结束时刻、睡 2 秒），约 10 秒：bash tests/dotnet_lock_test.sh
#   期望按规则手写：① 两份 build 同时起 → 两段运行区间不重叠（后一份的开始 ≥ 前一份的结束）；② 别人持锁时 dotnet x.dll（运行程序集）不等锁、1 秒内跑完；
#   ③ 持锁的 build 被 kill -9 → 锁随即放出，下一份 build 3 秒内开始；④ 真 dotnet 看到 MSBUILDDISABLENODEREUSE=1
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); trap 'kill $(jobs -p) 2> /dev/null; rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p "$T/r/tools"; cp "$H/tools/dotnet_lock.sh" "$H/tools/flock_hold.py" "$T/r/tools/"
cat > "$T/fake" <<'F'
#!/bin/bash
now() { python3 -c 'import time; print(time.time())'; }
echo "$1 开始 $(now) nr=${MSBUILDDISABLENODEREUSE:-}" >> "$LOGF"; [ "$1" = x.dll ] || sleep "${NAP:-2}"; echo "$1 结束 $(now)" >> "$LOGF"
F
chmod +x "$T/fake"; export S2A_DOTNET_REAL=$T/fake LOGF=$T/log; D=$T/r/tools/dotnet_lock.sh
"$D" build & a=$!; sleep 0.2; "$D" build & b=$!; wait $a $b
ov=$(python3 -c 'import sys
ev = [l.split() for l in open(sys.argv[1])]
s = [float(x[2]) for x in ev if x[1] == "开始"]; e = [float(x[2]) for x in ev if x[1] == "结束"]
print("不重叠" if len(s) == 2 and max(s) >= min(e) - 0.05 else "重叠 %s %s" % (s, e))' $T/log)
ck "① 两份 build 同时起 → 运行区间不重叠（${ov}）" '[ "$ov" = 不重叠 ]'
ck "④ 真 dotnet 看到 MSBUILDDISABLENODEREUSE=1" 'grep -q "nr=1" $T/log'
: > $T/log; NAP=5 "$D" build & a=$!; sleep 0.5; t0=$SECONDS; "$D" x.dll; dt=$((SECONDS - t0)); wait $a
ck "② 别人持锁时 dotnet x.dll 不等锁（${dt} 秒）" '[ $dt -le 1 ]'
: > $T/log; NAP=30 "$D" build & a=$!; sleep 0.5; kill -9 $a; wait $a 2> /dev/null; t0=$SECONDS; NAP=0 "$D" build; dt=$((SECONDS - t0))
ck "③ 持锁的 build 被 kill -9 → 下一份 3 秒内跑完（${dt} 秒）" '[ $dt -le 3 ]'
[ $bad = 0 ] && echo "C# 构建锁单测全过" || { echo "C# 构建锁单测有不通"; cat $T/log; exit 1; }
