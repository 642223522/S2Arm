# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""游戏程序常驻与现建（11-16 维护者「程序部分极致压缩」）。

常驻（layout.program_store：默认位置根 .programs/<程序号>/，删游戏文件夹 / 释放空间都不碰，只有「删除游戏」才删）：
  exefs.tar.zst   原始程序（exefs 里的模块与 main.npdm，sgrade.save_program 存的那份）
  recipe.tar.zst  配方：iPhone 程序件（kit）里除「原始程序各模块的改写产物」以外的全部——main.npdm、ctl/control.nacp、icon、随包表
                  （fps / widen / cpatch / cpatch_rows / cheat-src / …）、多程序合集 programs/<n>/、运行时收回的 NRO 模块等推不出来的小件。
                  没有原始程序的老款（出包时还没存原始程序）推不出改写产物：整份 kit 都进配方
  ios.json        程序件的兼容记录（layout.update_info 写 game.json 的 ios 时同存）
缓存（<工具缓存>/cache/programs/<程序号>/{kit, exefs}，释放空间「着色器与出包缓存」可删）：
  kit 缺了就按配方现建：解开配方、对原始程序的每个模块按配方里的表跑一遍改写器（同 rewrite_refresh：帧率表、宽屏点表、社区补丁行表、随包代码补丁），
  11-16 常驻库 14 款实测与原 kit 改写产物逐字节相同、合计 83 秒；常驻部分 1969 MB → 约 400 MB（zstd 9 档）。
手机端存的那份（Documents/games/<程序号>/.s2a-program/）用同样两个归档。"""
from __future__ import annotations

import contextlib
import io
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import threading
import time

from core import Failure
import layout

EXEFS, RECIPE = "exefs.tar.zst", "recipe.tar.zst"
# zstd 档位（11-16 实测一款 67 MB 原始程序，负载高的本机）：19 档 41.1 MB、压 87–234 秒；9 档多线程 45.0 MB、压 2 秒——体积多约一成，迁移 / 出包快两个数量级
LEVEL = 9
OUTPUTS = ("patched.bin", "fixups.tsv", "gates.tsv", "sites.tsv", "gaps.tsv", "widen.tsv", "code_patch.tsv")   # 同 rewrite_refresh.OUTPUTS
MODULES = ("main", "sdk") + tuple(f"subsdk{i}" for i in range(10))


def _compress(data):
    try:
        from compression import zstd   # Python 3.14
        return zstd.compress(data, options={zstd.CompressionParameter.compression_level: LEVEL, zstd.CompressionParameter.nb_workers: os.cpu_count() or 1})
    except ImportError:
        import zstandard   # 随包 Python 3.12（pack/jobs/toolchain.py 核过有它）
        return zstandard.ZstdCompressor(level=LEVEL, threads=-1).compress(data)


def _decompress(data):
    try:
        from compression import zstd
        return zstd.decompress(data)
    except ImportError:
        import zstandard
        return zstandard.ZstdDecompressor().decompress(data)


def cache(c, gid):
    return Path(c.work_root) / "cache" / "programs" / gid.upper()


def _write(path, base, files):
    """base 下的这些文件（相对路径排序、时间清零，同一内容出同一字节）→ tar → zstd → path（临时文件 + 改名）"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for f in sorted(files, key=lambda p: p.relative_to(base).as_posix()):
            info = tarfile.TarInfo(f.relative_to(base).as_posix())
            info.size, info.mode, info.mtime = f.stat().st_size, 0o644, 0
            with open(f, "rb") as src:
                t.addfile(info, src)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = _compress(buf.getvalue())
    try:   # 同一内容出同一字节：已是这份就不换（别的进程刚迁移完、正开着它读时，Windows 上换它会报 WinError 32）
        if path.read_bytes() == data:
            return
    except OSError:
        pass
    tmp = path.with_name(f"{path.name}.{os.getpid()}.{threading.get_ident()}.partial")   # 每个进程 / 线程各自的临时名：并发迁移同一款不互相覆盖
    tmp.write_bytes(data)
    _replace_file(tmp, path)


REPLACE_RETRIES = (0.1, 0.2, 0.5, 1, 2, 4, 8)   # 换文件被占（Windows WinError 5 / 32：别的进程开着目标读）时的退避，合计约 16 秒


def _replace_file(tmp, path):
    """os.replace 带 Windows 占用退避（11-16：0.4.4 升 0.5.0 首启，游戏库清单与两单作业同一秒迁移同一款，报 WinError 32 读库失败）"""
    for delay in (*REPLACE_RETRIES, None):
        try:
            return os.replace(tmp, path)
        except PermissionError as e:
            if delay is None or getattr(e, "winerror", None) not in (5, 32):
                Path(tmp).unlink(missing_ok=True)
                raise
            time.sleep(delay)


def _extract(path, dest):
    """归档解到 dest（先解到 dest.partial 再改名，中途断了不留半个）；只认普通文件、相对路径不出界"""
    part = dest.with_name(f"{dest.name}.{os.getpid()}.{threading.get_ident()}.partial")   # 各自的临时目录：并发解同一份不互相删
    shutil.rmtree(part, ignore_errors=True)
    part.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(_decompress(Path(path).read_bytes())), mode="r") as t:
        for m in t.getmembers():
            rel = Path(m.name)
            if not m.isfile() or rel.is_absolute() or ".." in rel.parts:
                continue
            out = part / rel
            out.parent.mkdir(parents=True, exist_ok=True)
            with t.extractfile(m) as src, open(out, "wb") as dst:
                shutil.copyfileobj(src, dst)
    shutil.rmtree(dest, ignore_errors=True)
    os.replace(part, dest)


def exefs_modules(exefs):
    return [m for m in MODULES if exefs is not None and (Path(exefs) / m).is_file()]


def save_exefs(c, gid, exefs):
    """原始程序存进常驻（exefs.tar.zst），解开的一份放缓存；已有的配方按「这些模块的产物能现建」重存一次 → 缓存里的 exefs 目录"""
    exefs = Path(exefs)
    files = [exefs / n for n in os.listdir(exefs) if (exefs / n).is_file() and (n in MODULES or n == "main.npdm")]
    _write(layout.program_store(c, gid, create=True) / EXEFS, exefs, files)
    dest = cache(c, gid) / "exefs"
    if dest.resolve() != exefs.resolve():
        part = dest.with_name("exefs.partial"); shutil.rmtree(part, ignore_errors=True); part.mkdir(parents=True)
        for f in files:
            shutil.copyfile(f, part / f.name)
        shutil.rmtree(dest, ignore_errors=True); os.replace(part, dest)
    kit = cache(c, gid) / "kit"
    if (kit / "main.npdm").is_file():
        save_recipe(c, gid)
    return dest


def exefs_dir(c, gid):
    """解开的原始程序（缓存）；缓存没有、常驻有 → 现解；都没有 → None"""
    d = cache(c, gid) / "exefs"
    if (d / "main").is_file() and (d / "main.npdm").is_file():
        return d
    arc = layout.program_store(c, gid) / EXEFS
    if arc.is_file():
        _extract(arc, d)
        return d
    return None


def recipe_files(kit, modules):
    drop = {f"{m}.{o}" for m in modules for o in OUTPUTS}
    return [p for p in Path(kit).rglob("*") if p.is_file() and not (p.parent == Path(kit) and p.name in drop) and p.suffix != ".log"]


def save_recipe(c, gid, full=False):
    """缓存里的 kit → 常驻配方（recipe.tar.zst）：原始程序在常驻里的模块，改写产物不存（现建）；其余全存。full：整份 kit 都存（现建对不上时，见 adopt）"""
    kit = cache(c, gid) / "kit"
    if not (kit / "main.npdm").is_file():
        return None
    have = layout.program_store(c, gid) / EXEFS
    mods = exefs_modules(exefs_dir(c, gid)) if have.is_file() and not full else []
    _write(layout.program_store(c, gid, create=True) / RECIPE, kit, recipe_files(kit, mods))
    return layout.program_store(c, gid) / RECIPE


def has_kit(c, gid):
    """这款有没有 iPhone 程序件（不现建，便宜，给游戏库清单 / 就绪判断）：缓存 kit 在，或常驻配方在"""
    kit = cache(c, gid) / "kit"
    try:   # 缓存 kit：主程序表非空、有改写产物表（同原先 iphone_ready 的判据，审计 P2-212）
        if (kit / "main.npdm").stat().st_size > 0 and any(kit.glob("*.fixups.tsv")):
            return True
    except OSError:
        pass
    return (layout.program_store(c, gid) / RECIPE).is_file()


def rebuild(c, gid):
    """按常驻配方 + 原始程序现建 kit 到缓存 → kit 目录；没有配方 → None。改写器跑不起来照实报（不静默缺件）"""
    arc = layout.program_store(c, gid) / RECIPE
    if not arc.is_file():
        return None
    import rewrite_refresh as rr
    kit = cache(c, gid) / "kit"
    work = Path(tempfile.mkdtemp(prefix=".kit-", dir=cache(c, gid).parent if cache(c, gid).parent.is_dir() else None))
    try:
        built = work / "kit"
        _extract(arc, built)
        exefs = exefs_dir(c, gid) if (layout.program_store(c, gid) / EXEFS).is_file() else None
        mods = [m for m in exefs_modules(exefs) if not (built / f"{m}.patched.bin").is_file()]   # 配方里已带产物的模块（整份存的老 kit）不重跑
        if mods:
            env = rr.rewrite_env(c, built, exefs, "ios")
            rows = built / "cpatch_rows.tsv"
            if rows.is_file() and rows.stat().st_size:   # 社区补丁 / 金手指要改代码的行（出包与 S 级补进时同一份）
                env["S2A_CPATCH_TSV"] = str(rows)
            rr.rewrite_modules(rr.rewriter_bin(c), env, exefs, built, built / "widen_sites.tsv")
        kit.parent.mkdir(parents=True, exist_ok=True)
        shutil.rmtree(kit, ignore_errors=True)
        os.replace(built, kit)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return kit


def kit_dir(c, gid):
    """iPhone 程序件（缓存）：在就用；缺了按配方现建。没有配方也没有缓存 → 缓存路径（不存在，调用方按「没有」处理）"""
    kit = cache(c, gid) / "kit"
    if (kit / "main.npdm").is_file():
        return kit
    adopt(c, gid)
    if (kit / "main.npdm").is_file():
        return kit
    try:
        return rebuild(c, gid) or kit
    except (OSError, Failure) as e:
        raise Failure(f"按常驻配方现建 {gid} 的 iPhone 程序件失败：{e}", code="job_failed") from e  # 非玩家句


def adopt(c, gid):
    """旧布局搬进来（第一次用到时）：游戏文件夹的 image/ios/kit、original-exefs，或上一版的 .programs/<号>/kit、original-exefs
    → 原始程序进常驻归档 + 缓存，kit 进缓存并存配方；旧位置删掉。没有旧件什么都不做。
    整段持这款的迁移锁（programs-migrate-<号>）：几个进程同时第一次用到同一款（升级首启的游戏库清单 + 后台作业），只有一个在搬，
    其余等它搬完、再看时已经没有旧件。不用 program-<号>：出包交付 / 装机持着它再调到这里，同一把锁不可重入"""
    lock = getattr(c, "lock", None)
    with (lock("programs-migrate-" + gid.upper(), wait=MIGRATE_LOCK_WAIT_S) if lock else contextlib.nullcontext()):
        _adopt(c, gid)


MIGRATE_LOCK_WAIT_S = 600   # 迁移一款：压原始程序 + 按配方现建对拍，大款几十秒；等别的进程搬完


def _adopt(c, gid):
    store = layout.program_store(c, gid)
    old_exefs = [d for d in (store / layout.PROGRAM_EXEFS, layout.path(c, gid, layout.PROGRAM_EXEFS, create=False)) if (d / "main").is_file()]
    old_kits = [d for d in (store / layout.IOS_KIT, layout.image_ios(c, gid, create=False) / layout.IOS_KIT) if (d / "main.npdm").is_file()]
    if old_exefs and not (store / EXEFS).is_file():
        save_exefs(c, gid, old_exefs[0])
    kit = cache(c, gid) / "kit"
    if old_kits and not (store / RECIPE).is_file():
        if not (kit / "main.npdm").is_file():
            kit.parent.mkdir(parents=True, exist_ok=True)
            shutil.rmtree(kit, ignore_errors=True)
            shutil.copytree(old_kits[0], kit)
        # 旧 kit 不一定能按配方现建回同样的字节：老版本改写器出的、或 S 级补进时没同步补丁行表的（11-16 之前的 rewrite_refresh）。
        #   先按配方现建一次逐字节对：对得上才省掉改写产物；对不上整份 kit 进配方（不压，但绝不悄悄换掉玩家的程序），之后刷新 / 重出包时自然变回只存配方
        save_recipe(c, gid)
        if not _rebuilds_same(c, gid, kit):
            save_recipe(c, gid, full=True)
    for d in old_exefs if (store / EXEFS).is_file() else []:
        shutil.rmtree(d, ignore_errors=True)
    for d in old_kits if (store / RECIPE).is_file() else []:
        shutil.rmtree(d, ignore_errors=True)


def _rebuilds_same(c, gid, kit):
    """按刚存的配方现建到临时目录，与 kit 逐文件逐字节比；改写器跑不起来也算对不上"""
    keep = cache(c, gid) / "kit.verify"
    shutil.rmtree(keep, ignore_errors=True)
    os.replace(kit, keep)
    try:
        try:
            built = rebuild(c, gid)
        except (OSError, Failure):
            return False
        if built is None:
            return False
        files = lambda d: {p.relative_to(d).as_posix() for p in Path(d).rglob("*") if p.is_file() and p.suffix != ".log"}
        a, b = files(keep), files(built)
        return a == b and all((keep / f).read_bytes() == (built / f).read_bytes() for f in a)
    finally:
        shutil.rmtree(kit, ignore_errors=True)
        os.replace(keep, kit)


def drop(c, gid):
    """删除游戏：常驻与缓存一起删"""
    for d in (layout.program_store(c, gid), cache(c, gid)):
        shutil.rmtree(d, ignore_errors=True)
