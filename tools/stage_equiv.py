#!/usr/bin/env python3
"""阶段缓存键的「产物等价」表（pack/stage_inputs/equiv.tsv）：
  stage_equiv.py add <仓库相对路径> <基线提交> <证据>   打印一行等价声明（新内容 = 工作树里的文件，旧版本 = 基线提交里的同一文件；
                                                         旧版本自己也登记过等价时顺着链取最早那一版，即老玩家缓存里记的那一版）
  证据必填、要可复核（登错一行老玩家会一直拿旧产物且没人发现）：写实测读数和它在哪（提交说明 / 单测名），例如
    「#606 实测：同根换代码抽取 / 直连都跳过、冷抽 extract/ 产物 15 个文件逐字节同 main，读数见提交说明」；只写「只提速 / 产物不变」拒绝
供 tools/stage_deps.py import：canon(仓库相对路径, 内容 sha256 前 16 位) → 等价表里登记过就回旧版本的 sha16，否则原样。
阶段源码键那一层（git 对象号）在 pack/stage_keyfiles.sh 里用同一张表替换，不经本文件。"""
import hashlib, os, subprocess, sys

TABLE = os.path.join('pack', 'stage_inputs', 'equiv.tsv')


def load(repo):
    """→ {(路径, 新 sha16): (旧对象号, 旧 sha16)}；没有表 → {}"""
    out = {}
    try:
        for ln in open(os.path.join(repo, TABLE), encoding='utf-8'):
            if ln.startswith('#') or not ln.strip(): continue
            c = ln.rstrip('\n').split('\t')
            if len(c) >= 4: out[(c[0], c[1])] = (c[2], c[3])
    except FileNotFoundError:
        pass
    return out


_cache = {}
def canon(repo, rel, h):
    t = _cache.get(repo)
    if t is None: t = _cache[repo] = load(repo)
    return t.get((rel, h), (None, h))[1]


def sha16(b): return hashlib.sha256(b).hexdigest()[:16]


def git(repo, *a):
    env = os.environ.copy(); env.pop('DEVELOPER_DIR', None)
    return subprocess.run(['git', '-C', repo, *a], capture_output=True, check=True, env=env).stdout


def add(repo, rel, base, why):
    if len(why) < 20 or not any(ch.isdigit() for ch in why) or why.strip() in ('产物不变', '只提速'):
        raise SystemExit('证据不够：要写可复核的实测读数和它在哪（提交说明 / 单测名），例如「同根换代码两阶段跳过、冷抽产物 N 个文件逐字节同基线，见提交说明」')
    new = sha16(open(os.path.join(repo, rel), 'rb').read())
    obj = git(repo, 'rev-parse', f'{base}:{rel}').decode().strip()
    old = sha16(git(repo, 'cat-file', 'blob', obj))
    t = load(repo)
    obj, old = t.get((rel, old), (obj, old))   # 旧版本本身是等价登记的新内容：取它登记的更早一版
    if new == old: raise SystemExit(f'{rel} 内容与基线相同，不用登记')
    return f'{rel}\t{new}\t{obj}\t{old}\t{why}'


if __name__ == '__main__':
    a = sys.argv[1:]
    if len(a) >= 3 and a[0] == 'add':
        repo = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True, check=True).stdout.strip()
        print(add(repo, a[1], a[2], ' '.join(a[3:])))
    else:
        print(__doc__.strip(), file=sys.stderr); sys.exit(2)
