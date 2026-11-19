#!/bin/bash
# 宽屏核心发布成 Mac 本机动态库（NativeAOT）：bash graphics/widen/publish_native.sh <中间产物目录> <输出目录>
#   runtime/build.mk 的 NVN_TEST_WIDEN 与 graphics/nvn/tests/t_present_settings.sh 共用这一条命令；后者不经顶层 Makefile（解析时会扫全部宿主源码）
set -euo pipefail
[ $# -eq 2 ] || { echo "用法：$0 <中间产物目录> <输出目录>" >&2; exit 2; }
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# dotnet 同 runtime/build.mk DOTNET_CMD 的取法：DOTNET 给了用它，否则 PATH 上的，再否则 ~/.dotnet/dotnet
D=${DOTNET:-$(command -v dotnet 2>/dev/null || echo "$HOME/.dotnet/dotnet")}
exec "$D" publish graphics/widen/S2Arm.Gfx.Widen.csproj -c Release -r osx-arm64 -nodeReuse:false -p:UseSharedCompilation=false \
  --artifacts-path "$1" -o "$2" -p:PublishAot=true -p:NativeLib=Shared -p:InvariantGlobalization=true
