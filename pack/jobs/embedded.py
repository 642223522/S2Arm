"""Install the app's immutable engine snapshot into a writable cache (the default location's hosts/engine, see engines_root).

The snapshot contains a fresh, local-only Git object database for the existing
pipeline's HEAD-based stage keys. It contains no developer history or remotes.
"""
from pathlib import Path
import os
import shutil
import uuid
from core import Failure, atomic, contained, read


def check_git(engine):
    """内置引擎的 Git 快照必须自成一库：Git 认出的仓库目录就是引擎自己的 .git，不许往上认到外层仓库"""
    import subprocess
    env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(Path(engine).resolve().parent))
    p = subprocess.run(["git", "-C", str(engine), "rev-parse", "--absolute-git-dir"], capture_output=True, text=True, env=env)
    if p.returncode or Path(p.stdout.strip()).resolve() != (Path(engine) / ".git").resolve():
        raise Failure("应用内置引擎的版本快照无效，请重新安装完整应用。")


def install(c):
    bundle = c.r.get("engineBundle")
    if not bundle:
        return  # Source-checkout CLI/development tests.
    from build import clone_tree, validate_files
    source = Path(bundle).resolve()
    manifest = read(source / "engine.json", {})
    identity = manifest.get("id", "")
    if manifest.get("schema") != 1 or len(identity) != 64 or any(x not in "0123456789abcdef" for x in identity):
        raise Failure("应用内置引擎不完整，请重新安装完整应用。")
    root = engines_root(c)
    destination = contained(root, root / identity)
    _adopt_private_copy(c, root, identity)
    # 已装的副本每次用前按大小快速复核（#304：玩家机上已装副本里宿主的 Info.plist 被外部改过，0.1.7 只看安装标记、之后每次出包都报 runtime_invalid、
    #   重新打包也好不了）；对不上就挪开、从 App 包重解。逐文件 lstat，约 8500 个文件几十毫秒；摘要级核对仍在用到具体产物时（artifact）
    if read(destination / ".installed.json", {}).get("schema") == 2 and not _intact(c, destination, manifest, full=False):
        _set_aside(c, root, destination, "已装的内置引擎文件被改过")
    # 安装标记第 2 版：第 1 版的复制丢了空目录、Git 快照无效（10-23），旧安装一律重装
    if read(destination / ".installed.json", {}).get("schema") != 2:
        if destination.exists():
            shutil.rmtree(contained(root, destination))
        c.begin("初始化内置 S2Arm 引擎")
        try:
            validate_files(c, source, manifest.get("files"))
        except Failure as e:   # App 包本身的文件就不对：重解也没用，只能重装 App
            raise Failure("S2Arm 应用里的内置引擎文件不完整（" + str(e).rsplit("：", 1)[-1] + "），请重新安装完整的 S2Arm。", code="engine_incomplete") from e
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(identity + "." + uuid.uuid4().hex + ".partial")
        temporary.mkdir()
        try:
            clone_tree(c, source, temporary)
            validate_files(c, temporary, manifest["files"])
            check_git(temporary)
            atomic(temporary / ".installed.json", dict(schema=2, id=identity))
            c.check()
            # Concurrent read-only catalogue/check workers may initialize once.
            try:
                os.rename(temporary, destination)
            except OSError:
                if read(destination / ".installed.json", {}).get("id") != identity:
                    raise
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
    c.engine = destination
    _retain(c, root, identity)
    c.require_source()


# ---- 引擎副本放哪、留几份（游戏库结构 P3）----
# 原来每版一份放 <私有目录>/engines/<引擎号>/、从不清（约 4 GB / 版）。现在放默认位置的 hosts/engine/<引擎号>/，只留在用的一份和上一份
# （上一份给升级当口还在跑的旧版作业、以及回退旧版 App 时直接用，不用重解）。库还没建好（setup 之前）退回私有目录；建库后下次装引擎时
# 同一卷的直接改名搬过去，跨卷的从 App 里重新解出，私有目录里的旧副本一律删掉。

def engines_root(c):
    from core import default_home
    home = default_home(c.private, c.library)
    return home / "engines" if home == c.private else home / "hosts" / "engine"


def _adopt_private_copy(c, root, identity):
    """库建好后第一次装引擎：私有目录里同号的完整副本同卷改名搬进 hosts/engine，其余旧副本删掉（可从 App 重解）"""
    old = c.private / "engines"
    if root == old or not old.is_dir():
        return
    source, target = old / identity, root / identity
    if read(source / ".installed.json", {}).get("schema") == 2 and not target.exists():
        try:
            root.mkdir(parents=True, exist_ok=True)
            if os.stat(source).st_dev == os.stat(root).st_dev:
                os.rename(source, target)
        except OSError:
            pass   # 搬不了就重解，旧副本照删
    shutil.rmtree(old, ignore_errors=True)


def _retain(c, root, identity):
    """hosts/engine 下只留在用的这份 + 上一份（按 .last-used 时刻取最近用过的另一份）；在用的这份每次装引擎时记一次时刻"""
    if root.name != "engine":
        return
    stamp = root / identity / ".last-used"
    try:
        stamp.touch()
    except OSError:
        return
    others = []
    for d in root.iterdir():
        if d.name == identity or d.is_symlink() or not d.is_dir():
            continue
        if d.name.endswith(".partial"):
            continue   # 别的作业正在解的
        try:
            used = (d / ".last-used").stat().st_mtime
        except OSError:
            used = 0
        others.append((used, d.name, d))
    for _, _, d in sorted(others, reverse=True)[1:]:
        shutil.rmtree(d, ignore_errors=True)


def _intact(c, root, manifest, files=None, full=True):
    """副本里这些文件（缺省清单全部）在、是普通文件、大小对（full 再核摘要）"""
    from build import validate_files
    try:
        validate_files(c, root, files if files is not None else manifest.get("files"), full)
        return True
    except Failure as e:
        if e.code != "runtime_invalid":
            raise
        c.emit("message", "内置引擎副本校验没过：" + str(e).rsplit("：", 1)[-1])
        return False


def _set_aside(c, root, destination, why):
    """坏副本改名挪开（同卷改名；正在用它的别的作业照常读完），随后删掉；install 接着从 App 包重解"""
    c.emit("message", why + "，从 S2Arm 应用里重新解出一份")
    broken = destination.with_name(destination.name + "." + uuid.uuid4().hex + ".broken")
    try:
        os.rename(destination, broken)
    except OSError:
        return   # 别的作业刚挪走 / 正在重解
    shutil.rmtree(broken, ignore_errors=True)


def artifact(c, name):
    manifest = read(c.engine / "engine.json", {})
    if not manifest:
        return None
    prefix = "Binaries/" + name
    files = {p: v for p, v in manifest.get("files", {}).items() if p.startswith(prefix + "/")}
    if not files:
        raise Failure("应用内置引擎产物缺失，请重新安装完整应用。")
    if not _intact(c, c.engine, manifest, files):
        if not c.r.get("engineBundle"):   # 源码树开发：没有 App 包可重解，照原样报
            from build import validate_files
            validate_files(c, c.engine, files)
        # 已装副本里这件产物被改过（#304）：从 App 包重解整份引擎再核一次；App 包本身坏了由 install 报「重新安装 S2Arm」
        _set_aside(c, c.engine.parent, c.engine, "内置引擎里的 " + name + " 被改过")
        install(c)
        from build import validate_files
        validate_files(c, c.engine, files)
    return c.engine / prefix
