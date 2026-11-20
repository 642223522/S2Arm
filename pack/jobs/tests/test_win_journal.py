# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""#245 / #561 journal_write_failed：长任务里作业重写 jobs/<任务>.json 时，启动器正好在读它（ControlPort.Tasks 每秒轮询，带 FileShare.Delete）。
os.replace = MoveFileExW 旧语义：目标还开着就报「拒绝访问。」，1.57 秒退避只能压低概率。
根修是写端 POSIX 语义替换 + 本仓读方带共享删除；这里在真 Windows 上（CI windows-cleanup 工作流）证明：
读方句柄开着的时候，作业照样能替换记录，读方读到的是替换前的完整一份。Mac / Linux 上跳过（POSIX 本来就允许）。"""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))
import core
import winproc


@unittest.skipUnless(os.name == "nt", "needs a real Windows host (CI: windows-cleanup.yml)")
class ReplaceWhileLauncherReads(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.job = Path(self.tmp.name, "jobs", "win-x.json")
        core.atomic(self.job, {"seq": 1})

    def launcher_reader(self):
        """照启动器 ControlPort.Tasks 打开：只读、共享读写删"""
        import msvcrt
        handle = winproc._open_shared(self.job, winproc._GENERIC_READ)
        return os.fdopen(msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY), "rb")

    def test_record_replaced_while_reader_holds_it(self):
        sleeps = []
        with mock.patch.object(core.time, "sleep", sleeps.append):
            with self.launcher_reader() as held:
                for seq in range(2, 202):   # 长任务：几百次重写都撞在同一个读方句柄上（旧语义下每一次都要退避到底再报拒绝访问）
                    core.atomic(self.job, {"seq": seq})
                self.assertEqual(json.loads(held.read()), {"seq": 1}, "读方句柄继续读到替换前的完整一份")
        self.assertLess(len(sleeps), 10, "读方句柄不该再触发退避（偶发几次只能是杀毒 / 索引的短暂占用）")
        self.assertEqual(core.read(self.job), {"seq": 201})
        self.assertEqual(sorted(p.name for p in self.job.parent.iterdir()), ["win-x.json"], "没有残留临时文件")

    def test_core_read_does_not_block_writer(self):
        real = winproc._open_shared
        def reader_stays_open(path, access, flags=0x80):
            handle = real(path, access, flags)
            if access == winproc._GENERIC_READ:   # 读的同时作业替换一次：读方带共享删除才换得了
                core.atomic(self.job, {"seq": 2})   # 旧读法（不带共享删除）下这里退避 1.57 秒后抛 PermissionError
            return handle
        with mock.patch.object(winproc, "_open_shared", reader_stays_open):
            self.assertEqual(core.read(self.job), {"seq": 1})
        self.assertEqual(core.read(self.job), {"seq": 2})

    def test_legacy_replace_is_what_failed(self):
        """记录根因：旧语义 MoveFileExW 遇到同一个读方报拒绝访问（新系统若已改成 POSIX 语义，只打印不判红）"""
        tmp = self.job.with_name("legacy.tmp")
        tmp.write_text("{}")
        with self.launcher_reader():
            try:
                os.replace(tmp, self.job)
                print("\nnote: os.replace succeeded over an open share-delete reader on this Windows build")
            except PermissionError as error:
                self.assertIn(getattr(error, "winerror", None), (5, 32))
        tmp.unlink(missing_ok=True)


class ReplaceFallback(unittest.TestCase):
    """卷不支持 POSIX 语义（FAT / exFAT、老系统）→ 回落 os.replace；别的错误照抛给外层退避。任何平台都跑"""
    def run_case(self, winerror):
        calls = []
        def posix(src, dst):
            calls.append("posix")
            error = OSError(13, "x"); error.winerror = winerror; raise error
        with mock.patch.object(winproc, "_rename_posix", posix), \
                mock.patch.object(winproc.os, "replace", lambda a, b: calls.append("legacy")):
            try:
                winproc.replace_file("a", "b")
            except OSError as error:
                calls.append(error.winerror)
        return calls

    def test_unsupported_volume_falls_back(self):
        for code in (1, 50, 87):
            self.assertEqual(self.run_case(code), ["posix", "legacy"])

    def test_access_denied_is_not_masked(self):
        self.assertEqual(self.run_case(5), ["posix", 5])


if __name__ == "__main__":
    unittest.main()
