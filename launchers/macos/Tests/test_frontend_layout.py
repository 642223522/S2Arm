"""build_app.py 的前端开关（S2A_APP_FRONTEND）：选哪个前端、App 身份、NX2Apple 前端资源放到 Resources 哪里。只测布局，不出壳。"""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("frontend_layout", ROOT / "launchers/macos/frontend_layout.py")
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)


class PickTests(unittest.TestCase):
    def test_default_is_apple_frontend(self):
        # 11-07 起发版缺省是 S2Arm × NX2Apple；文件名仍是 S2Arm.app（玩家原地覆盖升级、sign_release.sh / s2armctl 认这个名字）
        for environ in ({}, {"S2A_APP_FRONTEND": ""}, {"S2A_APP_FRONTEND": "apple"}):
            front = layout.pick(environ)
            self.assertEqual((front["key"], front["executable"], front["app"]), ("apple", "S2ArmApple", "S2Arm.app"))
            self.assertTrue(front["nx2apple_resources"])
            self.assertEqual(layout.info_identity(front), dict(
                CFBundleIdentifier="org.s2arm.macos.nx2apple", CFBundleExecutable="S2ArmApple",
                CFBundleName="S2Arm", CFBundleDisplayName="S2Arm"))   # App 名仍叫 S2Arm（维护者 11-07）；顶栏品牌字另由前端画

    def test_old_launcher_stays_as_fallback(self):
        front = layout.pick({"S2A_APP_FRONTEND": "launcher"})
        self.assertEqual((front["key"], front["executable"], front["app"]), ("launcher", "S2ArmLauncher", "S2Arm.app"))
        self.assertFalse(front["nx2apple_resources"])
        self.assertEqual(layout.info_identity(front), dict(
            CFBundleIdentifier="org.s2arm.macos.launcher", CFBundleExecutable="S2ArmLauncher",
            CFBundleName="S2Arm", CFBundleDisplayName="S2Arm"))

    def test_unknown_value_stops(self):
        with self.assertRaises(SystemExit):
            layout.pick({"S2A_APP_FRONTEND": "qt"})


class StageAppleResourcesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="s2a-frontend-layout-"))
        self.addCleanup(shutil.rmtree, self.tmp)

    def test_real_tree_layout(self):
        resources = self.tmp / "Resources"
        placed = layout.stage_apple_resources(ROOT, resources)
        self.assertEqual(placed, ["Licenses/NX2Apple/LICENSE", "Licenses/NX2Apple/Manrope-OFL.txt", "Licenses/NX2Apple/NOTICE",
                                  "l10n/en.json", "l10n/zh.json"])
        on_disk = sorted(str(p.relative_to(resources)) for p in resources.rglob("*") if p.is_file())
        self.assertEqual(on_disk, placed)
        frontend = ROOT / "launchers/macos/frontend"
        for got, source in (("l10n/zh.json", "l10n/zh.json"), ("Licenses/NX2Apple/LICENSE", "LICENSE"),
                            ("Licenses/NX2Apple/NOTICE", "NOTICE"), ("Licenses/NX2Apple/Manrope-OFL.txt", "fonts/Manrope-OFL.txt")):
            self.assertEqual((resources / got).read_bytes(), (frontend / source).read_bytes(), got)
        # 不碰 S2Arm 游戏共享字体目录（大小写不敏感的盘上 fonts 与 Fonts 同名）
        self.assertFalse((resources / "Fonts").exists())
        self.assertFalse((resources / "fonts").exists())

    def test_missing_license_stops(self):
        fake = self.tmp / "root"
        frontend = fake / "launchers/macos/frontend"
        (frontend / "l10n").mkdir(parents=True)
        (frontend / "fonts").mkdir()
        (frontend / "l10n/en.json").write_text("{}")
        (frontend / "LICENSE").write_text("MIT")
        (frontend / "fonts/Manrope-OFL.txt").write_text("OFL")
        with self.assertRaises(SystemExit) as caught:
            layout.stage_apple_resources(fake, self.tmp / "Resources")
        self.assertIn("NOTICE", str(caught.exception))
        self.assertFalse((self.tmp / "Resources").exists())

    def test_missing_english_text_stops(self):
        fake = self.tmp / "root"
        (fake / "launchers/macos/frontend/l10n").mkdir(parents=True)
        (fake / "launchers/macos/frontend/l10n/zh.json").write_text("{}")
        with self.assertRaises(SystemExit):
            layout.stage_apple_resources(fake, self.tmp / "Resources")


if __name__ == "__main__":
    unittest.main()
