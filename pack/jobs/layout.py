"""游戏库布局（11-09 jhz 拍板「游戏库结构双端统一」，设计见 run/s2arm/cmdr/游戏库结构_双端统一_设计_1109_修订.md）：库里每一样东西的路径只在这里算。

  <库>/games/<英文名>/   一款一个文件夹；程序只认里面 game.json 的游戏号，不认文件夹名（玩家改名、挪动不影响）
      game.json  cover.jpg  custom.json  community.json  input.json  ios-install.json
      image/mac/          Mac 镜像（不含宿主）          saves/  save-backups/  shader-cache/
      build/              出包缓存（原 cache/<号>：两平台共用的解包 + Mac 各产物根）  seen/  save_backup/（iPhone 存档备份）
  <库>/hosts/mac/<宿主摘要前 12 位>/S2ArmGame.app      Mac 宿主，多款共用（只换宿主见 host_update.py）
Windows 与 Mac 同一套（共用后端）。旧布局（按类型分：games/<号>/releases、cache/<号>、saves/<号>…）由 migrate() 一次性同盘改名过来，
.s2arm-layout.json 记已迁完的款，中途被杀下次接着做。
"""
from __future__ import annotations
import json
import os
import re
import shutil
from pathlib import Path

from core import Failure, atomic, contained, read

VERSION = 2
GAME_JSON = "game.json"
NAME_MAX = 48   # Windows 深路径预算：库根 + games\<名> + 镜像 / 出包缓存的深层目录要留在 260 以内（玩家路径见 pack/jobs/winenv.py 长路径检查）
_WIN_RESERVED = {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)), *(f"LPT{i}" for i in range(1, 10))}
_GID = re.compile(r"[0-9A-F]{16}")


def folder_name(english, gid, taken=()):
    """游戏文件夹名：原件 NACP 的英文名清洗成安全 ASCII（字母数字、空格、- _ . ( ) &），最长 NAME_MAX；空 / Windows 保留名 → 游戏号；
    与 taken 里的名字重了（同名不同号，如不同地区版）→ 加「 [号后 4 位]」。比较不分大小写（Windows / 默认 APFS 都不分）"""
    gid = gid.upper()
    name = re.sub(r"[^A-Za-z0-9 \-_.()&]", "", english or "")
    name = re.sub(r" +", " ", name).strip(" .")[:NAME_MAX].strip(" .")
    if not name or name.split(".")[0].upper() in _WIN_RESERVED:
        name = gid
    used = {t.lower() for t in taken}
    if name.lower() in used:
        name = (name[:NAME_MAX - 7].strip(" .") + " [" + gid[-4:] + "]")
        if name.lower() in used:
            name = gid
    return name


def games_root(c):
    return c.library / "games"


def hosts_mac(c):
    return c.library / "hosts" / "mac"


def _index(c):
    """游戏号 → 文件夹（扫 games/*/game.json；每个作业进程扫一次，建 / 迁文件夹时更新）"""
    idx = getattr(c, "_layout_index", None)
    if idx is None:
        idx = {}
        root = games_root(c)
        for d in (sorted(root.iterdir()) if root.is_dir() else []):
            if d.is_symlink() or not d.is_dir():
                continue
            gid = str(read(d / GAME_JSON, {}).get("id", "")).upper()
            if _GID.fullmatch(gid) and gid not in idx:
                idx[gid] = d
        c._layout_index = idx
    return idx


def find_game(c, gid):
    """这款的文件夹；还没有 → None"""
    return _index(c).get(gid.upper())


def game_dir(c, gid, english=None):
    """这款的文件夹，没有就按英文名新建（写 game.json）。english 缺省取 catalog 里这款的名字"""
    gid = gid.upper()
    if not _GID.fullmatch(gid):
        raise Failure("游戏标识无效。", code="game_id")
    d = find_game(c, gid)
    if d is not None:
        return d
    if english is None:
        english = next((g.get("englishName") or g.get("name") for g in read(c.library / "catalog.json", {}).get("games", []) if g.get("id", "").upper() == gid), "")
    root = games_root(c)
    root.mkdir(parents=True, exist_ok=True)
    taken = [p.name for p in root.iterdir()]
    d = contained(c.library, root / folder_name(english, gid, taken))
    d.mkdir()
    atomic(d / GAME_JSON, dict(schema=1, id=gid))
    _index(c)[gid] = d
    return d


def game_info(c, gid):
    d = find_game(c, gid)
    return read(d / GAME_JSON, {}) if d else {}


def update_info(c, gid, **fields):
    d = game_dir(c, gid)
    atomic(d / GAME_JSON, dict(read(d / GAME_JSON, {}), **fields))


def path(c, gid, *parts, create=True):
    """单款文件夹下的路径；create=False 且这款还没有文件夹时给出一个不存在的路径（读的一方按「没有」处理）"""
    d = game_dir(c, gid) if create else (find_game(c, gid) or games_root(c) / (".none-" + gid.upper()))
    return d.joinpath(*parts)


def image_mac(c, gid, create=True):
    return path(c, gid, "image", "mac", create=create)


def build_dir(c, gid, create=True):
    return path(c, gid, "build", create=create)


# ---- 迁移（旧布局 → VERSION 2）----
# 每款：先把 games/<号>/ 整个改名成 games/<英文名>/ 并写 game.json（之后任何时候中断，都能凭 game.json 认出来），再把散在别处的搬进去。
# 只做同盘改名；只删能重建的：Mac 旧的上一版运行版本（releases 里不是现行的那几份）。
MOVES = (("cache/{gid}", "build"), ("saves/{gid}", "saves"), ("save-backups/{gid}", "save-backups"),
         ("runtime-cache/{gid}", "shader-cache"), ("mappings/{gid}.json", "input.json"))


def _move(src, dst):
    if os.path.lexists(src) and not os.path.lexists(dst):
        dst.parent.mkdir(parents=True, exist_ok=True)
        os.replace(src, dst)


def _host_digest(app):
    from core import digest
    exe = app / "Contents/MacOS/s2arm-host"
    return digest(exe)[:12] if exe.is_file() else None


def _split_release(c, gid, d):
    """旧 Mac 运行版本（games/<号>/current → releases/<键>-…，含宿主）拆成 image/mac + hosts/mac/<摘要>；其余旧版本删掉（可重出）"""
    from library import _rm
    link, releases = d / "current", d / "releases"
    image = d / "image" / "mac"
    if os.path.lexists(link) and not image.exists():
        cur = link.resolve()
        if cur.parent == releases.resolve() and cur.is_dir():
            app = cur / "S2ArmGame.app"
            if app.is_dir():
                sha = _host_digest(app)
                if sha:
                    dest = hosts_mac(c) / sha / "S2ArmGame.app"
                    if dest.exists():
                        _rm(c, c.library, app)
                    else:
                        _move(app, dest)
                    info = read(d / GAME_JSON, {})
                    atomic(d / GAME_JSON, dict(info, hostMac=sha))
            m = read(cur / "manifest.json", {})
            if m.get("files"):
                m["files"] = {k: v for k, v in m["files"].items() if not k.startswith("S2ArmGame.app/")}
                atomic(cur / "manifest.json", m)
            _move(cur, image)
    if os.path.lexists(link):
        link.unlink()
    if releases.is_dir():
        _rm(c, c.library, releases)


def migrate(c):
    """旧布局一次性迁到 VERSION 2（调用方持执行锁）；已迁完直接返回。可中断续做"""
    marker = c.library / ".s2arm-layout.json"
    state = read(marker, {})
    if state.get("version") == VERSION:
        return False
    c.begin("整理游戏库结构（一次性，只改名不复制）")
    done = set(state.get("games", []))
    names = {g.get("id", "").upper(): (g.get("englishName") or g.get("name") or "") for g in read(c.library / "catalog.json", {}).get("games", [])}
    old_root = games_root(c)
    legacy = sorted(p.name for p in old_root.iterdir() if _GID.fullmatch(p.name.upper()) and p.is_dir() and not (p / GAME_JSON).is_file()) if old_root.is_dir() else []
    ids = sorted((set(names) | set(legacy) | {g for spec, _ in MOVES for g in _legacy_ids(c, spec)}) - done)
    for gid in ids:
        if not _GID.fullmatch(gid):
            continue
        d = find_game(c, gid)
        if d is None:
            src = old_root / gid
            taken = [p.name for p in old_root.iterdir()] if old_root.is_dir() else []
            name = folder_name(names.get(gid, ""), gid, [t for t in taken if t != gid])
            dest = contained(c.library, old_root / name)
            if src.is_dir() and not dest.exists():
                os.replace(src, dest)
            dest.mkdir(parents=True, exist_ok=True)
            atomic(dest / GAME_JSON, dict(read(dest / GAME_JSON, {}), schema=1, id=gid))
            _index(c)[gid] = d = dest
        for spec, rel in MOVES:
            _move(c.library / spec.format(gid=gid), d / rel)
        _split_release(c, gid, d)
        done.add(gid)
        atomic(marker, dict(version=1, games=sorted(done)))
    for spec, _ in MOVES:   # 搬空的旧类型目录
        top = c.library / spec.split("/")[0]
        if top.is_dir() and not any(top.iterdir()):
            top.rmdir()
    atomic(marker, dict(version=VERSION, games=sorted(done)))
    return True


def _legacy_ids(c, spec):
    top = c.library / spec.split("/")[0]
    if not top.is_dir():
        return []
    return [p.name.removesuffix(".json").upper() for p in top.iterdir() if _GID.fullmatch(p.name.removesuffix(".json").upper())]


def ensure(c):
    """作业开始前：库还是旧布局就拿执行锁迁移（拿不到每 2 秒再试，最多 120 秒：别的作业在跑时它已经迁过了，再看一眼标记）"""
    import time
    import filelock
    if read(c.library / ".s2arm-layout.json", {}).get("version") == VERSION or not (c.library / ".s2arm-library.json").is_file():
        return
    c.require_library()
    t0 = time.time()
    while True:
        with (c.library / ".execution.lock").open("a") as f:
            try:
                filelock.try_lock(f)
            except BlockingIOError:
                if time.time() - t0 > 120:
                    raise Failure("游戏库正在被别的任务使用，结构整理没能开始，请稍后重试。") from None
            else:
                try:
                    migrate(c)
                finally:
                    filelock.unlock(f)
                return
        if read(c.library / ".s2arm-layout.json", {}).get("version") == VERSION:
            return
        time.sleep(2)
