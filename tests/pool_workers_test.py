"""进程池路数（#1332 / D-VV4J：88 核 Windows 出 iPhone 包停在「资源包 N/N」几小时——Windows 进程池超过 61 个卡死 / 抛错）。
五处按核数开进程池的真实入口逐个跑（pack.py 算哈希、ui_lyt 宽屏布局、nxsh_extract 抽取着色器、shader_split 直连抽取、
wide_scan 宽屏扫描——#1332 / D-V5QR 88 核卡死在「八个轻阶段」的就是它，原先没给 J 时 Pool(本机核数)），
核数打成 88 / 128、模拟 Windows（只换 tools/pool_workers._windows，不碰全局 os.name），记下各处真正交给进程池的路数。期望手写：
  ① Windows：88 / 128 核 → 每处都是 61；② 非 Windows：128 核 → 128（不封顶）；③ 少于 61 的照给（16 核 → 16）
池按记下的路数开但实际只起 2 个进程（不真起 61 个进程），入口其余逻辑照跑"""
import concurrent.futures as cf, multiprocessing.context as mpc, os, runpy, shutil, subprocess, sys, tempfile
from pathlib import Path
from unittest import mock
R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / "tools"))
import pool_workers
bad = 0
def ck(name, want, got):
    global bad
    ok = want == got; bad += not ok; print(f"{'通' if ok else '不通'} {name}：期望 {want} → 真结果 {got}")

asked = []
RealPPE = cf.ProcessPoolExecutor
class RecPPE(RealPPE):
    def __init__(self, max_workers=None, *a, **k):
        asked.append(max_workers); super().__init__(2, *a, **k)
real_pool = mpc.BaseContext.Pool
def rec_pool(self, processes=None, *a, **k):
    asked.append(processes); return real_pool(self, 2, *a, **k)

def run(entry, cores, windows, env):
    asked.clear()
    keep = {k: os.environ.get(k) for k in ("J", "S2A_JOBS", "S2A_NCPU", "S2A_KEYSCAN_J")}   # 核数只按下面打桩的 os.cpu_count 算，不吃外面给的覆盖
    for k in keep: os.environ.pop(k, None)
    os.environ.update(env)
    try:
        with mock.patch.object(os, "cpu_count", lambda: cores), mock.patch.object(pool_workers, "_windows", lambda: windows), \
             mock.patch.object(cf, "ProcessPoolExecutor", RecPPE), mock.patch.object(mpc.BaseContext, "Pool", rec_pool):
            entry()
    finally:
        for k, v in keep.items():
            os.environ.pop(k, None)
            if v is not None: os.environ[k] = v
    return sorted(set(asked))

T = Path(tempfile.mkdtemp(prefix="s2a-pool61-"))
def argv_run(script, args):
    def go():
        old = sys.argv; sys.argv = [str(script), *map(str, args)]
        try: runpy.run_path(str(script), run_name="__main__")
        except SystemExit as e:
            if e.code not in (0, None): raise
        finally: sys.argv = old
    return go

# pack.py：源目录一个文件 → 克隆后算哈希的进程池
src = T / "src"; src.mkdir(); (src / "a.bin").write_bytes(b"x" * 100)
def pack_entry(tag):
    out = T / f"pack_{tag}"; shutil.rmtree(out, ignore_errors=True)
    return argv_run(R / "pack/pack.py", [out, f"d={src}"])
# ui_lyt：空的 Layout 目录（入口照样开池）
lyt = T / "romfs"; (lyt / "Layout").mkdir(parents=True)
ui_entry = argv_run(R / "graphics/widen/scan/ui_lyt.py", [lyt, T / "lyt_out", 1920])
# nxsh_extract：空资源目录（入口最后一段整体扫描照样开池）；路数来自编排给的 J
nx_root = T / "nx_root"; nx_root.mkdir()
def nx_entry(tag): return argv_run(R / "graphics/tools/shbake/nxsh_extract.py", [T / f"nx_out_{tag}", nx_root])
# shader_split：仓库自带的最小夹具（tests/shader_split_reuse.py 同一套：空 RomFS + 自编 NSO + 档案）
fx = R / "tests/fixtures/shader_split_reuse"
prof = T / "profile"; prof.mkdir(); shutil.copyfile(fx / "shader_split_reuse_profile.tsv", prof / "game.tsv")
main_nso = T / "main"; shutil.copyfile(fx / "fixture.nso", main_nso); ss_romfs = T / "ss" / "romfs"; ss_romfs.mkdir(parents=True)
os.environ["DM_GAME"] = str(prof)
for k in ("DM_GLSLC_CAPTURE", "DM_UE_SHADERS", "DM_OODLE_JOB"): os.environ.pop(k, None)
def ss_entry(tag):
    out = T / f"ss_{tag}"; out.mkdir()
    return argv_run(R / "translator/shader_split.py", [ss_romfs, main_nso, out / "pkg", out / "map.tsv", out / "facts.tsv", out / "pairs.tsv"])

# wide_scan：一段 1 MB 的空镜像（够 1<<16 个字，才会分段开池）；单测强制 fork 起法（Mac 上起池，记下交给 Pool 的路数）
sys.path.insert(0, str(R / "graphics/widen/scan")); import wide_scan
def ws_entry(): wide_scan.scan(bytes(4 << 18), start="fork")

for cores in (88, 128):
    ck(f"① pack.py 算哈希：Windows {cores} 核", [61], run(pack_entry(f"w{cores}"), cores, True, {}))
    ck(f"① ui_lyt 宽屏布局：Windows {cores} 核", [61], run(ui_entry, cores, True, {}))
    ck(f"① nxsh_extract 抽取：Windows、编排给 J={cores}", [61], run(nx_entry(f"w{cores}"), cores, True, {"J": str(cores)}))
    ck(f"① shader_split 直连抽取：Windows {cores} 核", [61], run(ss_entry(f"w{cores}"), cores, True, {}))
    ck(f"① wide_scan 宽屏扫描：Windows {cores} 核（#1332 原卡死点）", [61], run(ws_entry, cores, True, {}))
ck("② pack.py：非 Windows 128 核不封顶", [128], run(pack_entry("m128"), 128, False, {}))
ck("② ui_lyt：非 Windows 128 核不封顶", [128], run(ui_entry, 128, False, {}))
ck("② wide_scan：非 Windows 128 核不封顶", [128], run(ws_entry, 128, False, {}))
ck("③ wide_scan：Windows 16 核照给 16", [16], run(ws_entry, 16, True, {}))
ck("④ wide_scan：Windows 88 核、编排给 S2A_JOBS=22（按内存预算分到的路数）→ 22", [22], run(ws_entry, 88, True, {"S2A_JOBS": "22"}))
ck("③ pack.py：Windows 16 核照给 16", [16], run(pack_entry("w16"), 16, True, {}))
ck("③ shader_split：Windows 16 核照给 16", [16], run(ss_entry("w16"), 16, True, {}))
shutil.rmtree(T, ignore_errors=True)
print(f"pool_workers：{'全过' if not bad else f'{bad} 处不通'}"); sys.exit(1 if bad else 0)
