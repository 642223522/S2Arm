#!/bin/bash
# 门禁覆盖：graphics/vulkan/*
# Vulkan 后端 C# 单测（10-29 基础设施线：#867 改 graphics/vulkan/core/**，这里的 C# 单测从来没有门禁跑）：只跑 CPU 侧、不要 GPU 的那几个工程，
#   12 个工程无参数跑 CPU 宿主回归，一个红整支红；不证明 GPU/设备/游戏。
#   门禁覆盖查询生命周期：query-semantics-tests 跑真 BufferedQuery/CounterQueue/CounterQueueEvent——Begin 清零、
#   超时计数不锁结果、段溢出显式失败、消费线程 Peek 留队、FlushTo 有界、Flush(true) 不持锁等超时。
#   另跑 stop_after_acquire.py --mode all（15 个 Present/Poll/租约相位）：真实 NativeLease ABI 消费方 + 受控
#   Vulkan 边界；含 #1228 回归守卫 revoke-early / revoke-early-prior（acquire 与提交之间撤销）。缺任一 PASS 即红。
#   依赖须预先准备；本入口清空包源、13 个工程编进本树 build/vulkan_backend_test（其中 9 个经树外按内容缓存 tools/cs_cache.sh），不联网下载。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
DN=${DOTNET:-$HOME/.dotnet/dotnet}; [ -x "$DN" ] || DN=$(command -v dotnet)
bad=0; n=0
# 构建输出放本树固定目录 build/vulkan_backend_test（被忽略；目录只归本单测用，不碰各工程自己的 obj/bin、不和别的步共用，包源配置也放这里且内容固定）。
#   开发机上跨次保留、按 MSBuild 增量编；门禁每步前 git clean -fdx，这个目录每次都是空的、跨次增量不成立，所以 9 个工程改走树外缓存（见下）。
#   Control.Tests 引用 S2A.Services，连带整套 Ryujinx（HLE / ARMeilleure / Gpu …）冷编一遍，实测整步 178 秒里这一个工程占 109 秒。
# 13 个工程在同一次 MSBuild 里编完：原先每个工程各起一次 dotnet run——各自起 MSBuild、评估、还原、按引用链检查一遍，共用的引用被 13 次分别核对；
#   现在一份解决方案文件列全 13 个工程，每个被引用的工程只编一次（MSBuild 自己排图，不会两边写同一份输出），随后逐个工程串行跑
#   （参数、退出码判定与原先相同；工程之间不并行，Control.Tests 内部分进程见下）。
#   合编不过：固定目录里可能留着上一次的旧程序，不许拿它们跑出「通」——改回原先的逐个 dotnet run（串行各自现编、各自报自己的错）
# 分两批编进同一个产物目录：前 9 个工程经 tools/cs_cache.sh（键 = 闭包源码在 HEAD 的内容 + 命令参数 + SDK 版本 …，命中就克隆上次的产物、不调 dotnet；
#   闭包有未提交改动 / 产物目录事先非空就照常现编），后 4 个直接编——它们构建时 Exec 调外部编译器（spirv-as / cc）或读闭包外的头文件
#   （CodecTests 汇编 .spvasm、Control.Tests 与 WsiTests 编 android/native 头 + .c 夹具、Runtime.Tests 编 asset_fixture.c），这些输入不在缓存键里。
#   缓存那批必须先编：它只在产物目录事先为空时才收进缓存，命中时会整个替换产物目录。
ART=$H/build/vulkan_backend_test; mkdir -p "$ART"
NC='<configuration><packageSources><clear /></packageSources></configuration>'
[ "$(cat "$ART/NuGet.Config" 2> /dev/null)" = "$NC" ] || printf '%s\n' "$NC" > "$ART/NuGet.Config"   # 内容不变就不重写（不动时间戳）
P=(-c Release --artifacts-path "$ART/artifacts" -p:GeneratePackageOnBuild=false -p:CreateHardLinksForCopyFilesToOutputDirectoryIfPossible=true
   -p:CreateHardLinksForCopyLocalIfPossible=true -p:NuGetAudit=false -p:RestoreConfigFile="$ART/NuGet.Config")
PROJ_C=(   # 经缓存
  "$H/graphics/vulkan/cache/tests/renderer/RendererProfile.Tests.csproj"
  "$H/graphics/vulkan/core/cache-tests/CacheAdmission.Tests.csproj"
  "$H/graphics/vulkan/core/fence-tests/Fence.Results.Tests.csproj"
  "$H/graphics/vulkan/core/tests/DeviceFeatures.Tests.csproj"
  "$H/graphics/vulkan/runtime/geometry-output-tests/GeometryOutput.Tests.csproj"
  "$H/graphics/vulkan/runtime/counter-tests/CounterLifetime.csproj"
  "$H/graphics/vulkan/runtime/query-semantics-tests/QuerySemantics.csproj"
  "$H/graphics/vulkan/runtime/readback-registration-tests/Host.csproj"
  "$H/graphics/vulkan/runtime/varying-tests/Varying.Tests.csproj"
)
PROJ_X=(   # 构建时 Exec 读键外输入，直接编
  "$H/graphics/vulkan/cache/tests/CodecTests.csproj"
  "$H/graphics/vulkan/runtime/control-tests/Control.Tests.csproj"
  "$H/graphics/vulkan/runtime/tests/Runtime.Tests.csproj"
  "$H/graphics/vulkan/wsi/tests/WsiTests.csproj"
)
PROJ=("${PROJ_C[@]}" "${PROJ_X[@]}")
sln() { echo '<Solution>'; for p in "$@"; do echo "  <Project Path=\"$p\" />"; done; echo '</Solution>'; }
sln "${PROJ_C[@]}" > "$T/vulkan_backend_cached.slnx"; sln "${PROJ_X[@]}" > "$T/vulkan_backend_exec.slnx"
built=1
o=$(MSBUILDDISABLENODEREUSE=1 timeout 600 bash "$H/tools/cs_cache.sh" "$ART/artifacts" "${PROJ_C[@]}" -- "$DN" build "$T/vulkan_backend_cached.slnx" "${P[@]}" -nologo -v q 2>&1 < /dev/null) \
  && o=$(MSBUILDDISABLENODEREUSE=1 timeout 600 "$DN" build "$T/vulkan_backend_exec.slnx" "${P[@]}" -nologo -v q 2>&1 < /dev/null) || {
  echo "不通 13 个工程合编（rc=$?）：$(grep -E ' error ' <<< "$o" | sort -u | head -3 | tr '\n' ' ' | cut -c1-400)"; bad=1; built=; }
# 合编过了就直接用 dotnet 起编好的程序（与 dotnet run --no-build 起的是同一个程序、同样的工作目录与参数；省掉每个工程再起一次 MSBuild 评估，一个约 2–3 秒）
exe() { local d c; d=$ART/artifacts/bin/$(basename "$1" .csproj)/release; c=("$d"/*.runtimeconfig.json)
  [ ${#c[@]} = 1 ] && [ -f "${c[0]}" ] && echo "${c[0]%.runtimeconfig.json}.dll"; }
say() { if [ "$2" = 0 ]; then echo "通 ${1#$H/}：$(tail -1 <<< "$3" | cut -c1-120)"; else echo "不通 ${1#$H/}（rc=${2}）：$(tail -3 <<< "$3" | tr '\n' ' ' | cut -c1-300)"; bad=1; fi; }
run() { n=$((n + 1)); local o r d
  if [ -z "$built" ]; then o=$(MSBUILDDISABLENODEREUSE=1 timeout 600 "$DN" run -p:BuildInParallel=false --project "$1" "${P[@]}" 2>&1 < /dev/null); r=$?
  elif d=$(exe "$1"); then o=$(timeout 600 "$DN" "$d" 2>&1 < /dev/null); r=$?
  else o="合编报通过，却找不到 $(basename "$1" .csproj) 编出的程序（$ART/artifacts/bin/<工程>/release 下 runtimeconfig 不是恰好一个）"; r=1; fi
  say "$1" "$r" "$o"; }
# Control.Tests 两路同时跑（11-14 门禁提速）：整跑一个进程约 96 秒，九成是在真实时钟上等生产时限、CPU 几乎闲着；等得最久的两个用例
#   （PublicationClockOrigin 约 35 秒：30 秒总预算 + 31.5 秒积压；NonGpuWaitsBounded 约 12 秒：五种等待各 2 秒判卡死，判据余量 ≥ 1 秒）单独一个进程
#   （S2A_CONTROL_PART=threaded + S2A_THREADED_CHECK），其余照原样一个进程跑（S2A_THREADED_SKIP 跳过这两个）。只两路、另一路几乎全在睡：
#   11-14 试过每个用例一个进程、4 路并行，负载 40 时 SyncWakeLatency（最大唤醒延迟 < 25 ms）等时延判据被挤红，故不再细拆。
#   两个进程都须退 0、各自打出带 skip / only 的那行 PASS（另一路还须有单线程部分的 PASS 行）；用例改名对不上程序当场报错
LONG=PublicationClockOrigin,NonGpuWaitsBounded
ctl() { local d sum=0 c msg=
  { [ -n "$built" ] && d=$(exe "$1"); } || { run "$1"; return; }
  n=$((n + 1)); mkdir -p "$T/ctl"
  ( S2A_THREADED_SKIP=$LONG timeout 600 "$DN" "$d" > "$T/ctl/rest.log" 2>&1 < /dev/null; echo $? > "$T/ctl/rest.rc" ) &
  ( S2A_CONTROL_PART=threaded S2A_THREADED_CHECK=$LONG timeout 600 "$DN" "$d" > "$T/ctl/long.log" 2>&1 < /dev/null; echo $? > "$T/ctl/long.rc" ) &
  wait
  [ "$(cat "$T/ctl/rest.rc")" = 0 ] && grep -q '^PASS: .*production Runtime backing handshake assertions' "$T/ctl/rest.log" \
    && grep -q "^PASS: [0-9]* threaded-renderer assertions.*, skip $LONG)" "$T/ctl/rest.log" || msg="其余用例（rc=$(cat "$T/ctl/rest.rc")）：$(tail -3 "$T/ctl/rest.log" | tr '\n' ' ' | cut -c1-300)"
  [ "$(cat "$T/ctl/long.rc")" = 0 ] && grep -q "^PASS: [0-9]* threaded-renderer assertions.*, only $LONG)" "$T/ctl/long.log" \
    || msg="${msg:+${msg}；}${LONG}（rc=$(cat "$T/ctl/long.rc")）：$(tail -3 "$T/ctl/long.log" | tr '\n' ' ' | cut -c1-300)"
  if [ -n "$msg" ]; then echo "不通 ${1#$H/}：$msg"; bad=1; return; fi
  for c in rest long; do sum=$((sum + $(grep -o '^PASS: [0-9]* threaded-renderer' "$T/ctl/$c.log" | grep -o '[0-9]*'))); done
  echo "通 ${1#$H/}：两路同时跑全过（$LONG 单独一路），拆线程断言共 ${sum} 条"; }
for p in "${PROJ[@]}"; do case $p in */Control.Tests.csproj) ctl "$p";; *) run "$p";; esac; done
# 同族 Python 跑器（11-01 接线：分母按 tests 目录后查出没人调）：输出都放本次临时目录；本机负载 30 时合计约 45 秒。
#   run_host 要 spirv-as / spirv-val（汇编三段 SPIR-V 再跑 CodecTests 全量），utility 用 spirv-val 校验项目内嵌工具着色器
pyck() { n=$((n + 1)); if [ "$2" = 0 ]; then echo "通 ${1}：$(tail -1 <<< "$3" | cut -c1-120)"; else echo "不通 ${1}（rc=${2}）：$(tail -5 <<< "$3" | tr '\n' ' ' | cut -c1-400)"; bad=1; fi; }
PYV=${S2A_PY:-python3}; export PATH="${DN%/*}:$PATH"   # run_host / wsi 跑器按 PATH 找 dotnet：与上面工程用同一个 SDK
# run_host 直接用上面合编好的 CodecTests（11-14 门禁提速：原先在临时目录里重新还原 + 冷编一遍，约 25 秒）；合编没过（built 空）照旧自己编
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/cache/tests/run_host.py" --out "$T/codec-host" ${built:+--artifacts "$ART/artifacts"} 2>&1 < /dev/null); pyck cache/run_host $? "$o"
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/cache/tests/test_profile_runner.py" 2>&1 < /dev/null); pyck cache/test_profile_runner $? "$o"
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/runtime/utility-tests/run.py" --vulkan-root "$H/compat/tree/src/Ryujinx.Graphics.Vulkan" --spirv-val "$(command -v spirv-val || echo spirv-val)" --output "$T/utility" 2>&1 < /dev/null); pyck runtime/utility-tests $? "$o"
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/wsi/tests/run.py" --negative-controls --output-root "$T/wsi-run" 2>&1 < /dev/null); pyck wsi/run $? "$o"
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/wsi/tests/test_runner.py" --out "$T/wsi-test-runner" 2>&1 < /dev/null); pyck wsi/test_runner $? "$o"
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/wsi/tests/retirement_diagnostics.py" --android-window "$H/graphics/vulkan/wsi/AndroidWindow.cs" --ledger "$H/graphics/vulkan/wsi/RetirementLedger.cs" --dotnet "$DN" --output "$T/wsi-retirement" 2>&1 < /dev/null); pyck wsi/retirement_diagnostics $? "$o"
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/wsi/tests/backing_lost_replay.py" "$T/wsi-lost" 2>&1 < /dev/null); pyck wsi/backing_lost_replay $? "$o"
o=$(timeout 300 "$PYV" "$H/graphics/vulkan/wsi/tests/backing_lost_replay.py" "$T/wsi-lost-negative" --negative 2>&1 < /dev/null); r=$?
if [ "$r" != 0 ] && [[ "$o" == *"device lost did not replay recorded zero VA"* ]]; then pyck wsi/backing_lost_negative 0 "$o"; else pyck wsi/backing_lost_negative 1 "$o"; fi
# #1228 回归守卫：撤销在 acquire 与提交之间送达时，必须走「只等不送」排空。--mode all 覆盖 15 个相位；
# 这里显式核 revoke-early / revoke-early-prior 的 PASS，模式被删或脚本没接上都会红。
run_stop_after_acquire() { local o r c; o=$(timeout 600 python3 "$H/graphics/vulkan/wsi/tests/stop_after_acquire.py" --mode all \
  --android-window "$H/graphics/vulkan/wsi/AndroidWindow.cs" \
  --ledger "$H/graphics/vulkan/wsi/RetirementLedger.cs" \
  --native-lease "$H/graphics/vulkan/wsi/NativeLease.cs" \
  --dotnet "$DN" --output "$T/stop-after-acquire" 2>&1 < /dev/null); r=$?
  c=$(grep -cE '^PASS [a-z]' <<< "$o")
  if [ $r = 0 ] && [ "$c" -ge 15 ] && grep -q '^PASS revoke-early$' <<< "$o" && grep -q '^PASS revoke-early-prior$' <<< "$o"; then
    echo "通 graphics/vulkan/wsi/tests/stop_after_acquire.py：${c} 个模式，含 revoke-early / revoke-early-prior"
  else echo "不通 graphics/vulkan/wsi/tests/stop_after_acquire.py（rc=${r}，模式=${c}）：$(tail -3 <<< "$o" | tr '\n' ' ' | cut -c1-300)"; bad=1; fi; }
run_stop_after_acquire
[ $bad = 0 ] && echo "vulkan_backend 单测全过（${n} 项：工程 + Python 跑器 + stop_after_acquire 全模式）" || { echo "vulkan_backend 单测有不通"; exit 1; }
