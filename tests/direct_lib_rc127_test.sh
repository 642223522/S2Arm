#!/bin/bash
# 门禁覆盖：graphics/tools/direct/direct_lib.sh pack/jobs/errors.py tests/direct_lib_rc127_test.sh
# 出库 rc=127 的说法（direct_lib.sh rc127_note，约 1 秒）：bash tests/direct_lib_rc127_test.sh
#   11-09 维护方测试树诊断替换写错，dsh_batch 抛异常退 127，原先在 Windows 上一律译成「127 = 盘满」（T 盘还剩 127 GB，照提示误删 37 GB 缓存）。
#   函数从 direct_lib.sh 原样抽出来跑；uname 换成桩造 Git Bash / Mac；余量用 S2A_DISK_FREE_G 注入（⑥ 不注入、量真盘）。期望手写：
#   ① Windows、build.log 有 .NET 盘满原文 → 「127 = 盘满」，错误分类归 disk_full
#   ② Windows、没有盘满原文、两盘都剩 127 GB → 「不是盘满」、带余量、让看 build.log；错误分类不归 disk_full（负对照：旧码这里一律报盘满）
#   ③ Windows、没有盘满原文、剩 1 GB（< 2 GB）→ 「多半是盘满」、带余量，错误分类归 disk_full
#   ④ Mac 上 rc=127 → 不加说明（bash 的「命令找不到」，原样报）
#   ⑤ Windows、rc=1 → 不加说明
#   ⑥ Windows、不注入余量、临时目录在本机（远大于 2 GB）→ 「不是盘满」
#   ⑦ Windows、不注入余量、有一个目录量不出余量（不存在）→ 不下结论（「可能是盘满…也可能是…异常退出」），错误分类不归 disk_full
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p $T/win $T/mac $T/bt $T/c
printf '#!/bin/sh\necho MINGW64_NT-10.0-26100\n' > $T/win/uname; printf '#!/bin/sh\necho Darwin\n' > $T/mac/uname; chmod +x $T/win/uname $T/mac/uname
source <(sed -n '/^rc127_note() {/,/^}/p' "$H/graphics/tools/direct/direct_lib.sh")
type rc127_note > /dev/null 2>&1 || { echo "不通 direct_lib.sh 里找不到 rc127_note"; exit 1; }
cls() { python3 -c 'import re, sys; sys.path.insert(0, sys.argv[1]); import errors; print(next((c for p, c in errors.LOG_CAUSES if re.search(p, sys.argv[2])), "无"))' "$H/pack/jobs" "$1"; }
printf 'Unhandled exception. System.IO.IOException: There is not enough space on the disk. : spill.dat\n' > $T/full.log
printf 'Unhandled exception. System.MissingMethodException: Method not found: Diag.Replace\n' > $T/exc.log
o1=$(PATH=$T/win:$PATH S2A_DISK_FREE_G=127 rc127_note 127 $T/full.log $T/bt $T/c)
ck "① 有盘满原文 → 盘满（${o1}）、分类 $(cls "$o1")" '[[ $o1 == *"127 = 盘满"* ]] && [ "$(cls "$o1")" = disk_full ]'
o2=$(PATH=$T/win:$PATH S2A_DISK_FREE_G=127 rc127_note 127 $T/exc.log $T/bt $T/c)
ck "② 余量充足、没有盘满原文 → 不是盘满（${o2}）、分类 $(cls "$o2")" '[[ $o2 == *"不是盘满"* ]] && [[ $o2 == *"剩 127 GB"* ]] && [[ $o2 == *"build.log"* ]] && [ "$(cls "$o2")" != disk_full ]'
o3=$(PATH=$T/win:$PATH S2A_DISK_FREE_G=1 rc127_note 127 $T/exc.log $T/bt $T/c)
ck "③ 剩 1 GB → 多半是盘满（${o3}）、分类 $(cls "$o3")" '[[ $o3 == *"多半是盘满"* ]] && [[ $o3 == *"剩 1 GB"* ]] && [ "$(cls "$o3")" = disk_full ]'
o4=$(PATH=$T/mac:$PATH S2A_DISK_FREE_G=1 rc127_note 127 $T/exc.log $T/bt $T/c)
ck "④ Mac 上 127 → 不加说明（「${o4}」）" '[ -z "$o4" ]'
o5=$(PATH=$T/win:$PATH S2A_DISK_FREE_G=1 rc127_note 1 $T/full.log $T/bt $T/c)
ck "⑤ rc=1 → 不加说明（「${o5}」）" '[ -z "$o5" ]'
o6=$(unset S2A_DISK_FREE_G; PATH=$T/win:$PATH rc127_note 127 $T/exc.log $T/bt)
ck "⑥ 不注入、量本机真盘 → 不是盘满（${o6}）" '[[ $o6 == *"不是盘满"* ]]'
o7=$(unset S2A_DISK_FREE_G; PATH=$T/win:$PATH rc127_note 127 $T/exc.log $T/no/such/dir)
ck "⑦ 量不出余量 → 不下结论（${o7}）、分类 $(cls "$o7")" '[[ $o7 == *"可能是盘满"* ]] && [[ $o7 == *"异常退出"* ]] && [ "$(cls "$o7")" != disk_full ]'
[ $bad = 0 ] && echo "direct_lib rc127 单测全过" || { echo "direct_lib rc127 单测有不通"; exit 1; }
