#!/usr/bin/env python3
# 直连库容器打包按存储身份认同一份字节的单测（#1331：C# LibPack.PackFiles 的 ident 分支，经 dsh_batch --libpack ident-test 调，判据在 LibPack.IdentTest）。
#   两组输入（手给 ident、真 Side 的 Ident），每组按 ident=null 与给 ident 各打一次：期望两次产物（lib.000.pak + lib.idx）逐字节相同、汇总行相同；
#   给 ident 时同身份三名的 get 合计 1 次，字节相同但身份不同的照旧读 1 次；ident=null 时每名各 1 次。不依赖 Metal 工具链，Linux / Windows / Mac 都能跑。
#   负对照（手做过）：PackFiles 不看 ident → 「同身份合计读 1 次」两条红；ident 分支记错段长 → 回读报红、「逐字节相同」两条红
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '../../../../translator')); import dsh_batch
CMD, _ = dsh_batch.get()
with tempfile.TemporaryDirectory() as t:
    r = subprocess.run([*CMD, '--libpack', 'ident-test', t], capture_output=True, text=True, encoding='utf-8')
print(r.stdout, end=''); print(r.stderr, end='', file=sys.stderr)
# 第 ② 组在 Build.cs 的分部方法里，没编进来时编译器会整句略去：要求它的判据行真出现，免得少一组还报绿
ok = r.returncode == 0 and r.stdout.rstrip().endswith('ident-test: ok') and '✗' not in r.stdout and 'Side.Ident：' in r.stdout and 'side：' in r.stdout
print('PASS' if ok else f'FAIL（退出 {r.returncode}）')
sys.exit(0 if ok else 1)
