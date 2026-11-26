#!/bin/bash
# 发版应用布局下的作业层导入门禁（tools/app_layout_check.py）：bash tests/app_layout_test.sh
# 门禁覆盖：pack/jobs/*.py launchers/macos/jobs_bundle.py launchers/macos/build_app.py launchers/macos/bundle_engine.py launchers/windows/bundle_win.py tools/redact.py tools/sha256_fast.py graphics/nvn/tools/romfs_list.py pack/romfs_img.py
# A 段（合成的作业层目录，期望按规则手写，只跑「全文扫 import」那一步）：
#   ① 函数里按 __file__ 往上推再 from pack… → 红（11-16 b7432493f 同形）
#   ② 函数里先 sys.path.insert(0, str(c.engine)) 再 from pack… → 过
#   ③ 外层 if os.name == "nt" 里 from pack… → 过（Windows 的作业层就在引擎快照里）
#   ④ 函数开头 if os.name != "nt": return，后面 from pack… → 过
#   ⑤ 文件头写「# 应用布局：<原因>」→ 整个文件不扫
#   ⑥ 导入不存在的模块 → 红；包在 try … except ImportError 里 → 过
#   ⑦ 标准库、作业层自己的模块、随包第三方包 → 过
# B 段：真仓库搭两种布局跑全套（导入每个模块 + 全文扫 import + 最小作业 setup / catalog），退出 0 才过
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
J=$T/Jobs; mkdir -p $J
cat > $J/own.py <<'EOF'
X = 1
EOF
cat > $J/a.py <<'EOF'
import sys
from pathlib import Path
def bad_rename():
    sys.path.append(str(Path(__file__).resolve().parents[2]))
    from pack.orch.dirrename import rename_dir
def good(c):
    sys.path.insert(0, str(c.engine))
    from pack.orch.dirrename import rename_dir
EOF
cat > $J/b.py <<'EOF'
import os, sys
if os.name == "nt":
    from pack.orch import winlong
def link(a, b):
    if os.name != "nt":
        os.symlink(a, b)
        return
    from pack.orch.winlong import create_junction
EOF
cat > $J/c.py <<'EOF'
# 应用布局：只从引擎快照里起，单测样例
from pack.contracts import x
EOF
cat > $J/d.py <<'EOF'
import json, own, numpy
try:
    import resource_only_here
except ImportError:
    resource_only_here = None
def f():
    import nowhere_module
EOF
o=$(python3 - "$H" "$J" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/tools")
import app_layout_check as A
for where, why in A.scan(sys.argv[2], {"own", "a", "b", "c", "d"}, {"numpy"}):
    print(where, why)
PY
)
echo "$o"
ck "① 按 __file__ 推再 from pack → 红（a.py:5）" 'grep -q "^a.py:5 " <<< "$o"'
ck "② 先放 c.engine 再 from pack → 过（a.py:8 不报）" '! grep -q "^a.py:8 " <<< "$o"'
ck "③ if os.name == \"nt\" 里 → 过（b.py:3 不报）" '! grep -q "^b.py:3 " <<< "$o"'
ck "④ 函数开头非 Windows 先 return → 过（b.py:8 不报）" '! grep -q "^b.py:8 " <<< "$o"'
ck "⑤ 文件头表态 → 整个文件不扫（c.py 不报）" '! grep -q "^c.py:" <<< "$o"'
ck "⑥ 不存在的模块 → 红（d.py:7）；try/except ImportError 里的 → 过（d.py:3 不报）" 'grep -q "^d.py:7 " <<< "$o" && ! grep -q "^d.py:3 " <<< "$o"'
ck "⑦ 标准库 / 作业层模块 / 随包第三方 → 过（d.py:1 不报）" '! grep -q "^d.py:1 " <<< "$o"'
ck "合成目录一共报 2 处（期望 a.py:5、d.py:7）" '[ "$(grep -c . <<< "$o")" = 2 ]'

o=$(python3 "$H/tools/app_layout_check.py" --repo "$H" 2>&1); r=$?; echo "$o" | tail -5
ck "B 真仓库两种布局全套：退出 ${r}（期望 0）" '[ $r = 0 ]'
[ $bad = 0 ] && echo "✓ app_layout_test" || echo "✗ app_layout_test"
exit $bad
