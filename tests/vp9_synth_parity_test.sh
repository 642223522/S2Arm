#!/usr/bin/env bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Nvdec/Vp9*.cs compat/tree/src/Ryujinx.Graphics.Nvdec/Vpx/* compat/tree/src/Ryujinx.Graphics.Nvdec/Types/Vp9/* compat/tree/src/Ryujinx.Graphics.Nvdec.Vp9/** compat/tree/src/Ryujinx.Graphics.Video/*Vp9* services/vpx/** tests/vp9_native_parity/* tests/vp9_synth_parity/* tests/data/vp9_synth/*
# 原生 VP9（libvpx + S2Arm 补丁，Vp9NativeFrame.cs 写帧头 / 参考槽）与托管解码器的逐作业对拍，合成码流版（t_vp9_native_parity.sh 要设备抓取、门禁跑不了）：
#   不打补丁的 libvpx 1.17.0（同 services/vpx/build.sh 的源码包）加测试专用钩子（tests/vp9_synth_parity/jobgen_hook.patch，默认 NULL）解 tests/data/vp9_synth
#   的合成码流，jobgen.c 把每个解出的帧写成游戏驱动交给 NVDEC 的作业（S2V9 v1，与设备抓取同格式），再由 tests/vp9_native_parity 逐作业跑原生与托管：
#   画面、MV 回写、计数逐字节相同，且画面等于 libvpx 自己解出的（三方一致）。不含任何游戏数据。
# 负对照（每次都跑）：只给托管解码器错的锐度 → 原生≠托管必须红；两边同样错 → 原生=托管但≠libvpx，必须靠参考哈希红（证明三方那一条不瞎）。
# 已知缺口：fp_ragged（350x198）的托管画面在右下角最后一个不满的超级块与 libvpx 不同（原生一致），该流只要求原生=libvpx、MV / 计数原生=托管。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd -P)
[ "$(uname -s)" = Darwin ] || { echo "vp9_synth_parity：要苹果配方的 libs2a_vpx.dylib（macOS），本机 $(uname -s)" >&2; exit 75; }
command -v xcrun >/dev/null || { echo 'missing Xcode' >&2; exit 75; }
command -v dotnet >/dev/null || { echo 'missing .NET SDK' >&2; exit 75; }
export MSBUILDDISABLENODEREUSE=1
RID=osx-$( [ "$(uname -m)" = arm64 ] && echo arm64 || echo x64 )
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# 1. 作业生成器：不打 S2Arm 补丁的 libvpx（版本与 sha256 取 services/vpx/build.sh 那一行）+ 钩子，只解码、单线程（几秒）
eval "$(grep -m1 '^VER=' "$H/services/vpx/build.sh")"
source "$H/android/tools/fetch_source.sh"
TGZ=$(s2a_source_fetch "libvpx-$VER.tar.gz" "https://github.com/webmproject/libvpx/archive/refs/tags/v$VER.tar.gz" "$SHA")
mkdir -p "$W/src" "$W/obj"; tar xzf "$TGZ" -C "$W/src" --strip-components 1
patch -p1 -s -d "$W/src" < "$H/tests/vp9_synth_parity/jobgen_hook.patch"
( cd "$W/obj" && CC="xcrun clang" "$W/src/configure" --disable-vp8 --disable-vp9-encoder --enable-vp9-decoder --disable-examples --disable-tools \
    --disable-docs --disable-unit-tests --disable-webm-io --disable-libyuv --enable-static --disable-shared > "$W/configure.log" 2>&1 &&
  make -j8 > "$W/make.log" 2>&1 ) || { echo "🔴 vp9_synth_parity：生成器用的 libvpx 构建失败" >&2; tail -5 "$W"/*.log >&2; exit 1; }
xcrun clang -std=c11 -O2 -I"$W/src" -I"$W/obj" "$H/tests/vp9_synth_parity/jobgen.c" "$W/obj/libvpx.a" -o "$W/jobgen"

# 2. 被测的原生库（产品配方）与对拍程序
lib=$(bash "$H/services/vpx/build.sh" "$RID" | tail -1)
cd "$H/compat/tree"   # SDK（global.json）与包源（nuget.config）跟当前目录走
dotnet build "$H/tests/vp9_native_parity/Vp9NativeParity.csproj" -c Release -m:1 -p:UseSharedCompilation=false --nologo -v q
run() { dotnet "$H/tests/vp9_native_parity/bin/Release/net10.0/Vp9NativeParity.dll" "$W/jobs/$1" "${lib%/*}/libs2a_vpx.dylib" "$2"; }

# 3. 对拍
fails=0
for s in adapt_720 resize fp_ragged; do
    mkdir -p "$W/jobs/$s"; "$W/jobgen" "$H/tests/data/vp9_synth/$s.ivf" "$W/jobs/$s"
    mode=--ref; [ "$s" = fp_ragged ] && mode=--ref-native
    if run "$s" "$mode"; then echo "通 ${s}（${mode}）"; else echo "🔴 ${s}：原生 / 托管 / libvpx 不一致"; fails=$((fails + 1)); fi
done

# 4. 负对照：必须红
for p in managed both; do
    if S2A_VP9_PARITY_PERTURB=$p run adapt_720 --ref > "$W/neg.log"; then
        echo "🔴 负对照 $p 没红：对拍看不出差别"; cat "$W/neg.log"; fails=$((fails + 1))
    else echo "通 负对照 $p 红了：$(tr "\n" " " < "$W/neg.log")"; fi
done
[ "$fails" = 0 ] && echo "vp9_synth_parity 单测全过" || { echo "vp9_synth_parity：$fails 项不过"; exit 1; }
