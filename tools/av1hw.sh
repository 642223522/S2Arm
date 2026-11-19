#!/bin/bash
# AV1 硬件解码探测（S2A_DAV1D=auto 的判据，Makefile / services/build.mk / 启动器 Python 都走这里）：
#   VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) 说本机有 AV1 硬解、且用真 av1C（graphics/nvn/tests/t_nvn2_codec.c av1c_want 那份
#   96x64 序列头，ffmpeg 封 WebM 时写的 CodecPrivate）真建得出 AV1 解码会话（CMVideoFormatDescriptionCreate +
#   VTDecompressionSessionCreate）——两条都过才算有。判法与运行时同一条路（nvn2_codec.c 的 AV1 先 VideoToolbox、失败才回 dav1d），
#   单独信 VTIsHardwareDecodeSupported 不行：VP9 上实测过它报 true 而会话建不出（nvn2_codec.c nvn2_vp9_vt_probe 的注）。
# 输出（stdout 恰好一行）：1 = 本机有 AV1 硬解（AV1 走 VideoToolbox，dav1d 软解兜底整条不进构建 / 出包）；0 = 没有（要 dav1d）。
#   探测失败（xcrun / 编译 / 运行任一步挂了）也回 0：保守保留软解兜底 = 原默认行为；失败结果不缓存（装好 Xcode 后下次重新探测）。
# --want：回「本机构建要不要 dav1d 软解兜底」（1 要 / 0 不要）。S2A_DAV1D=1 / 0 直接透传、不探测；
#   没设 / auto = 探测结果取反（有硬解就不要软解）。启动器 Python（prepare_build.py / bundle_engine.py / applenv.py）与
#   顶层 Makefile（S2A_DAV1D_EFF）都按这个口径调。
# 结果按本脚本内容哈希缓存在 ${S2A_AV1HW_CACHE:-${S2A_RUN_ROOT:-~/.s2arm/run}/s2arm/cache/av1hw}/<哈希>/result：
#   本机的 AV1 硬解不会变，缓存终身有效；改了本脚本（判法 / av1C）= 换键 = 重新探测。几棵树同时探测照 services/dav1d/build.sh 的
#   .lock 排队。缓存根可能带空格（启动器的 S2A_RUN_ROOT 在 ~/Library/Application Support 下）：照 build.sh 走无空格别名。
#   编译用 xcrun（认 DEVELOPER_DIR）；av1C 不进构建键——它写死在本脚本里，改它自然换脚本哈希换键。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# --want：S2A_DAV1D 给了 1 / 0 就直接回，不出编译器
if [ "${1:-}" = --want ]; then
  case ${S2A_DAV1D:-auto} in
    1|0) echo "${S2A_DAV1D}"; exit 0;;
  esac
fi
want=0; [ "${1:-}" = --want ] && want=1
C=${S2A_AV1HW_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/av1hw}
source "$ROOT/tools/nospace.sh"
if ! C=$(s2a_nospace "$C"); then
  echo "🔴 av1hw：建不了缓存目录的无空格别名" >&2
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
    if W=$(mktemp -d "${TMPDIR:-/tmp}/s2a-av1hw.XXXXXX"); then
      cat > "$W/probe.c" <<'EOF'
// av1hw 探针：两条都过（VTIsHardwareDecodeSupported 说有硬件 + 真 av1C 建得出 VideoToolbox 解码会话）才打 1（与运行时 AV1 路线同一条判法）
#include <stdio.h>
#include <VideoToolbox/VideoToolbox.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
int main(void) {
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) { puts("0"); return 0; }
    static const uint8_t av1c[] = {0x81,0x00,0x0c,0x00, 0x0a,0x0b,0x02,0x00,0x00,0x05,0x55,0x7f,0xfc,0x6a,0xf9,0x80,0x40};
    CFDataRef cd = CFDataCreate(NULL, av1c, (CFIndex)sizeof av1c);
    if (!cd) { puts("0"); return 0; }
    const void *ak[] = { CFSTR("av1C") }, *av[] = { cd };
    CFDictionaryRef atoms = CFDictionaryCreate(NULL, ak, av, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *ek[] = { kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms }, *ev[] = { atoms };
    CFDictionaryRef ext = CFDictionaryCreate(NULL, ek, ev, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus st = atoms && ext ? CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_AV1, 96, 64, ext, &fmt) : -1;
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
