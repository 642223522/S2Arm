"""一款一份资源（0.6.0，体系文档 A 项）：Mac 运行版本与 iPhone 资源包共用同一个 game.img。

iPhone 资源包 image/ios/.pack/game.img 是真身；Mac 运行版本 image/mac/game.img 是它的硬链接（同一个文件），romfs.std 删掉——省一整份 RomFS。
用硬链接不用「引用文件」：iPhone 换包是新包改名过去、删 iPhone 版是删 .pack，Mac 那个名字仍连着原来那份数据，Mac 运行版本和它的程序始终配套，
换包 / 删包的各处都不用知道这件事。建不了硬链接的盘（exFAT）、两边不在同一块盘、RomFS 不是同一份 → 原样不动（只是多占一份，不坏）。

合并（dedupe）只在两边都有时做：只有 Mac 的款保留 romfs.std（转成 game.img 不省空间，之后出 iPhone 包时 iPhone 那份照样新写）。
先逐字节核 game.img 的 RomFS 段与 romfs.std 相同，再建链、改清单、删 romfs.std；任何一步之前断了，下次从头再核（建链之后断了，下次认出链已在、直接接着做）。
旧库（11-16 前）的 Mac 运行版本是 romfs/ 散文件目录：逐文件核与 game.img 的 RomFS 段同一份（文件集合相同、每个文件逐字节相同）才合并，
删 romfs/ 与它的索引 romfs.s2aidx；有一个文件不同（老的就地改界面布局）就原样不动。
按款加锁（拿不到就跳过：别的进程正在做）。挂通用壳开关（program_pack.enabled）：开关关着一个字节不动。
谁调：出完 iPhone 包（ipa 换包之后）、出完 Mac 版、Mac 起局后游戏跑满 MIGRATE_AFTER_S 秒在后台做（玩家不等；游戏退出就停，下次再做）。"""
from __future__ import annotations

import os
import threading
from pathlib import Path

import layout
from core import Failure, atomic, read

CHUNK = 1 << 22
MIGRATE_AFTER_S = 120   # Mac 起局后过了加载期再在后台核（核要整份读两遍 RomFS，不和游戏加载抢盘）


def _img_mod(c):
    import sgrade_bf
    return sgrade_bf._img(c)


def _same_range(a_path, a_off, b_path, b_off, n, stop):
    """a_path 从 a_off 起、b_path 从 b_off 起的 n 字节逐字节相同 → True；stop() 为真时中途放弃 → None"""
    with open(a_path, "rb") as a, open(b_path, "rb") as b:
        a.seek(a_off); b.seek(b_off)
        left = n
        while left:
            if stop():
                return None
            k = min(CHUNK, left)
            x, y = a.read(k), b.read(k)
            if len(x) != k or x != y:
                return False
            left -= k
        return True


def dedupe(c, gid, stop=None, keep_dir=False):
    """→ (结果, 说明)。结果：linked = 这次合并了；done = 早已合并；skip = 不合并（说明写原因）；stopped = 中途放弃（下次再做）。
    keep_dir：游戏正在跑（Mac 起局后后台做）——旧形态 romfs/ 散文件是游戏现读的，只核、建链，不删（游戏退出后 during 收尾删）"""
    import program_pack
    if not program_pack.enabled(c):
        return "skip", "通用壳开关关着"  # 非玩家句
    stop = stop or (lambda: False)
    mac = layout.image_mac(c, gid, create=False)
    std, link, img = mac / "romfs.std", mac / "game.img", layout.ios_pack(c, gid) / "game.img"
    if not img.is_file() or img.is_symlink():
        return "skip", "没有 iPhone 资源包的 game.img"  # 非玩家句
    if link.exists() and not std.exists() and not (mac / "romfs").is_dir() and os.path.samefile(link, img):
        return "done", "已合并"  # 非玩家句
    rdir = mac / "romfs"
    if not std.is_file() and not (link.is_file() and not link.is_symlink()) and not rdir.is_dir():
        return "skip", "Mac 运行版本没有 romfs.std / romfs/"  # 非玩家句
    lock = getattr(c, "lock", None)
    try:
        with (lock("onerom-" + gid.upper(), wait=0) if lock else _nolock()):
            return _dedupe(c, gid, mac, std, link, img, stop, keep_dir)
    except Failure as e:
        if e.code == "library_busy":
            return "skip", "别的任务正在合并这款"  # 非玩家句
        raise


class _nolock:
    def __enter__(self): return self
    def __exit__(self, *a): return False


def _dedupe(c, gid, mac, std, link, img, stop, keep_dir=False):
    if link.exists() and os.path.samefile(link, img):
        return _finish(c, gid, mac, std, link, keep_dir)   # 上次建好链之后断了：接着改清单、删 romfs.std / romfs/
    if not link.exists() and not std.exists() and (mac / "romfs").is_dir():
        return _dedupe_dir(c, gid, mac, std, link, img, stop, keep_dir)
    # 两种来源：Mac 还是 romfs.std（整个文件就是 RomFS）；或 Mac 已有自己的 game.img（iPhone 重出过包，Mac 那个名字还连着旧数据）
    src = link if link.exists() else std
    if img.stat().st_dev != src.stat().st_dev:
        return "skip", "两边不在同一块盘，建不了硬链接"  # 非玩家句
    m = _img_mod(c)
    h = m.header(str(img))
    off, n = h["romfs"]
    s_off, s_n = (m.header(str(src))["romfs"] if src == link else (0, src.stat().st_size))
    if h["total"] != img.stat().st_size or n != s_n:
        return "skip", f"RomFS 段长 {n} 与 Mac 那份 {s_n} 不同（不是同一份资源）"  # 非玩家句
    same = _same_range(img, off, src, s_off, n, stop)
    if same is None:
        return "stopped", "核到一半游戏退出 / 被取消，下次再做"  # 非玩家句
    if not same:
        return "skip", "RomFS 段与 romfs.std 内容不同（不是同一份资源）"  # 非玩家句
    part = mac / "game.img.part"
    try:
        part.unlink()
    except FileNotFoundError:
        pass
    try:
        os.link(img, part)
    except OSError as e:
        return "skip", f"建不了硬链接（{e.strerror}，多半是 exFAT 这类盘）"  # 非玩家句
    os.replace(part, link)
    return _finish(c, gid, mac, std, link)


def _dedupe_dir(c, gid, mac, std, link, img, stop, keep_dir):
    """旧形态：Mac 运行版本是 romfs/ 散文件。文件集合与每个文件的字节都和 game.img 的 RomFS 段相同才建链"""
    rdir = mac / "romfs"
    if img.stat().st_dev != rdir.stat().st_dev:
        return "skip", "两边不在同一块盘，建不了硬链接"  # 非玩家句
    rom = _romfs_img(c).RomfsImage.in_img(str(img))
    want = {rel: span for rel, span in ((r, rom.span(r)) for r in rom.files())}
    import importlib.util
    from build import romfs_list_path
    spec = importlib.util.spec_from_file_location("_s2arm_onerom_romfs_list", romfs_list_path())
    rl = importlib.util.module_from_spec(spec); spec.loader.exec_module(rl)
    tree = rl.scan(str(rdir))   # RomFS 目录盘点只走 romfs_list（tools/romfs_walk_lint.py）
    if tree.errors or any(e.lstat_error is not None for e in tree.entries):
        return "skip", "romfs/ 盘点出错，下次再核"  # 非玩家句
    have = {e.rel: Path(e.path) for e in tree.entries if e.file and not e.symlink}
    if set(want) != set(have):
        return "skip", f"romfs/ 与 iPhone 资源包的文件集合不同（多 {len(set(have) - set(want))}、少 {len(set(want) - set(have))}）"  # 非玩家句
    for rel, (off, n) in want.items():
        if have[rel].stat().st_size != n:
            return "skip", f"romfs/{rel} 与 iPhone 资源包那份长度不同（多半是就地改过的界面布局），不合并"  # 非玩家句
        same = _same_range(img, off, have[rel], 0, n, stop)
        if same is None:
            return "stopped", "核到一半游戏退出 / 被取消，下次再做"  # 非玩家句
        if not same:
            return "skip", f"romfs/{rel} 与 iPhone 资源包那份内容不同（多半是就地改过的界面布局），不合并"  # 非玩家句
    part = mac / "game.img.part"
    try:
        part.unlink()
    except FileNotFoundError:
        pass
    try:
        os.link(img, part)
    except OSError as e:
        return "skip", f"建不了硬链接（{e.strerror}，多半是 exFAT 这类盘）"  # 非玩家句
    os.replace(part, link)
    return _finish(c, gid, mac, std, link, keep_dir)


def _romfs_img(c):
    import importlib.util
    spec = importlib.util.spec_from_file_location("s2a_pack_romfs_img", Path(c.engine) / "pack/romfs_img.py")
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


def _finish(c, gid, mac, std, link, keep_dir=False):
    manifest = read(mac / "manifest.json", {})
    files = manifest.get("files")
    if isinstance(files, dict):
        files = {k: v for k, v in files.items() if k not in ("romfs.std", "romfs.s2aidx") and not k.startswith("romfs/")}
        files["game.img"] = [link.stat().st_size, ""]   # 同 build.snapshot：只记大小
        atomic(mac / "manifest.json", dict(manifest, files=files))
    rdir = mac / "romfs"
    if rdir.is_dir() and keep_dir:
        return "linked", "Mac 运行版本已链上 iPhone 资源包那份 game.img；romfs/ 散文件游戏正在读，等游戏退出再删"  # 非玩家句
    if rdir.is_dir():   # 旧形态：改完清单再删散文件（删到一半断了，下次认出链已在，接着删）
        rom = _romfs_img(c).RomfsImage.in_img(str(link))   # 散文件与它逐文件相同（建链前核过），腾出的就是这些文件的大小
        saved = sum(rom.span(r)[1] for r in rom.files())
        from library import _rmtree
        _rmtree(rdir)
        try:
            (mac / "romfs.s2aidx").unlink()
        except FileNotFoundError:
            pass
        return "linked", f"Mac 运行版本的 romfs/ 散文件改用 iPhone 资源包那份 game.img，腾出 {saved / 1e9:.2f} GB"  # 非玩家句
    if not std.exists():
        return "linked", "Mac 运行版本换链到 iPhone 新出的那份 game.img（RomFS 相同），旧那份腾出"  # 非玩家句
    saved = std.stat().st_size
    std.unlink()
    try:
        (mac / "romfs.s2aidx").unlink()   # romfs.std 的索引：改用 game.img 后没人读了（清单里上面已去掉）
    except FileNotFoundError:
        pass
    return "linked", f"Mac 运行版本改用 iPhone 资源包那份 game.img，腾出 {saved / 1e9:.2f} GB"  # 非玩家句


def note(c, gid, result):
    """记进本任务的决定日志（不打扰玩家）"""
    import install
    install.note(c, f"一款一份资源（{gid}）：{result[0]} {result[1]}")  # 非玩家句


def background(c, gid, delay=MIGRATE_AFTER_S):
    """Mac 起局时调：返回 stop()。游戏跑满 delay 秒后在后台线程里合并；stop() 让它停下并等它收尾（游戏退出时调）"""
    import program_pack
    halt = threading.Event()
    if not program_pack.enabled(c):
        return lambda: None
    def run():
        if halt.wait(delay):
            return
        try:
            note(c, gid, dedupe(c, gid, stop=halt.is_set, keep_dir=True))
        except Exception as e:   # 后台合并出什么错都不影响这局游戏：记下原因，原样不动
            note(c, gid, ("skip", f"出错：{e!r}"))  # 非玩家句
    t = threading.Thread(target=run, name="onerom-" + gid, daemon=True)
    t.start()
    def stop():
        halt.set()
        t.join()
    return stop


def during(c, gid, run):
    """Mac 起局：run() 是起游戏并等它退出；期间按 background 在后台合并，游戏退出（含出错 / 取消）一定停下并等它收尾"""
    stop = background(c, gid)
    try:
        return run()
    finally:
        stop()
        _finish_after_exit(c, gid)


def _finish_after_exit(c, gid):
    """游戏退出后：后台已核完、建好链，只剩旧形态 romfs/ 散文件没删 → 现在删（没建链就什么都不做，不在这里现核）"""
    import program_pack
    if not program_pack.enabled(c):
        return
    mac = layout.image_mac(c, gid, create=False)
    link, img = mac / "game.img", layout.ios_pack(c, gid) / "game.img"
    try:
        if (mac / "romfs").is_dir() and link.exists() and img.exists() and os.path.samefile(link, img):
            note(c, gid, dedupe(c, gid))
    except Exception as e:   # 收尾删不掉不影响这局：下次再做
        note(c, gid, ("skip", f"收尾出错：{e!r}"))  # 非玩家句
