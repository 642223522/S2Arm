#!/bin/bash
# 门禁覆盖：graphics/tools/direct/dsh/batch/Program.cs translator/spvc_cli/* tests/spvc_deep_nest.py tests/spvc_deep_stack_test.sh
# 直连出库翻译线程的栈（约 1 分钟，编 dsh_batch 与 libspvc_cli）：bash tests/spvc_deep_stack_test.sh
#   #51 Switch Sports Resort：出库进程在 InprocSpvCross.Run 里 Stack overflow（rc=134）。spirv-cross 出 MSL 按控制流嵌套递归，
#   spirv-cross 在 Parallel.ForEach 的线程池线程上调，macOS 上这类线程缺省只有 1.5 MB 栈。修法是 #57：dsh_batch.csproj 的
#   System.Threading.DefaultStackSize = 64 MB，对线程池线程同样生效。本单测守住它：哪天 runtimeconfig 里这项被删了，3000 层那项会红。
#   夹具：tests/spvc_deep_nest.py 合成嵌套 N 层 if 的片元着色器（原创字节）；dsh_batch --spvc-file <lib> <spv> 在线程池线程上翻一支
#   期望（手写）：嵌套 50 层与 3000 层都退出 0、打印「msl … chars」；
#   负对照：同一支 3000 层直接在 1.5 MB 栈的线程上调同一份库（tests 里不另编，用 python ctypes 起线程）→ 进程被信号杀（不是一律放过）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/spvc_deep.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1：期望 $2，实际 $3"; bad=1; fi; }
LIB=$(cd "$H/translator" && python3 -c 'import spvc_inproc; print(spvc_inproc.lib_path())') && [ -f "$LIB" ] || { echo "✗ 取不到 libspvc_cli"; exit 1; }
(cd "$H/translator" && python3 -c 'import dsh_batch, shlex; print(shlex.join(dsh_batch.build()[0]))') > "$T/cmd" 2> "$T/b.log" || { echo "✗ dsh_batch 编不过：$(tail -2 "$T/b.log")"; exit 1; }
CMD=$(tail -n 1 "$T/cmd"); [ -n "$CMD" ] || { echo "✗ dsh_batch 编不过：$(tail -2 "$T/b.log")"; exit 1; }
python3 "$H/tests/spvc_deep_nest.py" 50 "$T/n50.spv"; python3 "$H/tests/spvc_deep_nest.py" 3000 "$T/n3000.spv"
o=$($CMD --spvc-file "$LIB" "$T/n50.spv" 2>&1); r=$?
ck "嵌套 50 层：退出 0" 0 "$r"; ck "嵌套 50 层：出了 MSL" 1 "$(grep -c '^msl [0-9]* chars' <<< "$o")"
o=$($CMD --spvc-file "$LIB" "$T/n3000.spv" 2>&1); r=$?
ck "嵌套 3000 层（线程池线程上调）：退出 0" 0 "$r"; ck "嵌套 3000 层：出了 MSL" 1 "$(grep -c '^msl [0-9]* chars' <<< "$o")"
# 负对照：同一份库、同一支 3000 层，在 1.5 MB 栈的线程上直接调 → 必须被信号杀
python3 - "$LIB" "$T/n3000.spv" > /dev/null 2>&1 <<'PY'
import ctypes, sys, threading
lib = ctypes.CDLL(sys.argv[1]); spv = open(sys.argv[2], 'rb').read()
argv = [b"spirv-cross", b"--msl", b"--msl-version", b"30100", b"--msl-argument-buffers", b"--msl-texture-buffer-native", b"--msl-pad-fragment-output", b"mem:in", b"--output", b"mem:out"]
a = (ctypes.c_char_p * len(argv))(*argv); o = ctypes.c_void_p(); on = ctypes.c_size_t(); e = ctypes.c_void_p(); en = ctypes.c_size_t()
threading.stack_size(1536 * 1024)
t = threading.Thread(target=lambda: lib.spvc_cli_run_mem(len(argv), a, spv, len(spv), ctypes.byref(o), ctypes.byref(on), ctypes.byref(e), ctypes.byref(en))); t.start(); t.join()
PY
r=$?; ck "负对照：1.5 MB 栈上直接调被信号杀（退出码 > 128）" 1 "$([ $r -gt 128 ] && echo 1 || echo 0)"
[ $bad = 0 ] && echo "✓ spvc_deep_stack_test 全过" || echo "✗ spvc_deep_stack_test 有不符合项"; exit $bad
