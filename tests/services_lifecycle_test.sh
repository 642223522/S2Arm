#!/bin/bash
# 门禁覆盖：services/*
# 服务层生命周期 C# 单测：内存诊断线程（MemDiag.Lifecycle.Tests：只编生产 MemDiag / S2AShutdown / S2AThreadAlloc 三个文件，不引用整套 Ryujinx），各平台都跑。
#   另两项不在这里重编：文件系统重建（FileSystemRestart）是服务单测的独立模式 --filesystem-restart，随 services/test.sh 那次编译跑；
#   Apple 音频会话重复释放要 macOS + NativeAOT，拆到 tests/apple_audio_lifecycle_test.sh（只在 Mac 跑）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
DN=${DOTNET:-$HOME/.dotnet/dotnet}; [ -x "$DN" ] || DN=$(command -v dotnet || true)
# 没有 .NET SDK：这支没跑，退 75（环境未就绪，审计 P1-154）
[ -n "$DN" ] || { echo "services_lifecycle：没有 .NET SDK，没跑（环境未就绪）" >&2; exit 75; }
P=$H/services/MemDiag.Lifecycle.Tests/MemDiag.Lifecycle.Tests.csproj
o=$(MSBUILDDISABLENODEREUSE=1 timeout 300 "$DN" run -c Release --project "$P" --artifacts-path "$T/a" 2>&1 < /dev/null); r=$?
if [ $r = 0 ]; then echo "通 ${P#$H/}：$(tail -1 <<< "$o" | cut -c1-120)"; echo "services_lifecycle 单测全过（1 个工程）"; exit 0; fi
echo "不通 ${P#$H/}（rc=${r}）：$(tail -3 <<< "$o" | tr '\n' ' ' | cut -c1-300)"; echo "services_lifecycle 单测有不通"; exit 1
