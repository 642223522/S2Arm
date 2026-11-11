#!/usr/bin/env python3
"""阶段缓存键「产物等价」（pack/stage_inputs/equiv.tsv、tools/stage_equiv.py；pack/stage_keyfiles.sh 与 tools/stage_deps.py 两层都认）：
临时 git 仓库造一张阶段表（「入」a.py），期望值是「与改前相同 / 不同」，不跑被测实现推：
  ① 改 a.py、不登记 → 源码键变、实际读入清单的哈希变（宁可重跑）
  ② 登记等价（stage_equiv.py add a.py <改前提交>）→ 两层都回到改前（老游戏命中缓存）
  ③ 再改一次、以上一版为基线登记 → 顺着链回到最早一版（老玩家缓存里记的那一版）
  ④ 登记了，但文件又被改成别的内容（哈希对不上登记）→ 照旧变"""
import os, shutil, subprocess, sys, tempfile
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
bad = 0
def ck(ok, msg):
    global bad; bad += not ok; print(('通 ' if ok else '不通 ') + msg)

with tempfile.TemporaryDirectory() as t:
    def sh(*a, **k): return subprocess.run(a, cwd=t, capture_output=True, text=True, check=True, **k).stdout.strip()
    sh('git', 'init', '-q'); sh('git', 'config', 'user.email', 't@t'); sh('git', 'config', 'user.name', 't')
    for d in ('pack/stage_inputs', 'tools'): os.makedirs(os.path.join(t, d))
    shutil.copy(os.path.join(R, 'pack/stage_keyfiles.sh'), os.path.join(t, 'pack'))
    for f in ('stage_deps.py', 'stage_equiv.py'): shutil.copy(os.path.join(R, 'tools', f), os.path.join(t, 'tools'))
    open(os.path.join(t, 'pack/stage_inputs/s.tsv'), 'w').write('入\ta.py\n')
    open(os.path.join(t, 'pack/stage_inputs/equiv.tsv'), 'w').write('# 表头\n')
    def put(txt, msg): open(os.path.join(t, 'a.py'), 'w').write(txt); sh('git', 'add', '-A'); sh('git', 'commit', '-qm', msg); return sh('git', 'rev-parse', 'HEAD')
    def key(): return subprocess.run(['bash', '-c', f'source pack/stage_keyfiles.sh; stage_files_key s "{t}"'], cwd=t, capture_output=True, text=True).stdout.strip()
    def dep(): return subprocess.run([sys.executable, 'tools/stage_deps.py', 'rehash', 'm.tsv', t], cwd=t, capture_output=True, text=True).stdout
    def eq(base):
        row = subprocess.run([sys.executable, os.path.join(t, 'tools/stage_equiv.py'), 'add', 'a.py', base, '测试'], cwd=t, capture_output=True, text=True, check=True).stdout
        open(os.path.join(t, 'pack/stage_inputs/equiv.tsv'), 'a').write(row); sh('git', 'add', '-A'); sh('git', 'commit', '-qm', 'eq')
    c0 = put('x = 1\n', 'v0'); open(os.path.join(t, 'm.tsv'), 'w').write('f\tR:a.py\t-\n')
    k0, d0 = key(), dep()
    c1 = put('x = 1  # 只改注释\n', 'v1')
    ck(key() != k0 and dep() != d0, f'① 改了不登记 → 两层都变（键 {k0} → {key()}）')
    eq(c0)
    ck(key() == k0 and dep() == d0, f'② 登记等价 → 两层回到改前（键 {key()}，清单 {dep().split()[-1]}）')
    put('x = 1  # 又改注释\n', 'v2'); eq(c1)
    ck(key() == k0 and dep() == d0, f'③ 链式登记（基线是上一版）→ 回到最早一版（键 {key()}）')
    put('x = 2\n', 'v3')
    ck(key() != k0 and dep() != d0, f'④ 又改成别的内容（与登记对不上）→ 照旧变（键 {key()}）')
print(f'stage_equiv 单测：{"全通" if not bad else f"{bad} 项不通"}'); sys.exit(1 if bad else 0)
