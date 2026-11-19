#!/bin/bash
# 门禁覆盖：*.py tools/pool_size_lint.py tools/pool_workers.py tests/pool_size_lint_test.sh
# 并行度唯一来源守卫单测（tools/pool_size_lint.py，#1332 / D-V5QR，约 2 秒）：bash tests/pool_size_lint_test.sh
# 期望（按规则手写）：
#   ① 本仓库：除 tools/pool_workers.py 外不直接读核数；进程池路数都经 process_pool_size（白名单逐条有理由、没有过期条目）
#   ② 坏写法夹具都报：os.cpu_count()、multiprocessing.cpu_count()、Pool(本机核数)（#1332 原样）、ProcessPoolExecutor() 不给路数、
#      ProcessPoolExecutor(8) 字面数、变量来源不是 process_pool_size 的 Pool(n)
#   ③ 好写法夹具不报：Pool(process_pool_size(n))、J = process_pool_size(...) 后 ProcessPoolExecutor(J)、ThreadPoolExecutor(cores())、tests/ 下的夹具
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
o=$(python3 "$H/tools/pool_size_lint.py" "$H" 2>&1); r=$?
ck "① 本仓库核数只在 pool_workers 读、进程池都经 process_pool_size（命中：${o:0:400}）" '[ $r = 0 ] && [ -z "$o" ]'
mkdir -p "$T/r/pack/jobs" "$T/r/tools" "$T/r/tests" && cd "$T/r" && git init -q .
cat > pack/bad.py <<'X'
import os, multiprocessing as mp, concurrent.futures as cf
a = os.cpu_count()
b = mp.cpu_count()
def scan(jobs=None):
    jobs = jobs or int(os.environ.get('J') or 4)
    ctx = mp.get_context('spawn')
    with ctx.Pool(jobs) as p: pass
def c():
    with cf.ProcessPoolExecutor() as ex: pass
    with cf.ProcessPoolExecutor(8) as ex: pass
X
cat > pack/good.py <<'X'
import concurrent.futures as cf, multiprocessing as mp
from pool_workers import process_pool_size, env_jobs, cores
def scan(n):
    with mp.get_context('fork').Pool(process_pool_size(n)) as p: pass
J = process_pool_size(env_jobs('J', 'S2A_JOBS'))
def c():
    with cf.ProcessPoolExecutor(J) as ex: pass
    with cf.ProcessPoolExecutor(max_workers=J) as ex: pass
    with cf.ThreadPoolExecutor(cores()) as ex: pass
X
cat > tests/fixture.py <<'X'
import os
n = os.cpu_count()
X
printf 'import os\nn = os.cpu_count()\n' > pack/jobs/programs.py   # 白名单那一条：命中、不报
cp "$H/tools/pool_size_lint.py" tools/ && git add -A && git commit -qm f
o=$(python3 tools/pool_size_lint.py "$T/r" 2>&1)
ck "② os.cpu_count() 报（pack/bad.py:2）" 'echo "$o" | grep -q "^pack/bad.py:2: 直接读本机核数"'
ck "② multiprocessing.cpu_count() 报（pack/bad.py:3）" 'echo "$o" | grep -q "^pack/bad.py:3: 直接读本机核数"'
ck "② Pool(jobs)，jobs 不是 process_pool_size 给的（#1332 原样，pack/bad.py:7）" 'echo "$o" | grep -q "^pack/bad.py:7: 进程池路数没经 process_pool_size"'
ck "② ProcessPoolExecutor() 不给路数（pack/bad.py:9）" 'echo "$o" | grep -q "^pack/bad.py:9: 进程池路数"'
ck "② ProcessPoolExecutor(8) 字面数（pack/bad.py:10）" 'echo "$o" | grep -q "^pack/bad.py:10: 进程池路数"'
ck "③ 好写法不报（pack/good.py 0 条）" '! echo "$o" | grep -q "^pack/good.py"'
ck "③ tests/ 下的夹具不扫" '! echo "$o" | grep -q "^tests/"'
ck "③ 白名单 pack/jobs/programs.py 命中不报、也不报过期" '! echo "$o" | grep -q "programs.py"'
ck "② 共 5 条命中、退出 1" '[ "$(echo "$o" | grep -c "^pack/bad.py")" = 5 ]'
[ $bad = 0 ] && echo "pool_size_lint 单测全过" || { echo "pool_size_lint 单测有不通"; exit 1; }
