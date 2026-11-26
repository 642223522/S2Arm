#!/bin/bash
# 门禁覆盖：tools/cs_cache.sh tools/csproj_closure.py
# C# 编译产物缓存单测（临时仓库 + 真 dotnet 编一个最小控制台工程，经计数用的假 dotnet 转调真 dotnet）：bash tests/cs_cache_test.sh
# 期望（手写，不靠被测脚本算）：
#   ① 首编：假 dotnet 起编 1 次，程序打印 v1，缓存里多 1 份；② 同输入、产物目录删掉重来：起编次数不变（命中），产物与首编逐文件相同；
#   ③ 改 Program.cs 提交：起编 +1，打印 v2，缓存 2 份；④ 改 Program.cs 不提交：起编 +1（绕过），打印工作树里的 v3，缓存仍 2 份；
#   ⑤ 产物目录事先有旧文件：照编（起编 +1）、不存（缓存仍 2 份）；⑥ 原命令失败：退出码 7、原输出原样透传、缓存仍 2 份。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
REAL=${DOTNET:-$HOME/.dotnet/dotnet}; [ -x "$REAL" ] || REAL=$(command -v dotnet)
R=$T/repo; mkdir -p "$R/tools" "$R/app" "$T/bin"; cp "$H/tools/cs_cache.sh" "$H/tools/csproj_closure.py" "$R/tools/"
cat > "$T/bin/dotnet" <<EOF
#!/bin/bash
case "\${1:-}" in build|publish) echo x >> "$T/count";; esac
exec "$REAL" "\$@"
EOF
chmod +x "$T/bin/dotnet"; export PATH="$T/bin:$PATH" DOTNET="$T/bin/dotnet"
export S2A_CSCLOSURE_CACHE=$T/closure S2A_CS_BUILD_CACHE=$T/cache DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 MSBUILDDISABLENODEREUSE=1
echo '<configuration><packageSources><clear /></packageSources></configuration>' > "$R/NuGet.Config"
echo '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>' > "$R/app/App.csproj"
echo 'System.Console.WriteLine("v1");' > "$R/app/Program.cs"
cd "$R" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm a
com() { git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -qm "$1"; }
cnt() { [ -f "$T/count" ] && wc -l < "$T/count" | tr -d ' ' || echo 0; }
ents() { find "$T/cache" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l | tr -d ' '; }
A=$R/build/art
cb() { rm -rf "$A"; bash "$R/tools/cs_cache.sh" "$A" "$R/app/App.csproj" -- dotnet build "$R/app/App.csproj" -c Release --artifacts-path "$A" -nologo -v q > "$T/out.log" 2>&1; }
run() { "$REAL" "$A/bin/App/release/App.dll"; }
cb; r=$?
ck "① 首编：退出 0（${r}）、起编 1 次（$(cnt)）、打印 v1（$(run)）、缓存 1 份（$(ents)）" '[ $r = 0 ] && [ "$(cnt)" = 1 ] && [ "$(run)" = v1 ] && [ "$(ents)" = 1 ]'
cp -R "$A" "$T/first"
cb; r=$?
ck "② 同输入再编：退出 0、起编次数不变（$(cnt)）、日志说命中" '[ $r = 0 ] && [ "$(cnt)" = 1 ] && grep -q 命中 "$T/out.log"'
ck "② 命中产物与首编逐文件相同（diff -r）" 'diff -r "$T/first" "$A" > /dev/null && [ "$(run)" = v1 ]'
echo 'System.Console.WriteLine("v2");' > "$R/app/Program.cs"; com v2
cb; r=$?
ck "③ 改闭包内源文件提交：键变、重编（起编 $(cnt)）、打印 v2（$(run)）、缓存 2 份（$(ents)）" '[ $r = 0 ] && [ "$(cnt)" = 2 ] && [ "$(run)" = v2 ] && [ "$(ents)" = 2 ]'
echo 'System.Console.WriteLine("v3");' > "$R/app/Program.cs"
cb; r=$?
ck "④ 闭包文件有未提交改动：绕过缓存现编（起编 $(cnt)）、打印 v3（$(run)）、缓存仍 2 份（$(ents)）" '[ $r = 0 ] && [ "$(cnt)" = 3 ] && [ "$(run)" = v3 ] && [ "$(ents)" = 2 ] && grep -q 未提交 "$T/out.log"'
git -C "$R" checkout -q app/Program.cs; echo "class N {}" > "$R/app/new.cs"
cb; r=$?
ck "④ 工程目录里有没跟踪的新文件：同样绕过（起编 $(cnt)）" '[ $r = 0 ] && [ "$(cnt)" = 4 ] && grep -q 未提交 "$T/out.log"'
rm -f "$R/app/new.cs"; rm -rf "$A"; mkdir -p "$A"; echo old > "$A/stale"
bash "$R/tools/cs_cache.sh" "$A" "$R/app/App.csproj" -- dotnet build "$R/app/App.csproj" -c Release --artifacts-path "$A" -p:X=1 -nologo -v q > "$T/out.log" 2>&1; r=$?
ck "⑤ 产物目录事先非空：照编（起编 $(cnt)）、不存（缓存 $(ents) 份）" '[ $r = 0 ] && [ "$(cnt)" = 5 ] && [ "$(ents)" = 2 ]'
o=$(bash "$R/tools/cs_cache.sh" "$T/fail" "$R/app/App.csproj" -- bash -c 'echo 原输出; echo 原报错 >&2; exit 7' 2> "$T/err"); r=$?
ck "⑥ 原命令失败：退出码透传 7（${r}）、标准输出原样（${o}）、报错原样、缓存仍 2 份（$(ents)）" '[ $r = 7 ] && [ "$o" = 原输出 ] && grep -qx 原报错 "$T/err" && [ "$(ents)" = 2 ]'
[ $bad = 0 ] && echo "✓ cs_cache 单测全过" || { echo "cs_cache 单测有不通"; exit 1; }
