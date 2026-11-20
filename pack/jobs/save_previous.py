"""回到上一份存档（Mac）：每次存档提交换下来的旧版本留在 <存档>/.s2a_prev（compat S2ASaveTransaction.PreviousDir，APFS 克隆、只留一份）。

savePrevious         只读：这款哪几棵存档有上一份；要不要在开始前问玩家（上一局开局就崩，或那局有存档护栏红行）
saveRestorePrevious  起局前（stopped：游戏没在跑、没收尾的存档事务先回退）：每棵与 .s2a_prev 原子交换（renamex_np RENAME_SWAP，
                     同 platform/apple/cs/savecommit/AppleHostDirectoryTransaction.Exchange），再 F_FULLFSYNC 存档目录；再做一次就换回来。
                     一棵失败就把这次已换过的几棵换回去，整次报失败——不留「一半新一半旧」

起局结果（note_launch，build.launch 收局时记）：开局 EARLY_SECONDS 内游戏异常退出记 earlyCrash，正常收局清掉。
存档护栏：compat S2ASaveCommit 拦下一次提交时在 <存档>/.s2a_guard 留记号、之后正常提交删掉（GUARD_MARK，同服务层 SaveTransfer.GuardMark）。
两样只用来决定问不问，不拦、不自动覆盖。
"""
import ctypes
import errno
import json
import os
import sys
import time
from pathlib import Path

from saves import fail, locations, stopped

PREVIOUS_DIR = ".s2a_prev"
EARLY_SECONDS = 60          # 同 host_update.TRIAL_OK_SECONDS：玩过这么久才崩不算「读存档就崩」
GUARD_MARK = ".s2a_guard"
RENAME_SWAP = 0x2
F_FULLFSYNC = 51

_libc = None


def _darwin_libc():
    """renamex_np / F_FULLFSYNC 是 macOS 专有：用到时才加载，导入本模块不碰平台专有的东西
    （main.py 启动就导入它；原先导入时 ctypes.CDLL(None)，Windows 上 CDLL 必须给库名，所有作业一启动就崩）。
    别的系统报 ENOTSUP，restore 按「没能回到上一份存档，存档保持原样」报"""
    global _libc
    if sys.platform != "darwin":
        raise OSError(errno.ENOTSUP, "renamex_np is macOS only")
    if _libc is None:
        _libc = ctypes.CDLL(None, use_errno=True)
    return _libc


def _exchange(a, b):
    if _darwin_libc().renamex_np(os.fsencode(a), os.fsencode(b), ctypes.c_uint(RENAME_SWAP)) != 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e), str(a))


def _full_sync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        try:
            import fcntl
            fcntl.fcntl(fd, F_FULLFSYNC)
        except OSError as e:   # 卷不支持 F_FULLFSYNC 才退回 fsync；真刷盘失败原样报（同 AppleHostDirectoryTransaction.SyncDirectory）
            if e.errno not in (errno.ENOTSUP, errno.EINVAL, errno.ENOTTY):
                raise
            os.fsync(fd)
    finally:
        os.close(fd)


def previous_dirs(root):
    base = Path(root) / "bis" / "user" / "save"
    if not base.is_dir():
        return []
    out = []
    for d in sorted(base.iterdir()):
        if d.is_symlink() or not d.is_dir() or len(d.name) != 16:
            continue
        if (d / "0").is_dir() and not (d / "0").is_symlink() and (d / PREVIOUS_DIR).is_dir() and not (d / PREVIOUS_DIR).is_symlink():
            out.append(d)
    return out


def _outcome_path(c, gid):
    return Path(c.private) / "launch-outcome" / (gid.upper() + ".json")


def note_launch(c, gid, early_crash):
    """build.launch 收局时调：开局就崩记下，正常收局清掉。写不下不影响收局"""
    p = _outcome_path(c, gid)
    try:
        if not early_crash:
            p.unlink(missing_ok=True)
            return
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_suffix(".partial")
        tmp.write_text(json.dumps({"earlyCrash": True, "at": time.time()}), encoding="utf-8")
        os.replace(tmp, p)
    except OSError:
        pass


def trouble(c, gid, dirs):
    """上一局读存档出事的迹象 → 原因码（guardRed 护栏拦下过 / earlyCrash 开局就崩）或空串"""
    if any((d / GUARD_MARK).exists() for d in dirs):
        return "guardRed"
    try:
        rec = json.loads(_outcome_path(c, gid).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    return "earlyCrash" if rec.get("earlyCrash") else ""


def status(c):
    c.begin("查上一份存档")
    game = c.game()
    root, _, _ = locations(c, game)
    dirs = previous_dirs(root)
    return dict(hasPrevious=bool(dirs), saveIds=[d.name for d in dirs], trouble=trouble(c, game["id"], dirs) if dirs else "")


def restore(c):
    c.begin("回到上一份存档")
    with stopped(c) as (game, _recovered, _failed):
        root, _, _ = locations(c, game)
        dirs = previous_dirs(root)
        if not dirs:
            fail(c, "这款游戏没有上一份存档。", "no_previous")
        done = []
        for d in dirs:
            try:
                _exchange(d / PREVIOUS_DIR, d / "0")
                _full_sync_dir(d)
                done.append(d)
                (d / GUARD_MARK).unlink(missing_ok=True)   # 回过去了：这棵的护栏记号已处理
            except OSError as error:
                stuck = []
                for back in done:
                    try:
                        _exchange(back / PREVIOUS_DIR, back / "0")
                        _full_sync_dir(back)
                    except OSError:
                        stuck.append(back.name)
                print(f"回到上一份存档失败：{d.name}：{error!r}；换不回的：{stuck}", flush=True)  # 非玩家句
                fail(c, "没能回到上一份存档，存档保持原样。" if not stuck else "没能回到上一份存档，而且有存档没能换回原样，请导出诊断包。",
                     "previous_failed")
        _outcome_path(c, game["id"]).unlink(missing_ok=True)   # 回过去了：这次的提示已处理，下一局按新结果再判
        return dict(restored=len(done), saveIds=[d.name for d in done])
