#!/bin/bash
# App 图标：Branding/AppIcon-1024.png（维护者 11-08 定稿的玻璃 S 标）→ S2Arm.icns。
#   原图铺满整个 1024 方形、不带圆角和透明留边，圆角由系统套（10-25 维护者：Dock 里我们的图标比别人小一圈、外面多一层灰框——
#   macOS 26 把自带圆角 + 透明留边的旧式图标整个缩小装进灰色圆角框；铺满后系统按标准形状遮罩，与其他 App 一致）
# 用法：bash make_icns.sh <输出.icns>；只用系统自带 sips / iconutil
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)/Branding/AppIcon-1024.png"; OUT=$1
T=$(mktemp -d); S="$T/S2Arm.iconset"; mkdir "$S"
for n in 16 32 128 256 512; do
  sips -z $n $n "$SRC" --out "$S/icon_${n}x${n}.png" > /dev/null
  sips -z $((n * 2)) $((n * 2)) "$SRC" --out "$S/icon_${n}x${n}@2x.png" > /dev/null
done
iconutil -c icns "$S" -o "$OUT"
rm -rf "$T"
