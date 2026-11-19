# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""系统附属文件不是业务输入（#812 #816 #911 #1010 #369 #382 同一类）：游戏库 / 数据目录 / mod / 金手指 / 导出文件夹放在 exFAT / FAT 上时，
macOS 给每个带扩展属性的文件配一份 ._<名>（4 KB AppleDouble，头 00 05 16 07，含 NUL、非 UTF-8），访达写 .DS_Store，资源管理器写 desktop.ini。
这些读到一律按「不存在」处理。夹具照 exFAT 的样子：每个真文件旁边都放一份 ._<名>。期望按规则手写"""
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))
sys.path.insert(0, str(JOBS / "tests"))
import cheats
import core
import install
import layout
import mods
import test_cheats
from test_cheats import BID, TEXT

APPLEDOUBLE = b"\x00\x05\x16\x07\x00\x02\x00\x00Mac OS X        " + b"\x00\xb0" * 2040   # 4096 字节，非 UTF-8


def with_sidecars(root):
    """照 exFAT：root 下每个文件 / 目录旁边补一份 ._<名>，每级目录放一份 .DS_Store"""
    root = Path(root)
    for p in sorted(root.rglob("*"), reverse=True):
        (p.parent / ("._" + p.name)).write_bytes(APPLEDOUBLE)
    for d in [root, *(p for p in root.rglob("*") if p.is_dir())]:
        (d / ".DS_Store").write_bytes(b"\x00\x00\x00\x01Bud1")


class Entries(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.d, True)

    def test_flat_and_recursive_skip_sidecars_at_any_level(self):
        (self.d / "a.json").write_text("{}")
        (self.d / "romfs" / "Model").mkdir(parents=True)
        (self.d / "romfs" / "Model" / "x.bfres").write_bytes(b"x")
        with_sidecars(self.d)
        self.assertEqual([p.name for p in layout.entries(self.d, "*.json")], ["a.json"])
        self.assertEqual([p.relative_to(self.d).as_posix() for p in layout.entries(self.d, recursive=True)],
                         ["a.json", "romfs", "romfs/Model", "romfs/Model/x.bfres"])

    def test_missing_dir_is_empty(self):
        self.assertEqual(layout.entries(self.d / "none", "*.json"), [])


class Mods(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.d, True)
        (self.d / "exefs").mkdir()
        (self.d / "exefs" / "60fps.pchtxt").write_text("@nsobid-0\n")
        (self.d / "romfs").mkdir()
        (self.d / "romfs" / "a.bin").write_bytes(b"a")

    def test_sidecar_patches_are_not_compiled_in(self):
        with_sidecars(self.d)
        self.assertEqual([p.name for p in mods._code_files(self.d / "exefs")], ["60fps.pchtxt"])

    def test_fingerprint_ignores_sidecars(self):
        before = mods.fingerprint(self.d)
        with_sidecars(self.d)
        self.assertEqual(mods.fingerprint(self.d), before, "访达在外置盘上生灭附属文件，不该让 mod 记号变、每次装机整份重推")


class ExportImgs(unittest.TestCase):
    def test_sidecar_img_is_not_a_game(self):
        d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d, True)
        (d / "Game.img").write_bytes(b"S2AIMG01" + b"\0" * 8 + b"0100000000010000" + b"\0" * 16)
        with_sidecars(d)
        self.assertEqual([p.name for p in install._full_imgs(d)], ["Game.img"])


class JobStatus(unittest.TestCase):
    def test_sidecar_records_are_not_invalid(self):
        d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d, True)
        jobs = core.jobs_dir(d)
        jobs.mkdir(parents=True)
        (jobs / "t1.json").write_text(json.dumps(dict(schema=1, id="t1", operation="ipa", state="succeeded", ended=1)))
        with_sidecars(jobs)
        self.assertEqual(core.status(d)["invalidRecords"], [])


class Cheats(test_cheats.CheatsTests):
    def test_sidecar_txt_is_not_a_cheat(self):
        self.d.mkdir(parents=True, exist_ok=True)
        (self.d / f"{BID}.txt").write_text(TEXT)
        with_sidecars(self.d)
        self.assertEqual({it["file"] for it in cheats.listing(self.c, self.game)["items"]}, {f"{BID}.txt"})


for name in [n for n in vars(test_cheats.CheatsTests) if n.startswith("test_")]:   # 只跑本文件新加的，不把 test_cheats 的全量再跑一遍
    setattr(Cheats, name, None)


if __name__ == "__main__":
    unittest.main()
