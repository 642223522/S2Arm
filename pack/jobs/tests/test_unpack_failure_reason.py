"""#1411：打 iPhone 包（ipa）在自己里面解包，读取器以 🔴 报「源文件数据哈希校验不过」后退 1。
修前：码 tool_exit、摘要取到末行「第 0 段数据 通过」；修后：码 content_invalid、摘要是那条 🔴 原因行。
夹具是玩家 #1411 原样的 extract.log（文件名换成 game.xci）。期望手写。"""
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import build  # noqa: E402
import errors  # noqa: E402
from core import Failure  # noqa: E402

FIX = HERE / "fixtures" / "extract_hash_mismatch_1411.log"


class UnpackFailureReason(unittest.TestCase):
    def test_tool_reason_takes_the_red_circle_line(self):
        reason = errors.tool_reason(FIX)
        self.assertIn("源文件数据哈希校验不过", reason)
        self.assertNotIn("第 0 段数据 通过", reason)

    def test_ipa_unpack_failure_is_classified_not_tool_exit(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            logs = root / "logs"; logs.mkdir()

            def run(args, log, env=None, *a, **k):
                Path(log).write_text(FIX.read_text(encoding="utf-8"), encoding="utf-8")
                raise Failure("解包失败（退出码 1）：…", code="tool_exit")

            c = types.SimpleNamespace(run=run, keys=root / "prod.keys", emit=lambda *a, **k: None)
            with patch.object(build, "shared_dir", return_value=root / "shared"), \
                 patch.object(build, "input_identity", return_value="id"), \
                 patch.object(build.ms, "reuse"), patch.object(build.ms, "enter"), \
                 patch.object(build, "source_path", side_effect=lambda c, p: p["path"]), \
                 patch.object(build.toolchain, "reader", return_value="nx_unpack"):
                with self.assertRaises(Failure) as cm:
                    build.ensure_extract(c, {"id": "01008DB008C2C000"}, [{"path": "/x/game.xci", "format": "xci"}], {}, logs, valid=False)
        self.assertEqual(cm.exception.code, "content_invalid")
        self.assertIn("源文件数据哈希校验不过", cm.exception.internal)

    def test_non_tool_exit_failures_pass_through(self):
        # Mac 准备（build）在 core.run 里已归好类（码不是 tool_exit）：原样抛出，不再改写
        with tempfile.TemporaryDirectory() as t:
            root = Path(t); logs = root / "logs"; logs.mkdir()

            def run(args, log, env=None, *a, **k):
                raise Failure("磁盘满", code="disk_full")

            c = types.SimpleNamespace(run=run, keys=root / "k", emit=lambda *a, **k: None)
            with patch.object(build, "shared_dir", return_value=root / "shared"), \
                 patch.object(build, "input_identity", return_value="id"), \
                 patch.object(build.ms, "reuse"), patch.object(build.ms, "enter"), \
                 patch.object(build, "source_path", side_effect=lambda c, p: p["path"]), \
                 patch.object(build.toolchain, "reader", return_value="nx_unpack"):
                with self.assertRaises(Failure) as cm:
                    build.ensure_extract(c, {"id": "x"}, [{"path": "/x/g.xci", "format": "xci"}], {}, logs, valid=False)
        self.assertEqual(cm.exception.code, "disk_full")


if __name__ == "__main__":
    unittest.main()
