#!/bin/bash
# 本机自签（ad-hoc）：pack/oneclick/adhoc_sign.sh <S2Arm.app> <权限文件>   pack/ipa.sh 在 S2A_SIGN=adhoc 时调
# 给没有付费开发者账号的玩家侧载用：AltStore / Sideloadly / Xcode 个人团队重签时按 App 原签名里的权限去申请，真不签名会丢「提高内存上限」。
# 所以不嵌描述文件、不要团队，但带上权限文件（pack/app.entitlements，只有 increased-memory-limit：免费个人团队能签、整块 64 GB 窗口 + 6 GB 上限，
#   见 docs/研究/免费账号.md）。先签内嵌库（深的先签），再带权限签 App，最后核签名里确有这项权限。
set -u
APP=${1:?App 路径}; ENT=${2:?权限文件}
[ -d "$APP" ] && [ -f "$ENT" ] || { echo "🔴 App 或权限文件不在"; exit 1; }
rm -f "$APP/embedded.mobileprovision"
# 扩展属性（Finder 信息、资源分叉、iCloud 同步的桌面 / 文稿里文件被挂上的属性）codesign 一律拒签「resource fork, Finder information,
#   or similar detritus not allowed」（#1138：游戏库在 ~/Desktop，成功两次后每次都卡在内嵌库）。签名前整棵清掉，苹果给的标准做法
xattr -cr "$APP" 2> /dev/null || :
# App 在 exFAT 盘上时还会有 AppleDouble 附属文件 ._<名>（存扩展属性用；被不认得它的拷贝当普通文件带进来就清不掉，成了孤儿）：
#   它不是 App 的内容，codesign 把 ._NS2Pro.framework 当库去签报 Operation not permitted（#1529）。签名前一并删掉
find "$APP" -name '._*' -exec rm -f {} + 2> /dev/null || :
n=0
while IFS= read -r p; do
  err=$(codesign --force --sign - --timestamp=none "$p" 2>&1 > /dev/null) || { echo "🔴 自签内嵌库失败：${p#$APP/}（${err##*: }）"; exit 1; }; n=$((n + 1))
done < <(find "$APP" \( -name '*.dylib' -o -name '*.framework' \) -print | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)
codesign --force --sign - --timestamp=none --entitlements "$ENT" "$APP" || { echo "🔴 自签 App 失败"; exit 1; }
got=$(codesign -d --entitlements - --xml "$APP" 2> /dev/null)
grep -q 'com.apple.developer.kernel.increased-memory-limit' <<< "$got" || { echo "🔴 签名里没有「提高内存上限」权限（com.apple.developer.kernel.increased-memory-limit）"; exit 1; }
echo "🟢 自签：内嵌 $n 个库，权限只带提高内存上限（侧载工具重签时按它申请）"
