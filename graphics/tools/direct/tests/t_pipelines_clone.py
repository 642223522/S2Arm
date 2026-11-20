#!/usr/bin/env python3
# 门禁覆盖：graphics/tools/direct/cs_pipelines.py graphics/tools/direct/base_pipelines.py
# cs_pipelines.clone 多线程同写一个目标（base_pipelines / cs_pipelines 用 ThreadPoolExecutor 并发出管线，两路碰上同一缓存键时同写一个缓存文件）：
#   16 条线程各 200 次同时 clone 到同一目标。期望按构造写死：没有任何一次抛异常；目标内容等于源；目录里不留 *.tmp。
#   修前临时件名只带进程号，同进程两条线程共用一个临时件：先改名的一条把它挪走，后一条 os.replace 报 FileNotFoundError（Ori 2 出包实例）
import os, sys, tempfile, threading
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cs_pipelines import clone

with tempfile.TemporaryDirectory() as d:
    d = Path(d); src = d / 'src.bin'; src.write_bytes(os.urandom(64 * 1024)); dst = d / 'cache' / 'ab' / 'ab12.e'; dst.parent.mkdir(parents=True)
    errs = []; go = threading.Barrier(16)
    def worker():
        go.wait()
        for _ in range(200):
            try: clone(src, dst)
            except Exception as e: errs.append(repr(e)); return
    ts = [threading.Thread(target=worker) for _ in range(16)]
    for t in ts: t.start()
    for t in ts: t.join()
    left = [p.name for p in dst.parent.iterdir() if p.name.endswith('.tmp')]
    ok = not errs and dst.read_bytes() == src.read_bytes() and not left
    print(('✓' if ok else '✗') + f' t_pipelines_clone：16 线程 × 200 次同写一个目标，异常 {len(errs)} 次{("（例 " + errs[0][:120] + "）") if errs else ""}，内容{"一致" if dst.read_bytes() == src.read_bytes() else "不一致"}，残留临时件 {len(left)} 个')
    sys.exit(0 if ok else 1)
