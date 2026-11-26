#!/bin/bash
# 门禁覆盖：*.py
# ctypes.cast 只接受整数地址（约 2 秒）：bash tests/ctypes_cast_lint_test.sh
# cast 的源是 ctypes 对象（缓冲区 / 指针实例）时，结果在 _objects 里挂着源与自己，成引用环：源要等循环垃圾回收才释放，
#   循环回收按新建对象数触发、不看字节数，大缓冲越攒越多（11-18 抽取器整树峰值 1376 MB，改 addressof 后 892 MB）。
#   规则：cast 的第一个参数写成整数地址——ctypes.addressof(…)、<指针>.value、int(…)、整数运算或整数常量；要指针参数直接传缓冲区或 from_buffer。
# 期望（按规则手写）：① 全仓（compat/tree 除外）0 处；② 正对照：cast(缓冲区, …) / cast(指针实例, …) / C.cast(名字, …) 报；
#   ③ 反对照：cast(addressof(b), …) / cast(p.value, …) / cast(v.buf + i, …) / cast(int(r), …) / 别的对象的 .cast 方法（memoryview.cast）不报
#   ④ 判据本身：本机实测 cast(缓冲区, POINTER) 进环、cast(addressof, POINTER) 不进环（规则的前提随 Python 版本变了会红）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); cd "$H" || exit 1; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
LINT='
import ast, sys, warnings
warnings.simplefilter("ignore")   # 只看语法树，别的文件的转义警告不是本检查的事
def bad_calls(src, name):
    tree = ast.parse(src, name); mods = set()
    for n in ast.walk(tree):
        if isinstance(n, ast.Import):
            mods |= {a.asname or a.name for a in n.names if a.name == "ctypes"}
    out = []
    for n in ast.walk(tree):
        if not (isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "cast"
                and isinstance(n.func.value, ast.Name) and n.func.value.id in mods and n.args): continue
        a = n.args[0]
        ok = (isinstance(a, ast.Call) and isinstance(a.func, ast.Attribute) and a.func.attr == "addressof") or \
             (isinstance(a, ast.Call) and isinstance(a.func, ast.Name) and a.func.id == "int") or \
             (isinstance(a, ast.Attribute) and a.attr == "value") or isinstance(a, ast.BinOp) or \
             (isinstance(a, ast.Constant) and isinstance(a.value, int))
        if not ok: out.append(f"{name}:{n.lineno}: {ast.unparse(n)[:100]}")
    return out
'
hits=$(git ls-files -z '*.py' | python3 -c "$LINT"'
for f in sys.stdin.read().split("\0"):
    if not f or f.startswith("compat/tree/"): continue
    try: src = open(f, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError): continue
    try: print(*bad_calls(src, f), sep="\n") if bad_calls(src, f) else None
    except SyntaxError: pass
')
ck "① 全仓 ctypes.cast 第一个参数不是整数地址的 0 处（命中：${hits:0:400}）" '[ -z "$hits" ]'
pos=$(python3 -c "$LINT"'
src = "import ctypes\nimport ctypes as C\nb = ctypes.create_string_buffer(8)\nx = ctypes.cast(b, ctypes.POINTER(ctypes.c_char))\ny = C.cast(p, C.POINTER(C.c_ushort * 2))\nz = C.cast(text, C.c_wchar_p)\n"
print(len(bad_calls(src, "pos")))')
ck "② 正对照 3 种坏写法都报（实 ${pos}）" '[ "$pos" = 3 ]'
neg=$(python3 -c "$LINT"'
src = "import ctypes\nimport ctypes as C\nx = ctypes.cast(ctypes.addressof(b), ctypes.POINTER(ctypes.c_char))\ny = C.cast(p.value, C.POINTER(C.c_ushort * 2))\nz = ctypes.cast(v.buf + i, ctypes.c_char_p)\nw = memoryview(b).cast(\"I\")\nu = ctypes.cast(int(r), ctypes.POINTER(ctypes.c_uint32))\n"
print(len(bad_calls(src, "neg")))')
ck "③ 反对照 5 种写法都不报（实 ${neg}）" '[ "$neg" = 0 ]'
cyc=$(python3 -c '
import ctypes as C, gc
def n(f):
    f(); gc.collect(); gc.set_debug(gc.DEBUG_SAVEALL); f(); gc.collect()
    k = sum(isinstance(o, C.Array) for o in gc.garbage); gc.set_debug(0); del gc.garbage[:]; return k
print(n(lambda: C.cast(C.create_string_buffer(64), C.POINTER(C.c_char))), n(lambda: (lambda b: C.cast(C.addressof(b), C.POINTER(C.c_char)))(C.create_string_buffer(64))))')
ck "④ 判据前提：cast(缓冲区) 进环的缓冲 1 个、cast(addressof) 0 个（实 ${cyc}）" '[ "$cyc" = "1 0" ]'
[ $bad = 0 ] && echo "✅ ctypes_cast_lint 全过" || { echo "🔴 ctypes_cast_lint 有不通项"; exit 1; }
