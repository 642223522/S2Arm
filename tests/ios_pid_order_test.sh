#!/bin/bash
# iOS 起局顺序（runtime/src/host_main.c）：模块目录必须在放行图形模式判定（s2a_gfx_mode_data_ready）之前设好。
#   放行后谁先调 s2a_gfx_mode() 谁就落定程序号（gfxmode.c decide 读 <模块目录>/main.npdm）；原先 iOS 装模块才设目录，
#   上次没正常收尾 → 开局诊断提示 → 关掉后恢复回调先问图形模式 → 程序号锁成 0（11-10 测试设备冷启动 3 次后两次中）
# 门禁覆盖：runtime/src/host_main.c runtime/src/gfxmode.c
# 期望：① 本仓库 host_main.c 的 iOS 段里「设模块目录」在「放行判定」之前；② 负对照：去掉那行的副本判红
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
order_ok() {   # $1 = host_main.c：放行判定那一行之前、同一个 #if TARGET_OS_IPHONE 段里有 s2a_module_dir_set(lc->module_dir)
  awk '/^#if TARGET_OS_IPHONE/ {ios = 1; set = 0} /^#endif|^#else/ {ios = 0}
       ios && /s2a_module_dir_set\(lc->module_dir\)/ {set = 1}
       ios && /s2a_gfx_mode_data_ready\(\); \}/ {found = 1; ok = set}
       END {exit !(found && ok)}' "$1"
}
ck "① iOS：设模块目录在放行图形模式判定之前" 'order_ok "$H/runtime/src/host_main.c"'
grep -v 's2a_module_dir_set(lc->module_dir)' "$H/runtime/src/host_main.c" > "$T/old.c"
ck "② 负对照：去掉设目录那行 → 判红" '! order_ok "$T/old.c"'
exit $bad
