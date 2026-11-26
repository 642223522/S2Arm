#!/usr/bin/env bash
# Build the production managed composition and exercise its shutdown entry on a fresh thread.
# The parked guest is a controlled host thread; this does not prove native park or device behavior.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd -P)
art=${1:?external artifact directory required}
dotnet=${2:-dotnet}
mkdir -p "$art"
art=$(cd "$art" && pwd -P)
"$dotnet" build "$root/services/S2A.Services.Tests/S2A.Services.Tests.csproj" -c Release -p:ArtifactsPath="$art" -nologo -v q
"$dotnet" build "$root/android/cs/aot/S2A.Android.Aot.csproj" -c Release -p:PublishAot=false -p:ArtifactsPath="$art" -nologo -v q
services="$art/bin/S2A.Services.Tests/release"
aot="$art/bin/S2A.Android.Aot/release"
"$dotnet" build "$root/android/core-runtime/tests/AndroidRuntime.Tests.csproj" -c Release -nologo -v q \
  -p:ArtifactsPath="$art" -p:ServicesDirectory="$services" -p:AudioAssembly="$aot/S2A.Audio.AAudio.dll" \
  -p:VulkanAssembly="$aot/Ryujinx.Graphics.Vulkan.dll" -p:GpuAssembly="$aot/Ryujinx.Graphics.Gpu.dll" \
  -p:MemoryAssembly="$aot/Ryujinx.Memory.dll" -p:GpuSourceRoot="$root"
timeout 20 "$dotnet" "$art/bin/AndroidRuntime.Tests/release/AndroidRuntime.Tests.dll" shutdown-new-thread-parked
# 资源消费者（真 Exports.Initialize 的游戏数据校验 / RomFS 读取，主机夹具）：原先这两个场景写好了却没有调用方（11-16 安卓包带 romfs.std
#   起局被启动校验拦下才发现），接进来让整套真跑
timeout 20 "$dotnet" "$art/bin/AndroidRuntime.Tests/release/AndroidRuntime.Tests.dll" resource-control
timeout 20 "$dotnet" "$art/bin/AndroidRuntime.Tests/release/AndroidRuntime.Tests.dll" resource-romfs
