#!/bin/bash
# 门禁覆盖：tools/l10n_merge.py .gitattributes
# 翻译表合并器单测（11-09：#221 #238 都往 Localizable.json 文件尾追加，先合一支另一支就冲突退回）：临时仓库登记合并器，两支各改依次合进 main。
# 期望（按规则手写）：
#   ① 条目表两支各在尾部追加一条 → 两次合并都不冲突，结果是合法 JSON：原条目在前、先合的、后合的依次在后，各一份
#   ② 键值表两支各加一个键、一支改了另一个键 → 不冲突，三处改动都在
#   ③ 两支把同一条英文改成不同的 → 仍冲突（留给人）
#   ④ 一支删了一条、另一支没动它 → 删掉
#   ⑤ .xcstrings（Xcode「" : "」格式）两支各在 strings 下加一个键 → 不冲突，两个键都在，仍是 Xcode 格式
#   ⑥ .strings 两支各在不同位置加一条（k1 后 / k2 后）、一支改 k3 → 不冲突，顺序 k1 a k2 b k3、k3 是改后的
#   ⑦ .strings 同一个键两边改成不同 → 仍冲突；⑧ .strings 注释两边都改 → 冲突
#   ⑨ 手排格式的 JSON（短数组写在一行，写不回原样）两支各加一个键 → 仍冲突（不碰，交人）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid GIT_CONFIG_GLOBAL=/dev/null
R=$T/r; git init -q -b main $R; cd $R
git config merge.s2a-l10n.driver "python3 $H/tools/l10n_merge.py %O %A %B %P"
printf 'L.json merge=s2a-l10n\nK.json merge=s2a-l10n\nX.xcstrings merge=s2a-l10n\nS.strings merge=s2a-l10n\nE.json merge=s2a-l10n\n' > .gitattributes
ent() { printf ' {\n  "source": "%s",\n  "en": "%s"\n }' "$1" "$2"; }
lst() { local s='[' sep=''; while [ $# -gt 0 ]; do s="$s$sep"$'\n'"$(ent "$1" "$2")"; sep=','; shift 2; done; printf '%s\n]\n' "$s"; }
lst 甲 A 乙 B > L.json; printf '{\n  "k1": "一",\n  "k2": "二"\n}\n' > K.json; git add -A; git commit -qm base
git checkout -q -b b1; lst 甲 A 乙 B 丙 C > L.json; printf '{\n  "k1": "一",\n  "k2": "二",\n  "k3": "三"\n}\n' > K.json; git commit -qam b1
git checkout -q main; git checkout -q -b b2; lst 甲 A 乙 B 丁 D > L.json; printf '{\n  "k1": "壹",\n  "k2": "二",\n  "k4": "四"\n}\n' > K.json; git commit -qam b2
git checkout -q main; git merge -q --no-edit b1 > /dev/null 2>&1; m1=$?; git merge -q --no-edit b2 > /dev/null 2>&1; m2=$?
ck "① 条目表两支尾部追加：不冲突（rc ${m1} / ${m2}），合法 JSON，顺序 甲乙丙丁" '[ $m1 = 0 ] && [ $m2 = 0 ] && [ "$(python3 -c "import json;print(\"\".join(e[\"source\"] for e in json.load(open(\"L.json\"))))")" = 甲乙丙丁 ]'
ck "② 键值表：k1 改成壹、k3 k4 都在" '[ "$(python3 -c "import json;d=json.load(open(\"K.json\"));print(d[\"k1\"],d[\"k3\"],d[\"k4\"])")" = "壹 三 四" ]'
git checkout -q -b c1 main; lst 甲 A1 乙 B 丙 C 丁 D > L.json; git commit -qam c1
git checkout -q -b c2 main; lst 甲 A2 乙 B 丙 C 丁 D > L.json; git commit -qam c2
git checkout -q main; git merge -q --no-edit c1 > /dev/null 2>&1; git merge -q --no-edit c2 > /dev/null 2>&1; m3=$?; git merge --abort 2> /dev/null
ck "③ 同一条两边改成不同 → 仍冲突（rc ${m3}）" '[ $m3 != 0 ]'
git checkout -q -b d1 main; lst 甲 A1 丙 C 丁 D > L.json; git commit -qam d1
git checkout -q -b d2 main; lst 甲 A1 乙 B 丙 C 丁 D 戊 E > L.json; git commit -qam d2
git checkout -q main; git merge -q --no-edit d1 > /dev/null 2>&1; git merge -q --no-edit d2 > /dev/null 2>&1; m4=$?
ck "④ 一支删乙、另一支加戊 → 不冲突（rc ${m4}），乙没了、戊在" '[ $m4 = 0 ] && [ "$(python3 -c "import json;print(\"\".join(e[\"source\"] for e in json.load(open(\"L.json\"))))")" = 甲丙丁戊 ]'
xc() { python3 -c 'import json,sys; print(json.dumps({"sourceLanguage":"zh-Hans","strings":{k:{"localizations":{"en":{"stringUnit":{"state":"translated","value":k.upper()}}}} for k in sys.argv[1:]},"version":"1.0"},ensure_ascii=False,indent=2,separators=(",", " : ")))' "$@"; }
st() { printf '/* 注释 %s */\n' "$1"; shift; for k in "$@"; do printf '"%s" = "%s";\n' "${k%%=*}" "${k#*=}"; done; }
git checkout -q main; xc ka kb > X.xcstrings; st 一 k1=1 k2=2 k3=3 > S.strings; printf '{\n  "revision": 1,\n  "langs": ["zh", "en"],\n  "a": 1\n}\n' > E.json; git add -A; git commit -qm base2
git checkout -q -b x1 main; xc ka kb kc > X.xcstrings; st 一 k1=1 a=A k2=2 k3=3 > S.strings; printf '{\n  "revision": 1,\n  "langs": ["zh", "en"],\n  "a": 1,\n  "b": 2\n}\n' > E.json; git commit -qam x1
git checkout -q -b x2 main; xc ka kb kd > X.xcstrings; st 一 k1=1 k2=2 b=B k3=三 > S.strings; printf '{\n  "revision": 1,\n  "langs": ["zh", "en"],\n  "a": 1,\n  "c": 3\n}\n' > E.json; git commit -qam x2
git checkout -q main; git merge -q --no-edit x1 > /dev/null 2>&1; git merge -q --no-edit x2 > /dev/null 2>&1; m5=$?
ck "⑤ .xcstrings 两支各加键：kc kd 都在、仍是「\" : \"」格式" 'python3 -c "import json;d=json.load(open(\"X.xcstrings\"));assert {\"kc\",\"kd\"}<=set(d[\"strings\"])" 2> /dev/null && grep -q "\" : " X.xcstrings'
ck "⑥ .strings 两支不同位置各加一条、一支改 k3：顺序 k1 a k2 b k3、k3=三" '[ "$(grep -o "^\"[^\"]*\"" S.strings | tr -d "\"" | tr "\n" " ")" = "k1 a k2 b k3 " ] && grep -q "^\"k3\" = \"三\";" S.strings'
ck "⑨ 手排 JSON 两支各加键 → 仍冲突（rc ${m5}，E.json 判未合并、本侧原样不改写）" '[ $m5 != 0 ] && git ls-files -u E.json | grep -q . && grep -q "\"b\": 2" E.json && ! grep -q "\"c\"" E.json'
git merge --abort 2> /dev/null; git checkout -q -f main
git checkout -q -b y1 main; st 一 k1=1 k2=二 k3=3 > S.strings; git commit -qam y1
git checkout -q -b y2 main; st 一 k1=1 k2=贰 k3=3 > S.strings; git commit -qam y2
git checkout -q main; git merge -q --no-edit y1 > /dev/null 2>&1; git merge -q --no-edit y2 > /dev/null 2>&1; m7=$?; git merge --abort 2> /dev/null; git reset -q --hard y1~1
ck "⑦ .strings 同键两边改成不同 → 冲突（rc ${m7}）" '[ $m7 != 0 ]'
git checkout -q -b z1 main; st 甲 k1=1 k2=2 k3=3 > S.strings; git commit -qam z1
git checkout -q -b z2 main; st 乙 k1=1 k2=2 k3=3 k4=4 > S.strings; git commit -qam z2
git checkout -q main; git merge -q --no-edit z1 > /dev/null 2>&1; git merge -q --no-edit z2 > /dev/null 2>&1; m8=$?; git merge --abort 2> /dev/null
ck "⑧ .strings 注释两边都改 → 冲突（rc ${m8}）" '[ $m8 != 0 ]'
[ $bad = 0 ] && echo "l10n_merge 单测全过"; exit $bad
