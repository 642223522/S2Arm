#!/bin/bash
# Production shader cache queue and detached syncpoint callback; host only, no GPU.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
OUT=${1:-"$ROOT/build/tests/shared-contract"}
mkdir -p "$OUT"
cat > "$OUT/NuGet.Config" <<'XML'
<configuration><packageSources><clear /></packageSources></configuration>
XML
bash "$ROOT/tools/cs_cache.sh" "$OUT/art" "$HERE/SharedContracts.csproj" -- bash -c 'dotnet restore "$1" --configfile "$2" --artifacts-path "$3" -p:NuGetAudit=false${4:+ -p:S2AConsumer=$4} && dotnet build "$1" -c Release --no-restore --artifacts-path "$3"${4:+ -p:S2AConsumer=$4}' _ "$HERE/SharedContracts.csproj" "$OUT/NuGet.Config" "$OUT/art" > "$OUT/build.log" 2>&1   # restore + build（树外缓存 tools/cs_cache.sh）
dotnet "$OUT/art/bin/SharedContracts/release/SharedContracts.dll"
