#!/bin/bash
# 门禁覆盖：pack/roots.sh tests/roots_rm_junk_test.sh
# 产物根删除遇到「删的同时有程序往里写系统文件」（#369：游戏库在外置盘，访达往正在删的目录写 .DS_Store，rm 报 Directory not empty）：bash tests/roots_rm_junk_test.sh（约 2 秒）
#   PATH 前面放一个假 rm：真删一遍后（只第一次）往目标目录里塞一个文件并退 1，确定性地模拟「删完那一刻又被写进东西」。期望手写：
#   ① 塞的是 .DS_Store → _root_rm 清掉系统文件再删，目录没了、_root_rm_red 不报红；._x 同理
#   ② 塞的是普通文件且每次都塞（真有程序在写）→ 删不掉、目录还在，_root_rm_red 报一行【红】带路径
#   ③ 负对照：假 rm 不塞东西 → 一次删掉（不受影响）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'chmod -R u+w "$T" 2>/dev/null; /bin/rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export S2A_ROOTS=$T/roots S2A_ROOTS_SHARED=$T/shared S2A_ROOTS_PRIV=$T/priv; mkdir -p $T/bin; source "$H/pack/roots.sh"
cat > $T/bin/rm <<'X'
#!/bin/bash
# 假 rm：先真删；FAKE_NAME 给了就往最后一个参数（目标目录）里塞这个文件、退 1。FAKE_ONCE=1 只塞一次（用 $FAKE_FLAG 记）
/bin/rm "$@"; t=${!#}
if [ -n "${FAKE_NAME:-}" ] && { [ "${FAKE_ONCE:-0}" = 0 ] || [ ! -e "$FAKE_FLAG" ]; }; then mkdir -p "$t" && : > "$t/$FAKE_NAME" && : > "$FAKE_FLAG"; echo "rm: $t: Directory not empty" >&2; exit 1; fi
X
chmod +x $T/bin/rm
mk() { /bin/rm -rf "$1"; mkdir -p "$1/romfs/sub"; : > "$1/romfs/sub/a.bin"; : > "$1/b.bin"; chmod -R a-w "$1/romfs"; }
for n in .DS_Store ._x.nsp; do
  d=$T/roots/g@v1.tmp; mk $d; rm_flag=$T/flag.$n; /bin/rm -f "$rm_flag"
  o=$(PATH=$T/bin:$PATH FAKE_NAME=$n FAKE_ONCE=1 FAKE_FLAG=$rm_flag _root_rm_red "$d" 测试 2>&1); r=$?
  ck "① 删的同时被写进 ${n} → 删干净、不报红（rc=${r}，输出「${o}」）" '[ $r = 0 ] && [ ! -e "$d" ] && [ -e "$rm_flag" ]'
done
d=$T/roots/g@v2.tmp; mk $d
o=$(PATH=$T/bin:$PATH FAKE_NAME=game.nsp FAKE_ONCE=0 FAKE_FLAG=$T/flag.g _root_rm_red "$d" 测试 2>&1); r=$?
ck "② 一直被写进普通文件 → 不硬删、报红（rc=${r}，「${o}」）" '[ $r = 1 ] && [ -e "$d/game.nsp" ] && [[ $o == *"【红】测试：删不掉 $d"* ]]'
d=$T/roots/g@v3.tmp; mk $d
o=$(PATH=$T/bin:$PATH _root_rm_red "$d" 测试 2>&1); r=$?
ck "③ 负对照：没人写 → 一次删掉（rc=${r}）" '[ $r = 0 ] && [ ! -e "$d" ]'
[ $bad = 0 ] && echo "roots_rm_junk 单测全过" || { echo "roots_rm_junk 单测有不通"; exit 1; }
