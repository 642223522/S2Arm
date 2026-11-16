#!/bin/bash
# 门禁覆盖：launchers/macos/*.swift launchers/windows/launcher/*.cs ios/*.m launchers/shared/experience.v1.json launchers/macos/frontend/l10n/en.json ios/l10n/en.lproj/S2ArmHost.strings tools/l10n_key_lint.py
# 界面文案键对表（11-15：v0.4.0 候选出包完成页金色横幅显示 [export.export.boost.title]——横幅收到会加「export.」前缀的 x，自己的键又带前缀；
#   标题、说明、四个分类共 6 个键都成了键名，候选重切）。本测让同类「前缀重复 / 键不存在」在入队预检就红。
# 期望（按规则手写，不跑被测实现推导）：
#   ① 真仓库：0 处问题，退出 0
#   ② 样例 Swift 取文案函数 x(id) = launcherText("export." + id)，调 x("export.done") → DOUBLE export.export.done；调 x("done") 对表不报
#   ③ 样例组件 Banner 收闭包 text: x，组件里 text("export.boost.title") 与分类表字面量 "export.boost.fps" → 各一条 DOUBLE；
#      同组件改传 text: { BackendText.launcherText($0, …) } → 不报
#   ④ 样例 C# S(id) => T("export.sign." + id)，S("export.sign.mode") → DOUBLE export.sign.export.sign.mode；T("nope.key") → MISSING
#   ⑤ 样例 iOS S2AL(@"app.ok") 不报，S2AL(@"app.nope") → MISSING
set -u
H=$(cd "$(dirname "$0")/.." && pwd); bad=0
ck() { if eval "$2"; then echo "🟢 $1"; else echo "🔴 $1"; bad=1; fi; }
T=$(mktemp -d "${TMPDIR:-/tmp}/t_l10n_key_lint.XXXXXX"); trap 'rm -rf "$T"' EXIT

o=$(python3 "$H/tools/l10n_key_lint.py" "$H" 2>&1); rc=$?
ck "① 真仓库 0 处（rc=$rc${o:+；$(head -3 <<< "$o" | tr '\n' ' ')}）" '[ $rc = 0 ] && [ -z "$o" ]'

R=$T/r
mkdir -p "$R/launchers/shared" "$R/launchers/macos/frontend/l10n" "$R/launchers/macos/frontend/Sources/A" "$R/launchers/windows/launcher/App" "$R/ios/l10n/en.lproj"
cat > "$R/launchers/shared/experience.v1.json" << 'E'
{"launcher": {"items": [{"id": "export.done"}, {"id": "export.boost.title"}, {"id": "export.boost.fps"}, {"id": "export.sign.mode"}]}}
E
echo '{"library.play": "Play"}' > "$R/launchers/macos/frontend/l10n/en.json"
printf '"app.ok" = "OK";\n' > "$R/ios/l10n/en.lproj/S2ArmHost.strings"
cat > "$R/launchers/macos/frontend/Sources/A/Page.swift" << 'E'
struct Page: View {
    private func x(_ id: String) -> String { BackendText.launcherText("export." + id, language: lang) }
    var body: some View {
        Text(x("export.done"))
        Text(x("done"))
        Banner(boost: boost, text: x)
    }
}
struct Banner: View {
    let text: (String) -> String
    private var parts: [String] { [("fps", "export.boost.fps")].map { _, id in text(id) } }
    var body: some View { Text(text("export.boost.title")) }
}
E
cat > "$R/launchers/windows/launcher/App/Sign.cs" << 'E'
class Sign {
    private string S(string id) => T("export.sign." + id);
    void Build() { var a = S("export.sign.mode"); var b = T("nope.key"); var c = T("export.done"); }
}
E
printf 'void f(void) { NSString *a = S2AL(@"app.ok"); NSString *b = S2AL(@"app.nope"); }\n' > "$R/ios/app.m"

o2=$(python3 "$H/tools/l10n_key_lint.py" "$R" 2>&1); rc2=$?
ck "② x(\"export.done\") → DOUBLE export.export.done（行 4）" 'grep -qE "^DOUBLE	launchers/macos/frontend/Sources/A/Page.swift:4	.*	export\.export\.done$" <<< "$o2"'
ck "② x(\"done\") 对表不报" '! grep -qE "Page.swift:5	" <<< "$o2"'
ck "③ 组件 text(\"export.boost.title\") → DOUBLE（行 12）" 'grep -qE "^DOUBLE	launchers/macos/frontend/Sources/A/Page.swift:12	.*	export\.export\.boost\.title$" <<< "$o2"'
ck "③ 组件分类表字面量 → DOUBLE export.export.boost.fps（行 11）" 'grep -qE "^DOUBLE	launchers/macos/frontend/Sources/A/Page.swift:11	.*	export\.export\.boost\.fps$" <<< "$o2"'
ck "④ C# S(\"export.sign.mode\") → DOUBLE export.sign.export.sign.mode" 'grep -qE "^DOUBLE	launchers/windows/launcher/App/Sign.cs:3	.*	export\.sign\.export\.sign\.mode$" <<< "$o2"'
ck "④ C# T(\"nope.key\") → MISSING；T(\"export.done\") 不报" 'grep -qE "^MISSING	launchers/windows/launcher/App/Sign.cs:3	.*	nope\.key$" <<< "$o2" && ! grep -q "	export.done$" <<< "$o2"'
ck "⑤ iOS S2AL(@\"app.nope\") → MISSING，app.ok 不报" 'grep -qE "^MISSING	ios/app.m:1	ios	S2AL	app\.nope$" <<< "$o2" && ! grep -q "app.ok" <<< "$o2"'
ck "②–⑤ 样例共 6 处、退出 1（rc=${rc2}，$(grep -c . <<< "$o2") 行）" '[ $rc2 = 1 ] && [ "$(grep -c . <<< "$o2")" = 6 ]'

sed -i.bak 's/Banner(boost: boost, text: x)/Banner(boost: boost, text: { BackendText.launcherText($0, language: lang) })/' "$R/launchers/macos/frontend/Sources/A/Page.swift" && rm "$R/launchers/macos/frontend/Sources/A/Page.swift.bak"
o3=$(python3 "$H/tools/l10n_key_lint.py" "$R" 2>&1)
ck "③ 改传不带前缀的闭包后组件不再报（剩 $(grep -c . <<< "$o3") 行）" '! grep -q "Page.swift:1[12]	" <<< "$o3" && [ "$(grep -c . <<< "$o3")" = 4 ]'
[ $bad = 0 ] && echo "l10n_key_lint 单测全过"; exit $bad
