"""回到上一份存档（Mac 作业层 save_previous）：真文件系统、真 renamex_np 交换；合成存档字节，不碰玩家存档。
期望值按规则手写：交换后 0/ 是原来的 .s2a_prev 内容，再做一次逐字换回。"""

import contextlib
import io
import json
import os
os.environ.setdefault("S2A_BANNER_FETCH", "0")
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))
import library  # noqa: E402
import save_previous  # noqa: E402
from core import Context, Failure, atomic  # noqa: E402

GID = "0100000000000000"
SID = "0000000000000001"


@unittest.skipUnless(sys.platform == "darwin", "renamex_np 只在 macOS")
class SavePreviousTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="s2arm prev ")
        self.addCleanup(self.tmp.cleanup)
        d = Path(self.tmp.name).resolve()
        self.events = io.StringIO()
        r = contextlib.redirect_stdout(self.events)
        r.__enter__()
        self.addCleanup(r.__exit__, None, None, None)
        self.request = dict(schema=1, operation="setup", privateRoot=str(d / "private"), engineDir="/nonexistent-engine",
                            library=str(d / "library"), libraryId="")
        self.request["libraryId"] = library.setup(self.context())["libraryId"]
        self.request["gameId"] = GID
        game = dict(id=GID, name="Synthetic", packages=[dict(type="base", titleId=GID, baseId=GID, version=1, sha256="a" * 64,
                                                               path="sources/f.nsp", display="1.0")], hidden=False)
        atomic(d / "library/catalog.json", dict(schema=1, games=[game]))
        folder = d / "library/games/TestGame"
        folder.mkdir(parents=True)
        atomic(folder / "game.json", dict(schema=1, id=GID))
        self.save = folder / "saves/bis/user/save" / SID

    def context(self, **extra):
        return Context(self.request | dict(taskId=uuid.uuid4().hex) | extra)

    def put(self, sub, data):
        p = self.save / sub / "slot.bin"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)

    def read(self, sub):
        return (self.save / sub / "slot.bin").read_bytes()

    def test_no_previous(self):
        self.put("0", b"newer")
        self.assertFalse(save_previous.status(self.context(operation="savePrevious"))["hasPrevious"])
        with self.assertRaises(Failure) as e:
            save_previous.restore(self.context(operation="saveRestorePrevious"))
        self.assertEqual(e.exception.code, "save_no_previous")
        self.assertEqual(self.read("0"), b"newer")

    def test_restore_then_switch_back(self):
        self.put("0", b"newer")
        self.put(".s2a_prev", b"older")
        s = save_previous.status(self.context(operation="savePrevious"))
        self.assertEqual((s["hasPrevious"], s["saveIds"], s["trouble"]), (True, [SID], ""))
        r = save_previous.restore(self.context(operation="saveRestorePrevious"))
        self.assertEqual(r["restored"], 1)
        self.assertEqual((self.read("0"), self.read(".s2a_prev")), (b"older", b"newer"))
        save_previous.restore(self.context(operation="saveRestorePrevious"))
        self.assertEqual((self.read("0"), self.read(".s2a_prev")), (b"newer", b"older"))

    def test_trouble_from_last_launch(self):
        self.put("0", b"newer")
        self.put(".s2a_prev", b"older")
        c = self.context(operation="savePrevious")
        status = lambda: save_previous.status(self.context(operation="savePrevious"))["trouble"]
        self.assertEqual(status(), "", "有上一份、上一局没出事：不问")
        save_previous.note_launch(c, GID, True)
        self.assertEqual(status(), "earlyCrash")
        save_previous.note_launch(c, GID, False)   # 好好收局清掉
        self.assertEqual(status(), "")
        (self.save / ".s2a_guard").write_text("commit 3 refused", encoding="utf-8")
        self.assertEqual(status(), "guardRed", "护栏拦下过（存档旁的记号）")
        save_previous.note_launch(c, GID, True)
        save_previous.restore(self.context(operation="saveRestorePrevious"))   # 回过去了：记号和开局就崩都清掉，不再问
        self.assertFalse((self.save / ".s2a_guard").exists())
        self.assertEqual(status(), "")

if __name__ == "__main__":
    unittest.main()


class SavePreviousWindowsImportTest(unittest.TestCase):
    """Windows 上作业层一启动就导入 save_previous（main.py）：导入时不能碰 macOS 专有的 libc。
    合成 Windows：sys.platform = win32，ctypes.CDLL(None) 照 Windows 的行为抛 TypeError；重新导入 save_previous 与 main 不报错，
    真要交换时报 ENOTSUP（restore 据此按「没能回到上一份存档，存档保持原样」报）"""
    def test_import_on_windows_does_not_load_libc(self):
        import ctypes
        import importlib
        from unittest import mock
        real_cdll = ctypes.CDLL
        def windows_cdll(name, *a, **k):
            if name is None:
                raise TypeError("argument of type 'NoneType' is not iterable")
            return real_cdll(name, *a, **k)
        try:
            with mock.patch.object(sys, "platform", "win32"), mock.patch.object(ctypes, "CDLL", windows_cdll):
                mod = importlib.reload(save_previous)
                import main  # noqa: F401
                importlib.reload(main)
                with self.assertRaises(OSError) as e:
                    mod._exchange("a", "b")
                self.assertEqual(e.exception.errno, __import__("errno").ENOTSUP)
        finally:
            importlib.reload(save_previous)
