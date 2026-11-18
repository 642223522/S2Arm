#!/usr/bin/env python3
"""宿主约定号表态门禁（runtime/include/s2a_host_abi.h S2A_HOST_ABI，11-16）。

宿主读每款产物的方式（改写器与运行时的约定、各表格式、程序 / 镜像目录布局）变了要把 S2A_HOST_ABI 加 1，否则旧产物在新宿主上
静默崩（宿主载入时按它拒载：runtime/src/launchctx.c s2a_host_abi_check）。这件事机器判不了，只要求作者表态：
本支改了 CONTRACT 里的文件、又没动 S2A_HOST_ABI → 本支某条提交信息里要有一行「host-abi: unchanged <原因>」，没有就报红。
不替作者判断改动是否真影响约定。

用法：python3 tools/host_abi_lint.py [--repo 仓库] [--base origin/main] [--ref HEAD]   → 退出 0 过、1 红
"""
import argparse, re, subprocess, sys

HEADER = "runtime/include/s2a_host_abi.h"
# 宿主读产物的约定所在：写的一方（改写器、容器组装）与读的一方（宿主载入 / 补丁点 / 地址需求 / 启动上下文布局）
CONTRACT = (
    "runtime/rewriter/rewriter.c", "runtime/rewriter/rewriter.h", "runtime/rewriter/main.c",   # 跳板 / 虚拟寄存器槽 / 门控表、*.fixups / *.gates 的写法
    "runtime/src/loader.c", "runtime/include/s2a_programs.h",                                   # 载入程序：读 *.fixups / *.gates、程序目录布局
    "runtime/src/patch.c", "runtime/include/patch.h",                                           # *.sites
    "runtime/src/svc_mem.c",                                                                    # addr_need.tsv
    "runtime/src/launchctx.c", "runtime/include/s2a_launch_ctx.h",                              # 多款容器 / 程序清单布局
    "pack/ship_ext.py",                                                                         # 容器组装：Games/<号>、S2AImages-<号>.dylib、s2a_catalogue.json
)
DECL = re.compile(r"^host-abi: unchanged\s+\S", re.M)


def git(repo, *a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True, encoding="utf-8", errors="replace")


def abi_at(repo, rev):
    r = git(repo, "show", f"{rev}:{HEADER}")
    m = re.search(r"^#define S2A_HOST_ABI (\d+)$", r.stdout, re.M) if r.returncode == 0 else None
    return int(m.group(1)) if m else None


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".")
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("--ref", default="HEAD")
    a = ap.parse_args(argv)
    mb = git(a.repo, "merge-base", a.base, a.ref)
    if mb.returncode:
        print(f"【红】host_abi_lint：取不到 {a.base} 与 {a.ref} 的合并基点：{mb.stderr.strip()}"); return 1
    mb = mb.stdout.strip()
    changed = set(git(a.repo, "-c", "core.quotepath=off", "diff", "--name-only", mb, a.ref).stdout.split("\n"))
    touched = sorted(f for f in CONTRACT if f in changed)
    if not touched:
        print("host_abi_lint：本支没改宿主读产物的约定文件"); return 0
    before, after = abi_at(a.repo, mb), abi_at(a.repo, a.ref)
    if before is None: before = 1   # 基点还没有这个头：约定号当时是 pack/jobs/host_update.py 里手写的 1
    if after is not None and after != before:
        print(f"host_abi_lint：改了约定文件 {len(touched)} 个，S2A_HOST_ABI {before} → {after}，已表态"); return 0
    msgs = git(a.repo, "log", "--format=%B", f"{mb}..{a.ref}").stdout
    m = DECL.search(msgs)
    if m:
        line = msgs[m.start():].split("\n", 1)[0]
        print(f"host_abi_lint：改了约定文件 {len(touched)} 个，提交信息表态「{line}」"); return 0
    print("【红】host_abi_lint：本支改了宿主读产物的约定文件，S2A_HOST_ABI 没动，提交信息里也没有表态：")
    for f in touched: print(f"  {f}")
    print(f"  宿主读产物的方式变了 → 把 {HEADER} 的 S2A_HOST_ABI 加 1；没变（只修宿主自身的 bug 等）→ 提交信息里加一行「host-abi: unchanged <原因>」")
    return 1


if __name__ == "__main__":
    sys.exit(main())
