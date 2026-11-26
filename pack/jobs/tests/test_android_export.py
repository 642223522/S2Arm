"""启动器出安卓包（pack/jobs/android_export.py）：开关缺省关、关着不碰 adb、出包编排只在开关开时认安卓、adb devices 输出解析。"""
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))
import android_export  # noqa: E402
import export_plan  # noqa: E402


class SwitchTests(unittest.TestCase):
    def test_default_off(self):
        self.assertFalse(android_export.ON_BY_DEFAULT, "安卓出包缺省关：维护者验收后再定开放")
        for v, want in (("", False), ("1", True), ("0", False), ("yes", False)):
            with mock.patch.dict(os.environ, {"S2A_ANDROID_EXPORT": v}):
                self.assertEqual(android_export.enabled(), want, repr(v))
        with mock.patch.dict(os.environ, clear=False):
            os.environ.pop("S2A_ANDROID_EXPORT", None)
            self.assertFalse(android_export.enabled())

    def test_off_reports_disabled_without_adb(self):
        with mock.patch.dict(os.environ, {"S2A_ANDROID_EXPORT": "0"}), \
                mock.patch.object(android_export, "fetch_adb", side_effect=AssertionError("关着不该碰 adb")):
            self.assertEqual(android_export.devices_job(None), dict(enabled=False, adb=None, devices=[]))

    def test_off_build_refused(self):
        with mock.patch.dict(os.environ, {"S2A_ANDROID_EXPORT": "0"}):
            with self.assertRaises(android_export.Failure) as raised:
                android_export.build_job(None)
            self.assertEqual(raised.exception.code, "android_disabled")

    def test_export_plan_supports_android_only_when_on(self):
        with mock.patch.dict(os.environ, {"S2A_ANDROID_EXPORT": "0"}):
            self.assertFalse(export_plan.supported("android"))
        with mock.patch.dict(os.environ, {"S2A_ANDROID_EXPORT": "1"}):
            self.assertTrue(export_plan.supported("android"))
        self.assertEqual(export_plan.OPERATION["android"], "android")
        self.assertIn("installSerial", export_plan.CHILD_KEYS_DROPPED, "父请求的序列号不能漏给苹果平台的子作业")


class DevicesTests(unittest.TestCase):
    def test_parse_adb_devices(self):
        out = ("List of devices attached\n"
               "10AF4N00TA002NC        device usb:1-1 product:PD2454 model:V2454A device:PD2454 transport_id:1\n"
               "emulator-5554          unauthorized transport_id:2\n"
               "192.168.1.9:5555       offline product:x model:Pixel_8 device:shiba\n\n")
        done = mock.Mock(returncode=0, stdout=out, stderr="")
        with mock.patch.object(android_export.subprocess, "run", return_value=done):
            self.assertEqual(android_export.list_devices("adb"), [
                dict(serial="10AF4N00TA002NC", state="device", model="V2454A"),
                dict(serial="emulator-5554", state="unauthorized", model=""),
                dict(serial="192.168.1.9:5555", state="offline", model="Pixel 8")])

    def test_sdk_adb_preferred_over_download(self):
        with tempfile.TemporaryDirectory() as tmp:
            adb = Path(tmp) / "platform-tools" / android_export.ADB_EXE
            adb.parent.mkdir()
            adb.write_text("")
            with mock.patch.dict(os.environ, {"ANDROID_HOME": tmp}), \
                    mock.patch.object(android_export, "toolchain_dir", return_value=Path(tmp) / "none"), \
                    mock.patch.object(android_export.urllib.request, "urlopen", side_effect=AssertionError("SDK 里有就不下载")):
                self.assertEqual(android_export.fetch_adb(), adb)

    def test_engine_dir_from_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            c = mock.Mock(engine=tmp)
            self.assertIsNone(android_export.engine_dir(c))
            d = Path(tmp) / "Binaries/Android/engine"
            d.mkdir(parents=True)
            (d / "engine.json").write_text("{}")
            self.assertEqual(android_export.engine_dir(c), d)


if __name__ == "__main__":
    unittest.main()
