#!/usr/bin/env python3
"""RomFS 清单：仓库里唯一遍历 RomFS 目录的地方（11-03 维护者根修；tools/romfs_walk_lint.py 守住，别处出现 RomFS 目录遍历即红）。

起因：一键出包里 6–8 个步骤各自从头遍历 RomFS、逐个打开文件读头（火纹 Switch 2 版 27.4 万个文件：配置推导单次 337 秒、
GLSLC 判「要不要」82 秒、能力清单 326 秒）。现在：
  - 目录盘点（scandir + lstat，只取文件信息，不打开文件）只有这里一份实现：scan() / walk() / listdir()；
  - 文件头（前 32 字节）只读一次：heads() 按「内容身份」把读头结果落盘成清单，同一份 RomFS 的各版本根、各阶段、各进程按身份命中就不再读盘。

清单（接口见 graphics/nvn/tools/README.profile.md「RomFS 清单」）：
  位置：<清单目录>/<标签>-<身份>.json。清单目录 = 环境变量 S2A_ROMFS_WALK（给了就用；off = 不落盘），否则 <产物根的上一级>/.romfs-walk
        （roots.sh 版本根 → <S2A_ROOTS>/.romfs-walk，各版本、各阶段共用）；标签 = 产物根目录名 @ 之前（同一款各版本共用一个前缀，只留最近两份）。
  身份：全部条目按相对路径（/ 分隔）排序，每条「相对路径 \\0 类型 \\0 大小:修改时间纳秒（文件才带）」喂 sha256（前缀 FORMAT），取前 32 位。
        不含 inode / ctime / 目录时间：clonefile 克隆的版本根身份不变；阶段改了 RomFS 文件 → 大小或修改时间变 → 身份变 → 重读。
        同 make / rsync 快速比对的假设：内容变了修改时间必变。盘点有任何错误（目录打不开、lstat 失败）→ 没有身份，不读也不写清单。
  格式：UTF-8 JSON（ensure_ascii）{"format": FORMAT, "identity": 身份, "head": 32, "entries": [[相对路径, 类型位, 大小, 修改时间纳秒, 头十六进制|null, 读错误|null], …]}
        类型位：1 = 软链、2 = 目录（不跟随软链）、4 = 普通文件（跟随软链）、8 = 目录（跟随软链，os.walk 的分法）；修改时间取 lstat；
        大小：读到头的普通文件取打开后的大小（跟随软链），其余取 lstat；
        头 / 读错误只给类型位含 4 的条目：头 = 打开（跟随软链）读到的前 32 字节；读错误 = [errno, strerror, filename]。
        读：格式、身份、条目集合与类型位全对上才用，否则当没有（重读并重写）；写：临时文件 + os.replace 原子替换；写不了不报错（只是不提速）。
  不进任何键：读清单与现读逐字节相同（tests/romfs_list_test.py 钉住）；清单在仓库外、产物根外，出包读入记录（tools/stage_deps.py）不收。

walk() 与 os.walk(top)（topdown、不跟随软链目录、onerror 同义）逐项相同：每层（目录路径, 子目录名, 其余名）同 scandir 顺序，调用方原地改子目录名单照样生效。
与 os.walk 的差别只有一条：盘点在开始迭代时一次做完（os.walk 边走边盘点），迭代途中 RomFS 被改动看不到——出包期 RomFS 只在阶段的工作副本里改，读的一方不与写的一方并发。
每次调用都现盘点（不跨调用缓存）：同一进程里先后两次盘点照样能看出中间的改动（resource_input_key.py 前后两次盘点比对靠这一点）。
跨平台：只用 os.scandir / os.replace / os.path.join，相对路径一律 /；Windows 照用。
镜像（11-16 维护者：出包 RomFS 不落散文件）：目录 <top> 不在、旁边有 <top>.std（标准 RomFS，pack/romfs_img.py 读；不叫 .img：老资源包形态的 romfs.img 是拼接件、不是标准 RomFS，旁边也没有 romfs/）→ 盘点改从镜像建，
  条目 / 大小 / 读头 / walk / listdir / 命令行 has-ext、sizes 与读同内容的目录相同（单测对拍）；目录在就照旧读目录，镜像不看。
  镜像里的子目录（<top>/Layout，目录不在）照样能 scan / walk / listdir：找最近一层有 .std 的上级，只盘点那棵子树。
  镜像里的条目：文件 = 普通文件、目录 = 实目录（没有软链）；空目录不在镜像里；大小取镜像记的长度，修改时间一律取镜像文件的（身份随镜像换而换）。
  e.path 是「目录还在的话」它该在的路径（不存在），要读内容用 e.open()（镜像 / 目录都行）；files0 给的是散文件路径，镜像下没有，报红退 1。
  按路径读（跨进程传路径、交给按路径读的格式库）：open_file / read_file / file_size / is_file / is_dir / exists / map_file 是 open / os.path.* / mmap 的替身，
  路径在盘上就是原函数，不在就从它所在的镜像读（见 open_file 上方注释）。
用法（给 shell 阶段）：romfs_list.py has-ext <目录> <后缀>…   任一条目名（不分大小写）以其中一个后缀结尾 → 退 0，否则退 1（同 find -iname '*<后缀>' -print -quit）
                      romfs_list.py sizes <目录> <输出>       普通文件（lstat）每个一行「字节数\\t相对路径」，给 RomFS 索引（services/romfs_index --list，免得它再枚举、逐个打开）
                      romfs_list.py files0 <目录>            普通文件（lstat，不跟随软链；同 find <目录> -type f）每个一行「<目录>/<相对路径>\\0」，scandir 顺序；有读不开的目录退 1（同 find）
"""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

FORMAT = "s2arm-romfs-walk-v2"
# 读头字节数：profile_guess 魔数（≤ 8）、GLSLC 判 NRO（+0x10..0x14）、SPIR-V 魔数（4）、zstd 字典号帧头（18）都在内
HEAD = 32
# 同标签只留最近两份（产物根只留现行 + 上一版）
KEEP = 2
SYMLINK, DIR, FILE, WALKDIR = 1, 2, 4, 8
_AUTO = object()


class Entry:
    """一个条目：rel = 相对路径（/ 分隔）；name；path = 盘点时的完整路径（os.path.join 拼）；kind = 类型位；
    lstat = 本次盘点的 os.lstat 结果（失败为 None，失败原因在 lstat_error）；size / head / error 只在 heads() 之后、只给普通文件"""
    __slots__ = ("rel", "name", "path", "kind", "lstat", "lstat_error", "size", "head", "error", "image", "image_rel")

    def __init__(self, rel, name, path, kind, st, st_error, image=None, image_rel=None):
        self.rel, self.name, self.path, self.kind, self.lstat, self.lstat_error = rel, name, path, kind, st, st_error
        self.size = self.head = self.error = None
        # 从镜像盘点时 = pack/romfs_img.RomfsImage（内容从镜像读），目录盘点为 None；image_rel = 在镜像里的相对路径（盘点镜像里的子目录时 ≠ rel）
        self.image, self.image_rel = image, image_rel if image_rel is not None else rel

    def open(self):
        """只读打开这个文件（二进制）：镜像盘点从镜像读，目录盘点 open(path)"""
        return self.image.open(self.image_rel) if self.image is not None else open(self.path, "rb")

    symlink = property(lambda self: bool(self.kind & SYMLINK))
    # 跟随软链后是普通文件（Path.is_file / DirEntry.is_file 的分法）
    file = property(lambda self: bool(self.kind & FILE))
    # 跟随软链后是目录（os.walk 归进子目录名单的分法）
    walkdir = property(lambda self: bool(self.kind & WALKDIR))
    # 不跟随软链的目录（会进去盘点）
    realdir = property(lambda self: bool(self.kind & DIR))

    def read(self):
        """(大小, 前 32 字节)；读失败的错误在用到时才抛（与原先「哪一项检查先碰到就由哪一项报」同序）"""
        if self.error is not None:
            raise self.error
        return self.size, self.head


class Tree:
    """一次盘点的结果：top = 调用方给的目录（原样，拼路径同 os.walk）；entries = 全部条目（盘点顺序）；
    children = {目录相对路径（根为 ""）: [该目录下的条目，scandir 顺序]}；errors = {目录相对路径: 打开该目录的 OSError}"""

    def __init__(self, top):
        self.top = os.fspath(top)
        self.entries, self.children, self.errors = [], {}, {}
        self.identity = None
        # 读头之后为 True
        self.complete = False
        # 从镜像盘点时 = RomfsImage
        self.image = None

    def files(self):
        return [e for e in self.entries if e.file]

    def walk(self, onerror=None):
        """同 os.walk(self.top)（topdown=True, followlinks=False）"""
        stack = [(self.top, "")]
        while stack:
            top, rel = stack.pop()
            if rel in self.errors:
                if onerror is not None:
                    onerror(self.errors[rel])
                continue
            kids = self.children.get(rel, [])
            dirs = [e.name for e in kids if e.walkdir]
            nondirs = [e.name for e in kids if not e.walkdir]
            yield top, dirs, nondirs
            byname = {e.name: e for e in kids}
            prefix = rel + "/" if rel else ""
            # 调用方可能原地改过 dirs（排序 / 剪枝）：按改后的名单进，软链目录不进（同 os.walk 的 islink 判）
            for d in reversed(dirs):
                e = byname.get(d)
                if e is not None and not e.symlink:
                    stack.append((os.path.join(top, d), prefix + d))


def image_of(top):
    """<top> 目录不在、<top>.std 是文件 → 镜像路径；否则 None（目录在就读目录）"""
    top = os.fspath(top)
    if os.path.isdir(top):
        return None
    img = top.rstrip("/" + os.sep) + ".std"
    return img if os.path.isfile(img) else None


_IMAGES = {}


def _romfs_image(path):
    """pack/romfs_img.RomfsImage(path)：随 Jobs 拷出去时与本文件同目录，仓库里在 pack/。
    同一进程按（镜像路径、inode、大小、修改时间纳秒）只解析一次元数据（按路径读的 open_file 等逐个文件调，王国之泪 30 万条目不能每次重建表）"""
    st = os.stat(path)
    sig = (st.st_ino, st.st_size, st.st_mtime_ns)
    hit = _IMAGES.get(path)
    if hit is not None and hit[0] == sig:
        return hit[1]
    im = _load_image(path)
    _IMAGES[path] = (sig, im)
    return im


def _load_image(path):
    here = Path(__file__).resolve().parent
    for d in (here, here.parents[2] / "pack"):
        if (d / "romfs_img.py").is_file():
            if str(d) not in sys.path:
                sys.path.insert(0, str(d))
            from romfs_img import RomfsImage
            return RomfsImage(path)
    raise FileNotFoundError(2, "RomFS 镜像读取模块 romfs_img.py 不在本目录，也不在仓库 pack/", str(here / "romfs_img.py"))


class _ImgStat:
    """镜像条目的 lstat 替身：盘点 / 身份 / 清单 / sizes 用到的几项"""
    __slots__ = ("st_mode", "st_size", "st_mtime_ns")

    def __init__(self, mode, size, mtime_ns):
        self.st_mode, self.st_size, self.st_mtime_ns = mode, size, mtime_ns


def _identity(tree):
    h = hashlib.sha256(FORMAT.encode())
    for e in sorted(tree.entries, key=lambda e: e.rel.encode("utf-8", "surrogateescape")):
        sig = f"{e.lstat.st_size}:{e.lstat.st_mtime_ns}" if stat.S_ISREG(e.lstat.st_mode) else ""
        h.update(f"{e.rel}\0{e.kind}\0{sig}\n".encode("utf-8", "surrogateescape"))
    return h.hexdigest()[:32]


def _scan_image(top, path, stat_entries, sub=""):
    """镜像建的盘点：每层条目按名字 UTF-8 字节序（目录与文件混排，同镜像的路径序）。
    sub：top 是镜像里的子目录（<镜像对应目录>/a/b，目录不在）时它在镜像里的相对路径，只盘点这棵子树、相对路径从它算起；镜像里没有这个目录 → 同目录盘点打不开（errors[""]）"""
    tree = Tree(top)
    im = tree.image = _romfs_image(path)
    mtime = os.stat(path).st_mtime_ns
    prefix = sub + "/" if sub else ""
    if sub and sub not in im.dirs():
        tree.errors[""] = FileNotFoundError(2, "No such file or directory", tree.top)
        return tree
    dirs = [d[len(prefix):] if d != sub else "" for d in im.dirs() if d == sub or d.startswith(prefix)]
    tree.children = {d: [] for d in dirs}
    rows = [(d, DIR | WALKDIR, _ImgStat(stat.S_IFDIR | 0o555, 0, mtime)) for d in dirs if d]
    rows += [(rel[len(prefix):], FILE, _ImgStat(stat.S_IFREG | 0o444, size, mtime)) for rel, _, size in im.entries() if rel.startswith(prefix)]
    rows.sort(key=lambda r: r[0].encode("utf-8", "surrogateescape"))
    for rel, kind, st in rows:
        parent, _, name = rel.rpartition("/")
        e = Entry(rel, name, os.path.join(tree.top, *rel.split("/")), kind, st if stat_entries else None, None, im, prefix + rel)
        tree.children[parent].append(e)
        tree.entries.append(e)
    if stat_entries:
        tree.identity = _identity(tree)
    return tree


def scan(top, stat_entries=True):
    """盘点一棵目录（不打开任何文件）：每层 scandir、每个条目 lstat 一次。打不开的目录记进 errors 并跳过（os.walk 同样跳过）。
    stat_entries=False：只要名字与类型（walk 用；类型取目录项自带的 d_type，不逐个 lstat），没有 lstat、没有身份。
    目录不在、旁边有 <top>.std → 从镜像建（见文件头「镜像」）；top 是镜像里的子目录（目录不在、上级有 .std）→ 从镜像建这棵子树"""
    img = image_of(top)
    if img is not None:
        return _scan_image(top, img, stat_entries)
    if not os.path.lexists(top):
        hit = _image_parent(top)
        if hit is not None and hit[2]:
            return _scan_image(top, hit[1], stat_entries, hit[2])
    tree = Tree(top)
    pending = [(tree.top, "")]
    ok = True
    while pending:
        folder, rel = pending.pop()
        kids = []
        try:
            with os.scandir(folder) as it:
                for c in it:
                    kids.append(c)
        except OSError as err:
            tree.errors[rel] = err
            ok = False
            continue
        prefix = rel + "/" if rel else ""
        out = tree.children[rel] = []
        for c in kids:
            kind = 0
            try:
                if c.is_symlink():
                    kind |= SYMLINK
            except OSError:
                pass
            try:
                if c.is_dir(follow_symlinks=False):
                    kind |= DIR
            except OSError:
                pass
            try:
                if c.is_dir():
                    kind |= WALKDIR
            except OSError:
                pass
            try:
                if c.is_file():
                    kind |= FILE
            except OSError:
                pass
            if not kind & DIR and (c.name == ".DS_Store" or c.name.startswith("._")):
                continue   # macOS 垃圾（同 pack/pack.py：不进资源包，也就不能进索引，否则游戏枚举到就读不到）
            st = st_err = None
            if stat_entries:
                try:
                    st = c.stat(follow_symlinks=False)
                except OSError as err:
                    st_err, ok = err, False
            e = Entry(prefix + c.name, c.name, c.path, kind, st, st_err)
            out.append(e)
            tree.entries.append(e)
            if kind & DIR:
                pending.append((c.path, e.rel))
    if ok and stat_entries:
        tree.identity = _identity(tree)
    return tree


def walk(top, onerror=None):
    """os.walk(top) 的替身（RomFS 目录遍历一律经这里）；只取名字与类型，不逐个 lstat"""
    return scan(top, stat_entries=False).walk(onerror)


def _image_parent(p):
    """p（不在盘上）落在哪份镜像里：最近一层「目录不在、旁边有 <目录>.std」的上级 → (该上级, 镜像路径, p 在镜像里的相对路径)；不在任何镜像里 → None"""
    rel, cur = [], os.fspath(p).rstrip("/" + os.sep)
    while cur and image_of(cur) is None:
        up, name = os.path.split(cur)
        if not name or up == cur:
            return None
        rel.insert(0, name)
        cur = up
    if not cur:
        return None
    return cur, image_of(cur), "/".join(rel)


def listdir(top):
    """os.listdir(top) 的替身：只列 RomFS 某一层（不进子目录），也归这里，好让 RomFS 目录读取只有一处；
    top 是镜像盘点里的子目录（<镜像对应目录>/a/b，目录不在）也认：找最近一层有 .std 的上级"""
    top = os.fspath(top)
    if os.path.isdir(top):
        return os.listdir(top)
    hit = _image_parent(top)
    if hit is None:
        return os.listdir(top)   # 同 os.listdir 报错
    cur, img, rel = hit
    tree = _scan_image(cur, img, False)
    kids = tree.children.get(rel)
    if kids is None:
        raise FileNotFoundError(2, "No such file or directory", top)
    return [e.name for e in kids]


# 按路径读（11-16 维护者：出包 RomFS 不落散文件）：读取方拿 e.path / walk 拼出的路径读内容、跨进程传路径、交给按路径读的格式库时经这几个函数。
#   路径在盘上（目录形态）→ 与 open / os.path.getsize / os.path.isfile / os.path.isdir 完全相同（不看镜像）；
#   不在 → 找最近一层有 <目录>.std 的上级，从镜像读（路径同 e.path：「目录还在的话它该在的路径」）；两样都没有 → 同原函数（报错 / False）。
def _in_image(p):
    """(RomfsImage, 相对路径) 或 None"""
    hit = _image_parent(p)
    if hit is None or not hit[2]:
        return None
    return _romfs_image(hit[1]), hit[2]


def open_file(p):
    """open(p, "rb") 的替身：镜像里的文件给带缓冲的只读文件对象（read / seek / tell；没有 fileno，大小用 file_size）"""
    try:
        return open(p, "rb")
    except FileNotFoundError:
        hit = _in_image(p)
        if hit is None or hit[1] not in hit[0]:
            raise
        return io.BufferedReader(hit[0].open(hit[1]))


def read_file(p):
    """整份读出（同 open(p, "rb").read()）"""
    with open_file(p) as f:
        return f.read()


def file_size(p):
    """os.path.getsize(p) 的替身"""
    try:
        return os.path.getsize(p)
    except FileNotFoundError:
        hit = _in_image(p)
        if hit is None or hit[1] not in hit[0]:
            raise
        return hit[0].size(hit[1])


def is_file(p):
    """os.path.isfile(p) 的替身"""
    if os.path.isfile(p):
        return True
    if os.path.lexists(p):
        return False
    hit = _in_image(p)
    return hit is not None and hit[1] in hit[0]


def is_dir(p):
    """os.path.isdir(p) 的替身（镜像里记着的目录；镜像对应的那层目录本身也算）"""
    if os.path.isdir(p):
        return True
    if os.path.lexists(p):
        return False
    if image_of(p) is not None:
        return True
    hit = _in_image(p)
    return hit is not None and hit[1] in hit[0].dirs()


def exists(p):
    """os.path.exists(p) 的替身"""
    return os.path.exists(p) or is_file(p) or is_dir(p)


class _ImageSpan:
    """镜像里一个文件的只读映射视图（map_file 不对齐时用）：底下是从对齐处起映的文件映射，下标整体平移 delta。
    同 mmap 的用法：len、下标 / 切片（切片出 bytes）、find / rfind、size、close、with；正则 / struct / memoryview 经 __buffer__ 拿到的正是这个文件的字节"""
    def __init__(self, mm, delta, size):
        self._mm, self._d, self._n = mm, delta, size

    def __buffer__(self, flags):
        whole = memoryview(self._mm)
        view = whole[self._d:self._d + self._n]
        whole.release()
        return view

    def __release_buffer__(self, view):
        view.release()

    def __len__(self):
        return self._n

    def __getitem__(self, k):
        if isinstance(k, slice):
            a, b, step = k.indices(self._n)
            if step == 1:
                return self._mm[self._d + a:self._d + max(a, b)]
            with memoryview(self) as v:
                return bytes(v[k])
        i = k.__index__()
        if i < 0:
            i += self._n
        if not 0 <= i < self._n:
            raise IndexError("mmap index out of range")
        return self._mm[self._d + i]

    def _span(self, start, end):
        a, b, _ = slice(start, end).indices(self._n)
        return self._d + a, self._d + max(a, b)

    def find(self, sub, start=None, end=None):
        r = self._mm.find(sub, *self._span(start, end))
        return r - self._d if r >= 0 else -1

    def rfind(self, sub, start=None, end=None):
        r = self._mm.rfind(sub, *self._span(start, end))
        return r - self._d if r >= 0 else -1

    def size(self):
        return self._n

    @property
    def closed(self):
        return self._mm.closed

    def close(self):
        self._mm.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def map_file(p):
    """mmap（with 里用；同 mmap.mmap(open(p).fileno(), 0, access=ACCESS_READ)，空文件同样抛 ValueError）。
    镜像里的文件：数据起点按映射粒度（mmap.ALLOCATIONGRANULARITY）对齐 → 直接映射镜像里那一段（不拷贝）；
    不对齐（LibHac 建的镜像文件数据只按 0x10 对齐，几乎都不对齐）→ 从下方对齐处起映射镜像（多映前面不到一个粒度），交 _ImageSpan 平移下标：
    仍是文件映射、零拷贝，页走系统文件缓存，多个进程映同一份共用一份（#1439：原先拷进同长匿名映射，大文件分段扫的每一段、trpfs 的每个包各拷一整份，
    宝可梦紫 10 路各拷几 GB，整机内存耗尽卡死）。Python 3.12 以下没有 __buffer__（PEP 688），正则 / struct 拿不到平移后的内容，退回拷贝"""
    import mmap
    try:
        f = open(p, "rb")
    except FileNotFoundError:
        hit = _in_image(p)
        if hit is None or hit[1] not in hit[0]:
            raise
        im, rel = hit
        start, size = im.span(rel)
        if not size:
            raise ValueError("cannot mmap an empty file")
        delta = start % mmap.ALLOCATIONGRANULARITY
        if delta == 0:
            with open(im.path, "rb") as g:
                return mmap.mmap(g.fileno(), size, offset=start, access=mmap.ACCESS_READ)
        if sys.version_info >= (3, 12):
            with open(im.path, "rb") as g:
                return _ImageSpan(mmap.mmap(g.fileno(), size + delta, offset=start - delta, access=mmap.ACCESS_READ), delta, size)
        m = mmap.mmap(-1, size)
        with im.open(rel) as src:
            view, at = memoryview(m), 0
            try:
                while at < size:
                    got = src.readinto(view[at:at + (8 << 20)])
                    if not got:
                        raise OSError(f"RomFS 镜像 {im.path} 里 {rel} 读短了（{at} / {size} 字节）")
                    at += got
            finally:
                view.release()
        return m
    with f:
        return mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)


def default_listing(top):
    """清单目录：S2A_ROMFS_WALK（off = 不落盘）> <产物根的上一级>/.romfs-walk（产物根 = top 的上一级，同 direct_profile_stage.py 缺省）。
    只给名为 romfs 的目录落盘：追加内容 aoc/<序号> 等别的目录的上两级是产物根本身（缺省位置会写进产物根里），标签也会各款撞名，不落盘（照常现读）"""
    if os.path.basename(os.path.normpath(os.path.abspath(top))) != "romfs":
        return None
    env = os.environ.get("S2A_ROMFS_WALK")
    if env:
        return None if env == "off" else Path(env)
    return Path(os.path.abspath(top)).parent.resolve().parent / ".romfs-walk"


def _listing_path(listing, top, identity):
    tag = Path(os.path.abspath(top)).parent.name.split("@")[0] or "romfs"
    return Path(listing) / f"{tag}-{identity}.json"


def _save(path, tree):
    rows = []
    for e in tree.entries:
        st = e.lstat
        rows.append([e.rel, e.kind, e.size if e.size is not None else st.st_size, st.st_mtime_ns,
                     e.head.hex() if e.head is not None else None,
                     [e.error.errno, e.error.strerror, e.error.filename] if e.error is not None else None])
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".walk-", dir=path.parent)
        try:
            # ensure_ascii：非 UTF-8 文件名的代理字符原样往返
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
                json.dump({"format": FORMAT, "identity": tree.identity, "head": HEAD, "entries": rows}, f, separators=(",", ":"))
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
        tag = path.name[:-len(tree.identity) - 6]
        mine = re.compile(re.escape(tag) + r"-[0-9a-f]{32}\.json")
        old = sorted((p for p in path.parent.iterdir() if p != path and mine.fullmatch(p.name)),
                     key=lambda p: p.stat().st_mtime, reverse=True)
        for p in old[KEEP - 1:]:
            p.unlink(missing_ok=True)
    except OSError:
        # 清单只是提速：写不了照常出结果
        pass


def _load(path, tree):
    """清单里的（大小、头、读错误）填进本次盘点的文件条目；对不上返回 False（调用方重读）"""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if not (isinstance(data, dict) and data.get("format") == FORMAT and data.get("identity") == tree.identity
                and data.get("head") == HEAD):
            return False
        rows = {r[0]: r for r in data["entries"]}
        if len(rows) != len(tree.entries):
            return False
        filled = []
        for e in tree.entries:
            rel, kind, size, mtime, head, error = rows[e.rel]
            if kind != e.kind:
                return False
            if e.file:
                filled.append((e, size if head is not None else None, bytes.fromhex(head) if head is not None else None,
                               OSError(*error) if error is not None else None))
        for e, size, head, error in filled:
            e.size, e.head, e.error = size, head, error
        return True
    except (OSError, ValueError, KeyError, TypeError):
        return False


def _read_heads(entries):
    for e in entries:
        try:
            with open(e.path, "rb") as f:
                e.head = f.read(HEAD)
                e.size = os.fstat(f.fileno()).st_size
        except OSError as err:
            e.error = err


def _read_heads_image(files):
    """镜像：按数据偏移顺序一个句柄读完（同一个大文件里顺着走，不逐个打开）"""
    if not files:
        return
    spans = files[0].image.files()
    with open(files[0].image.path, "rb") as f:
        for e in sorted(files, key=lambda e: spans[e.image_rel][0]):
            off, size = spans[e.image_rel]
            f.seek(off)
            e.head, e.size = f.read(min(HEAD, size)), size


def heads(top, listing=_AUTO, tree=None):
    """盘点 + 每个普通文件的（大小、前 32 字节）：有对得上身份的清单就从清单取（不读盘），否则并行读头并写清单。
    listing：清单目录；缺省见 default_listing；None = 不落盘（只在本次调用里用）。tree：已盘点的结果（同一进程里复用，调用方保证期间没改）"""
    tree = tree if tree is not None else scan(top)
    if tree.complete:
        return tree
    if listing is _AUTO:
        listing = default_listing(top)
    path = _listing_path(listing, top, tree.identity) if listing is not None and tree.identity else None
    # 本标签没有：同目录下别的标签同身份的清单也认（身份 = 相对路径 + 类型 + 大小 + 修改时间纳秒，同身份即同一批文件；
    #   11-06 出包速度线：解包目录读过的头，播种搬进产物根后 caps 再冷读一遍，王国之泪 30.5 万个文件Windows 出包机约 119 秒）
    alt = sorted(p for p in Path(listing).glob(f"*-{tree.identity}.json") if p != path) if path and not path.exists() and Path(listing).is_dir() else []
    if not (path and (_load(path, tree) or any(_load(p, tree) for p in alt))):
        files = tree.files()
        if tree.image is not None:
            _read_heads_image(files)
            files = []
        # 读头是磁盘随机读（外置 SSD 单线程约 1.8k 个/秒），线程多只排队等盘、几乎不占核：16 路约 8k 个/秒（11-03 火纹实测，32 路只再快约 5%）
        workers = max(1, min(16, 2 * (os.cpu_count() or 1)))
        chunks = [files[i::workers * 8] for i in range(workers * 8)]
        with ThreadPoolExecutor(workers) as pool:
            list(pool.map(_read_heads, chunks))
        if path:
            _save(path, tree)
    tree.complete = True
    return tree


def main(argv):
    if len(argv) >= 3 and argv[0] == "has-ext":
        exts = tuple(x.lower() for x in argv[2:])
        return 0 if any(e.name.lower().endswith(exts) for e in scan(argv[1]).entries) else 1
    if len(argv) == 2 and argv[0] == "files0":
        tree = scan(argv[1])
        if tree.image is not None:
            print(f"romfs_list.py files0：{argv[1]} 只有镜像 {tree.image.path}，没有散文件路径可给（读取方要改成从镜像读）", file=sys.stderr)
            return 1
        out = sys.stdout.buffer
        for e in tree.entries:
            if e.lstat is not None and stat.S_ISREG(e.lstat.st_mode):
                out.write(os.fsencode(tree.top) + b"/" + os.fsencode(e.rel) + b"\0")
        bad = [(rel, err) for rel, err in tree.errors.items()] + [(e.rel, e.lstat_error) for e in tree.entries if e.lstat_error is not None]
        if bad:
            rel, err = bad[0]
            print(f"romfs_list.py files0：读不开 {rel or tree.top}：{err}", file=sys.stderr)
            return 1
        return 0
    if len(argv) == 3 and argv[0] == "sizes":
        tree = scan(argv[1])
        bad = [(rel, err) for rel, err in tree.errors.items()] + [(e.rel, e.lstat_error) for e in tree.entries if e.lstat_error is not None]
        if bad:
            rel, err = bad[0]
            print(f"romfs_list.py sizes：读不开 {rel or tree.top}：{err}", file=sys.stderr)
            return 1
        with open(argv[2], "w", encoding="utf-8", errors="surrogateescape", newline="\n") as f:
            for e in tree.entries:
                if stat.S_ISREG(e.lstat.st_mode):
                    f.write(f"{e.lstat.st_size}\t{e.rel}\n")
        return 0
    print(__doc__.split("用法（给 shell 阶段）：")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
