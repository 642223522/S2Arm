#!/usr/bin/env python3
"""#1126：每局结束把系统应用登记里的 S2ArmGame.app 全部注销（启动台不再出灰色「S2ArmGame」）。
   用假 lsregister：-dump 吐固定登记表，-u 把路径记进文件；期望注销清单按登记表手写。"""
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

import jobcase  # noqa: F401  同目录用例的导入路径（pack/jobs）由它设好
import host_update

DUMP = """\
--------------------------------------------------------------------------------
bundle id:                  Contents/Info.plist (0x1a20)
path:                       /srv/Game Disk/S2Arm/hosts/mac/cff558f9c04b/S2ArmGame.app (0x1a20)
name:                       S2Arm Game
--------------------------------------------------------------------------------
path:                       /srv/Game Disk/Application Support/S2Arm/游戏库/games/0100AAAA00000000/releases/ab12/S2ArmGame.app (0x1a2c)
--------------------------------------------------------------------------------
path:                       /Applications/S2Arm.app (0x0100)
--------------------------------------------------------------------------------
path:                       /srv/Game Disk/S2Arm/hosts/mac/cff558f9c04b/S2ArmGame.app (0x1b00)
--------------------------------------------------------------------------------
path:                       /Applications/Other Game.app (0x0200)
"""


@unittest.skipUnless(sys.platform == "darwin", "只在 Mac 上做")
class ForgetRegistrations(unittest.TestCase):

    def test_unregisters_every_s2armgame_path_and_nothing_else(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "dump.txt").write_text(DUMP, encoding="utf-8")
            fake = d / "lsregister"
            fake.write_text(f'#!/bin/bash\nif [ "$1" = -dump ]; then cat "{d}/dump.txt"; else printf "%s\\n" "$*" >> "{d}/calls.txt"; fi\n', encoding="utf-8")
            fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
            host_update.forget_registrations(str(fake), wait=True)
            calls = sorted((d / "calls.txt").read_text(encoding="utf-8").splitlines())
        self.assertEqual(calls, sorted([
            "-u /srv/Game Disk/S2Arm/hosts/mac/cff558f9c04b/S2ArmGame.app",
            "-u /srv/Game Disk/Application Support/S2Arm/游戏库/games/0100AAAA00000000/releases/ab12/S2ArmGame.app",
        ]))

    def fake_lsregister(self, d, body):
        fake = Path(d) / "lsregister"
        fake.write_text("#!/bin/bash\n" + body, encoding="utf-8")
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        return str(fake)

    def test_fake_host_without_info_plist_never_reaches_lsregister(self):
        # 11-15：单测起局的假宿主只有可执行文件（系统不会登记它），不许打到登记库；真包（带 Info.plist）照常注销
        with tempfile.TemporaryDirectory() as d:
            mark = Path(d) / "called"
            fake = self.fake_lsregister(d, f'touch "{mark}"\n')
            app = Path(d) / "S2ArmGame.app"; (app / "Contents/MacOS").mkdir(parents=True)
            self.assertIsNone(host_update.forget_registrations(fake, wait=True, app=app))
            self.assertFalse(mark.exists())
            (app / "Contents/Info.plist").write_text("<plist/>")
            self.assertIsNotNone(host_update.forget_registrations(fake, wait=True, app=app))
            self.assertTrue(mark.exists())

    def test_only_one_runs_at_a_time(self):
        # 11-15 门禁机 38 个 -dump 同时跑：上一个没跑完，这次跳过、不叠
        with tempfile.TemporaryDirectory() as d:
            go = Path(d) / "go"
            fake = self.fake_lsregister(d, f'while [ ! -e "{go}" ]; do sleep 0.05; done\n')
            first = host_update.forget_registrations(fake)
            try:
                self.assertIsNotNone(first)
                self.assertIsNone(host_update.forget_registrations(fake), "上一个还在跑")
            finally:
                go.touch(); first.wait()
            again = host_update.forget_registrations(fake, wait=True)
            self.assertIsNotNone(again, "跑完放锁，下一局照常")

    def test_missing_lsregister_does_nothing(self):
        self.assertIsNone(host_update.forget_registrations("/nonexistent/lsregister", wait=True))


if __name__ == "__main__":
    unittest.main()
