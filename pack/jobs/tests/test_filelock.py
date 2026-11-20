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
from unittest.mock import Mock, patch

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))


class NativeImport(unittest.TestCase):
    def test_core_import_succeeds_without_posix_runtime(self):
        code = "import sys;sys.path.insert(0,sys.argv[1]);import core;print('imported')"
        p = subprocess.run([sys.executable, '-B', '-c', code, str(JOBS)],
                           capture_output=True, text=True, timeout=5)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(), 'imported')


class HolderState(unittest.TestCase):
    def setUp(self):
        self.module = importlib.import_module('filelock')
        from winproc import EPOCH_AS_FILETIME
        self.epoch = EPOCH_AS_FILETIME
        self.holder = dict(pid=123, host='this-host', startedAt=1000.0)

    def test_remote_or_legacy_holder_is_unknown(self):
        probe = Mock(return_value=str(self.epoch + 1000 * 10_000_000))
        self.assertIsNone(self.module.holder_is_stale(self.holder, current_host='other-host', windows=True, pid_start=probe))
        self.assertIsNone(self.module.holder_is_stale({"pid": 123, "startedAt": 1000.0}, current_host='this-host', windows=True, pid_start=probe))
        probe.assert_not_called()

    def test_invalid_start_time_is_unknown(self):
        holder = dict(self.holder, startedAt=float('nan'))
        probe = Mock()
        self.assertIsNone(self.module.holder_is_stale(holder, current_host='this-host', windows=True, pid_start=probe))
        probe.assert_not_called()

    def test_exited_process_is_stale(self):
        def missing(_pid):
            raise ProcessLookupError(errno.ESRCH, 'process exited')
        self.assertIs(self.module.holder_is_stale(self.holder, current_host='this-host', windows=True, pid_start=missing), True)

    def test_reused_pid_is_stale_but_original_live_pid_is_not(self):
        later = str(self.epoch + 1001 * 10_000_000)
        earlier = str(self.epoch + 999 * 10_000_000)
        self.assertIs(self.module.holder_is_stale(self.holder, current_host='this-host', windows=True, pid_start=lambda _pid: later), True)
        self.assertIs(self.module.holder_is_stale(self.holder, current_host='this-host', windows=True, pid_start=lambda _pid: earlier), False)

    def test_access_denied_is_unknown(self):
        def denied(_pid):
            raise PermissionError(errno.EACCES, 'access denied')
        self.assertIsNone(self.module.holder_is_stale(self.holder, current_host='this-host', windows=True, pid_start=denied))


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
        self.assertEqual((raised.exception.code, raised.exception.holder), ('library_busy', holder))
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


class SharedLibraryLock(unittest.TestCase):
    """执行锁读写化（11-19）：共享的几方可同时拿着、独占要等它们都放；占锁记录每个共享方一份。期望值手写，按读写锁的定义"""
    def setUp(self):
        import core
        self.core = core
        self.tmp = tempfile.TemporaryDirectory(prefix='s2arm 读写锁 ')
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def hold(self, name, shared, holder=None):
        # 另一个进程按 filelock.held 拿 <库>/.<name>.lock（共享或独占），等 stdin 再放
        code = ("import sys,json;sys.path.insert(0,sys.argv[1]);import filelock;from pathlib import Path\n"
                "h=json.loads(sys.argv[3]) if sys.argv[3] else None\n"
                "with filelock.held(Path(sys.argv[2]),holder=h,shared=sys.argv[4]=='1'):\n"
                "    print('locked',flush=True);sys.stdin.readline()\n")
        p = subprocess.Popen([sys.executable, '-B', '-u', '-c', code, str(JOBS), str(self.dir / ('.' + name + '.lock')),
                              __import__('json').dumps(holder) if holder else '', '1' if shared else '0'],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def stop():
            if p.poll() is None:
                p.stdin.write('x\n'); p.stdin.flush()
            p.communicate(timeout=5)
        self.addCleanup(stop)
        self.assertEqual(p.stdout.readline().strip(), 'locked', p.stderr.read() if p.poll() is not None else '')
        return p

    def release(self, p):
        p.stdin.write('x\n'); p.stdin.flush(); p.wait(timeout=5)

    def try_held(self, name, shared):
        import filelock
        try:
            with filelock.held(self.dir / ('.' + name + '.lock'), shared=shared):
                return 'acquired'
        except filelock.Busy:
            return 'busy'

    def test_shared_coexist_exclusive_waits(self):
        a = self.hold('execution', True, dict(taskId='a', operation='launch'))
        b = self.hold('execution', True, dict(taskId='b', operation='build'))
        self.assertEqual(self.try_held('execution', True), 'acquired')    # 第三个共享方也拿得到
        self.assertEqual(self.try_held('execution', False), 'busy')       # 独占要等两个共享方都放
        self.release(a)
        self.assertEqual(self.try_held('execution', False), 'busy')
        self.release(b)
        self.assertEqual(self.try_held('execution', False), 'acquired')

    def test_exclusive_blocks_shared(self):
        p = self.hold('execution', False, dict(taskId='d', operation='delete'))
        self.assertEqual(self.try_held('execution', True), 'busy')
        self.release(p)
        self.assertEqual(self.try_held('execution', True), 'acquired')

    def test_holder_records_per_shared_party_and_cleanup(self):
        import filelock
        lock = self.dir / '.execution.lock'
        a = self.hold('execution', True, dict(taskId='a', operation='launch'))
        b = self.hold('execution', True, dict(taskId='b', operation='build'))
        self.assertEqual(sorted(filelock._read(f)['taskId'] for f in filelock.shared_holders(lock)), ['a', 'b'])
        self.assertIn(filelock.read_holder(lock)['taskId'], ('a', 'b'))   # 独占方等的时候说得出在等谁
        with self.assertRaises(filelock.Busy) as e:
            with filelock.held(lock, wait_s=0.2, poll=0.05):
                pass
        self.assertIn(e.exception.holder.get('taskId'), ('a', 'b'))
        self.release(a)
        self.assertEqual([filelock._read(f)['taskId'] for f in filelock.shared_holders(lock)], ['b'])   # 放锁只删自己那份
        b.kill(); b.wait(timeout=5)   # 崩溃：共享记录留下
        self.assertEqual(len(filelock.shared_holders(lock)), 1)
        with filelock.held(lock, holder=dict(taskId='c')):   # 独占拿到 = 共享方都不在：留下的记录清掉
            self.assertEqual(filelock.shared_holders(lock), [])
            self.assertEqual(filelock.read_holder(lock)['taskId'], 'c')
        # 独占崩溃留下的记录：共享方拿到时清掉（这时不可能有活着的独占方）
        filelock.holder_path(lock).write_text('{"taskId": "dead"}', encoding='utf-8')
        with filelock.held(lock, holder=dict(taskId='s'), shared=True):
            self.assertFalse(filelock.holder_path(lock).exists())
            self.assertEqual(filelock.read_holder(lock)['taskId'], 's')

    def context(self, gid):
        c = object.__new__(self.core.Context)
        c.library, c.lock_wait, c.task, c.operation, c.r = self.dir, 0.3, 't1', 'build', {'gameId': gid}
        return c

    def produce(self, gid):
        import build
        c = self.context(gid)
        with patch.object(c, 'check'), patch.object(c, 'require_library'):
            try:
                with build.produce_locks(c):
                    return 'acquired'
            except self.core.Failure as e:
                return e.code

    def test_produce_runs_beside_other_game_but_waits_for_same_game_and_other_build(self):
        # 期望：H 在玩（执行锁共享 + H 的按款锁）→ 出 G 照样拿得到；G 在玩 → 出 G 等到上限报 library_busy；
        #   别的出包拿着出包锁 → 等；全库独占动作（删除）拿着执行锁 → 等
        h = self.hold('execution', True); hg = self.hold('sgrade-0100000000000002', False)
        self.assertEqual(self.produce('0100000000000001'), 'acquired')
        g = self.hold('sgrade-0100000000000001', False, dict(taskId='p', operation='launch'))
        self.assertEqual(self.produce('0100000000000001'), 'library_busy')
        self.release(g)
        other = self.hold('produce', False, dict(taskId='o', operation='ipa'))
        self.assertEqual(self.produce('0100000000000001'), 'library_busy')
        self.release(other); self.release(h); self.release(hg)
        d = self.hold('execution', False, dict(taskId='d', operation='delete'))
        self.assertEqual(self.produce('0100000000000001'), 'library_busy')
        self.release(d)
        self.assertEqual(self.produce('0100000000000001'), 'acquired')
