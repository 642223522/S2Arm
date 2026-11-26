# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""exFAT / FAT 盘上 macOS 把扩展属性存成同目录的 AppleDouble 附属文件 ._<名>（#1529 同类）：按后缀收文件的地方不能把它算进去。
期望手写：金手指摘要有没有旁边的 ._x.txt 都一样；ipa 解开后 Payload 里同时有 S2Arm.app 目录与 ._S2Arm.app 文件时取到的是目录。"""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))
import cheats  # noqa: E402
import layout  # noqa: E402
import rewrite_refresh  # noqa: E402


class AppleDouble(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(__import__("shutil").rmtree, self.t, True)

    def test_cheats_digest_ignores_appledouble(self):
        d = self.t / "cheats"; d.mkdir()
        (d / "inf.txt").write_text("[无限血]\n04000000 00000000\n", encoding="utf-8")
        with patch.object(cheats, "cheats_dir", lambda c, gid, create=False: d):
            before = rewrite_refresh.cheats_digest(None, "0100000000010000")
            (d / "._inf.txt").write_bytes(b"\x00\x05\x16\x07" + b"\x00" * 60)
            self.assertEqual(rewrite_refresh.cheats_digest(None, "0100000000010000"), before)
            (d / "._only.txt").write_bytes(b"\x00\x05\x16\x07")
            (d / "inf.txt").unlink()
            self.assertEqual(rewrite_refresh.cheats_digest(None, "0100000000010000"), "-", "只剩附属文件 = 没有金手指")

    def test_payload_app_pick_skips_appledouble(self):
        pay = self.t / "Payload"; pay.mkdir()
        (pay / "._S2Arm.app").write_bytes(b"\x00\x05\x16\x07")
        (pay / "S2Arm.app").mkdir()
        self.assertEqual(next(iter(layout.entries(pay, "*.app")), None), pay / "S2Arm.app")


if __name__ == "__main__":
    unittest.main()
