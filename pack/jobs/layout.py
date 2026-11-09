"""游戏库布局（11-09 维护者拍板「游戏库结构双端统一」，v3 起支持多个存放位置）：库里每一样东西的路径只在这里算。

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


LOCATION_JSON = ".s2arm-location.json"


def games_root(c, root=None):
    return Path(root or c.library) / "games"


def hosts_mac(c):
    return c.library / "hosts" / "mac"   # 公共件只在默认位置（游戏库结构 v3）


# ---- 存放位置 + 索引表（游戏库结构 v3：像 Steam 的库文件夹）----
# 默认位置 = 请求里的 library（c.library），公共件（hosts/、catalog.json、iPhone 产物、全局执行锁）都在这里；玩家可以再加别的位置（别的分区、移动硬盘）。
# 索引表 <私有目录>/library-index.json：{schema, locations: [{id, path}], games: {游戏号: {location, folder}}, last}。它只是缓存，
# 真相是每个位置下 games/*/game.json；索引丢了按位置扫描重建。

def _index_path(c):
    return (getattr(c, "private", None) or c.library) / "library-index.json"


def load_index(c):
    idx = getattr(c, "_layout_idx", None)
    if idx is None:
        idx = read(_index_path(c), {}) or {}
        idx.setdefault("schema", 1); idx.setdefault("locations", []); idx.setdefault("games", {})
        c._layout_idx = idx
    want = default_id(c)   # 默认位置总在表里、排第一；它的号以库里的标识文件为准（迁移写标识后，旧的 "default" 引用跟着改）
    old = next((l for l in idx["locations"] if l.get("path") == str(c.library)), None)
    if old is None or old.get("id") != want:
        if old is not None:
            idx["locations"].remove(old)
            for e in idx["games"].values():
                if e.get("location") == old.get("id"):
                    e["location"] = want
        idx["locations"].insert(0, dict(id=want, path=str(c.library)))
    return idx


def default_id(c):
    return location_id(c.library) or "default"


def save_index(c):
    atomic(_index_path(c), load_index(c))


def location_id(root):
    return read(Path(root) / LOCATION_JSON, {}).get("id")


def register_location(c, root):
    """把一个文件夹登记成存放位置（写 .s2arm-location.json，进索引表）→ 位置号"""
    import uuid
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    lid = location_id(root)
    if not lid:
        lid = uuid.uuid4().hex
        atomic(root / LOCATION_JSON, dict(schema=1, id=lid, version=VERSION))
    idx = load_index(c)
    idx["locations"] = [l for l in idx["locations"] if l.get("path") != str(root) and l.get("id") != lid] + [dict(id=lid, path=str(root))]
    save_index(c)
    return lid


def locations(c):
    """[(位置号, 路径, 在不在)]，默认位置排第一"""
    return [(l["id"], Path(l["path"]), Path(l["path"]).is_dir()) for l in load_index(c)["locations"]]


def _location_path(c, lid):
    return next((Path(l["path"]) for l in load_index(c)["locations"] if l.get("id") == lid), None)


def _scan(root):
    out = {}
    g = games_root(None, root)
    for d in (sorted(g.iterdir()) if g.is_dir() else []):
        if d.is_symlink() or not d.is_dir():
            continue
        gid = str(read(d / GAME_JSON, {}).get("id", "")).upper()
        if _GID.fullmatch(gid) and gid not in out:
            out[gid] = d
    return out


def _remember(c, gid, d):
    idx = load_index(c)
    root = d.parent.parent
    lid = default_id(c) if root == c.library else (location_id(root) or register_location(c, root))
    if idx["games"].get(gid) != dict(location=lid, folder=d.name):
        idx["games"][gid] = dict(location=lid, folder=d.name)
        save_index(c)


def state(c, gid):
    """这款在哪 → ("ok", 文件夹) | ("offline", 位置路径)（位置没连上，如移动硬盘没插）| ("missing", 位置路径)（位置在、文件夹没了）| ("none", None)（还没建）。
    索引对不上时（玩家改了文件夹名）扫一遍这个位置再认"""
    gid = gid.upper()
    entry = load_index(c)["games"].get(gid)
    if entry:
        root = _location_path(c, entry.get("location"))
        if root is None:
            return "none", None
        if not root.is_dir():
            return "offline", root
        d = games_root(c, root) / entry.get("folder", "")
        if entry.get("folder") and str(read(d / GAME_JSON, {}).get("id", "")).upper() == gid:
            return "ok", d
        found = _scan(root).get(gid)
        if found:
            _remember(c, gid, found)
            return "ok", found
        return "missing", root
    for _, root, ok in locations(c):   # 索引里没有：各位置扫一遍（旧库刚迁完 / 索引丢了）
        found = _scan(root).get(gid) if ok else None
        if found:
            _remember(c, gid, found)
            return "ok", found
    return "none", None


def find_game(c, gid):
    """这款的文件夹；还没有、位置没连上或找不到 → None"""
    st, d = state(c, gid)
    return d if st == "ok" else None


def require_in_location(c, p):
    """路径必须在某个已登记存放位置的 games/ 下（运行镜像校验用，挡住指到库外的路径）"""
    p = Path(p).resolve()
    for _, root, ok in locations(c):
        if ok and p.is_relative_to(games_root(c, root).resolve()):
            return p
    raise Failure("运行文件不在任何存放位置里。", code="runtime_invalid")


def root_of(c, gid):
    """这款所在存放位置的根（托管路径校验、同盘临时目录用）；还没有就是默认位置"""
    d = find_game(c, gid)
    return d.parent.parent if d else c.library


def game_dir(c, gid, english=None, location=None):
    """这款的文件夹，没有就新建（写 game.json）：建在 location（路径），缺省上次用的位置，再缺省默认位置。english 缺省取 catalog 里这款的名字"""
    gid = gid.upper()
    if not _GID.fullmatch(gid):
        raise Failure("游戏标识无效。", code="job_failed")
    st, d = state(c, gid)
    if st == "ok":
        return d
    if st == "offline":
        raise Failure(f"这款游戏所在的存放位置没连上（{d}）：插上那块盘再试。", code="job_failed")
    if english is None:
        english = next((g.get("englishName") or g.get("name") for g in read(c.library / "catalog.json", {}).get("games", []) if g.get("id", "").upper() == gid), "")
    idx = load_index(c)
    if location:   # 玩家指定的位置：没有就建
        root = Path(location)
    else:          # 上次用的位置；没连上就退回默认位置
        root = _location_path(c, idx.get("last")) or c.library
        if not root.is_dir():
            root = c.library
    if root != c.library:
        register_location(c, root)
    g = games_root(c, root)
    g.mkdir(parents=True, exist_ok=True)
    taken = [p.name for p in g.iterdir()]
    d = g / folder_name(english, gid, taken)   # 返回原样路径（不解析软链）：调用方按位置根前缀比对（library._rm）
    contained(root, d)
    d.mkdir()
    atomic(d / GAME_JSON, dict(schema=1, id=gid))
    _remember(c, gid, d)
    return d


def use_location(c, root):
    """记下「上次用的位置」（出包页新游戏缺省选它）"""
    lid = default_id(c) if Path(root) == c.library else (location_id(root) or register_location(c, root))
    idx = load_index(c)
    idx["last"] = lid
    save_index(c)


def move_game(c, gid, dest_root, progress=None):
    """把这款整个文件夹挪到另一个存放位置：同一卷直接改名；跨卷先拷到 <目标>/games/<名>.partial，逐文件核对大小与摘要，再换名、删旧的。存档跟着走"""
    from core import digest
    src = find_game(c, gid)
    if src is None:
        raise Failure("找不到这款游戏的文件夹，没法移动。", code="job_failed")
    dest_root = Path(dest_root)
    if src.parent.parent == dest_root:
        return src
    dest = _move_folder(c, gid, src, dest_root)
    _remember(c, gid, dest)
    return dest


def _move_folder(c, gid, src, dest_root):
    """把一个游戏文件夹搬进 <dest_root>/games/：同一卷改名；跨卷拷到 .partial（链接拷链接本身，library.copy_tree_links）、
    核对（存档逐字节、其余文件数与大小，同整库搬家 library._verify_copy）再换名、删旧的，最后把指向旧位置的链接改指新位置"""
    from library import _retarget_links, _verify_copy, copy_tree_links
    if dest_root != c.library:
        register_location(c, dest_root)
    g = games_root(c, dest_root); g.mkdir(parents=True, exist_ok=True)
    dest = g / folder_name(read(src / GAME_JSON, {}).get("name") or src.name, gid, [p.name for p in g.iterdir()]) if (g / src.name).exists() else g / src.name
    if _same_volume(src, g):
        os.replace(src, dest)
    else:
        temporary = dest.with_name(dest.name + ".partial")
        shutil.rmtree(temporary, ignore_errors=True)
        try:
            copy_tree_links(src, temporary)
            _verify_copy(src, temporary, strict=False)
            for sub in ("saves", "save-backups"):
                if (src / sub).is_dir():
                    _verify_copy(src / sub, temporary / sub, strict=True)
        except Failure:
            shutil.rmtree(temporary, ignore_errors=True)
            raise Failure("拷到新位置后核对不一致，没有移动（原位置的文件都还在）。", code="job_failed")
        os.replace(temporary, dest)
        shutil.rmtree(src)
    _retarget_links(dest, src, dest)
    return dest


def _same_volume(a, b):
    return os.stat(a).st_dev == os.stat(b).st_dev


def relink(c, gid, folder):
    """「重新指定文件夹」：选到的文件夹 game.json 游戏号对得上才接受。它在某个存放位置的 games/ 里就原地认；
    在别处（玩家挪到了桌面等）就搬回这款原来的存放位置（没连上就搬到默认位置），玩家不用懂目录结构"""
    folder, gid = Path(folder), gid.upper()
    if str(read(folder / GAME_JSON, {}).get("id", "")).upper() != gid:
        raise Failure("选的文件夹不是这款游戏（里面的 game.json 游戏号对不上）。", code="job_failed")
    if folder.parent.name != "games":
        entry = load_index(c)["games"].get(gid) or {}
        home = _location_path(c, entry.get("location"))
        folder = _move_folder(c, gid, folder, home if home and home.is_dir() else c.library)
    _remember(c, gid, folder)
    return folder


def forget(c, gid):
    """「从游戏库移除」：只从索引去掉（文件不动）"""
    idx = load_index(c)
    if idx["games"].pop(gid.upper(), None) is not None:
        save_index(c)


def game_info(c, gid):
    d = find_game(c, gid)
    return read(d / GAME_JSON, {}) if d else {}


def update_info(c, gid, **fields):
    d = game_dir(c, gid)
    atomic(d / GAME_JSON, dict(read(d / GAME_JSON, {}), **fields))


def launch_json(c, gid, create=True):
    """启动设置（新功能线）：每款文件夹里的 launch.json"""
    return path(c, gid, "launch.json", create=create)


def job_tmp(c, gid, task):
    """作业临时目录 <这款所在位置>/temp/<任务号>（与游戏数据同卷，改名快；出包修复线约定的 S2A_JOB_TMP）"""
    return root_of(c, gid) / "temp" / task


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


_NACP_GLOBS = ("games/{gid}/current/ctl/control.nacp", "games/{gid}/current/exefs/control.nacp", "iPhone/{gid}/*资源包/ctl/control.nacp",
               "iPhone/{gid}/roots/*/ctl/control.nacp", "iPhone/{gid}/container-kit/ctl/control.nacp", "cache/{gid}/*/roots/*/ctl/control.nacp")


def _english_from_disk(c, gid):
    """旧清单只有中文名时，到这款已有的产物里找 control.nacp 读英文名（美式 → 英式英语），玩家在文件夹里认得出；找不到返回空串"""
    try:
        from library import engine_tool
        dump = engine_tool(c, "ns2_dump")
    except Exception:   # noqa: BLE001 —— 引擎工具载不进来就退回游戏号命名
        return ""
    for pattern in _NACP_GLOBS:
        for p in sorted(c.library.glob(pattern.format(gid=gid))):
            try:
                n = p.read_bytes()
            except OSError:
                continue
            if len(n) == 0x4000:
                name = dump.nacp_title(n, 0) or dump.nacp_title(n, 1)
                if name and re.sub(r"[^A-Za-z0-9]", "", name):
                    return name
    return ""


def _ascii_name(name):
    return bool(re.sub(r"[^A-Za-z0-9]", "", name or ""))


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
            english = names.get(gid, "")
            if not _ascii_name(english):
                english = _english_from_disk(c, gid) or english
            name = folder_name(english, gid, [t for t in taken if t != gid])
            dest = old_root / name
            contained(c.library, dest)
            if src.is_dir() and not dest.exists():
                os.replace(src, dest)
            dest.mkdir(parents=True, exist_ok=True)
            atomic(dest / GAME_JSON, dict(read(dest / GAME_JSON, {}), schema=1, id=gid))
            _remember(c, gid, dest); d = dest
        for spec, rel in MOVES:
            _move(c.library / spec.format(gid=gid), d / rel)
        _split_release(c, gid, d)
        done.add(gid)
        atomic(marker, dict(version=1, games=sorted(done)))
    for spec, _ in MOVES:   # 搬空的旧类型目录
        top = c.library / spec.split("/")[0]
        if top.is_dir() and not any(top.iterdir()):
            top.rmdir()
    if not location_id(c.library):   # 旧库原地变成第一个存放位置（游戏库结构 v3）
        import uuid
        atomic(c.library / LOCATION_JSON, dict(schema=1, id=uuid.uuid4().hex, version=VERSION))
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
