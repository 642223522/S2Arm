#!/bin/bash
# 门禁覆盖：tools/l10n_dupkeys.py .gitattributes launchers/shared/experience.v1.json launchers/macos/adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json launchers/macos/frontend/l10n ios/l10n ios/Settings.bundle shell/Sources/ShellUI/Resources/Localizable.xcstrings
# 本地化 / 体验表内重复键（tools/l10n_dupkeys.py，11-11 合入运维线）：名字带 lint，入队确定性快检查自动跑，重复就当场拒收、点名哪张表哪个键第几项。
#   起因：launcher/ios-error-codes 的 Localizable.json 同一个 source 写了两条，按键合并器判不了、每次合 main 冲突退回。期望按构造手写：
#   ① 假仓库四张表都干净 → 退出 0、「重复 0 处」
#   ② 条目表 source 重复 → 退出 1，点名表、「从电脑重新装到 iPhone。」、第 3 项与第 2 项同
#   ③ JSON 对象同名键两次（键值表 / xcstrings 的 strings 下）→ 点名键
#   ④ .strings 同一个键两行 → 点名第几行
#   ⑤ 体验表对象数组 id 重复（没登记 merge=s2a-l10n 也查）→ 点名
#   ⑥ 真仓库：重复 0 处（上线前确认没有存量，不拦所有人）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
D=$H/tools/l10n_dupkeys.py
R=$T/r; mkdir -p $R/a $R/launchers/shared; git init -q $R
printf 'a/L.json merge=s2a-l10n\na/K.json merge=s2a-l10n\na/S.strings merge=s2a-l10n\n' > $R/.gitattributes
printf '[\n {"source": "甲", "en": "A"},\n {"source": "从电脑重新装到 iPhone。", "en": "x"}\n]\n' > $R/a/L.json
printf '{\n  "k1": "一",\n  "k2": "二"\n}\n' > $R/a/K.json
printf '"k1" = "一";\n"k2" = "二";\n' > $R/a/S.strings
printf '{\n  "revision": 1,\n  "launcher": {"items": [{"id": "a"}, {"id": "b"}]}\n}\n' > $R/launchers/shared/experience.v1.json
git -C $R add -A
o=$(python3 $D $R 2>&1); r=$?
ck "① 四张表干净 → 退出 0（${r}）、重复 0 处" '[ $r = 0 ] && grep -q "查了 4 张表，重复 0 处" <<< "$o"'
printf '[\n {"source": "甲", "en": "A"},\n {"source": "从电脑重新装到 iPhone。", "en": "x"},\n {"source": "从电脑重新装到 iPhone。", "en": "x"}\n]\n' > $R/a/L.json
o=$(python3 $D $R 2>&1); r=$?
ck "② 条目表 source 重复 → 退出 1、点名表 / 键 / 第 3 项与第 2 项（${o%%$'\n'*}）" '[ $r = 1 ] && grep -q "a/L.json/：第 3 项 source 重复「从电脑重新装到 iPhone。」（与第 2 项同）" <<< "$o"'
git -C $R checkout -q -- a/L.json 2> /dev/null || printf '[\n {"source": "甲", "en": "A"}\n]\n' > $R/a/L.json
printf '{\n  "k1": "一",\n  "k1": "壹"\n}\n' > $R/a/K.json
o=$(python3 $D $R 2>&1)
ck "③ 对象同名键两次 → 点名「k1」" 'grep -q "a/K.json：对象里键「k1」出现两次" <<< "$o"'
printf '{\n  "k1": "一"\n}\n' > $R/a/K.json; printf '"k1" = "一";\n"k2" = "二";\n"k1" = "壹";\n' > $R/a/S.strings
o=$(python3 $D $R 2>&1)
ck "④ .strings 同键两行 → 点名第 3 行" 'grep -q "a/S.strings：第 3 行键「k1」重复（与第 1 行同）" <<< "$o"'
printf '"k1" = "一";\n' > $R/a/S.strings
printf '{\n  "revision": 1,\n  "launcher": {"items": [{"id": "a"}, {"id": "a"}]}\n}\n' > $R/launchers/shared/experience.v1.json
o=$(python3 $D $R 2>&1); r=$?
ck "⑤ 体验表数组 id 重复（没登记也查）→ 退出 1、点名" '[ $r = 1 ] && grep -q "experience.v1.json/launcher/items：第 2 项 id 重复「a」" <<< "$o"'
o=$(python3 $D "$H" 2>&1); r=$?
ck "⑥ 真仓库：重复 0 处（$(tail -1 <<< "$o")）" '[ $r = 0 ]'
[ $bad = 0 ] && echo "l10n_dupkey_lint 单测全过" || { echo "l10n_dupkey_lint 单测有不通"; grep '【红】' <<< "$o" | head -5; exit 1; }
