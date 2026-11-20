# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Library locks on both hosts: a non-blocking primitive (try_lock / unlock) and held(), which queues for the lock with a cap
and records who holds it (启动器剃刀 H1 / H2，11-11：原先 7 把锁 7 种等待语义，拿不到就报「另一个任务正在使用游戏库」、不说是谁).
共享模式（读写锁，11-19）：shared=True 的几方可以同时拿着，独占的一方要等它们都放掉；独占拿着时共享的也拿不到。"""
import contextlib
import errno
import json
import math
import os
import socket
import time


def try_lock(f, shared=False):
    if os.name == 'nt':
        import msvcrt
        f.seek(0)
        if shared:
            _win_lock_shared(f)
            return
        try:
            msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EDEADLK):
                raise BlockingIOError(error.errno, 'Library lock is already held') from None
            raise
    else:
        import fcntl
        fcntl.flock(f, (fcntl.LOCK_SH if shared else fcntl.LOCK_EX) | fcntl.LOCK_NB)


def _win_lock_shared(f):
    """Windows 共享锁：msvcrt 只有独占（LockFile），共享要 LockFileEx 不带 LOCKFILE_EXCLUSIVE_LOCK。锁同一个字节 0：
    和 msvcrt 的独占锁是同一套字节区锁，互相认得；放锁照旧走 unlock（UnlockFile 对 LockFileEx 锁的区也有效）"""
    import ctypes
    import msvcrt
    from ctypes import wintypes

    class Overlapped(ctypes.Structure):
        _fields_ = [("Internal", ctypes.c_void_p), ("InternalHigh", ctypes.c_void_p), ("Offset", wintypes.DWORD),
                    ("OffsetHigh", wintypes.DWORD), ("hEvent", wintypes.HANDLE)]
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.LockFileEx.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(Overlapped)]
    kernel32.LockFileEx.restype = wintypes.BOOL
    LOCKFILE_FAIL_IMMEDIATELY, ERROR_LOCK_VIOLATION = 0x1, 33
    if not kernel32.LockFileEx(msvcrt.get_osfhandle(f.fileno()), LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, ctypes.byref(Overlapped())):
        code = ctypes.get_last_error()
        if code == ERROR_LOCK_VIOLATION:
            raise BlockingIOError(errno.EACCES, 'Library lock is already held')
        raise OSError(errno.EIO, f'LockFileEx failed (Windows error {code})')


def unlock(f):
    if os.name == 'nt':
        import msvcrt
        f.seek(0)
        msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)
    else:
        import fcntl
        fcntl.flock(f, fcntl.LOCK_UN)


class Busy(BlockingIOError):
    """held() 等到上限仍拿不到：holder = 占锁任务写下的 {taskId, operation, gameId, pid, startedAt}（读不到为空字典）"""
    def __init__(self, holder):
        super().__init__(errno.EAGAIN, 'Library lock is already held')
        self.holder = holder


def holder_path(lock, shared=False):
    # 占锁者另写旁挂文件：Windows 上锁住的那一字节别的进程读不了，不能写进锁文件本身。
    #   共享的几方各写一份 <锁>.holder.<进程号>.<序号>（同时拿着的不止一个），独占的写 <锁>.holder
    if shared:
        global _shared_seq
        _shared_seq += 1
        return lock.with_name(f'{lock.name}.holder.{os.getpid()}.{_shared_seq}')
    return lock.with_name(lock.name + '.holder')


_shared_seq = 0


def shared_holders(lock):
    return sorted(lock.parent.glob(glob_escape(lock.name) + '.holder.*'))


def glob_escape(name):
    return ''.join('[' + ch + ']' if ch in '*?[' else ch for ch in name)


def _read(path):
    try:
        info = json.loads(path.read_text(encoding='utf-8'))
        return info if isinstance(info, dict) else {}
    except (OSError, ValueError):
        return {}


def read_holder(lock):
    """占锁者：独占的那份；没有就取共享里最新写下的一份（等的一方据此说清在等谁）；都没有 → {}"""
    info = _read(holder_path(lock))
    if info:
        return info
    for path in reversed(shared_holders(lock)):
        info = _read(path)
        if info:
            return info
    return {}


def holder_is_stale(holder, *, current_host=None, windows=None, pid_start=None):
    """Return True only when this host can prove the recorded process is gone or its PID was reused.

    Missing/remote/legacy holder metadata and access-denied process queries are unknown, never stale.
    The filesystem lock remains authoritative; this check must not be used to remove a lock file.
    """
    if not isinstance(holder, dict):
        return None
    host = holder.get("host")
    current_host = socket.gethostname() if current_host is None else current_host
    windows = os.name == "nt" if windows is None else windows
    if not windows or not isinstance(host, str) or not host or host.casefold() != str(current_host).casefold():
        return None
    pid, started = holder.get("pid"), holder.get("startedAt")
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
        return None
    if isinstance(started, bool) or not isinstance(started, (int, float)) or not math.isfinite(started):
        return None
    if pid_start is None:
        try:
            import winproc
            pid_start = winproc.pid_start
        except ImportError:
            return None
    try:
        created_filetime = pid_start(pid)
    except ProcessLookupError:
        return True
    except OSError as error:
        if isinstance(error, PermissionError) or error.errno in (errno.EACCES, errno.EPERM) or getattr(error, "winerror", None) == 5:
            return None
        if getattr(error, "winerror", None) == 87 or error.errno == errno.ESRCH:
            return True
        return None
    try:
        from winproc import EPOCH_AS_FILETIME
        created = (int(created_filetime) - EPOCH_AS_FILETIME) / 10_000_000
    except (ImportError, TypeError, ValueError, OverflowError):
        return None
    return created > float(started)


def _write_holder(mine, holder, tries=20, pause=0.02):
    """写旁挂的占锁说明（谁拿着、从什么时候）。它只是给排队的一方看的说明，写不成不能让拿到锁的作业失败：
    Windows 上排队的一方每 poll 秒读一次这个文件，读的那一刻覆盖（os.replace）会报 WinError 32「另一个程序正在使用此文件」——
    11-20 v0.6.1 候选 Windows 升级首启：几个作业同时排搬库锁，setup 写说明撞上，整单报「游戏库没建好」。短暂重试几次，仍不成就不写（不抛）"""
    tmp = mine.with_name(mine.name + '.%d.tmp' % os.getpid())
    try:
        tmp.write_text(json.dumps(holder, ensure_ascii=False), encoding='utf-8')
        for i in range(tries):
            try:
                os.replace(tmp, mine)
                return True
            except PermissionError:   # WinError 32 / 5：读的一方正开着，稍等再换
                time.sleep(pause)
    except OSError:
        pass
    with contextlib.suppress(OSError):
        tmp.unlink()
    return False


@contextlib.contextmanager
def held(lock, *, wait_s=0.0, holder=None, on_wait=None, poll=0.5, shared=False):
    """拿 lock（Path）：拿不到每 poll 秒再试，最多等 wait_s 秒，期间占锁者变了就调 on_wait(holder, 已等秒数)；到上限抛 Busy。
    拿到后写 holder（JSON）到旁挂文件，放锁时删掉（只删自己写的那份）。崩溃留下的旁挂文件不影响拿锁：
    独占拿到时别人的旁挂文件（独占的、共享的）都不是活的，直接覆盖 / 清掉；共享拿到时独占的那份不是活的，清掉。
    shared = True：共享模式（读写锁的「读」），见文件头"""
    with open(lock, 'a') as f:
        t0, seen = time.monotonic(), None
        while True:
            try:
                try_lock(f, shared)
                break
            except BlockingIOError:
                info, waited = read_holder(lock), time.monotonic() - t0
                if waited >= wait_s:
                    raise Busy(info) from None
                if on_wait and info != seen:
                    seen = info
                    on_wait(info, waited)
                time.sleep(min(poll, max(0.0, wait_s - waited)))
        mine = holder_path(lock, shared)
        stale = [holder_path(lock)] if shared else shared_holders(lock)   # 拿着这把锁时不可能活着的那些旁挂文件
        for path in stale:
            with contextlib.suppress(OSError):
                path.unlink()
        try:
            if holder is not None:
                _write_holder(mine, holder)
            yield
        finally:
            if holder is not None and _read(mine) == holder:
                with contextlib.suppress(OSError):
                    mine.unlink()
            unlock(f)
