#!/usr/bin/env bash
# 新图形层设备普查：在接着的安卓设备上直连起一局，收齐回报要的 7 项，写成一个目录 + 一页 report.md。
#   bash android/tools/nvk_survey.sh <程序号> [秒数=60] [输出目录=./nvk-survey-<程序号>-<时间>]
# 前提：
#   · 设备上装的是新层的包（构建时带 S2ARM_ANDROID_VK_BACKEND=nvk，见 docs/安卓新图形层_联合开发.md）；
#   · 这款游戏已经在应用里导入过；
#   · adb 在 PATH 上，或设了 ANDROID_HOME / ANDROID_SDK_ROOT；接了多台设备时设 ANDROID_SERIAL。
# 只读数：不改设备上的游戏与存档；收完把调试属性复位、把游戏进程停掉。
# 收的 7 项（docs/安卓新图形层_联合开发.md「回报什么」）：
#   1 机型 / 芯片 / 系统版本 / 刷新率   2 程序号   3 未接清单   4 其它红行   5 最后一行呈现读数   6 截图   7 进程是否还在（没了附崩溃日志）
set -euo pipefail
T=${1:?用法：nvk_survey.sh <程序号> [秒数=60] [输出目录]}
S=${2:-60}
case $T in [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) ;; *) echo "【红】程序号要 16 位十六进制：$T" >&2; exit 2;; esac
case $S in ''|*[!0-9]*) echo "【红】秒数要是整数：$S" >&2; exit 2;; esac
O=${3:-./nvk-survey-$T-$(date +%Y%m%d-%H%M%S)}
P=org.s2arm.android

ADB=$(command -v adb 2> /dev/null || true)
if [ -z "$ADB" ]; then
  for d in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    if [ -n "$d" ] && [ -x "$d/platform-tools/adb" ]; then ADB=$d/platform-tools/adb; break; fi
  done
fi
[ -n "$ADB" ] || { echo "【红】找不到 adb（PATH、ANDROID_HOME、ANDROID_SDK_ROOT 都没有）" >&2; exit 2; }
a() { "$ADB" "$@" < /dev/null; }
n=$(a devices | awk 'NR > 1 && $2 == "device"' | wc -l | tr -d ' ')
if [ "$n" = 0 ]; then echo "【红】没有接着的设备（adb devices 里没有 device 状态的）" >&2; exit 2; fi
if [ "$n" != 1 ] && [ -z "${ANDROID_SERIAL:-}" ]; then echo "【红】接了 ${n} 台设备：设 ANDROID_SERIAL 指定一台" >&2; exit 2; fi
a shell pm path "$P" > /dev/null 2>&1 || { echo "【红】设备上没装 ${P}" >&2; exit 2; }

mkdir -p "$O"
prop() { a shell getprop "$1" | tr -d '\r'; }
restore() { a shell "am force-stop $P; setprop debug.s2a.debug_env 0" > /dev/null 2>&1 || true; }
trap restore EXIT

a shell "setprop debug.s2a.debug_env 1; am force-stop $P; logcat -c; logcat -b crash -c; input keyevent WAKEUP"
a shell am start -W -n "$P/$P.MainActivity" --es s2arm.title_id "$T" --ez s2arm.experimental_revision true --es s2arm.graphics_mode direct > /dev/null
t0=$SECONDS
while [ $((SECONDS - t0)) -lt "$S" ]; do
  sleep 3
  if [ $((SECONDS - t0)) -gt 6 ] && [ -z "$(a shell pidof "$P:game" | tr -d '\r')" ]; then break; fi   # 进程没了立刻收
done
waited=$((SECONDS - t0))
alive=$(a shell pidof "$P:game" | tr -d '\r')
a logcat -d -s S2Arm > "$O/logcat.txt"
LC_ALL=C grep -a -v 'prev|' "$O/logcat.txt" > "$O/this-run.txt" || true   # 带 prev| 的是应用转述的上一局日志，不算这一局的
a logcat -d -b crash > "$O/crash.txt"
"$ADB" exec-out screencap -p < /dev/null > "$O/screen.png"

g() { LC_ALL=C grep -a "$@" || true; }
hz=$(a shell dumpsys display | g -m1 -o -E 'fps=[0-9.]+' | head -1)
session=$(g -E 'nvk session: backend open|graphics selection' "$O/this-run.txt" | sed 's/^.*S2Arm *: //' | tail -2)
unimpl=$(g '未接：' "$O/this-run.txt" | sed 's/.*未接：//; s/（首次.*//')
red=$(g '【红】' "$O/this-run.txt" | g -v '未接：' | sed 's/^.*S2Arm *: //' | cut -c1-200 | sort | uniq -c | sort -rn)
present=$(g 'nvk present: 第' "$O/this-run.txt" | sed 's/^.*nvk present: //' | tail -1)
crash=$(g -E 'signal |Abort message' "$O/crash.txt" | head -3 | cut -c1-200)

{
  echo "# 新图形层设备普查"
  echo
  echo "| 项 | 值 |"
  echo "|---|---|"
  echo "| 机型 | $(prop ro.product.manufacturer) $(prop ro.product.model) |"
  echo "| 芯片 | $(prop ro.soc.manufacturer) $(prop ro.soc.model)（平台 $(prop ro.board.platform)） |"
  echo "| 系统 | Android $(prop ro.build.version.release)（API $(prop ro.build.version.sdk)） |"
  echo "| 刷新率 | ${hz:-读不到} |"
  echo "| 程序号 | $T |"
  echo "| 仓库提交 | $(git -C "$(dirname "$0")" rev-parse --short HEAD 2> /dev/null || echo 不在仓库里跑) |"
  echo "| 起局后等了 | ${waited} 秒（上限 ${S}） |"
  if [ -n "$alive" ]; then echo "| 游戏进程 | 还在 |"; else echo "| 游戏进程 | 没了 |"; fi
  echo
  echo "## 选路与会话"
  echo '```'
  echo "${session:-（日志里没有会话行：多半没走到新层，核对包是不是带 nvk 编的）}"
  echo '```'
  echo "## 未接清单（每种一行，按首次出现的先后）"
  echo '```'
  echo "${unimpl:-（0 种）}"
  echo '```'
  echo "## 其它红行（去重计数）"
  echo '```'
  echo "${red:-（0 行）}"
  echo '```'
  echo "## 最后一行呈现读数"
  echo '```'
  echo "${present:-（没有：还没呈现满 600 帧，或没走到呈现）}"
  echo '```'
  echo "## 崩溃"
  echo '```'
  echo "${crash:-（无）}"
  echo '```'
  echo
  echo "截图：screen.png；完整日志：logcat.txt；崩溃日志：crash.txt。回报时把这一页贴进 Issue，三个文件作附件。"
} > "$O/report.md"
cat "$O/report.md"
echo
rm -f "$O/this-run.txt"
echo "已写到 ${O}/"
