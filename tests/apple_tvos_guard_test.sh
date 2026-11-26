#!/bin/bash
# 门禁覆盖：*.cs
# Apple TV 平台判断守卫（11-15 Apple TV 版，约 1 秒）：bash tests/apple_tvos_guard_test.sh
# OperatingSystem.IsIOS() 在 tvOS 上为假：按它分支的代码到电视上会走成非 iOS 那支（不挂 iOS 图层 = 黑屏、音频后端选不上、内存 / 休眠走错路）。
#   规则：C# 源码里每处 OperatingSystem.IsIOS() 同一行必须带 OperatingSystem.IsTvOS()（写成 (OperatingSystem.IsIOS() || OperatingSystem.IsTvOS())）。
#   只给 iOS、电视上确实不该走的分支另写 IsTvOS() 排除，同样满足本规则。测试工程（*Tests*、tests/）与安卓目录不扫。
# 期望（按规则手写）：① 全仓 0 处裸 IsIOS()；② 临时文件里写一处裸 IsIOS() → 报红并点名文件:行；写成带 IsTvOS 的 → 不报
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
scan() { grep -rn --include='*.cs' 'OperatingSystem\.IsIOS()' "$@" 2>/dev/null | grep -v 'IsTvOS' | grep -v -E '/(android|bin|obj)/|Tests?/|/tests/' ; }
got=$(cd "$H" && scan compat services graphics platform launchers tests/visual)
ck "① 全仓没有裸 OperatingSystem.IsIOS()（实得：${got:-无}）" '[ -z "$got" ]'
mkdir -p "$T/src"; printf 'class A { bool x = OperatingSystem.IsIOS(); }\n' > "$T/src/a.cs"; printf 'class B { bool y = (OperatingSystem.IsIOS() || OperatingSystem.IsTvOS()); }\n' > "$T/src/b.cs"
got2=$(scan "$T/src")
ck "② 裸写法报红且点名 a.cs:1、带 IsTvOS 的不报（实得：${got2}）" '[ "$(printf "%s\n" "$got2" | grep -c .)" = 1 ] && printf "%s" "$got2" | grep -q "a.cs:1:"'
[ $bad = 0 ] && echo "✅ apple_tvos_guard_test 全过" || { echo "🔴 apple_tvos_guard_test 有不通项"; exit 1; }
