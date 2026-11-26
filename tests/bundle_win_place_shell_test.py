"""Windows 发版组装「先组装、后放壳」（launchers/windows/bundle_win.place_shell，11-19 发版提速：Windows 不必等 Mac 出壳）。期望手写：
① 壳号对（= 本提交 current_id）→ 放进 Shell/、Shell-tvOS/；② 壳号不对 → 报红、不放；③ 目标不是组装好的目录（没有 Engine/engine.json）→ 报红；
④ 已有 Shell/ → 报红、不覆盖"""
import json, sys, tempfile, unittest
from pathlib import Path
R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / "launchers/windows")); sys.path.insert(0, str(R))
import bundle_win  # noqa: E402
from pack.shell.manifest import current_id  # noqa: E402


def shell(d, sid):
    d.mkdir(parents=True); (d / "manifest.json").write_text(json.dumps({"details": {"shellId": sid}})); (d / "root").mkdir(); (d / "root/x").write_text("1")
    return d


class Place(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.target = self.t / "S2Arm"; (self.target / "Engine").mkdir(parents=True)
        (self.target / "Engine/engine.json").write_text("{}")

    def test_place(self):
        bundle_win.place_shell(self.target, shell(self.t / "ios", current_id()), shell(self.t / "tv", current_id("tvos")))
        self.assertTrue((self.target / "Shell/root/x").is_file()); self.assertTrue((self.target / "Shell-tvOS/manifest.json").is_file())

    def test_wrong_id(self):
        with self.assertRaises(SystemExit):
            bundle_win.place_shell(self.target, shell(self.t / "ios", "0" * 16))
        self.assertFalse((self.target / "Shell").exists())

    def test_not_bundled(self):
        with self.assertRaises(SystemExit):
            bundle_win.place_shell(self.t / "空", shell(self.t / "ios", current_id()))

    def test_no_overwrite(self):
        (self.target / "Shell").mkdir()
        with self.assertRaises(SystemExit):
            bundle_win.place_shell(self.target, shell(self.t / "ios", current_id()))


if __name__ == "__main__":
    unittest.main()
