#!/bin/bash
# 门禁覆盖：services/*
# Apple 音频会话重复释放与事件句柄复用（AppleAudio.Lifecycle.Tests）：要 NativeAOT 产物才覆盖 GCHandle 槽复用（JIT 跑测试自己抛「本回归必须运行NativeAOT产物」），
#   按 services/README.md 发布后跑产物。Apple 音频后端只在 macOS 上有：别的系统退 75（环境未就绪），门禁只派 Mac。原在 services_lifecycle_test.sh 里，11-18 拆出
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
DN=${DOTNET:-$HOME/.dotnet/dotnet}; [ -x "$DN" ] || DN=$(command -v dotnet || true)
[ -n "$DN" ] || { echo "apple_audio_lifecycle：没有 .NET SDK，没跑（环境未就绪）" >&2; exit 75; }
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64) RID=osx-arm64 ;;
  Darwin/x86_64) RID=osx-x64 ;;
  *) echo "apple_audio_lifecycle：Apple 音频后端要 macOS，本机 $(uname -s) 没跑（环境未就绪）"; exit 75 ;;
esac
P=$H/services/AppleAudio.Lifecycle.Tests/AppleAudio.Lifecycle.Tests.csproj
o=$(MSBUILDDISABLENODEREUSE=1 timeout 600 "$DN" publish "$P" -c Release -r $RID --artifacts-path "$T/a" -o "$T/pub" 2>&1 < /dev/null) && o=$(timeout 60 "$T/pub/Ryujinx.Audio.Backends.Apple" 2>&1 < /dev/null); r=$?
if [ $r = 0 ]; then echo "通 ${P#$H/}（NativeAOT）：$(tail -1 <<< "$o" | cut -c1-120)"; echo "apple_audio_lifecycle 单测全过"; exit 0; fi
echo "不通 ${P#$H/}（NativeAOT，rc=${r}）：$(tail -3 <<< "$o" | tr '\n' ' ' | cut -c1-300)"; echo "apple_audio_lifecycle 单测有不通"; exit 1
