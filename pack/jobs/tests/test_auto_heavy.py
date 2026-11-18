# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""打开启动器时自动起的后台重活（main.AUTO_HEAVY：installUpdatePrepare、sgradeMac；#1439 / #1442 / #1443）。期望按规则手写：
① 跑的时候拿着游戏库的 auto-heavy 锁，别的作业不拿；② 锁被另一项自动任务占着时排队，对方放了才开始（串行）；
③ 只有这两项降优先级；④ 降优先级是真的：本进程 nice 19，之后起的子进程也是 19"""
import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from jobcase import JobCase
from core import atomic
import filelock
import main

JOBS = Path(main.__file__).resolve().parent


class AutoHeavyTests(JobCase):
    def run_op(self, op, fn, task=None):
        path = self.root / ("req-" + (task or op) + ".json")
        atomic(path, self.request | dict(taskId=task or ("auto-" + op), operation=op))
        with patch("library.store_meta_background"), patch("embedded.install"), patch("layout.heal_folder_names"), \
                patch.object(main, "background_priority"):
            return main.run_request(path, operation_overrides={op: fn})

    def lock_path(self):
        return Path(self.request["library"]) / ".auto-heavy.lock"

    def held_by_other(self):
        try:
            with filelock.held(self.lock_path(), wait_s=0):
                return False
        except filelock.Busy:
            return True

    def test_auto_tasks_hold_the_lock_others_do_not(self):
        seen = []
        def probe(c):
            seen.append((c.operation, self.held_by_other()))
            return {}
        for op in ("installUpdatePrepare", "sgradeMac", "ipa", "catalog"):
            self.assertEqual(self.run_op(op, probe), 0)
        self.assertEqual(seen, [("installUpdatePrepare", True), ("sgradeMac", True), ("ipa", False), ("catalog", False)])
        self.assertFalse(self.held_by_other())   # 跑完放开

    def test_second_auto_task_waits_for_the_first(self):
        # 另一项自动任务（线程里模拟）拿着锁 1.5 秒；这边的 sgradeMac 要等它放了才开始
        released, started = [], []
        ready = threading.Event()
        def other():
            with filelock.held(self.lock_path(), holder={"taskId": "first", "operation": "installUpdatePrepare"}):
                ready.set(); time.sleep(1.5); released.append(time.monotonic())
        t = threading.Thread(target=other); t.start(); ready.wait(5)
        self.assertEqual(self.run_op("sgradeMac", lambda c: started.append(time.monotonic()) or {}), 0)
        t.join()
        self.assertEqual(len(started), 1)
        self.assertGreaterEqual(started[0], released[0])

    def test_only_auto_tasks_lower_priority(self):
        calls = []
        for op in ("installUpdatePrepare", "sgradeMac", "ipa", "build"):
            path = self.root / ("req-p-" + op + ".json")
            atomic(path, self.request | dict(taskId="p-" + op, operation=op))
            with patch("library.store_meta_background"), patch("embedded.install"), patch("layout.heal_folder_names"), \
                    patch.object(main, "background_priority", lambda op=op: calls.append(op)):
                main.run_request(path, operation_overrides={op: lambda c: {}})
        self.assertEqual(calls, ["installUpdatePrepare", "sgradeMac"])

    @unittest.skipUnless(hasattr(__import__("os"), "nice"), "没有 nice（Windows）")
    def test_background_priority_is_inherited_by_children(self):
        code = ("import sys, os, subprocess; sys.path.insert(0, sys.argv[1]); import main; main.background_priority(); "
                "print(os.nice(0), subprocess.run(['ps', '-o', 'nice=', '-p', str(os.getpid())], capture_output=True, text=True).stdout.strip(), "
                "subprocess.run(['/bin/sh', '-c', 'ps -o nice= -p $$'], capture_output=True, text=True).stdout.strip())")
        out = subprocess.run([sys.executable, "-c", code, str(JOBS)], capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr[-400:])
        self.assertEqual(out.stdout.split(), ["19", "19", "19"])


class AutoListSameAsLauncherTests(unittest.TestCase):
    def test_launcher_list_matches_auto_heavy(self):
        # 「自动任务」一处概念两端用：Mac 启动器 JobTrigger.automaticOperations（不开 userInitiated、进程按 utility）与作业层 AUTO_HEAVY（串行、低优先级）。
        #   名单不一致 = 一边按自动任务让路、另一边不让 → 红。读 Swift 那一行字面量（逗号后可有空格），不跑被测代码推期望
        import re
        src = (JOBS.parents[1] / "launchers/macos/adapter/Sources/S2ArmAppleAdapter/JobProcess.swift").read_text(encoding="utf-8")
        m = re.search(r"automaticOperations\s*:\s*Set<String>\s*=\s*\[(.*?)\]", src)
        self.assertIsNotNone(m, "JobProcess.swift 里找不到 automaticOperations 的字面量")
        swift = {x.strip().strip('"') for x in m.group(1).split(",") if x.strip()}
        self.assertEqual(swift, set(main.AUTO_HEAVY))


if __name__ == "__main__":
    unittest.main()
