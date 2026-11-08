#!/bin/bash
# 门禁覆盖：launchers/macos/sign_release.sh
# 发版签名不签预编 iOS 壳（11-08 beta.8 验收）：Contents/Resources/Shell 下的 Mach-O 和 .framework 不进签名清单，其余照常。
#   手算期望：造 App 树——Contents/MacOS/main（Mach-O 魔数）、Contents/Resources/Shell/root/S2Arm（Mach-O）、Shell/root/Frameworks/NS2Pro.framework/NS2Pro（Mach-O）、
#   Contents/Frameworks/X.framework/X（Mach-O）→ Mach-O 清单只有 main 与 X.framework/X（2 个），捆绑包清单只有 Contents/Frameworks/X.framework（1 个）。
#   负对照 = 旧脚本（不排除壳）清单里会有 3+1 个壳条目，下面的「壳条目数」必须是 0
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
A=$T/S2Arm.app; mkdir -p $A/Contents/MacOS $A/Contents/Resources/Shell/root/Frameworks/NS2Pro.framework $A/Contents/Frameworks/X.framework
M=$(printf '\xcf\xfa\xed\xfe'); for f in Contents/MacOS/main Contents/Resources/Shell/root/S2Arm Contents/Resources/Shell/root/Frameworks/NS2Pro.framework/NS2Pro Contents/Frameworks/X.framework/X; do printf '%s-body' "$M" > $A/$f; done
py() { awk -v tag="$1" '$0 ~ "<<'"'"'PY'"'"'" {n++; next} n==tag+0 && /^PY$/ {exit} n==tag+0 {print}' $H/launchers/macos/sign_release.sh; }
py 1 > $T/machos.py; py 2 > $T/bundles.py
python3 -I $T/machos.py $A > $T/machos.txt; python3 -I $T/bundles.py $A > $T/bundles.txt
ck "Mach-O 清单 $(wc -l < $T/machos.txt | tr -d ' ') 个（期望 2）、壳条目 $(grep -c '/Shell/' $T/machos.txt)（期望 0）" '[ "$(wc -l < $T/machos.txt | tr -d " ")" = 2 ] && [ "$(grep -c /Shell/ $T/machos.txt)" = 0 ]'
ck "捆绑包清单 $(wc -l < $T/bundles.txt | tr -d ' ') 个（期望 1，X.framework）、壳条目 $(grep -c '/Shell' $T/bundles.txt)（期望 0）" '[ "$(wc -l < $T/bundles.txt | tr -d " ")" = 1 ] && grep -q "Contents/Frameworks/X.framework" $T/bundles.txt && [ "$(grep -c /Shell $T/bundles.txt)" = 0 ]'
rm -rf $T; [ $bad = 0 ] && echo "sign_skip_shell 单测全过" || { echo "sign_skip_shell 单测有不通"; exit 1; }
