# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""0.6.0 通用壳「导出通用 S2Arm.ipa」（pack/jobs/install.py export_shell_ipa，经 export_phone(c, None)）：只有壳、不带游戏，
写进「S2Arm 游戏包」文件夹。游戏库是真的（library.setup），组壳用替身（写一个带小组件扩展的假 ipa），期望按替身写的内容手写。"""
import sys
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install  # noqa: E402
import ipa as packer  # noqa: E402
import program_pack  # noqa: E402
import tests.test_jobs as tj  # noqa: E402

APP = "Payload/S2Arm.app/S2Arm"
WIDGET = "Payload/S2Arm.app/PlugIns/Widget.appex/Widget"


class ShellIpaExport(unittest.TestCase):
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown

    def fake_shell(self, c, *, dest=None):
        Path(dest).mkdir(parents=True, exist_ok=True)
        ipa = Path(dest) / "S2Arm.ipa"
        with zipfile.ZipFile(ipa, "w") as z:
            z.writestr(APP, b"shell")
            z.writestr(WIDGET, b"widget")
        self.assembled += 1
        return ipa, [], "SHELL1"

    def export(self, on=True, shell=None):
        self.assembled = 0
        def no_catalog():
            raise AssertionError("导出通用 ipa 不读游戏库")
        self.c.catalog = no_catalog
        self.c.r.update(mode="export")
        with patch.object(program_pack, "enabled", lambda c: on), patch.object(packer, "assemble_shell", shell or self.fake_shell), \
                patch.object(install, "patches_results", lambda c: []):
            return install.export_phone(self.c)

    def names(self, p):
        with zipfile.ZipFile(p) as z:
            return sorted(z.namelist())

    def test_shell_only_ipa_into_game_packs_folder(self):
        old = Path(self.c.library) / "S2Arm 自签导出"
        old.mkdir(); (old / "S2Arm.ipa").write_bytes(b"0.5.x")
        r = self.export()
        folder = Path(self.c.library) / "S2Arm 游戏包"
        self.assertEqual(r["ipa"], str(folder / "S2Arm.ipa"))
        self.assertEqual(self.names(r["ipa"]), sorted([APP, WIDGET]))
        self.assertEqual((r["games"], r["files"], r["shellId"], r["exported"]), ([], [], "SHELL1", True))
        text = (folder / "怎么导入.txt").read_text(encoding="utf-8")
        self.assertTrue(text.startswith("S2Arm.ipa：用你自己的签名工具（AltStore、SideStore 等）签好装到手机。"), "导出了 ipa：说明最前面是 ipa 那句")
        self.assertIn("点开 .s2arm 文件", text)
        self.assertEqual((old / "S2Arm.ipa").read_bytes(), b"0.5.x", "0.5.x 的自签导出文件夹不碰")
        self.assertEqual(sorted(p.name for p in Path(self.c.library).iterdir() if p.name.startswith(".export-")), [], "不留临时目录")

    def test_readme_ipa_sentence_only_when_ipa_exported(self):
        # 只导出过 .s2arm 的文件夹（没 S2Arm.ipa）：说明里没有 ipa 那句；之后导出 ipa 再写 .s2arm，ipa 那句留着
        import install as ins
        folder = Path(self.c.library) / "S2Arm 游戏包"; folder.mkdir()
        ins.write_s2arm_readme(folder, "zh")
        self.assertNotIn("S2Arm.ipa", (folder / "怎么导入.txt").read_text(encoding="utf-8"))
        self.export()
        ins.write_s2arm_readme(folder, "en")
        self.assertTrue((folder / "How to import.txt").read_text(encoding="utf-8").startswith("S2Arm.ipa: sign it with your own tool"))

    def test_widget_off_strips_extension(self):
        self.c.r["widget"] = False
        r = self.export()
        self.assertEqual(self.names(r["ipa"]), [APP])

    def test_replaces_in_place_keeps_others_and_existing_folder(self):
        en = Path(self.c.library) / "S2Arm Game Packs"; en.mkdir()
        (en / "S2Arm.ipa").write_bytes(b"old"); (en / "Game.s2arm").write_bytes(b"pack")
        self.c.r["uiLanguage"] = "zh-Hans"
        r = self.export()
        self.assertEqual(Path(r["ipa"]).parent, en, "库根已有英文那个文件夹：换中文界面也写进它")
        self.assertEqual(self.names(r["ipa"]), sorted([APP, WIDGET]))
        self.assertEqual((en / "Game.s2arm").read_bytes(), b"pack")
        self.assertEqual([p.name for p in en.iterdir() if p.name.endswith(".partial")], [])

    def test_failure_keeps_previous_ipa(self):
        folder = Path(self.c.library) / "S2Arm 游戏包"; folder.mkdir()
        (folder / "S2Arm.ipa").write_bytes(b"previous")
        def broken(c, *, dest=None):
            raise RuntimeError("组壳失败")
        with self.assertRaises(RuntimeError):
            self.export(shell=broken)
        self.assertEqual((folder / "S2Arm.ipa").read_bytes(), b"previous")
        self.assertEqual(sorted(p.name for p in folder.iterdir()), ["S2Arm.ipa"])
        # 已经往文件夹里写了一半（去小组件另存时出错）：半个临时文件也清掉，上一份照旧
        def half(src, dst):
            Path(dst).write_bytes(b"half"); raise OSError("盘满")
        self.c.r["widget"] = False
        with patch.object(install, "ipa_strip_widget", half), self.assertRaises(OSError):
            self.export()
        self.assertEqual(sorted(p.name for p in folder.iterdir()), ["S2Arm.ipa"])
        self.assertEqual((folder / "S2Arm.ipa").read_bytes(), b"previous")

    def test_switch_off_keeps_old_export(self):
        class Old(Exception):
            pass
        def old_path(c):
            raise Old
        with patch.object(packer, "current_shell_id", old_path):
            with self.assertRaises(Old):
                self.export(on=False)
        self.assertEqual(self.assembled, 0)

    def test_update_phone_export_routes_here(self):
        # 「导出新版 S2Arm」（更新作业带 mode=export）开关开着也出通用 ipa
        self.assembled = 0
        self.c.catalog = lambda: {"games": []}
        self.c.r.update(mode="export")
        with patch.object(program_pack, "enabled", lambda c: True), patch.object(packer, "assemble_shell", self.fake_shell), \
                patch.object(install, "patches_results", lambda c: []):
            r = install._update_phone(self.c)
        self.assertTrue(r["updated"])
        self.assertEqual((self.assembled, Path(r["ipa"]).parent.name), (1, "S2Arm 游戏包"))


if __name__ == "__main__":
    unittest.main()
