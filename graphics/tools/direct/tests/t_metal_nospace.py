#!/usr/bin/env python3
# 编译时盘写满不能当成「这一支编不过、其余照出」（#265）：dsh_batch --metal-compile 走真实的 Metal.Init + Compile（graphics/tools/direct/dsh/batch/Build.cs），
#   PATH 前面放假 xcrun 注入编译器输出。期望按 Build.cs 的分类规则手写：
#   ① 编译器报 No space left on device → 整次停（退出 2，原话带 No space left on device，出包作业据此报 disk_full）
#   ② 普通语法错 → 只记这一支编不过（退出 1），不整次停
import os, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '../../../../translator')); import dsh_batch
CMD, _ = dsh_batch.get()
fails = []
def check(cond, msg):
    print(('  ✓ ' if cond else '  ✗ ') + msg)
    if not cond: fails.append(msg)

FAKE = '''#!/bin/sh
case " $* " in
  *" --version "*) echo "Apple metal version 32023.999 (fake)"; exit 0;;
  *" --show-sdk-version "*) echo 99.0; exit 0;;
  *" --show-sdk-build-version "*) echo FAKE1; exit 0;;
esac
echo "$FAKE_ERR" >&2; exit 1
'''
def run(err):
    with tempfile.TemporaryDirectory() as t:
        b = os.path.join(t, 'bin'); os.makedirs(b); x = os.path.join(b, 'xcrun'); open(x, 'w').write(FAKE); os.chmod(x, 0o755)
        src = os.path.join(t, 'k1.metal'); open(src, 'w').write('kernel void k() {}\n')
        w = os.path.join(t, 'work'); os.makedirs(w)
        env = dict(os.environ, PATH=b + os.pathsep + os.environ['PATH'], FAKE_ERR=err, S2A_METAL_PCH='0')
        return subprocess.run([*CMD, '--metal-compile', w, src], capture_output=True, text=True, env=env)

r = run("error: unable to open output file '/x/k1.air': 'No space left on device'")
check(r.returncode == 2 and 'No space left on device' in r.stdout, f'① 盘写满 → 整次停、原话带 No space left on device（实得 {r.returncode}：{r.stdout.strip()[:160]}{r.stderr.strip()[:200]}）')
r = run("k1.metal:1:15: error: expected expression")
check(r.returncode == 1 and 'expected expression' in r.stdout, f'② 普通语法错 → 只记这一支编不过（实得 {r.returncode}：{r.stdout.strip()[:160]}）')
print(f't_metal_nospace：{"全符" if not fails else f"{len(fails)} 例不符"}')
sys.exit(1 if fails else 0)
