#!/bin/bash
# C# 编译输入闭包单测（tools/csproj_closure.py，临时仓库 + 真 dotnet msbuild 求值，约 15 秒）：bash tests/csproj_closure_test.sh
# 期望（按 MSBuild 规则手写）：A 引 B；B 编 b.cs、Compile Remove 掉 gen/、导入 x.targets（以 $(MSBuildThisFileDirectory) 引 ../h.h）→
#   清单含 A.csproj a.cs B.csproj b.cs x.targets h.h，不含 notes.txt、gen/g.cs；改 notes.txt 提交 → 键不变；改 b.cs / h.h 提交 → 键变；B 里新加 c.cs 提交 → 清单含 c.cs（粗键随目录树变，缓存不吃旧清单）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
R=$T/repo; mkdir -p $R/tools $R/A $R/B/gen $R/inc; cp "$H/tools/csproj_closure.py" $R/tools/
P='<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>'
echo "$P<ItemGroup><ProjectReference Include=\"../B/B.csproj\" /></ItemGroup></Project>" > $R/A/A.csproj
echo "$P<Import Project=\"x.targets\" /><ItemGroup><Compile Remove=\"gen/**\" /></ItemGroup></Project>" > $R/B/B.csproj
echo '<Project><PropertyGroup><HdrSrc>$(MSBuildThisFileDirectory)../inc/h.h</HdrSrc></PropertyGroup></Project>' > $R/B/x.targets
echo 'class A {}' > $R/A/a.cs; echo 'class B {}' > $R/B/b.cs; echo 'class G {}' > $R/B/gen/g.cs; echo n > $R/B/notes.txt; echo '#define X 1' > $R/inc/h.h
cd $R && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm a
export S2A_CSCLOSURE_CACHE=$T/cache
cc() { python3 $R/tools/csproj_closure.py $R/A/A.csproj "$@"; }
com() { git -C $R add -A && git -C $R -c user.email=t@t -c user.name=t commit -qm "$1"; }
L=$(cc --files); k0=$(cc --key)
ck "清单含两工程、两源码、导入的 x.targets 与它引的 inc/h.h（$(echo $L | tr '\n' ' ')）" 'for f in A/A.csproj A/a.cs B/B.csproj B/b.cs B/x.targets inc/h.h; do grep -qx "$f" <<< "$L" || exit 1; done'
ck "清单不含不编译的 notes.txt、被 Compile Remove 的 gen/g.cs" '! grep -q -e notes.txt -e gen/g.cs <<< "$L"'
echo m >> $R/B/notes.txt; com notes; k1=$(cc --key)
ck "改不编译的文件 → 键不变（${k0}）" '[ "$k1" = "$k0" ]'
echo 'class B2 {}' >> $R/B/b.cs; com b; k2=$(cc --key)
ck "改编译源码 → 键变（${k2}）" '[ "$k2" != "$k1" ]'
echo '#define X 2' > $R/inc/h.h; com h; k3=$(cc --key)
ck "改导入目标引的仓库文件 → 键变（${k3}）" '[ "$k3" != "$k2" ]'
echo 'class C {}' > $R/B/c.cs; com c; L2=$(cc --files)
ck "新加源码 → 清单含它（缓存按目录树号失效）" 'grep -qx B/c.cs <<< "$L2"'
# 工程引用的几种写法（11-18 门禁 Vulkan 单测接缓存时撞到）：RepoRoot = $([System.IO.Path]::GetFullPath(...)) 拼出的路径、一个 Include 里分号列两个工程；
#   目录里的包源配置叫 NuGet.Config（大小写与 UPCFG 拼写不同，Mac 盘不分大小写）→ 照样算出键、清单用 HEAD 里的真实文件名
mkdir -p $R/D $R/E; echo 'class E {}' > $R/E/e.cs; echo "$P</Project>" > $R/E/E.csproj; echo '<configuration />' > $R/D/NuGet.Config; echo 'class D {}' > $R/D/d.cs
echo "$P<PropertyGroup><RepoRoot Condition=\"'\$(RepoRoot)' == ''\">\$([System.IO.Path]::GetFullPath('\$(MSBuildThisFileDirectory)../'))</RepoRoot></PropertyGroup><ItemGroup><ProjectReference Include=\"\$(RepoRoot)B/B.csproj;../E/E.csproj\" /></ItemGroup></Project>" > $R/D/D.csproj
com d; LD=$(python3 $R/tools/csproj_closure.py $R/D/D.csproj --files 2>&1); kd=$(python3 $R/tools/csproj_closure.py $R/D/D.csproj --key 2>&1)
ck "GetFullPath 拼的 RepoRoot、分号列两个工程、NuGet.Config 大小写：键算得出（${kd}），清单含 B/b.cs、E/e.cs、D/NuGet.Config" '[[ $kd =~ ^[0-9a-f]{16}$ ]] && for f in B/b.cs E/e.cs D/NuGet.Config; do grep -qx "$f" <<< "$LD" || exit 1; done'
[ $bad = 0 ] && echo "✓ csproj_closure 单测全过" || { echo "csproj_closure 单测有不通"; exit 1; }
