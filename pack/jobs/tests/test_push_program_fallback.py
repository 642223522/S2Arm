# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""#1756：Mac 推 .s2arm 时 s2a-devpush「找不到设备」（usbmuxd 那一刻列不出这台、devicectl 照样连着）→ 整份改走 devicectl，不整单失败。
s2a-devpush 用一个打原话、退 1 的替身脚本；devicectl 那条用替身记下推了什么。期望按剧本手写。"""
import os
import stat
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tools"))
import install  # noqa: E402
import push_pack as P  # noqa: E402


class PushProgramFallback(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="s2arm fallback ")
        self.w = Path(self.tmp.name)
        self.src = self.w / "0100000000010000.s2arm"; self.src.write_bytes(b"x" * 10)

    def tearDown(self):
        self.tmp.cleanup()

    def fake_devpush(self, said):
        exe = self.w / "s2a-devpush"
        exe.write_text(f"#!/bin/sh\necho '{said}' >&2\nexit 1\n")
        exe.chmod(exe.stat().st_mode | stat.S_IXUSR)
        return str(exe)

    def phone(self, exe):
        ph = install.MacPhone.__new__(install.MacPhone)   # 真的 devpush_client：S2A_DEVPUSH 指替身（发版内置的那份不在仓库里）
        ph.c = types.SimpleNamespace(env=lambda: dict(os.environ, S2A_DEVPUSH=exe), engine=Path(__file__).resolve().parents[3])
        ph.udid, ph.bid, ph.dev = "UDID-1", "io.s2arm.games.team", {"id": "CORE-1"}
        return ph

    def run_put(self, said):
        sent = []
        def dc_put(dc, src, rel):
            sent.append((dc.device, dc.bid, Path(src).name, rel))
        exe = self.fake_devpush(said)
        with patch.object(P.Devicectl, "put", dc_put):
            cl = self.phone(exe).client(self.w)
            try:
                cl.put(self.src, "Documents/Import Here/0100000000010000.s2arm")
                return None, sent
            except P.Fail as e:
                return e, sent

    def test_device_not_found_goes_through_devicectl(self):
        err, sent = self.run_put("找不到设备 UDID-1：device not found")
        self.assertIsNone(err, "改走 devicectl 推成，不报失败")
        self.assertEqual(sent, [("CORE-1", "io.s2arm.games.team", "0100000000010000.s2arm", "Documents/Import Here/0100000000010000.s2arm")])
        self.assertIn("改走 devicectl", (self.w / "devpush.log").read_text(encoding="utf-8"))

    def test_other_failures_still_fail(self):
        err, sent = self.run_put("afc error: No space left on device")
        self.assertIsInstance(err, P.Fail, "别的失败（不是找不到设备）照常报，不换路")
        self.assertEqual(sent, [])


if __name__ == "__main__":
    unittest.main()
