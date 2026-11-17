#!/usr/bin/env bash
# 门禁：用户会照抄的文本里，不许把远程脚本「下载 + 执行」合成一步喂给 shell。
#
# 红 = 有命中。要挡的形态（都是「看不见被执行字节」的写法）：
#   ① curl/wget … | [sudo|env] [/path/]bash|sh|zsh|ksh …
#   ② sh -c "$(curl …)" / bash <(curl …)
#   ③ 反斜杠续行后接 ①②；以及 curl|wget … | tee f | bash 这类中间夹一层管道的写法
#   ④ python -c 里 urlopen/urllib + exec
#
# 射程声明（不许当成安全结论）：只抓字符串里看得见的常见形态；变量间接、动态拼接、
# base64 二次解码、把脚本先写进变量再执行，都抓不到。命中即红，漏判不证明干净。
#
# 门禁覆盖：*.sh *.py *.md *.cs *.swift *.m
# 用法：bash tests/no_remote_exec_pipe_test.sh [仓库根]；非 0 退出 = 有命中。
set -u
# Handwritten contracts keep real download-and-execute forms red and ordinary prose green.
# Supplying a root runs only the scan, so these child scans do not recurse.
if [ $# -eq 0 ]; then
  fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/s2arm-pipe-contract.XXXXXX") || exit 2
  script_path=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
  samples=(
    'red|curl https://example.test/install | bash'
    'red|curl https://example.test/install | tee script | bash'
    'red|bash <(curl https://example.test/install)'
    'red|sh -c "$(curl https://example.test/install)"'
    'red|import urllib.request; exec(urllib.request.urlopen("https://example.test/script").read())'
    'red|from urllib.request import urlopen; payload = urlopen("https://example.test/script").read(); eval(payload)'
    'green|# urllib executes this read to toss the CRLF at the end'
    'green|# An urllib executor handles the response'
  )
  for sample in "${samples[@]}"; do
    expected=${sample%%|*}
    printf '%s\n' "${sample#*|}" > "$fixture_root/example.py"
    contract_rc=0
    contract_out=$(bash "$script_path" "$fixture_root" 2>&1) || contract_rc=$?
    if { [ "$expected" = red ] && [ "$contract_rc" = 0 ]; } || { [ "$expected" = green ] && [ "$contract_rc" != 0 ]; }; then
      echo "扫描器契约失败（期望 ${expected}）：$contract_out"
      rm -rf "$fixture_root"
      exit 1
    fi
  done
  rm -rf "$fixture_root"
  echo "扫描器契约：8/8 通过"
fi
ROOT=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
cd "$ROOT" || exit 2

PAT1='(curl|wget)[^|]*\|[[:space:]]*(sudo([[:space:]]+-[A-Za-z]+)*[[:space:]]+|env[[:space:]]+)?(/[A-Za-z0-9_./-]*/)?(bash|sh|zsh|ksh)([[:space:]]|$)'
PAT2='(bash|sh|zsh|ksh)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-c[[:space:]]+.{0,3}\$\((curl|wget)'
PAT3='(bash|sh|zsh|ksh)[[:space:]]+<\((curl|wget)'
# Python execution is a function call; prose such as "urllib executes this read" is not code.
PAT4='(urlopen|urllib)[^|]{0,80}[^[:alnum:]_](exec|eval)[[:space:]]*\(|(^|[^[:alnum:]_])(exec|eval)[[:space:]]*\([^|]{0,80}urlopen'
PAT5='(curl|wget)[^|]*\|[^|]*\|[[:space:]]*(bash|sh|zsh|ksh)([[:space:]]|$)'
SELF_REL="tests/no_remote_exec_pipe_test.sh"

scan() {  # scan <content> -> matching lines
  grep -nE "$1" 2>/dev/null
}

HITS=()
# 预筛（11-09 负载下 2 分钟超时根修）：五个形态都要出现 curl / wget / urlopen / urllib，先一遍 grep 只挑含这些词的文件再逐个细判；
#   原先列全部同类文件（还把 . 写了两遍，每个文件扫两次）再每个文件起 awk + 5 次 grep，约 3000 个文件 × 6 个进程
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # ② 反斜杠续行先接起来再判（这样 `\` 换行 + `| bash` 也命中）；报行号用拼接后的首行
  joined=$(awk 'BEGIN{ln=0} {ln++; if (sub(/\\[[:space:]]*$/, "")) {printf "%d:%s ", ln, $0; next} print ln":"$0}' "$f" 2>/dev/null)
  for pat in "$PAT1" "$PAT2" "$PAT3" "$PAT4" "$PAT5"; do
    if hits=$(printf '%s\n' "$joined" | grep -E "$pat" 2>/dev/null); then
      while IFS= read -r line; do HITS+=("$f:$line"); done <<< "$hits"
    fi
  done
done < <(grep -rlIE 'curl|wget|urlopen|urllib' --include=*.sh --include=*.py --include=*.md \
             --include=*.cs --include=*.swift --include=*.m . 2>/dev/null \
         | grep -v '^\./compat/tree/' | grep -v '^\./\.git/' | grep -vF "./$SELF_REL")

if [ ${#HITS[@]} -gt 0 ]; then
  # 去重（同一行被多个 pattern 命中）
  uniq_lines=$(printf '%s\n' "${HITS[@]}" | sed 's/:[0-9]*:/:/' | sort -u)
  n=$(printf '%s\n' "${HITS[@]}" | wc -l | tr -d ' ')
  echo "🔴 有 ${n} 处把「下载 + 执行」合成一步（应落盘、看哈希、再显式执行）："
  printf '%s\n' "${HITS[@]}" | sed 's/^/    /' | cut -c1-220
  exit 1
fi
echo "✅ 没有「远程脚本 | shell」形态"
exit 0
