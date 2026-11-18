#!/bin/bash
# C# 编译产物树外缓存（按内容寻址）：门禁每步前 git clean -fdx，调 dotnet build 的单测每次从零重编 Ryujinx 等整份闭包；输入没变就直接克隆上次编好的产物目录。
# 用法：bash tools/cs_cache.sh <产物目录>… <工程.csproj>… -- <原 dotnet build / publish 命令…>
#   第一个以 .csproj 结尾的参数之前都是产物目录（原命令会写的全部目录：--artifacts-path、-p:OutDir、-o …），之后到 -- 是这些命令编的工程（键按它们的闭包算）。
# 键（任何一项变了就是另一份）：
#   ① tools/csproj_closure.py --key：SDK 版本 + 全部工程 ProjectReference 闭包内编译输入（源码、嵌入资源、工程 / props / targets、沿途 global.json / nuget.config）在 HEAD 的对象号；
#   ② 原命令逐个参数原样（含产物目录：dll 里编进了 obj 下 pdb 的绝对路径，换个目录编出来就不是同一份字节，所以产物目录不同不共用），
#      参数本身是已有文件的（解决方案文件、包源配置）另并入文件内容哈希，仓库外的路径只认内容（门禁每次的临时目录名不同）；
#   ③ 实际起编的 dotnet 的 --version、本机系统与架构、仓库根与当前目录的绝对路径（源码路径会编进 pdb 与 [CallerFilePath]）、产物目录绝对路径、本脚本内容；
#   ④ 影响编译的环境变量：闭包内工程文件以 $(名字) / GetEnvironmentVariable 读到且当前设了的（MSBuild 环境变量即属性、名字不分大小写），
#      外加 DOTNET_* / MSBUILD* / NUGET_* / COMPlus_* 与几个 SDK 认的通用属性名（Configuration、Platform、RuntimeIdentifier …）。RID 走原命令 -r 参数，在 ② 里。
# 不走缓存、照原命令现编（输出与退出码原样）：S2A_CS_BUILD_CACHE_OFF=1；闭包算不出来；闭包文件或工程目录在工作树里有未提交改动 / 没跟踪的文件（开发机场景）。
# 没命中：照原命令编；原命令失败照原样失败、不写缓存；只有编之前产物目录都不存在或为空（门禁 git clean 之后就是这样）才把产物收进缓存——
#   目录里事先有旧东西就是增量编，收进去等于把旧产物带进别的树，所以只编不存。
# 命中：先删掉产物目录再从缓存克隆（macOS cp -c 走写时复制、Linux --reflink=auto，不支持就普通复制），不调 dotnet。
# 不接入的情形（接入点不调本脚本）：工程闭包里有 <Exec> 调外部编译器（cc、spirv-as …）或读闭包外文件的——那些输入不在键里。
# 缓存：${S2A_CS_BUILD_CACHE:-${S2A_RUN_ROOT:-~/.s2arm/run}/s2arm/cache/csbuild}/<键>/（0、1 … 依产物目录顺序，key.txt 记键的明细）；
#   按键加锁（mkdir 原子 + pid 存活检查），命中不拿锁；编完先复制到 <键>.tmp.<pid> 再原子 mv。每次命中 touch 续租；存新份后回收：
#   超过 S2A_CS_BUILD_CACHE_HOURS（缺省 48）小时没用的删，总量超过 S2A_CS_BUILD_CACHE_GB（缺省 3；门禁每槽一份家目录各存一份，键含树路径、跨槽本就不共用）GB 从最久没用的删起，1 小时内用过的不删。
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
say() { echo "cs_cache：$*" >&2; }
OUTS=(); PROJS=()
while [ $# -gt 0 ] && [ "$1" != -- ] && [[ $1 != *.csproj ]]; do OUTS+=("$1"); shift; done
while [ $# -gt 0 ] && [ "$1" != -- ]; do PROJS+=("$1"); shift; done
[ "${1:-}" = -- ] && [ $# -ge 2 ] && [ ${#OUTS[@]} -ge 1 ] && [ ${#PROJS[@]} -ge 1 ] || { say "用法：bash tools/cs_cache.sh <产物目录>… <工程.csproj>… -- <原命令…>"; exit 2; }
shift; CMD=("$@")
raw() { "${CMD[@]}"; exit $?; }   # 照原命令现编：输出原样、退出码原样
bypass() { say "不走缓存（$1），照原命令现编"; raw; }
[ "${S2A_CS_BUILD_CACHE_OFF:-}" = 1 ] && bypass "S2A_CS_BUILD_CACHE_OFF=1"

# 闭包与未提交改动
FILES=$(python3 "$ROOT/tools/csproj_closure.py" "${PROJS[@]}" --files 2> /dev/null) && [ -n "$FILES" ] || bypass "csproj_closure 算不出闭包"
CK=$(python3 "$ROOT/tools/csproj_closure.py" "${PROJS[@]}" --key 2> /dev/null) && [ -n "$CK" ] || bypass "csproj_closure 算不出键"
PDIRS=$(grep -E '\.csproj$' <<< "$FILES" | while IFS= read -r f; do dirname "$f"; done | sort -u)
DIRTY=$( { printf '%s\n' "$FILES"; printf '%s\n' "$PDIRS"; } | (cd "$ROOT" && tr '\n' '\0' | xargs -0 git status --porcelain -uall -- 2> /dev/null)) || bypass "git status 失败"
[ -n "$DIRTY" ] && bypass "闭包有未提交改动：$(head -3 <<< "$DIRTY" | tr '\n' ' ' | cut -c1-200)"

# 实际起编的 dotnet：原命令里第一个名叫 dotnet 的参数，没有（如 bash -c 包一层）就按 DOTNET / PATH 找
DN=; for a in "${CMD[@]}"; do [ "${a##*/}" = dotnet ] && { DN=$a; break; }; done
[ -n "$DN" ] || DN=dotnet   # 原命令包了一层（bash -c …）时，里面写的 dotnet 按 PATH 找
case $DN in */*) ;; *) DN=$(command -v "$DN" 2> /dev/null || echo "$DN");; esac
DNV=$("$DN" --version 2> /dev/null) && [ -n "$DNV" ] || bypass "取不到 $DN 的版本"

absp() { case $1 in /*) printf '%s' "$1";; *) printf '%s/%s' "$PWD" "$1";; esac; }
fhash() { shasum -a 256 < "$1" | cut -c1-64; }
keytext() {
  echo "cs_cache $(fhash "$ROOT/tools/cs_cache.sh")"
  echo "closure $CK"; echo "dotnet $DNV"; echo "host $(uname -sm)"; echo "root $ROOT"; echo "cwd $PWD"
  local a o f i
  for i in "${!OUTS[@]}"; do echo "out$i $(absp "${OUTS[$i]%/}")"; done
  for a in "${CMD[@]}"; do
    o=$a; f=$a; [[ $a == *=* ]] && [ ! -f "$a" ] && f=${a#*=}
    if [ -f "$f" ]; then case $(absp "$f") in "$ROOT"/*) ;; *) o=${o//"$f"/@FILE@};; esac; o="$o @content=$(fhash "$f")"; fi
    echo "arg $o"
  done
  # 环境变量：闭包内工程文件读到的名字（不分大小写）+ 固定几族
  local names; names=$(grep -E '\.(csproj|props|targets)$' <<< "$FILES" | (cd "$ROOT" && tr '\n' '\0' | xargs -0 cat 2> /dev/null) \
    | grep -oE "\\\$\([A-Za-z_][A-Za-z0-9_.-]*\)|GetEnvironmentVariable\('[A-Za-z_][A-Za-z0-9_]*'\)" | sed -E "s/^\\\$\(//; s/\)$//; s/^GetEnvironmentVariable\('//; s/'\)?$//" | tr 'A-Z' 'a-z' | sort -u)
  local n
  while IFS= read -r n; do
    case $n in DOTNET_*|MSBUILD*|NUGET_*|COMPlus_*|Configuration|Platform|RuntimeIdentifier|TargetFramework|TargetFrameworks|OutDir|OutputPath|BaseOutputPath|BaseIntermediateOutputPath|IntermediateOutputPath|DefineConstants|LangVersion|Optimize|Deterministic|ContinuousIntegrationBuild|PathMap|CI|TF_BUILD|GITHUB_ACTIONS) echo "env $n=${!n}"; continue;; esac
    grep -qxF "$(tr 'A-Z' 'a-z' <<< "$n")" <<< "$names" && echo "env $n=${!n}"
  done < <(compgen -e | LC_ALL=C sort)
  return 0
}
KT=$(keytext) || bypass "算键失败"
K=$(shasum -a 256 <<< "$KT" | cut -c1-24)
C=${S2A_CS_BUILD_CACHE:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm/cache/csbuild}; mkdir -p "$C" 2> /dev/null || bypass "建不了缓存目录 $C"
E=$C/$K

clone() {   # clone <源> <目标>：写时复制克隆，不支持就普通复制
  rm -rf "$2"; mkdir -p "$(dirname "$2")"
  case $(uname -s) in
    Darwin) cp -c -R "$1" "$2" 2> /dev/null || { rm -rf "$2"; cp -R "$1" "$2"; };;
    *) cp --reflink=auto -R "$1" "$2" 2> /dev/null || { rm -rf "$2"; cp -R "$1" "$2"; };;
  esac; }
hit() { [ -f "$E/ok" ]; }
use() {
  touch "$E"; local i
  for i in "${!OUTS[@]}"; do
    if [ -d "$E/$i" ]; then clone "$E/$i" "${OUTS[$i]%/}" || { say "克隆 $E/$i 失败，照原命令现编"; raw; }
    else rm -rf "${OUTS[$i]%/}"; fi   # 原命令没写这个目录：照样不留
  done
  say "命中（键 ${K}），产物克隆自 $E"; exit 0; }
hit && use

# 没命中：编之前产物目录都空才收进缓存
store=1; for o in "${OUTS[@]}"; do [ -e "$o" ] && [ -n "$(ls -A "$o" 2> /dev/null)" ] && store=; done
[ -n "$store" ] || { say "没命中（键 ${K}），产物目录事先非空（增量编），只编不存"; raw; }
L=$C/.lock-$K
until mkdir "$L" 2> /dev/null; do p=$(cat "$L/pid" 2> /dev/null || true); [ -n "$p" ] && ! kill -0 "$p" 2> /dev/null && rm -rf "$L"; sleep 0.5; done
echo $$ > "$L/pid"; trap 'rm -rf "$L" "$E.tmp.$$"' EXIT
hit && use   # 等锁期间别人编好了
say "没命中（键 ${K}），照原命令现编"
"${CMD[@]}"; rc=$?
[ $rc = 0 ] || exit $rc
rm -rf "$E.tmp.$$"; mkdir -p "$E.tmp.$$" || exit 0
for i in "${!OUTS[@]}"; do [ -d "${OUTS[$i]%/}" ] && { clone "${OUTS[$i]%/}" "$E.tmp.$$/$i" || { say "收进缓存失败（不影响本次产物）"; exit 0; }; }; done
printf '%s\n' "$KT" > "$E.tmp.$$/key.txt"; : > "$E.tmp.$$/ok"
rm -rf "$E"; mv "$E.tmp.$$" "$E" && say "已收进缓存 $E"
# 回收：超龄没用的删；总量超上限从最久没用的删起；1 小时内用过的不删
find "$C" -mindepth 1 -maxdepth 1 -type d ! -name '.lock-*' -mmin +$(( ${S2A_CS_BUILD_CACHE_HOURS:-48} * 60 )) -exec rm -rf {} + 2> /dev/null
cap=$(( ${S2A_CS_BUILD_CACHE_GB:-3} * 1024 * 1024 )); tot=0
while IFS= read -r d; do
  s=$(du -sk "$d" 2> /dev/null | cut -f1); tot=$((tot + ${s:-0}))
  [ $tot -gt $cap ] && [ -n "$(find "$d" -maxdepth 0 -mmin +60)" ] && rm -rf "$d"
done < <(ls -1dt "$C"/*/ 2> /dev/null | sed 's:/$::')
exit 0
