# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""S 级优化升级（pack/jobs/sgrade.py，v0.4.0）：原始程序存一份 / 按顺序找 / 升级前查找的分组 / Mac 逐款补。游戏库换成临时目录，期望手写"""
import contextlib
import shutil
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import jobcase  # noqa: F401
import build
import layout
import sgrade
from core import Failure


def nso(d, bid):
    d.mkdir(parents=True, exist_ok=True)
    b = bytearray(0x100); b[0:4] = b"NSO0"; b[0x40:0x48] = bytes.fromhex(bid); (d / "main").write_bytes(bytes(b)); (d / "main.npdm").write_bytes(b"npdm")
    (d / "sdk").write_bytes(b"sdk"); (d / "rtld").write_bytes(b"rtld")
    return d


class SGradeTests(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())
        self.events = []
        self.c = types.SimpleNamespace(private=self.t, emit=lambda k, text, **_: self.events.append(text), begin=lambda *a, **k: None,
                                       lock=lambda name: contextlib.nullcontext(), idle=lambda name: contextlib.nullcontext(self.free),
                                       catalog=lambda: {"games": [{"id": g, "name": n} for g, n in self.games]})
        self.games = []
        self.free = True   # execution 锁是不是没人用（c.idle）
        self.info = {}
        def game_path(c, gid, *parts, create=True):
            d = self.t / "lib" / gid.upper()
            return d.joinpath(*parts)
        for p in (patch.object(layout, "path", side_effect=game_path),
                  patch.object(layout, "image_mac", side_effect=lambda c, g, create=True: game_path(c, g, "image", "mac")),
                  patch.object(layout, "ios_kit", side_effect=lambda c, g: game_path(c, g, "image", "ios", "kit")),
                  patch.object(layout, "program_exefs", side_effect=lambda c, g: game_path(c, g, "original-exefs")),
                  patch.object(layout, "has_ios_kit", side_effect=lambda c, g: (game_path(c, g, "image", "ios", "kit") / "main.npdm").is_file()),
                  patch("programs.save_exefs", side_effect=lambda c, g, src: (shutil.rmtree(game_path(c, g, "original-exefs"), ignore_errors=True),
                                                                               shutil.copytree(src, game_path(c, g, "original-exefs")))[1]),   # 常驻归档另有单测（test_programs_store）
                  patch.object(layout, "game_info", side_effect=lambda c, g: self.info.get(g.upper(), {})),
                  patch.object(build, "extract_valid", return_value=False)):
            p.start(); self.addCleanup(p.stop)

    def test_save_program_copies_modules_once(self):
        src = nso(self.t / "x", "AABBCCDD00112233")
        d = sgrade.save_program(self.c, "0100A", src)
        self.assertEqual(sorted(p.name for p in d.iterdir()), ["main", "main.npdm", "sdk"], "只存模块与 main.npdm，rtld 这类不存")
        (d / "sdk").write_bytes(b"mine")
        sgrade.save_program(self.c, "0100A", src)
        self.assertEqual((d / "sdk").read_bytes(), b"mine", "同一主程序（构建号相同）不重复写")
        self.assertIsNone(sgrade.save_program(self.c, "0100B", self.t / "empty"), "源目录不完整不存")

    def test_find_program_order(self):
        g = {"id": "0100A"}
        nso(self.t / "lib/0100A/image/mac/exefs", "1111111111111111")
        self.assertEqual(sgrade.find_program(self.c, g, extract=False)[0], "mac", "没存下、没解包缓存 → Mac 运行版本")
        nso(self.t / "lib/0100A/original-exefs", "2222222222222222")
        self.assertEqual(sgrade.find_program(self.c, g, extract=False)[0], "saved", "存下的优先")
        self.assertEqual(sgrade.find_program(self.c, {"id": "0100B"}, extract=False), ("none", None))
        import rewrite_refresh
        with patch.object(rewrite_refresh, "original_exefs", side_effect=lambda c, game, work: nso(Path(work) / "x", "3333333333333333")):
            where, d = sgrade.find_program(self.c, {"id": "0100C"})
        self.assertEqual(where, "source"); self.assertEqual(d, self.t / "lib/0100C/original-exefs", "从原件解出来的存进游戏文件夹")

    def test_scan_groups(self):
        # A：iPhone 件 + 存下的原始程序 + 有补丁；B：有原始程序没补丁；C：只有 Mac 版、找不到原始程序以外的路 → Mac 版自带；D：iPhone 件但找不到原始程序；E：没出过包不列
        self.games = [("0100A", "甲"), ("0100B", "乙"), ("0100C", "丙"), ("0100D", "丁"), ("0100E", "戊")]
        for g in ("0100A", "0100B", "0100D"):
            (self.t / "lib" / g / "image/ios/kit").mkdir(parents=True); (self.t / "lib" / g / "image/ios/kit/main.npdm").write_bytes(b"x")
        nso(self.t / "lib/0100A/original-exefs", "AAAAAAAAAAAAAAAA"); nso(self.t / "lib/0100B/original-exefs", "BBBBBBBBBBBBBBBB")
        nso(self.t / "lib/0100C/image/mac/exefs", "CCCCCCCCCCCCCCCC")
        self.info["0100C"] = {"sgradeOff": True}
        pats = {"AAAAAAAAAAAAAAAA": {"widescreen": 1, "fps": 2, "gfx": 0, "cheat": 3}, "CCCCCCCCCCCCCCCC": {"widescreen": 1, "fps": 0, "gfx": 0, "cheat": 0}}
        import patches, rewrite_refresh
        with patch.object(sgrade, "local_patches", side_effect=lambda c, g, bid, others=None: pats.get(bid, {"widescreen": 0, "fps": 0, "gfx": 0, "cheat": 0})), \
             patch.object(rewrite_refresh, "original_exefs", return_value=None), \
             patch.object(patches, "display_version", return_value="1.0.0"), patch.object(patches, "own_widen", return_value=False):
            r = sgrade.scan(self.c)
        got = {x["id"]: (x["program"], x["total"], x["iphone"], x["mac"], x["off"]) for x in r["games"]}
        self.assertEqual(got, {"0100A": ("saved", 6, True, False, False), "0100B": ("saved", 0, True, False, False),
                               "0100C": ("mac", 1, False, True, True), "0100D": ("none", 0, True, False, False)})
        self.assertEqual((r["found"], r["upgradable"], r["noPatch"], r["missing"]), (3, 1, 1, 1), "丙出包时取消过 S 级优化，不算可升级")

    def test_mac_all_one_failing_does_not_block(self):
        self.games = [("0100A", "甲"), ("0100B", "乙"), ("0100C", "丙")]
        for g in ("0100A", "0100B"):
            nso(self.t / "lib" / g / "image/mac/exefs", "1111111111111111")
        import rewrite_refresh
        def refresh(c, gid, rt, hold=None):
            if gid == "0100A": raise Failure("坏了")
            return True
        with patch.object(rewrite_refresh, "refresh_mac", side_effect=refresh):
            r = sgrade.mac_all(self.c)
        self.assertEqual(r, {"updated": ["0100B"], "checked": 2})
        self.assertTrue(any("甲" in e and "没补上" in e for e in self.events))

    def test_mac_all_yields_when_library_busy(self):
        # 诊断 D-R8NG：execution 锁有人用（正在玩 / 玩家刚点开始）→ 后台一款都不做、不等锁，立刻返回；开始游戏起局前自己补
        self.games = [("0100A", "甲"), ("0100B", "乙")]
        for g in ("0100A", "0100B"):
            nso(self.t / "lib" / g / "image/mac/exefs", "1111111111111111")
        self.free = False
        import rewrite_refresh
        with patch.object(rewrite_refresh, "refresh_mac", side_effect=AssertionError("锁有人用不该开始改写")):
            r = sgrade.mac_all(self.c)
        self.assertEqual(r, {"updated": [], "checked": 2})

    def test_mac_all_rewrites_outside_lock(self):
        # 后台改写不拿 execution 锁（c.lock 不该被调用），换进运行版本那一下交 hold = c.idle
        self.games = [("0100A", "甲")]
        nso(self.t / "lib" / "0100A" / "image/mac/exefs", "1111111111111111")
        self.c.lock = lambda name: (_ for _ in ()).throw(AssertionError("后台不该排队等锁"))
        seen = []
        import rewrite_refresh
        def refresh(c, gid, rt, hold=None):
            with hold() as ok:
                seen.append(ok)
            return True
        with patch.object(rewrite_refresh, "refresh_mac", side_effect=refresh):
            r = sgrade.mac_all(self.c)
        self.assertEqual((r["updated"], seen), (["0100A"], [True]))


if __name__ == "__main__":
    unittest.main()
