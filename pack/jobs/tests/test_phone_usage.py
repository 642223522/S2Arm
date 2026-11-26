# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""0.6.0 通用壳总控台「手机上每款占多少」（pack/jobs/install.py phone_usage；tools/push_pack.py Devpush.du 解析）。
游戏库与设备记录是真的（library.setup + layout），手机是替身：一棵 {路径: 字节数} 的文件树，ls / du 按它回答（du 的输出格式同 s2a-devpush）。
期望按放进去的文件大小手算。"""
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install  # noqa: E402
import layout  # noqa: E402
import program_pack  # noqa: E402
import tests.test_jobs as tj  # noqa: E402

A, B = "0100000000010000", "0100000000020000"
P, ALT = install.PACK_GAMES, install.PACK_GAMES_ALT
SAVE = install.SAVE_REL


class FakePhoneFs:
    def __init__(self, files, du_ok=True):
        self.files, self.du_ok, self.calls = files, du_ok, []

    def call(self, op, *args):
        self.calls.append(op)
        if op == "ls":
            pre = args[0] + "/"
            kids = sorted({p[len(pre):].split("/")[0] for p in self.files if p.startswith(pre)})
            return (0, "\n".join(kids)) if kids else (1, "S2A_AFC_ERR 8 ObjectNotFound")
        if op == "du":
            if not self.du_ok:
                return 1, "不认识的操作 du"
            lines = []
            for r in args:
                hit = [n for p, n in self.files.items() if p.startswith(r + "/")]
                lines.append(f"du {sum(hit)} {len(hit)} {r}" if hit else f"du -1 0 {r}")
            return 0, "\n".join(lines)
        raise AssertionError(op)

    def du(self, *rels):   # 用真的解析（tools/push_pack.py Devpush.du）
        sys.path.insert(0, str(Path(install.__file__).resolve().parents[2] / "tools"))
        import push_pack
        return push_pack.Devpush.du(self, *rels)


class PhoneUsage(unittest.TestCase):
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown

    def files(self):
        return {f"{P}/{A}/program/S2AImages-{A}.dylib": 100, f"{P}/{A}/program/catalogue.json": 5, f"{P}/{A}/pack/game.img": 4000,
                f"{install.game_docs(A)}/{SAVE}/0000000000000001/0/save.dat": 30, f"{install.game_docs(A)}/cheats/x.txt": 2,
                f"{P}/{A}/snapshot/state.bin": 300, f"{ALT}/{B}/pack/game.img": 700, f"{ALT}/{B}/program/S2AImages-{B}.dylib": 50,
                "Documents/games/README.txt": 1}

    def usage(self, fs, connected=True, on=True):
        ph = types.SimpleNamespace(key="PHONE-1", udid="UDID-FAKE", bid="io.example.app")
        def pf(c):
            if not connected:
                raise install.Failure("没连", code="device_not_connected")
            return ph
        with patch.object(install, "phone_for", pf), \
                patch.object(install, "devpush_client", lambda c, u, b, w: fs), patch.object(install, "phone_bid", lambda p: p.bid), \
                patch.object(install, "trace", lambda *a, **k: None), patch.object(install.time, "time", lambda: 1_800_000_000.0):
            return install.phone_usage(self.c)

    def test_measures_each_category_from_phone(self):
        r = self.usage(FakePhoneFs(self.files()))
        (p,) = r["phones"]
        self.assertEqual((p["device"], p["at"], p["live"]), ("PHONE-1", 1_800_000_000.0, True))
        self.assertEqual(p["games"], [dict(gameId=A, program=105, resources=4002, saves=30, snapshots=300, files=6),
                                      dict(gameId=B, program=50, resources=700, saves=0, snapshots=0, files=2)])
        self.assertEqual(layout.load_device(self.c, "PHONE-1")["usage"]["games"][A]["resources"], 4002, "量完记进设备记录")

    def test_not_connected_gives_last(self):
        self.usage(FakePhoneFs(self.files()))
        r = self.usage(None, connected=False)
        (p,) = r["phones"]
        self.assertEqual((p["live"], p["at"], p["games"][0]["program"]), (False, 1_800_000_000.0, 105))

    def test_old_tool_keeps_last_record(self):
        self.usage(FakePhoneFs(self.files()))
        fs = self.files(); fs[f"{P}/{A}/pack/game.img"] = 9
        r = self.usage(FakePhoneFs(fs, du_ok=False))
        self.assertEqual((r["phones"][0]["live"], r["phones"][0]["games"][0]["resources"]), (False, 4002), "量不了：给上次的、不清零")

if __name__ == "__main__":
    unittest.main()
