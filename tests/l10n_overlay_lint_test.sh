#!/bin/bash
# 门禁覆盖：tools/l10n_overlay_lint.py launchers/shared/l10n launchers/macos/frontend/l10n launchers/shared/experience.v1.json launchers/macos/adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json
# 各语言叠加文案占位符门禁（tools/l10n_overlay_lint.py，11-14 加新语言）：名字带 lint，入队确定性快检查自动跑。期望按构造手写：
#   ① 假仓库：launcher 译文带同样的 {0}、text 译文带同样的 {0}、前端译文把 %@ / %ld 换成位置写法 %2$ld / %1$@ → 退出 0、不一致 0
#   ② launcher 译文丢了 {0} → 退出 1，点名 l10n/xx.json 与键 a
#   ③ 原表里已删的键 → 退出 0，只提示「原表已删」
#   ④ 真仓库：不一致 0 处
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
D=$H/tools/l10n_overlay_lint.py
R=$T/r; mkdir -p $R/launchers/shared/l10n $R/launchers/macos/frontend/l10n $R/launchers/macos/adapter/Sources/S2ArmAppleAdapter/Resources
printf '{"launcher": {"items": [{"id": "a", "zh-Hans": "你好 {0}", "en": "Hi {0}"}]}}\n' > $R/launchers/shared/experience.v1.json
printf '[{"source": "还剩 {0} 款", "en": "{0} left"}]\n' > $R/launchers/macos/adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json
printf '{"x": "%%@ of %%ld"}\n' > $R/launchers/macos/frontend/l10n/en.json
printf '{"_language": {"name": "X"}, "x": "%%2$ld 之 %%1$@"}\n' > $R/launchers/macos/frontend/l10n/xx.json
printf '{"launcher": {"a": "嗨 {0}"}, "text": {"还剩 {0} 款": "還剩 {0} 款"}}\n' > $R/launchers/shared/l10n/xx.json
o=$(python3 $D $R 2>&1); r=$?
ck "① 占位符一致（含位置写法）→ 退出 0（${r}）、不一致 0" '[ $r = 0 ] && grep -q "不一致 0 处" <<< "$o"'
printf '{"launcher": {"a": "嗨"}, "text": {"还剩 {0} 款": "還剩 {0} 款"}}\n' > $R/launchers/shared/l10n/xx.json
o=$(python3 $D $R 2>&1); r=$?
ck "② launcher 译文丢了 {0} → 退出 1、点名 xx.json 与键 a（${r}）" '[ $r = 1 ] && grep -q "launchers/shared/l10n/xx.json launcher「a」占位符和原文不一致" <<< "$o"'
printf '{"launcher": {"a": "嗨 {0}", "gone": "舊"}, "text": {}}\n' > $R/launchers/shared/l10n/xx.json
o=$(python3 $D $R 2>&1); r=$?
ck "③ 原表已删的键只提示 → 退出 0（${r}）" '[ $r = 0 ] && grep -q "1 条原表已删" <<< "$o"'
o=$(python3 $D $H 2>&1); r=$?
ck "④ 真仓库：不一致 0 处（${o##*$'\n'}）" '[ $r = 0 ] && grep -q "不一致 0 处" <<< "$o"'
[ $bad = 0 ] && echo "l10n_overlay_lint 单测全过" || { echo "l10n_overlay_lint 单测有不通"; exit 1; }
