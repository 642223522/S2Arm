#!/bin/bash
# libvpx 的空垫片静态库（stub.c 合成的 libs2a_vpx_stub.a）：S2A_VPX 探测到本机可走系统 VP9（tools/vp9hw.sh）、不链 libvpx 时
#   链这一份（services/build.mk），垫住 C# 侧 DirectPInvoke 的静态强引用（S2A.Aot.csproj DirectPInvoke s2a_vpx）。
#   为什么不是「放行未定义符号」：C# NativeAOT 的 DirectPInvoke 是强引用，链接器放行了也过不了 dyld——启动绑定就报
#   symbol not found（实测，弱链接放行那条路只对弱引用行得通）；垫一份全失败的 stub，VP9 走系统路线、VP8 如实报红，不出假画面。
# 用法：bash services/vpx/build_stub.sh [osx-arm64|osx-x64|ios-arm64|tvos-arm64] → 最后一行输出 libs2a_vpx_stub.a 路径。
#   按本脚本 + stub.c 内容哈希缓存在 ${S2A_VPX_STUB_CACHE:-~/.s2arm/run/s2arm/cache/vpx-stub}（S2A_RUN_ROOT 同 dav1d/build.sh），命中秒过；
#   不走预编库（services/prebuilt_lib.sh）：它只为垫住引用，玩家机器上本地编（半秒级）就够，App 里不值得多一份产物。
set -euo pipefail
RID=${1:-osx-arm64}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TCE=$ROOT/tools/toolchain.env; MMAC=$(sed -n 's/^MACOSX_DEPLOYMENT_TARGET=//p' "$TCE"); MIOS=$(sed -n 's/^IPHONEOS_DEPLOYMENT_TARGET=//p' "$TCE"); MTVOS=$(sed -n 's/^TVOS_DEPLOYMENT_TARGET=//p' "$TCE")
[ -n "$MMAC" ] && [ -n "$MIOS" ] && [ -n "$MTVOS" ] || { echo "🔴 vpx-stub：$TCE 里没有部署目标" >&2; exit 1; }
ARCH=arm64; MIN=-mmacosx-version-min=$MMAC; SDK=macosx
case $RID in
  osx-x64) ARCH=x86_64; SDK=macosx ;;
  ios-arm64) MIN=-miphoneos-version-min=$MIOS; SDK=iphoneos ;;
  tvos-arm64) MIN=-mtvos-version-min=$MTVOS; SDK=appletvos ;;
  osx-arm64) ;;
  *) echo "🔴 vpx-stub：不认识的平台 $RID" >&2; exit 1 ;;
esac
# 构建键 = 本脚本 + stub.c + 系统下限（内容哈希，不含路径：同 dav1d / vpx 的口径），键进缓存目录名；编译器版本另算进目录名（同 dav1d/build.sh 的审计）
H1=$( { cat "$0" "$ROOT/services/vpx/stub.c"; echo "$MIN"; } | shasum -a 256 | cut -c1-12)
C=${S2A_VPX_STUB_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/vpx-stub}; mkdir -p "$C"
source "$ROOT/tools/nospace.sh"; C=$(s2a_nospace "$C") || { echo "🔴 vpx-stub：建不了缓存目录的无空格别名" >&2; exit 1; }
# 几棵树同时编同一键时排队（同 dav1d/build.sh）
until mkdir "$C/.lock" 2> /dev/null; do p=$(cat "$C/.lock/pid" 2> /dev/null || true); [ -n "$p" ] && ! kill -0 "$p" 2> /dev/null && rm -rf "$C/.lock"; sleep 0.5; done
echo $$ > "$C/.lock/pid"; trap 'rm -rf "$C/.lock"' EXIT
OUT=$C/$RID-$H1
CC="xcrun --sdk $SDK clang -arch $ARCH $MIN"
TCV=$($CC --version 2> /dev/null | sed -n 1p) || TCV=
[ -n "$TCV" ] || { echo "🔴 vpx-stub：取不到 $SDK clang 的版本行（xcrun 失败），不出库" >&2; exit 1; }
OUT=$OUT-$(printf '%s' "$TCV" | shasum -a 256 | cut -c1-8)
L=$OUT/libs2a_vpx_stub.a
if [ ! -s "$L" ]; then
  W=$OUT.tmp; rm -rf "$W"; mkdir -p "$W"
  $CC -O2 -c "$ROOT/services/vpx/stub.c" -o "$W/stub.o" > "$W/cc.log" 2>&1 || { echo "🔴 vpx-stub：$RID 编译失败（$W/cc.log）" >&2; tail -5 "$W/cc.log" >&2; exit 1; }
  xcrun --sdk $SDK ar rcs "$W/libs2a_vpx_stub.a" "$W/stub.o"
  rm -rf "$OUT"; mv "$W" "$OUT"
fi
touch "$OUT"   # 取用即更新目录时间：同 dav1d 的维护口径
echo "$L"
