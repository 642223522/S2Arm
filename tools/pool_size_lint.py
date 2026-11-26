#!/usr/bin/env python3
"""并行度唯一来源守卫（#1332 / D-V5QR：Windows 88 核出包卡死在「八个轻阶段」——graphics/widen/scan/wide_scan.py 没给 J 时直接 Pool(本机核数)，
Windows 进程池超过 61 个工作进程就卡死）。规矩：本机核数只在 tools/pool_workers.py 读（cores / env_jobs），进程池路数一律经 process_pool_size。

判法（静态，.py）：
  ① 读核数：os.cpu_count() / multiprocessing.cpu_count() / mp.cpu_count() / os.process_cpu_count() 等任意 *.cpu_count() 调用 → 报
  ② 起进程池：ProcessPoolExecutor(...) / *.Pool(...) / Pool(...) 的路数参数（第一个位置参数，或 max_workers= / processes=）
     - 是 process_pool_size(...) 调用 → 不报
     - 是一个变量名、且同一文件里有「这个名字 = …process_pool_size(…)…」的赋值 → 不报
     - 其余（没给路数、字面数、别的式子、来源不明的变量）→ 报
  线程池（ThreadPoolExecutor）没有 Windows 61 的上限，不判②，但它的路数照①只许经 cores / env_jobs 读核数。
不扫：compat/（上游树）、tests 目录（单测自建夹具）、tools/pool_workers.py 本身、本文件。shell 里的 getconf 核数归 tools/cores.sh，不在本守卫。
白名单 ALLOW：逐条写理由；白名单里的条目已不再命中时报「白名单过期」。
用法：pool_size_lint.py [仓库根]   退出 0 = 没有；1 = 逐条点名「文件:行: 原文」
"""
import ast
import os
import re
import subprocess
import sys

MODULE = "tools/pool_workers.py"
SELF = "tools/pool_size_lint.py"
# (文件, 规则) → 理由
ALLOW = {
    ("pack/jobs/programs.py", "cpu_count"):
        "作业层（App 里在 Resources/Jobs，和引擎的 tools/ 分开发）只拿核数给 zstd 压缩定线程数，不起进程池；作业层不导入引擎的 tools",
}


def tracked(root):
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True, check=True).stdout
    for f in out.decode("utf-8", "surrogateescape").split("\0"):
        if not f or f in (MODULE, SELF) or f.startswith("compat/") or re.search(r"(^|/)[^/]*tests?/", f, re.I):
            continue
        if f.endswith(".py"):
            yield f


def _name(fn):
    return fn.attr if isinstance(fn, ast.Attribute) else fn.id if isinstance(fn, ast.Name) else None


def _has_pps(node):
    return any(isinstance(n, ast.Call) and _name(n.func) == "process_pool_size" for n in ast.walk(node))


def check(path, text):
    """→ [(行, 规则, 原文)]"""
    try:
        tree = ast.parse(text, path)
    except SyntaxError:
        return []
    lines = text.splitlines()
    sized = set()   # 由 process_pool_size 赋值过的名字
    for n in ast.walk(tree):
        if isinstance(n, (ast.Assign, ast.AnnAssign, ast.AugAssign)) and n.value is not None and _has_pps(n.value):
            for t in (n.targets if isinstance(n, ast.Assign) else [n.target]):
                if isinstance(t, ast.Name):
                    sized.add(t.id)
    hits = []
    for n in ast.walk(tree):
        if not isinstance(n, ast.Call):
            continue
        nm = _name(n.func)
        if nm in ("cpu_count", "process_cpu_count"):
            hits.append((n.lineno, "cpu_count"))
        elif nm in ("ProcessPoolExecutor", "Pool"):
            arg = n.args[0] if n.args else next((k.value for k in n.keywords if k.arg in ("max_workers", "processes")), None)
            ok = arg is not None and (_has_pps(arg) if isinstance(arg, ast.Call) else isinstance(arg, ast.Name) and arg.id in sized)
            if not ok:
                hits.append((n.lineno, "pool"))
    return [(ln, rule, lines[ln - 1].strip()[:160] if ln <= len(lines) else "") for ln, rule in hits]


def main(root):
    bad, used = [], set()
    for f in tracked(root):
        try:
            text = open(os.path.join(root, f), encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue
        for ln, rule, src in check(f, text):
            if (f, rule) in ALLOW:
                used.add((f, rule))
                continue
            why = "直接读本机核数（改用 tools/pool_workers.py 的 cores / env_jobs）" if rule == "cpu_count" else \
                "进程池路数没经 process_pool_size（Windows 至多 61 路，#1332）"
            bad.append(f"{f}:{ln}: {why}: {src}")
    for k in sorted(set(ALLOW) - used):
        bad.append(f"{k[0]}: 白名单过期（{k[1]} 已不再命中），删掉这一条")
    for b in bad:
        print(b)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
