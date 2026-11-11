#!/bin/bash
# 门禁覆盖：tools/dotnet_lock.c
# 同一棵树 C# 编译串行（tools/dotnet_lock.c，门禁开头现编；11-10 / 11-11）：假 dotnet 也是编出来的程序（记子命令、开始 / 结束时刻、两个环境变量，睡 NAP 秒），约 15 秒
#   期望按规则手写：① 两份 build 同时起 → 运行区间不重叠；② 别人持锁时 dotnet x.dll 不等锁、1 秒内跑完；③ 持锁的 build 被 kill -9 → 下一份 3 秒内跑完；
#   ⑥ env -i 只给 DOTNET（S2A_DOTNET_REAL 不在）：自己按 PATH 找真 dotnet、跳过自己（启动器作业环境单测 userenv ③，11-11）
#   ④ 真 dotnet 看到 MSBUILDDISABLENODEREUSE=1；⑤ 调用方给的 DYLD_INSERT_LIBRARIES 原样到真 dotnet（脚本包装会被 SIP 清掉，11-11 服务层 t_native_provider 红）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); trap 'kill $(jobs -p) 2> /dev/null; rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
cc -O2 -o "$T/dotnet" "$H/tools/dotnet_lock.c" || { echo "不通 编译 tools/dotnet_lock.c"; exit 1; }
cat > "$T/fake.c" <<'F'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>
static double now(void) { struct timeval t; gettimeofday(&t, 0); return t.tv_sec + t.tv_usec / 1e6; }
int main(int c, char **v) {
    FILE *f = fopen(getenv("LOGF"), "a"); const char *nr = getenv("MSBUILDDISABLENODEREUSE"), *dy = getenv("DYLD_INSERT_LIBRARIES");
    fprintf(f, "%s 开始 %.3f nr=%s dy=%s\n", c > 1 ? v[1] : "-", now(), nr ? nr : "", dy ? dy : ""); fflush(f);
    if (!(c > 1 && strstr(v[1], ".dll"))) { const char *n = getenv("NAP"); usleep((useconds_t)((n ? atof(n) : 2) * 1e6)); }
    fprintf(f, "%s 结束 %.3f\n", c > 1 ? v[1] : "-", now()); fclose(f); return 0; }
F
cc -O2 -o "$T/fake" "$T/fake.c" || { echo "不通 编译假 dotnet"; exit 1; }
export S2A_DOTNET_REAL=$T/fake S2A_DOTNET_LOCK=$T/lk LOGF=$T/log; D=$T/dotnet
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
printf 'int s2a_dl_test_marker(void) { return 1; }\n' > $T/e.c; cc -shared -o $T/empty.dylib $T/e.c   # 真能插入的空库（插不存在的库 dyld 直接中止）
: > $T/log; env DYLD_INSERT_LIBRARIES=$T/empty.dylib "$D" x.dll 2> /dev/null
ck "⑤ DYLD_INSERT_LIBRARIES 原样传到真 dotnet（$(grep -o 'dy=[^ ]*' $T/log | head -1)）" 'grep -q "dy=$T/empty.dylib" $T/log'
mkdir -p $T/sh $T/rb $T/h; cp $T/dotnet $T/sh/dotnet; cp $T/fake $T/rb/dotnet; : > $T/log
env -i HOME=$T/h PATH=$T/sh:$T/rb LOGF=$T/log $T/sh/dotnet x.dll; r6=$?
ck "⑥ env -i 只给包装：PATH 上跳过自己、找到真 dotnet（rc=${r6}）" '[ $r6 = 0 ] && grep -q "^x.dll 开始" $T/log'
[ $bad = 0 ] && echo "C# 构建锁单测全过" || { echo "C# 构建锁单测有不通"; cat $T/log; exit 1; }
