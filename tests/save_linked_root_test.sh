#!/bin/bash
# 门禁覆盖：services/S2A.Services/SaveTransfer*.cs tests/save_transfer/
# 存档路径上有链接（游戏库挪到外置盘再链回来、/tmp 系统链接）照常做，只拦解开后跑出存档目录的（诊断 D-R52E）
set -euo pipefail
cd "$(dirname "$0")/.."
dotnet="${DOTNET:-$HOME/.dotnet/dotnet}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
"$dotnet" build tests/save_transfer/SaveTransferTest.csproj -c Release --nologo -v q --artifacts-path "$T/artifacts" -p:GeneratePackageOnBuild=false >/dev/null
"$dotnet" "$T/artifacts/bin/SaveTransferTest/release/SaveTransferTest.dll" --linked-root
