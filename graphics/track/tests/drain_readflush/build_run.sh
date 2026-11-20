#!/bin/bash
# Real NxTrack consumers (Android and Apple) + real tracker; Mac signal / VM fixture only.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
OUT=${1:-"$ROOT/build/tests/drain-readflush"}
mkdir -p "$OUT"
cat > "$OUT/NuGet.Config" <<'XML'
<configuration><packageSources><clear /></packageSources></configuration>
XML
clang -O2 -dynamiclib -DS2A_TRACK_TEST -I "$ROOT/runtime/include" -I "$ROOT/graphics/track" \
  -o "$OUT/libs2a_native.dylib" "$HERE/fixture.c" "$ROOT/graphics/track/track.c" \
  "$ROOT/runtime/src/emul_ld.c" "$ROOT/runtime/src/emul_st.c" -lpthread
# 两个真实消费者：安卓（S2A_ANDROID）与苹果（审计 #806 第 5 条：苹果排空原先直接解引用客人页，读时回写设成不可读的页即缺页）
for c in android apple; do
  ART="$OUT/art-$c"
  bash "$ROOT/tools/cs_cache.sh" "$ART" "$HERE/DrainReadflush.csproj" -- bash -c 'dotnet restore "$1" --configfile "$2" --artifacts-path "$3" -p:NuGetAudit=false${4:+ -p:S2AConsumer=$4} && dotnet build "$1" -c Release --no-restore --artifacts-path "$3"${4:+ -p:S2AConsumer=$4}' _ "$HERE/DrainReadflush.csproj" "$OUT/NuGet.Config" "$ART" "$c" > "$OUT/build-$c.log" 2>&1   # restore + build（树外缓存 tools/cs_cache.sh）
  DLL="$ART/bin/DrainReadflush/release/DrainReadflush.dll"
  cp "$OUT/libs2a_native.dylib" "$(dirname "$DLL")/"
  for mode in "" clobber; do
    rc=0; (cd "$(dirname "$DLL")" && dotnet "$DLL" $mode) || rc=$?
    if [ $rc != 0 ]; then echo "✗ drain_readflush $c ${mode:-plain}：退出 ${rc}（134 / 5 = 直接读了不可读客人页（.NET 报 AccessViolation / 夹具信号处理）；4 = 读时回写保护被放松）"; exit 1; fi
  done
done
