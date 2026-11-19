# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""游戏库封面金色 S（pack/jobs/library.py sgrade_badge）：只认真打进去了的——Mac 运行版本 / iPhone 程序件里补丁表有条目，或带着随包金手指原文 → 亮；
补丁库里有这款的包但还没打进去（没出过包 / 还没补）、或出包页取消过「出包时打入」→ 不亮（11-14：原先「库里有包就亮」，没出过包的款也亮了）。期望手写。
另：主程序构建号在解包目录删了以后照样取得到（cheats.main_build：Mac 运行版本 / 存下的原始程序 / iPhone 记的 mainBid）"""
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import jobcase  # noqa: F401
import build
import cheats
import layout
import library
from core import Failure


class SGradeBadgeTests(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.c = types.SimpleNamespace(private=self.t, r={})
        self.img = self.t / "img"; self.img.mkdir(); self.kit = self.t / "kit"; self.kit.mkdir()
        self.info = {}
        for p in (patch.object(layout, "game_info", side_effect=lambda c, g: self.info), patch.object(layout, "ios_kit", return_value=self.kit),
                  patch.object(layout, "ios_kit_present", return_value=self.kit)):   # 金色 S 只读已有的程序件（清单里不迁移）
            p.start(); self.addCleanup(p.stop)

    def test_badge_only_when_applied(self):
        self.assertFalse(library.sgrade_badge(self.c, "0100AAAA00000000", self.img), "什么都没打进去（库里有没有包都不看）")
        (self.kit / "cpatch.tsv").write_text("编号\n")
        self.assertFalse(library.sgrade_badge(self.c, "0100AAAA00000000", self.img), "只有表头的补丁表不算")
        (self.kit / "cpatch.tsv").write_text("编号\nwsauto:x:w\n")
        self.assertTrue(library.sgrade_badge(self.c, "0100AAAA00000000", self.img), "iPhone 程序件里打进了补丁")
        (self.kit / "cpatch.tsv").unlink(); (self.img / "cheat-src.AABBCCDD00112233.txt").write_text("[x]\n04000000 0 1\n")
        self.assertTrue(library.sgrade_badge(self.c, "0100AAAA00000000", self.img), "Mac 运行版本带着随包金手指原文（只改内存，不进补丁表）")
        self.info["sgradeOff"] = True
        self.assertFalse(library.sgrade_badge(self.c, "0100AAAA00000000", self.img), "出包页取消过：不亮")

    def test_main_build_after_extract_removed(self):
        # 解包目录不在：Mac 运行版本 exefs/main 头 0x40 = AA..；没有 Mac 版 → iPhone 记的 mainBid
        mac = self.t / "mac"; (mac / "exefs").mkdir(parents=True)
        b = bytearray(0x100); b[0x40:0x48] = bytes.fromhex("1122334455667788"); (mac / "exefs/main").write_bytes(bytes(b))
        def no_extract(c, g): raise Failure("没解过包")
        with patch.object(build, "shared_dir", side_effect=no_extract), patch.object(layout, "image_mac", return_value=mac), \
             patch.object(layout, "path", side_effect=lambda c, g, *p, create=True: self.t / "nogame" / "/".join(p)), \
             patch.object(layout, "program_exefs", side_effect=lambda c, g: self.t / "nogame" / "original-exefs"):
            self.assertEqual(cheats.main_build(self.c, {"id": "0100AAAA00000000"}), "1122334455667788")
            (mac / "exefs/main").unlink(); self.info["ios"] = {"mainBid": "99aabbccddeeff00"}
            self.assertEqual(cheats.main_build(self.c, {"id": "0100AAAA00000000"}), "99AABBCCDDEEFF00")
            self.info.clear()
            self.assertEqual(cheats.main_build(self.c, {"id": "0100AAAA00000000"}), "", "都没有：真没解过包")


if __name__ == "__main__":
    unittest.main()
