# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Library locks on both hosts: a non-blocking primitive (try_lock / unlock) and held(), which queues for the lock with a cap
and records who holds it (启动器剃刀 H1 / H2，11-11：原先 7 把锁 7 种等待语义，拿不到就报「另一个任务正在使用游戏库」、不说是谁)."""
import contextlib
import errno
import json
import math
import os
import socket
import time


def try_lock(f):
    if os.name == 'nt':
        import msvcrt
        f.seek(0)
        try:
            msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EDEADLK):
                raise BlockingIOError(error.errno, 'Library lock is already held') from None
            raise
    else:
        import fcntl
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)


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


def holder_path(lock):
    # 占锁者另写旁挂文件：Windows 上锁住的那一字节别的进程读不了，不能写进锁文件本身
    return lock.with_name(lock.name + '.holder')


def read_holder(lock):
    try:
        info = json.loads(holder_path(lock).read_text(encoding='utf-8'))
        return info if isinstance(info, dict) else {}
    except (OSError, ValueError):
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


@contextlib.contextmanager
def held(lock, *, wait_s=0.0, holder=None, on_wait=None, poll=0.5):
    """拿 lock（Path）：拿不到每 poll 秒再试，最多等 wait_s 秒，期间占锁者变了就调 on_wait(holder, 已等秒数)；到上限抛 Busy。
    拿到后写 holder（JSON）到旁挂文件，放锁时删掉（只删自己写的那份）。崩溃留下的旁挂文件不影响拿锁，下一个拿到的直接覆盖"""
    with open(lock, 'a') as f:
        t0, seen = time.monotonic(), None
        while True:
            try:
                try_lock(f)
                break
            except BlockingIOError:
                info, waited = read_holder(lock), time.monotonic() - t0
                if waited >= wait_s:
                    raise Busy(info) from None
                if on_wait and info != seen:
                    seen = info
                    on_wait(info, waited)
                time.sleep(min(poll, max(0.0, wait_s - waited)))
        mine = holder_path(lock)
        try:
            if holder is not None:
                tmp = mine.with_name(mine.name + '.%d.tmp' % os.getpid())
                tmp.write_text(json.dumps(holder, ensure_ascii=False), encoding='utf-8')
                os.replace(tmp, mine)
            yield
        finally:
            if holder is not None and read_holder(lock) == holder:
                with contextlib.suppress(OSError):
                    mine.unlink()
            unlock(f)
