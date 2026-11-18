# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""S 级升级的资源上限（upgrade_budget）与取消（界面「批量升级所选」逐款排队起单款作业 sgradeUpgradeGame，同一时刻只一款）。期望按规则手写，不跑被测实现推：
③ 取消：正做的那款标记留着（= 未完成），取消照常往外抛
④ 并行度：核数上限 = 物理核一半；内存预算 = 可用内存一半，重活每路 1.5 GB、文件级每路 0.5 GB；可用内存降 → 路数降；有游戏在运行 → 1 路
⑤ 作业环境：升级作业起子进程带上算好的 S2A_JOBS / S2A_CPU_BAKE；execution 锁有人拿着（玩家在玩）→ 1；别的作业不带
⑥ 优先级：升级作业降到后台档，且不拿自动任务锁"""
import contextlib
import json
import os
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import jobcase
from jobcase import JobCase
import filelock
import layout
import sgrade
import upgrade_budget
from core import Cancelled, Failure


class CancelTests(unittest.TestCase):
    def test_cancel_keeps_marker(self):
        # 单款升级做到 iPhone 段时被取消（适配层 SIGTERM → core 置取消，下一次 emit / run 抛 Cancelled）：标记留着 = 未完成，取消照常往外抛
        import tempfile
        t = Path(tempfile.mkdtemp()); self.addCleanup(__import__("shutil").rmtree, t, True)
        (t / "0100A").mkdir()
        c = types.SimpleNamespace(r={"gameId": "0100A"}, task="s1", logs=t, emit=lambda *a, **k: None, begin=lambda *a, **k: None,
                                  idle=lambda name: contextlib.nullcontext(True))
        def ios(c, games):
            raise Cancelled()
        import ipa, rewrite_refresh
        with patch.object(layout, "game_dir", lambda c, g: t / g.upper()), patch.object(layout, "image_mac", lambda c, g, create=True: t / "none"), \
             patch.object(layout, "has_ios_kit", lambda c, g: True), patch.object(ipa, "program_locks", lambda c, games: contextlib.nullcontext()), \
             patch.object(rewrite_refresh, "refresh_ios", ios):
            with self.assertRaises(Cancelled):
                sgrade.upgrade_game(c)
        m = json.loads((t / "0100A" / sgrade.UPGRADING).read_text())
        self.assertEqual((m["task"], m["pid"]), ("s1", os.getpid()), "进程退出后 pid 不在 → upgrade_state = incomplete（test_sgrade.test_upgrade_state）")


class BudgetPlanTests(unittest.TestCase):
    def test_plan(self):
        P = lambda cores, mb, busy=False: (lambda p: (p["cap"], p["budgetMb"], p["jobs"], p["bake"]))(upgrade_budget.plan(cores, mb, busy))
        self.assertEqual(P(8, 16384), (4, 8192, 4, 4))     # 16 GB 机器空着：8192 ÷ 1536 = 5 → 封在核数上限 4
        self.assertEqual(P(8, 8192), (4, 4096, 4, 2))      # 4096 ÷ 1536 = 2
        self.assertEqual(P(8, 4096), (4, 2048, 4, 1))      # 8 GB 机器常见可用：重活 1 路
        self.assertEqual(P(8, 2048), (4, 1024, 2, 1))      # 再紧：文件级 1024 ÷ 512 = 2
        self.assertEqual(P(8, 600), (4, 300, 1, 1))        # 下限 1
        self.assertEqual(P(16, 65536), (8, 32768, 8, 8))
        self.assertEqual(P(1, 65536), (1, 32768, 1, 1))
        self.assertEqual(P(8, 16384, True)[2:], (1, 1), "有游戏在运行：都降到 1")
        p = upgrade_budget.plan(8, None)
        self.assertEqual((p["jobs"], p["bake"]), (2, 1), "读不到内存：核数上限再减半、重活 1 路")

    def test_available_override(self):
        with patch.dict(os.environ, {"S2A_MEM_AVAIL_MB": "4096"}):
            self.assertEqual(upgrade_budget.available_mb(), 4096)

    def test_available_real_machine(self):
        mb = upgrade_budget.available_mb()
        if sys.platform in ("darwin", "win32", "linux"):
            self.assertIsNotNone(mb, "本机读得到可用内存")
            self.assertGreater(mb, 0)
        self.assertGreaterEqual(upgrade_budget.physical_cores(), 1)


class BudgetEnvTests(JobCase):
    def env(self, op):
        self.c.operation = op
        return self.c.env()

    def test_upgrade_env_follows_memory_and_play(self):
        with patch.object(upgrade_budget, "physical_cores", return_value=8):
            with patch.dict(os.environ, {"S2A_MEM_AVAIL_MB": "4096"}):
                e = self.env("sgradeUpgradeGame")
                self.assertEqual((e["S2A_JOBS"], e["S2A_CPU_BAKE"]), ("4", "1"))
            with patch.dict(os.environ, {"S2A_MEM_AVAIL_MB": "16384"}):
                e = self.env("sgradeUpgradeGame")
                self.assertEqual((e["S2A_JOBS"], e["S2A_CPU_BAKE"]), ("4", "4"), "可用内存回来了，下一个阶段路数跟着回来")
                with filelock.held(Path(self.c.library) / ".execution.lock", holder={"taskId": "play", "operation": "launch"}):
                    e = self.env("sgradeUpgradeGame")
                self.assertEqual((e["S2A_JOBS"], e["S2A_CPU_BAKE"]), ("1", "1"), "玩家在玩：降到 1 路")
                e = self.env("ipa")
                self.assertNotIn("S2A_CPU_BAKE", e, "别的作业不带（出包仍按 tools/cores.sh / 阶段脚本自己定）")
        log = (self.c.logs / f"{self.c.task}-decisions.log").read_text(encoding="utf-8")
        self.assertIn("有游戏在运行", log)


class PriorityTests(JobCase):
    def test_upgrade_ops_lower_priority_without_auto_lock(self):
        import main
        from core import atomic
        calls, held = [], []
        def probe(c):
            try:
                with filelock.held(Path(self.request["library"]) / ".auto-heavy.lock", wait_s=0):
                    held.append(False)
            except filelock.Busy:
                held.append(True)
            return {}
        for op in ("sgradeUpgradeGame", "catalog"):
            path = self.root / ("req-" + op + ".json")
            atomic(path, self.request | dict(taskId="p-" + op, operation=op))
            with patch("library.store_meta_background"), patch("embedded.install"), patch("layout.heal_folder_names"), \
                    patch.object(main, "background_priority", lambda op=op: calls.append(op)):
                main.run_request(path, operation_overrides={op: probe})
        self.assertEqual(calls, ["sgradeUpgradeGame"])
        self.assertEqual(held, [False, False], "玩家点的升级不排在自动任务锁后面")


if __name__ == "__main__":
    unittest.main()
