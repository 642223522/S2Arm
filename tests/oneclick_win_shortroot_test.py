#!/usr/bin/env python3
"""Windows 一键出包 result 事件里的路径换回（诊断#0e3bd5）：python3 tests/oneclick_win_shortroot_test.py
期望按规则写：登记一条短入口 C:\\Data\\A\\AppData\\Local\\S2A\\j\\gkam → 玩家路径 D:\\Lib\\games\\x\\build\\ios，
  Run.ev 写出的 result 里 ipa 路径
  ① 大小写与登记不同（c:\\users\\a\\appdata\\local\\s2a\\j\\GKAM\\pkg\\t.ipa）→ 换成 D:\\Lib\\games\\x\\build\\ios\\pkg\\t.ipa
  ② 分隔符是 /（C:/Data/A/AppData/Local/S2A/j/gkam/pkg/t.ipa）→ 换成 D:\\Lib\\games\\x\\build\\ios/pkg/t.ipa（前缀换回，尾巴原样）
  ③ 写法完全一致 → 照旧换回；文案中间夹着短路径（say）→ 照旧换回
  反证（手工核过，不写成常驻用例：show 后来也改成不分大小写）：把 Run.ev 换回只走 show 的旧实现，① ② 原样留着短路径
④ pack/jobs/ipa.py win_oneclick：回报的 ipa 不存在且还在 \\S2A\\j\\ 下 → 报明确的 Failure，不是 WinError 3 / FileNotFoundError"""
import json, os, sys, tempfile, unittest
from pathlib import Path
from unittest import mock

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R)); sys.path.insert(0, str(R / "pack/jobs"))
from pack.orch import oneclick_win, shortroot   # noqa: E402

SHORT = r"C:\Data\A\AppData\Local\S2A\j\gkam"
LONG = r"D:\Lib\games\x\build\ios"


class Ev(unittest.TestCase):
    def ev(self, **kw):
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ, {shortroot.ENV: f"{LONG}\t{SHORT}"}):
            ev = Path(d) / "ev.jsonl"
            run = oneclick_win.Run(Path(d) / "out", str(ev))
            run.ev("result", **kw); run.evf.close(); run.timing.close()
            return json.loads(ev.read_text(encoding="utf-8").splitlines()[-1])

    def test_case_mismatch(self):
        self.assertEqual(self.ev(ipa=r"c:\data\a\appdata\local\s2a\j\GKAM\pkg\t.ipa")["ipa"], LONG + r"\pkg\t.ipa")

    def test_slash_mismatch(self):
        self.assertEqual(self.ev(ipa="C:/Data/A/AppData/Local/S2A/j/gkam/pkg/t.ipa")["ipa"], LONG + "/pkg/t.ipa")

    def test_exact_and_text(self):
        self.assertEqual(self.ev(ipa=SHORT + r"\pkg\t.ipa")["ipa"], LONG + r"\pkg\t.ipa")
        self.assertEqual(self.ev(msg=f"出到 {SHORT}\\pkg\\t.ipa 了")["msg"], f"出到 {LONG}\\pkg\\t.ipa 了")


class Copy(unittest.TestCase):
    def test_lost_short_path_is_clear_failure(self):
        import ipa as ipamod
        from core import Failure
        with tempfile.TemporaryDirectory() as d:
            out = Path(d); ev = out / "ev.jsonl"
            ev.write_text(json.dumps({"ev": "result", "ok": True, "ipa": r"C:\Data\A\AppData\Local\S2A\j\gkam\pkg\t.ipa", "pack": r"C:\x"}) + "\n", encoding="utf-8")
            c = mock.Mock(); c.keys = out / "k"; c.engine = out
            with mock.patch.object(ipamod, "bundled_shell", lambda c: "shell"):
                with self.assertRaises(Failure) as e:
                    ipamod.win_oneclick(c, "oneclick", "ex", out / "fonts", out, ev, out / "log", {}, None)
            self.assertIn("短路径入口", str(e.exception))


if __name__ == "__main__":
    unittest.main()
