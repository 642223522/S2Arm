#!/bin/bash
# 门禁覆盖：services/S2A.Services/SaveTransfer*.cs tests/save_transfer/
# 回到上一份存档：previous 只读（在跑也给）；restorePrevious 与 .s2a_prev 原子交换、再调换回，在跑 / 没有上一份拒。造的存档根，不要私有数据
set -euo pipefail
cd "$(dirname "$0")/.."
dotnet="${DOTNET:-$HOME/.dotnet/dotnet}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
"$dotnet" build tests/save_transfer/SaveTransferTest.csproj -c Release --nologo -v q --artifacts-path "$T/artifacts" -p:GeneratePackageOnBuild=false >/dev/null
"$dotnet" "$T/artifacts/bin/SaveTransferTest/release/SaveTransferTest.dll" --previous
