#!/usr/bin/env python3
"""t_present_settings.sh 的链接清单工具（graphics/nvn/tests/t_present_settings.link.txt 是唯一来源：构建只编、只链它列的宿主源文件，
门禁按同一份清单算这两支单测的输入，见 tools/gate_route.py「门禁清单」）。
  python3 t_present_settings.py sources <清单>                       清单里要编的源文件（.c / .m / .S），一行一个
  python3 t_present_settings.py depcheck <清单> <仓库根> <.d 文件…>    编译器实读的仓库内头文件都要在清单里；缺了逐个报、退出 1
  python3 t_present_settings.py weak <目标文件 / 静态库…>             链接放行参数：这些输入里只被弱引用、谁都不定义的符号（同 android/tests/host_link.py 按目标文件实算）
  python3 t_present_settings.py dyncheck <清单> <可执行文件>           链出来的程序里运行期才查找的符号都要在清单「dyn」行里（新多出一个 = 清单外的文件可能提供它，重生成清单）
清单格式：# 开头是注释；「src <路径>」编译链接的源文件；「hdr <路径>」这些源文件与 t_present_settings.m 实读的头文件；「dyn <符号>」运行期查找的弱符号。
清单由 graphics/nvn/tests/t_present_settings_closure.py 按链接器实算生成，宿主 / 前端代码改动让链接报未定义符号或上面两项核对报红时重跑它。"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = "graphics/nvn/tests/t_present_settings.m"   # 单测主文件：本身就是本测输入，不进清单
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools"))
import weak_link_decl  # noqa: E402  放行参数的唯一生成处


def entries(lst):
    out = {"src": [], "hdr": [], "dyn": []}
    with open(lst, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            kind, _, val = s.partition(" ")
            if kind not in out or not val.strip():
                sys.exit(f"【红】{lst}:{n} 认不出的行：{s}")
            out[kind].append(val.strip())
    return out


def deps(dfile):
    """编译器 -MD 写的依赖文件 → 编译实读的文件（含被编源文件本身与 SDK 文件）"""
    txt = open(dfile, encoding="utf-8", errors="replace").read().replace("\\\n", " ")
    _, _, rest = txt.partition(":")
    return [p.replace("\\ ", " ") for p in re.split(r"(?<!\\)\s+", rest) if p]


def depcheck(lst, root, dfiles):
    root = os.path.realpath(root)
    listed = set(entries(lst)["hdr"]) | set(entries(lst)["src"]) | {MAIN}
    missing = {}
    for d in dfiles:
        for p in deps(d):
            rp = os.path.realpath(p if os.path.isabs(p) else os.path.join(root, p))
            if not rp.startswith(root + "/"):
                continue   # 系统 / SDK 头
            rel = rp[len(root) + 1:]
            if rel.startswith("build/"):
                continue   # 构建产物（本测宿主侧不生成头，留作防御）
            if rel not in listed:
                missing.setdefault(rel, os.path.basename(d))
    for rel, d in sorted(missing.items()):
        print(f"【红】链接清单缺头文件 {rel}（{d} 实读）：清单过期，重跑 graphics/nvn/tests/t_present_settings_closure.py")
    return 1 if missing else 0


def symbols(paths):
    """nm -m → (定义的, 强引用的, 弱引用的) 外部符号"""
    r = subprocess.run(["nm", "-m", *paths], capture_output=True, text=True)
    if r.returncode:
        sys.exit(f"【红】nm 读不了链接输入：{r.stderr.strip()[-300:]}")
    defined, strong, weak = set(), set(), set()
    for line in r.stdout.splitlines():
        m = re.search(r"\(undefined\) (weak )?external (\S+)", line)
        if m:
            (weak if m.group(1) else strong).add(m.group(2))
            continue
        m = re.search(r"\) (?:weak )?external (?:\[[^\]]*\] )?(\S+)$", line)
        if m:
            defined.add(m.group(1))
    return defined, strong, weak


def dynamic(exe):
    r = subprocess.run(["nm", "-m", exe], capture_output=True, text=True, check=True)
    return {m.group(1) for m in re.finditer(r"\(undefined\) (?:weak )?external (\S+) \(dynamically looked up\)", r.stdout)}


def main(a):
    if len(a) == 2 and a[0] == "sources":
        print("\n".join(entries(a[1])["src"]))
        return 0
    if len(a) >= 3 and a[0] == "depcheck":
        return depcheck(a[1], a[2], a[3:])
    if len(a) >= 2 and a[0] == "weak":
        defined, strong, weak = symbols(a[1:])
        print(" ".join(weak_link_decl.u_flags(s[1:] for s in weak - defined - strong if s.startswith("_"))))
        return 0
    if len(a) == 3 and a[0] == "dyncheck":
        extra = sorted(dynamic(a[2]) - set(entries(a[1])["dyn"]))
        for s in extra:
            print(f"【红】{s} 链接后成了运行期查找（清单 dyn 行里没有）：清单外的文件可能提供它，重跑 graphics/nvn/tests/t_present_settings_closure.py")
        return 1 if extra else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
