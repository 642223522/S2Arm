#!/bin/bash
# VP9 系统解码探测（S2A_VPX=auto 的判据，Makefile / services/build.mk / 启动器 Python 都走这里）：
#   VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9) 注册后，用真 vpcC（graphics/nvn/gfx/nvn/nvn2_codec.c
#   vp9_vt_fmt 那份 12 字节：profile 0 / level 41 / 8-bit 4:2:0 / 视频范围）真建一次 64x64 解码会话（CMVideoFormatDescriptionCreate +
#   VTDecompressionSessionCreate）——建得出才算本机可走系统 VP9。判据与运行时同一条（nvn2_codec.c nvn2_vp9_vt_probe、
#   VideoToolboxVp9Backend.Available，#348）；VTIsHardwareDecodeSupported 不能当判据：注册过 supplemental 它就报 true、
#   会话照样建不出（实测注册前 0 / 注册后 1，nvn2_codec.c 的注）。
# 输出（stdout 恰好一行）：1 = 本机可走系统 VP9（VP9 走 VideoToolbox，libvpx 整条不进构建 / 出包）；0 = 不行（要 libvpx）。
#   探测失败（xcrun / 编译 / 运行任一步挂了）也回 0：保守保留 libvpx = 原默认行为；失败结果不缓存（装好 Xcode 后下次重新探测）。
#   注意 0 不代表「VP9 解不了」：会话判据过不了的流（短边 < 64、动态分辨率等）本来就要回退——那是运行时逐流回退，与这里无关。
# --want：回「本机构建要不要 libvpx」（1 要 / 0 不要）。S2A_VPX=1 / 0 直接透传、不探测；没设 / auto = 探测结果取反
#   （可走系统 VP9 就不要 libvpx）。启动器 Python（prepare_build.py / bundle_engine.py）与顶层 Makefile（S2A_VPX_EFF）都按这个口径调。
# 结果按本脚本内容哈希缓存在 ${S2A_VPXHW_CACHE:-${S2A_RUN_ROOT:-~/.s2arm/run}/s2arm/cache/vp9hw}/<哈希>/result：本机的解码器
#   不会变，缓存终身有效；改了本脚本（判法 / vpcC）= 换键 = 重新探测。几棵树同时探测照 services/dav1d/build.sh 的 .lock 排队。
#   缓存根可能带空格（启动器的 S2A_RUN_ROOT 在 ~/Library/Application Support 下）：照 build.sh 走无空格别名。编译用 xcrun（认 DEVELOPER_DIR）。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# --want：S2A_VPX 给了 1 / 0 就直接回，不出编译器
if [ "${1:-}" = --want ]; then
  case ${S2A_VPX:-auto} in
    1|0) echo "${S2A_VPX}"; exit 0;;
  esac
fi
want=0; [ "${1:-}" = --want ] && want=1
C=${S2A_VPXHW_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/vp9hw}
source "$ROOT/tools/nospace.sh"
if ! C=$(s2a_nospace "$C"); then
  echo "🔴 vp9hw：建不了缓存目录的无空格别名" >&2
  [ "$want" = 1 ] && echo 1 || echo 0
  exit 0
fi
mkdir -p "$C"   # 建好再排队：否则 .lock 的 mkdir 因目录不存在永远失败、空转死循环
K=$(cat "$0" | shasum -a 256 | cut -c1-12); OUT=$C/$K
r=
[ -s "$OUT/result" ] && r=$(cat "$OUT/result")
if [ -z "$r" ]; then
  # 几棵树同时探测排队（同 services/dav1d/build.sh）
  until mkdir "$C/.lock" 2> /dev/null; do p=$(cat "$C/.lock/pid" 2> /dev/null || true); [ -n "$p" ] && ! kill -0 "$p" 2> /dev/null && rm -rf "$C/.lock"; sleep 0.5; done
  echo $$ > "$C/.lock/pid"; trap 'rm -rf "$C/.lock"' EXIT
  [ -s "$OUT/result" ] && r=$(cat "$OUT/result")   # 排到队时别的树刚探完
  if [ -z "$r" ]; then
    r=0; probed=
    if W=$(mktemp -d "${TMPDIR:-/tmp}/s2a-vp9hw.XXXXXX"); then
      cat > "$W/probe.c" <<'EOF'
// vp9hw 探针：注册 supplemental 后用真 vpcC 真建一次 64x64 VP9 解码会话（与运行时同一条判据，#348）
#include <stdio.h>
#include <VideoToolbox/VideoToolbox.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
int main(void) {
    if (!__builtin_available(macOS 11.0, *)) { puts("0"); return 0; }
    VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9);
    static const uint8_t vpcC[] = { 1, 0, 0, 0, 0, 41, 0x82, 2, 2, 2, 0, 0 };   // nvn2_codec.c vp9_vt_fmt 的 vpcC（full=0）
    CFDataRef cd = CFDataCreate(NULL, vpcC, (CFIndex)sizeof vpcC);
    if (!cd) { puts("0"); return 0; }
    const void *ak[] = { CFSTR("vpcC") }, *av[] = { cd };
    CFDictionaryRef atoms = CFDictionaryCreate(NULL, ak, av, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *ek[] = { kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms }, *ev[] = { atoms };
    CFDictionaryRef ext = CFDictionaryCreate(NULL, ek, ev, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus st = atoms && ext ? CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_VP9, 64, 64, ext, &fmt) : -1;
    if (atoms) CFRelease(atoms); if (ext) CFRelease(ext); CFRelease(cd);
    if (st || !fmt) { puts("0"); return 0; }
    int32_t pf = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef pfn = CFNumberCreate(NULL, kCFNumberSInt32Type, &pf);
    const void *bk[] = { kCVPixelBufferPixelFormatTypeKey }, *bv[] = { pfn };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, bk, bv, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    VTDecompressionSessionRef sess = NULL;
    st = pfn && attrs ? VTDecompressionSessionCreate(NULL, fmt, NULL, attrs, NULL, &sess) : -1;
    if (pfn) CFRelease(pfn); if (attrs) CFRelease(attrs); CFRelease(fmt);
    int ok = st == 0 && sess;
    if (sess) { VTDecompressionSessionInvalidate(sess); CFRelease(sess); }
    puts(ok ? "1" : "0");
    return 0;
}
EOF
      if xcrun clang -O2 "$W/probe.c" -o "$W/probe" -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework CoreFoundation \
          > "$W/cc.log" 2>&1 && "$W/probe" > "$W/out" 2> "$W/err"; then
        r=$(tail -1 "$W/out"); [ "$r" = 1 ] || r=0   # 探针只在末行打 1 / 0；异常输出一律按没有
        probed=1
      fi
      rm -rf "$W"
    fi
    # 只有真探出结果才缓存（探测失败不缓存：装好 Xcode 后下次重新探测）
    if [ -n "$probed" ]; then mkdir -p "$OUT"; printf '%s' "$r" > "$OUT/result"; fi
  fi
fi
if [ "$want" = 1 ]; then [ "$r" = 1 ] && echo 0 || echo 1; else echo "$r"; fi
