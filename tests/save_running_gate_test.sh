#!/bin/bash
# 门禁覆盖：services/S2A.Services/SaveTransfer*.cs tests/save_transfer/
# 游戏在跑时存档桥只放只读的 status / export / inspect（iOS 切后台上传 iCloud 存档要用），restore / recover / 没收尾的事务拒（诊断#a87296）。造的空存档根，不要私有数据
set -euo pipefail
cd "$(dirname "$0")/.."
dotnet="${DOTNET:-$HOME/.dotnet/dotnet}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
"$dotnet" build tests/save_transfer/SaveTransferTest.csproj -c Release --nologo -v q --artifacts-path "$T/artifacts" -p:GeneratePackageOnBuild=false >/dev/null
"$dotnet" "$T/artifacts/bin/SaveTransferTest/release/SaveTransferTest.dll" --running-gate
