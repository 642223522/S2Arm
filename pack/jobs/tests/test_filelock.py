# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""#1100: native cross-process library locking, with original Failure text."""
import ast
import errno
import importlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))


class NativeImport(unittest.TestCase):
    def test_core_import_succeeds_without_posix_runtime(self):
        code = "import sys;sys.path.insert(0,sys.argv[1]);import core;print('imported')"
        p = subprocess.run([sys.executable, '-B', '-c', code, str(JOBS)],
                           capture_output=True, text=True, timeout=5)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(), 'imported')


class FileLocks(unittest.TestCase):
    def setUp(self):
        self.module = importlib.import_module('filelock')
        self.tmp = tempfile.TemporaryDirectory(prefix='s2arm lock 中文 ')
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'shared lock'
        self.path.touch()

    def holder(self):
        code = ("import sys;sys.path.insert(0,sys.argv[1]);import filelock;"
                "f=open(sys.argv[2],'a');filelock.try_lock(f);print('locked',flush=True);"
                "sys.stdin.readline();filelock.unlock(f);f.close()")
        p = subprocess.Popen([sys.executable, '-B', '-u', '-c', code, str(JOBS), str(self.path)],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def stop():
            if p.poll() is None:
                p.kill()
            p.communicate(timeout=5)
        self.addCleanup(stop)
        self.assertEqual(p.stdout.readline().strip(), 'locked')
        return p

    def probe(self):
        code = '''import sys
sys.path.insert(0,sys.argv[1])
import filelock
with open(sys.argv[2],'a') as f:
    try: filelock.try_lock(f)
    except BlockingIOError: print('busy')
    else:
        filelock.unlock(f)
        print('acquired')
'''
        p = subprocess.run([sys.executable, '-B', '-c', code, str(JOBS), str(self.path)],
                           capture_output=True, text=True, timeout=5)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.strip()

    def test_other_process_cannot_acquire_held_lock(self):
        with self.path.open('a') as f:
            self.module.try_lock(f)
            try: self.assertEqual(self.probe(), 'busy')
            finally: self.module.unlock(f)

    def test_explicit_unlock_allows_other_process(self):
        with self.path.open('a') as f:
            self.module.try_lock(f)
            self.module.unlock(f)
            self.assertEqual(self.probe(), 'acquired')

    def test_owner_process_exit_releases_lock(self):
        p = self.holder()
        self.assertEqual(self.probe(), 'busy')
        p.kill(); p.wait(timeout=5)
        self.assertEqual(self.probe(), 'acquired')

    def test_context_reports_original_failure_on_busy(self):
        import core
        directory = Path(self.tmp.name)
        self.path = directory / '.catalog.lock'
        self.path.touch()
        p = self.holder()
        context = object.__new__(core.Context)
        context.library = directory
        context.lock_wait = 0.3   # 排队上限调短：原先拿不到立刻报错，现在等到上限（剃刀 H1）
        with patch.object(context, 'check'), patch.object(context, 'require_library'):
            caught = None
            try:
                with context.lock():
                    pass
            except Exception as error:
                caught = error
            self.assertIsInstance(caught, core.Failure)
        self.assertEqual(str(caught), '另一个任务正在使用游戏库，请稍后重试。')
        p.stdin.write('release\n'); p.stdin.flush(); p.wait(timeout=5)
        with patch.object(context, 'check'), patch.object(context, 'require_library'):
            with context.lock(): pass
        self.assertEqual(self.probe(), 'acquired')

    def test_lock_uses_byte_zero_even_when_position_moves(self):
        self.path.write_bytes(b'abcdef')
        with self.path.open('a') as f:
            f.seek(5)
            self.module.try_lock(f)
            try: self.assertEqual(self.probe(), 'busy')
            finally:
                f.seek(4)
                self.module.unlock(f)
            self.assertEqual(self.probe(), 'acquired')
        self.assertEqual(self.path.read_bytes(), b'abcdef')

    def test_empty_file_is_not_modified(self):
        with self.path.open('a') as f:
            self.module.try_lock(f); self.module.unlock(f)
        self.assertEqual(self.path.read_bytes(), b'')

    def test_no_platform_specific_top_level_import(self):
        tree = ast.parse(Path(self.module.__file__).read_text(encoding='utf-8'))
        top = {name.name for node in tree.body if isinstance(node, ast.Import) for name in node.names}
        self.assertFalse(top & {'fcntl', 'msvcrt'})

    @unittest.skipUnless(os.name == 'nt', 'Windows errno adapter only')
    def test_windows_busy_errno_is_normalized(self):
        import msvcrt
        for number in (errno.EACCES, errno.EDEADLK):
            with self.subTest(errno=number), self.path.open('a') as f:
                with patch.object(msvcrt, 'locking', side_effect=OSError(number, 'synthetic busy')):
                    with self.assertRaises(BlockingIOError): self.module.try_lock(f)
        with self.path.open('a') as f:
            with patch.object(msvcrt, 'locking', side_effect=OSError(errno.EBADF, 'synthetic invalid fd')):
                with self.assertRaises(OSError) as caught: self.module.try_lock(f)
                self.assertNotIsInstance(caught.exception, BlockingIOError)


if __name__ == '__main__': unittest.main()


class QueuedLibraryLock(unittest.TestCase):
    """启动器剃刀 H1 / H2（11-11）：游戏库锁拿不到时排队（有上限），占锁者写进旁挂文件，等的一方说清在等谁。期望值手写"""
    def setUp(self):
        import core
        self.core = core
        self.tmp = tempfile.TemporaryDirectory(prefix='s2arm queued lock ')
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.lock = self.dir / '.execution.lock'

    def hold(self, seconds, holder=None):
        # 另一个进程按 filelock.held 拿锁（holder 写旁挂文件），seconds 秒后放；seconds < 0 = 等 stdin 再放
        code = ("import sys,json,time;sys.path.insert(0,sys.argv[1]);import filelock;"
                "h=json.loads(sys.argv[3]) if sys.argv[3] else None;s=float(sys.argv[4])\n"
                "with filelock.held(__import__('pathlib').Path(sys.argv[2]),holder=h):\n"
                "    print('locked',flush=True)\n"
                "    time.sleep(s) if s>=0 else sys.stdin.readline()\n")
        p = subprocess.Popen([sys.executable, '-B', '-u', '-c', code, str(JOBS), str(self.lock),
                              __import__('json').dumps(holder) if holder else '', str(seconds)],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: (p.poll() is None and p.kill(), p.communicate(timeout=5)))
        self.assertEqual(p.stdout.readline().strip(), 'locked')
        return p

    def context(self, wait):
        c = object.__new__(self.core.Context)
        c.library, c.lock_wait, c.task, c.operation, c.r = self.dir, wait, 't9', 'catalog', {}
        return c

    def test_short_job_waits_for_lock_instead_of_failing(self):
        # 占锁 0.5 秒后放；等待上限 5 秒 → 拿到锁（旧代码：立刻抛「另一个任务正在使用游戏库」）
        self.hold(0.5)
        c = self.context(5)
        with patch.object(c, 'check'), patch.object(c, 'require_library'), patch.object(c, 'emit'):
            t0 = __import__('time').monotonic()
            with c.lock('execution'):
                got = 'acquired'
        self.assertEqual(got, 'acquired')
        self.assertLess(__import__('time').monotonic() - t0, 5)

    def test_timeout_names_the_holder_and_reports_waiting(self):
        # 出包任务 t7（游戏 0100000000010000）一直占着；上限 0.6 秒 → 报原句；internal 写「出包 · 0100000000010000（任务 t7）」；
        #   等的期间发过一次 phase=waiting_lock 的进度，消息「在等「出包 · 0100000000010000（任务 t7）」结束…」、holder 原样带上
        holder = dict(taskId='t7', operation='build', gameId='0100000000010000', pid=1, startedAt=1.0)
        p = self.hold(-1, holder)
        c = self.context(0.6)
        events = []
        with patch.object(c, 'check'), patch.object(c, 'require_library'), \
                patch.object(c, 'emit', side_effect=lambda *a, **k: events.append((a, k))):
            with self.assertRaises(self.core.Failure) as raised:
                with c.lock('execution'):
                    pass
        self.assertEqual(str(raised.exception), '另一个任务正在使用游戏库，请稍后重试。')
        self.assertIn('出包 · 0100000000010000（任务 t7）', raised.exception.internal)
        waits = [k for a, k in events if k.get('phase') == 'waiting_lock']
        self.assertEqual(len(waits), 1)
        self.assertEqual(waits[0]['holder'], holder)
        self.assertEqual(events[0][0][1], '在等「出包 · 0100000000010000（任务 t7）」结束…')
        p.stdin.write('release\n'); p.stdin.flush(); p.wait(timeout=5)

    def test_holder_record_is_removed_on_release(self):
        c = self.context(1)
        holder_file = self.lock.with_name('.execution.lock.holder')
        with patch.object(c, 'check'), patch.object(c, 'require_library'):
            with c.lock('execution'):
                self.assertEqual(__import__('json').loads(holder_file.read_text())['taskId'], 't9')
        self.assertFalse(holder_file.exists())
