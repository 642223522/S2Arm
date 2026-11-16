# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""游戏程序专用文件夹（layout.program_store：默认位置根 .programs/<程序号>/）：玩家删了游戏文件夹 / 释放了 iPhone 包，更新 S2Arm 时照样带得上这款。
期望按规格手写：
  ① 出包存的程序件（save_container_kit）、原始程序（sgrade.save_program）、兼容记录（update_info 的 ios）都落在专用文件夹，不在游戏文件夹里
  ② 整个游戏文件夹删掉后：程序件还在、兼容记录读得到，usable_kit 照样认（本壳出的直接用）
  ③ 旧库的 image/ios/kit、original-exefs 第一次用到时搬进专用文件夹，内容不变、旧位置不再有
  ④ 释放空间的「已出好的 iPhone 包」只列资源包，不列程序件"""
import os
from pathlib import Path
import shutil
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import ipa
import layout
import library
import sgrade

GID = "0100000000010000"


class ProgramStoreTests(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(prefix="s2arm programs ")
        self.addCleanup(t.cleanup)
        self.root = Path(t.name)
        self.c = SimpleNamespace(library=self.root / "library", work_root=self.root / "work")
        self.c.library.mkdir()
        self.store = self.c.library / ".programs" / GID

    def product(self):
        root = self.root / "product"
        (root / "ctl").mkdir(parents=True)
        for n in ("main.npdm", "main.fixups.tsv", "main.patched.bin", "ctl/control.nacp"):
            (root / n).write_bytes(n.encode())
        return root

    def exefs(self):
        d = self.root / "exefs"; d.mkdir(exist_ok=True)
        (d / "main").write_bytes(bytes(0x60) + b"main"); (d / "main.npdm").write_bytes(b"npdm"); (d / "sdk").write_bytes(b"sdk")
        return d

    def test_outputs_land_in_the_store(self):
        kit = library.save_container_kit(self.c, GID, self.product())
        self.assertEqual(kit, self.store / "kit")
        self.assertEqual(sgrade.save_program(self.c, GID, self.exefs()), self.store / "original-exefs")
        layout.update_info(self.c, GID, ios=dict(shellId="S1", hostAbi=3))
        self.assertEqual(layout.read(self.store / "ios.json", {}), dict(shellId="S1", hostAbi=3))
        game = layout.find_game(self.c, GID)
        self.assertFalse((game / "image" / "ios" / "kit").exists())
        self.assertFalse((game / "original-exefs").exists())

    def test_game_folder_deleted_kit_still_usable(self):
        library.save_container_kit(self.c, GID, self.product())
        sgrade.save_program(self.c, GID, self.exefs())
        layout.update_info(self.c, GID, ios=dict(shellId="S1"))
        shutil.rmtree(layout.find_game(self.c, GID))   # 玩家在访达里把整款文件夹（含资源包）删了
        self.assertIsNone(layout.find_game(self.c, GID))
        self.assertEqual(Path(ipa.usable_kit(self.c, GID, "S1")).resolve(), (self.store / "kit").resolve())
        self.assertEqual(sgrade.saved_program(self.c, GID), self.store / "original-exefs")

    def test_legacy_locations_move_into_the_store(self):
        game = layout.game_dir(self.c, GID)
        old_kit, old_exefs = game / "image" / "ios" / "kit", game / "original-exefs"
        old_kit.mkdir(parents=True); (old_kit / "main.npdm").write_bytes(b"old-kit")
        old_exefs.mkdir(); (old_exefs / "main").write_bytes(b"old-main"); (old_exefs / "main.npdm").write_bytes(b"n")
        self.assertEqual(layout.ios_kit(self.c, GID), self.store / "kit")
        self.assertEqual((self.store / "kit" / "main.npdm").read_bytes(), b"old-kit")
        self.assertFalse(old_kit.exists())
        self.assertEqual(sgrade.saved_program(self.c, GID), self.store / "original-exefs")
        self.assertEqual((self.store / "original-exefs" / "main").read_bytes(), b"old-main")
        self.assertFalse(old_exefs.exists())

    def test_free_space_ipa_part_is_only_the_pack(self):
        library.save_container_kit(self.c, GID, self.product())
        pack = layout.image_ios(self.c, GID) / ".pack"; pack.mkdir(parents=True); (pack / "manifest.json").write_text("{}")
        self.assertEqual(library.space_parts(self.c, GID)["ipa"], [pack])


if __name__ == "__main__":
    unittest.main()
