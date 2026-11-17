#!/usr/bin/env python3
"""发版应用布局下的作业层导入门禁（11-16：一天两次候选被作业层的导入打断——上午 install.py 新 import、晚上 programs.py 按
Path(__file__).parents[2] 推引擎根，源码树里都对，打出来的应用里作业层在 Contents/Resources/Jobs，往上推只到 Contents）。

搭和发版应用一样的布局（临时目录，不碰真游戏库）：
  Mac：S2Arm.app/Contents/Resources/Jobs（launchers/macos/jobs_bundle.stage_jobs，与 build_app 同一个函数）+ 另放一份引擎快照 Engine/
       （launchers/macos/bundle_engine.snapshot_files，应用运行时引擎是这份快照的克隆，作业请求的 engineDir = c.engine）
  Windows：Engine/pack/jobs（作业层就在引擎快照里，cd 到 Engine 跑 python pack/jobs/main.py）
三步，任一步不过退出 1：
  ① 导入：两种布局各起隔离的 Python（-B -I，cwd 在临时目录），sys.path 与 main.py 起来时一样，逐个 import 作业层每个模块
  ② 全文扫 import（含函数里的，运行到才执行的那种）：每个导入的顶层名必须是作业层自己的模块、标准库、随包 Python 的第三方包；
     引擎包 pack.*：所在函数（没有就整个文件）里要把 c.engine / engine 放进 sys.path，不能按 __file__ 推（Mac 应用里推不到引擎）；
     包在 try … except ImportError / Exception 里的可选依赖不算
  ③ 最小作业：Mac 布局下照应用的起法（python -B -I Jobs/main.py run --request）跑 setup、catalog，HOME 与游戏库都在临时目录
用法：python3 tools/app_layout_check.py [--repo 仓库根] [--keep 目录]   → 退出 0 过、1 红
"""
import argparse, ast, json, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path


def runtime_packages(root):
    """随包 Python 的第三方包导入名（launchers/macos/requirements-runtime.txt 的包名 → 导入名）"""
    alias = {"pillow": "PIL", "pyyaml": "yaml", "zstandard": "zstandard"}
    names = set()
    for line in (Path(root) / "launchers/macos/requirements-runtime.txt").read_text(encoding="utf-8").splitlines():
        m = re.match(r"\s*([A-Za-z0-9_.-]+)", line.split("#", 1)[0])
        if m:
            n = m.group(1).lower()
            names.add(alias.get(n, n.replace("-", "_")))
    return names


def build_layout(root, tmp):
    sys.path[:0] = [str(Path(root) / "launchers/macos"), str(Path(root) / "pack/jobs")]
    import bundle_engine, jobs_bundle
    resources = tmp / "mac/S2Arm.app/Contents/Resources"
    resources.mkdir(parents=True)
    jobs = jobs_bundle.stage_jobs(root, resources)
    engines = []
    for side in ("mac", "win"):
        eng = tmp / side / "Engine"
        for rel in bundle_engine.snapshot_files(Path(root)):
            src = Path(root) / rel
            if src.is_file():
                (eng / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, eng / rel)
        engines.append(eng)
    return resources, jobs, engines[0], engines[1]


def modules(jobs):
    """作业层模块（文件头表态「应用布局：」不从应用的 Jobs 里跑的不算）"""
    return sorted(p.stem for p in Path(jobs).glob("*.py") if p.stem != "__init__" and not file_declared(p.read_text(encoding="utf-8")))


IMPORT_ALL = r'''
import importlib, json, sys, traceback
sys.path.insert(0, sys.argv[1])
if len(sys.argv) > 3: sys.path.insert(1, sys.argv[3])
bad = {}
for m in json.loads(sys.argv[2]):
    try: importlib.import_module(m)
    except BaseException as e: bad[m] = "%s: %s" % (type(e).__name__, e)
print(json.dumps(bad, ensure_ascii=False))
'''


def import_all(jobs, names, cwd, extra=None):
    """隔离的 Python 里按 main.py 的 sys.path（脚本目录在最前；Windows 还有引擎根）逐个 import"""
    env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "PYTHONHOME")}
    env["HOME"] = str(cwd)
    r = subprocess.run([sys.executable, "-B", "-I", "-c", IMPORT_ALL, str(jobs), json.dumps(names)] + ([str(extra)] if extra else []),
                       cwd=cwd, env=env, capture_output=True, text=True, timeout=600)
    try:
        return json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"(导入脚本)": (r.stderr or r.stdout)[-400:]}


def guarded(node, parents):
    """这个 import 在 try … except ImportError / ModuleNotFoundError / Exception 里（可选依赖）"""
    for p in parents:
        if isinstance(p, ast.Try) and any(node in ast.walk(b) for b in p.body):
            for h in p.handlers:
                t = h.type
                names = [t] if t is not None and not isinstance(t, ast.Tuple) else (t.elts if t is not None else [])
                if t is None or any(isinstance(n, ast.Name) and n.id in ("ImportError", "ModuleNotFoundError", "Exception", "BaseException") for n in names):
                    return True
    return False


def engine_on_path(scope_src):
    """这段代码把引擎根放进了 sys.path，且引擎根来自作业请求（c.engine / 参数 engine），Mac 应用里也对"""
    return bool(re.search(r"sys\.path\.(insert|append)\(", scope_src)) and bool(re.search(r"\bc\.engine\b|\bself\.c\.engine\b|\bengine\b", scope_src))


MARK = re.compile(r"#\s*应用布局：\s*\S")   # 作者表态：这段 / 这个文件不从应用的 Jobs 里跑（只在 Windows、只从引擎里的 pack/jobs 起、应用里不跑），写明原因


def windows_only(src, node, chain, fn):
    """只在 Windows 上走到：外层 if 判 os.name == "nt"，或所在函数前面先 if os.name != "nt": … return（Windows 的作业层就在引擎快照里，引擎根在 sys.path）"""
    for p in chain:
        if isinstance(p, ast.If) and any(node in ast.walk(b) for b in p.body):
            t = ast.get_source_segment(src, p.test) or ""
            if re.search(r'os\.name\s*==\s*["\']nt["\']|sys\.platform\s*==\s*["\']win32["\']', t):
                return True
    if fn is not None:
        for st in fn.body:
            if st.lineno >= node.lineno:
                break
            if isinstance(st, ast.If) and re.search(r'os\.name\s*!=\s*["\']nt["\']', ast.get_source_segment(src, st.test) or "") and isinstance(st.body[-1], ast.Return):
                return True
    return False


def declared(lines, *linenos):
    return any(0 < n <= len(lines) and MARK.search(lines[n - 1]) for n in linenos)


def file_declared(src):
    return any(MARK.search(l) for l in src.splitlines()[:40])


def scan(jobs, own, third):
    """全文扫 import（含函数里的）→ [(文件:行, 说明)]"""
    std = set(sys.stdlib_module_names) | {"__future__"}
    problems = []
    for f in sorted(Path(jobs).glob("*.py")):
        src = f.read_text(encoding="utf-8")
        if file_declared(src):
            continue
        lines = src.splitlines()
        tree = ast.parse(src, str(f))
        parent = {}
        for n in ast.walk(tree):
            for ch in ast.iter_child_nodes(n):
                parent[ch] = n
        for n in ast.walk(tree):
            if isinstance(n, ast.Import):
                tops = [a.name.split(".")[0] for a in n.names]
            elif isinstance(n, ast.ImportFrom) and n.level == 0 and n.module:
                tops = [n.module.split(".")[0]]
            else:
                continue
            chain, p = [], parent.get(n)
            while p is not None:
                chain.append(p); p = parent.get(p)
            if guarded(n, chain):
                continue
            fn = next((p for p in chain if isinstance(p, (ast.FunctionDef, ast.AsyncFunctionDef))), None)
            scope = ast.get_source_segment(src, fn) if fn else src
            if declared(lines, n.lineno, *((fn.lineno, fn.lineno - 1) if fn else ())) or windows_only(src, n, chain, fn):
                continue
            for top in tops:
                if top in own or top in std or top in third or engine_on_path(scope or ""):
                    continue
                where = f"{f.name}:{n.lineno}"
                if top == "pack":
                    if True:
                        problems.append((where, f"导入引擎包 {ast.get_source_segment(src, n)}，所在{'函数 ' + fn.name if fn else '文件'}没把 c.engine 放进 sys.path"
                                                "（Mac 应用里作业层在 Contents/Resources/Jobs，按 __file__ 往上推找不到 pack/）"))
                    continue
                problems.append((where, f"导入 {top}：应用里的作业层没有它（不是作业层模块、标准库或随包 Python 的第三方包；要用就随 Jobs 带进去，"
                                        "见 launchers/macos/jobs_bundle.py EXTRA）"))
    return problems


MINI = ("setup", "catalog")


def mini_jobs(resources, jobs, engine, tmp):
    """照应用的起法（python -B -I Jobs/main.py run --request，HOME 与游戏库都在临时目录）跑 setup、catalog → [(作业, 说明)]。
    判据：输出里没有导入错（ModuleNotFoundError / ImportError / No module named），结果事件 state = succeeded"""
    home, private, library = tmp / "home", tmp / "private", tmp / "library"
    for d in (home, private):
        d.mkdir(parents=True, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "PYTHONHOME")}
    env.update(HOME=str(home), PYTHONDONTWRITEBYTECODE="1")
    bad, extra = [], dict(acceptFormat=True)   # 门禁机的临时盘不一定是 APFS / NTFS：只核导入，格式照玩家确认过处理
    for i, op in enumerate(MINI):
        req = dict(schema=1, jobId=f"layout-{op}-{i}", operation=op, privateRoot=str(private), library=str(library),
                   engineDir=str(engine), resources=str(resources), **extra)
        rp = tmp / f"req_{op}.json"; rp.write_text(json.dumps(req), encoding="utf-8")
        r = subprocess.run([sys.executable, "-B", "-I", str(jobs / "main.py"), "run", "--request", str(rp)], cwd=home, env=env,
                           capture_output=True, text=True, timeout=600)
        out = (r.stdout or "") + (r.stderr or "")
        m = re.search(r"(ModuleNotFoundError|ImportError|No module named)[^\n]*", out)
        result = None
        for line in (r.stdout or "").splitlines():
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if isinstance(e, dict) and e.get("type") == "result":
                result = e
        if m:
            bad.append((op, m.group(0)[:300]))
        elif not result or result.get("state") != "succeeded":
            bad.append((op, f"没成（退出码 {r.returncode}，结果 {(result or {}).get('state')}：{(result or {}).get('message') or out[-200:]}）"))
        elif op == "setup":
            extra = dict(libraryId=(result.get("result") or {}).get("libraryId"))
    return bad


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parents[1]))
    ap.add_argument("--keep", help="布局搭在这里并保留（排查用）；不给 = 临时目录，用完删")
    a = ap.parse_args(argv)
    root = Path(a.repo).resolve()
    tmp = Path(a.keep) if a.keep else Path(tempfile.mkdtemp(prefix="s2a_app_layout_"))
    try:
        resources, jobs, mac_engine, win_engine = build_layout(root, tmp)
        names = modules(jobs)
        work = tmp / "cwd"; work.mkdir(exist_ok=True)
        red = []
        for side, where, extra in (("Mac", jobs, None), ("Windows", win_engine / "pack/jobs", win_engine)):
            for m, why in import_all(where, [n for n in modules(where)], work, extra).items():
                red.append(f"① {side} 布局导入 {m}：{why}")
        own = set(names) | {p.name for p in jobs.iterdir() if p.is_dir() and (p / "__init__.py").is_file()}
        for where, why in scan(jobs, own, runtime_packages(root)):
            red.append(f"② {where}：{why}")
        for op, why in mini_jobs(resources, jobs, mac_engine, tmp):
            red.append(f"③ 最小作业 {op}：{why}")
        if red:
            print("【红】发版应用布局下作业层导入不过：")
            for r in red:
                print("  " + r)
            print(f"期望 两种布局导入 {len(names)} 个模块、全文 import 都找得到、最小作业 {'/'.join(MINI)} 不出导入错 → 真结果 {len(red)} 处不过")
            return 1
        print(f"期望 两种布局导入 {len(names)} 个模块、全文 import 都找得到、最小作业 {'/'.join(MINI)} 不出导入错 → 真结果 通过")
        return 0
    finally:
        if not a.keep:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
