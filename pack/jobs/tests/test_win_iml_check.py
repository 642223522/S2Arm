# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Windows 签名后核「提高内存上限」（pack/orch/install_win.py iml_facts / iml_line，pack/jobs/install.py WinPhone.say）。
诊断 #7c32b3 等一族 4 份：手机上首启复核报签名丢了 IML，丢在哪一步看不到。plumesign 签主 App 用的权限就是描述文件里那份，
所以签好就读描述文件核。合成 ipa（描述文件 = CMS 外壳里夹一段 plist，这里用前后填充字节模拟），期望手写：
① 描述文件带 IML → iml True、名称 / 应用号 / 团队照读，行以「【IML】」开头
② 不带 → iml False，行以「【IML 丢了】」开头并写出描述文件名与应用号
③ 没有描述文件 → None，行写「读不到」
④ 作业层：「【IML 丢了】」行不当进度发、记一条黄字 iml_missing（原句进 internal）；别的行照常当进度发"""
import plistlib
import sys
import tempfile
import types
import unittest
import zipfile
from pathlib import Path

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))
sys.path.insert(0, str(JOBS.parent / "orch"))
import install  # noqa: E402
import install_win  # noqa: E402

KEY = "com.apple.developer.kernel.increased-memory-limit"


def ipa(path, ents=None):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("Payload/S2Arm.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "io.s2arm.games.ABCDE12345"}))
        if ents is not None:
            prof = plistlib.dumps({"Name": "PlumeImpactor io.s2arm.games.ABCDE12345", "TeamIdentifier": ["ABCDE12345"], "Entitlements": ents})
            z.writestr("Payload/S2Arm.app/embedded.mobileprovision", b"\x30\x82CMS-header" + prof + b"\x00CMS-signature")
    return path


class ImlCheck(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())

    def test_with_and_without(self):
        app_id = "ABCDE12345.io.s2arm.games.ABCDE12345"
        f = install_win.iml_facts(ipa(self.t / "a.ipa", {"application-identifier": app_id, KEY: True}))
        self.assertEqual(f, dict(iml=True, name="PlumeImpactor io.s2arm.games.ABCDE12345", app_id=app_id, team="ABCDE12345"))
        self.assertTrue(install_win.iml_line(self.t / "a.ipa").startswith("【IML】签好的 S2Arm 带"))
        ipa(self.t / "b.ipa", {"application-identifier": app_id})
        self.assertFalse(install_win.iml_facts(self.t / "b.ipa")["iml"])
        line = install_win.iml_line(self.t / "b.ipa")
        self.assertTrue(line.startswith("【IML 丢了】"))
        self.assertIn(app_id, line); self.assertIn("PlumeImpactor", line)
        self.assertIsNone(install_win.iml_facts(ipa(self.t / "c.ipa")))
        self.assertIn("读不到", install_win.iml_line(self.t / "c.ipa"))

    def test_job_layer_routes_lost_line_to_warning(self):
        emitted, diags = [], []
        c = types.SimpleNamespace(emit=lambda kind, m="", **k: emitted.append(m), diagnostic=lambda m, **k: diags.append((m, k)))
        ph = install.WinPhone.__new__(install.WinPhone); ph.c = c
        ph.say("签名 + 装机（设备编号 1）…")
        ph.say("【IML 丢了】签好的 S2Arm 描述文件里没有「提高内存上限」（…）")
        self.assertEqual(emitted, ["签名 + 装机（设备编号 1）…"])
        self.assertEqual([(k["code"], k["severity"], k["internal"].startswith("【IML 丢了】")) for _, k in diags], [("iml_missing", "warning", True)])


if __name__ == "__main__":
    unittest.main()
