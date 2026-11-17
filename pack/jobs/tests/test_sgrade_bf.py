# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""S 级升级补可读瓦片版着色器（pack/jobs/sgrade_bf.py 与 rewrite_refresh._refresh_bf_ios）。合成目录夹具，期望值按写进去的内容手算；
整份重出（rebuild：跑出包阶段脚本）桩掉——它的真跑验收是010074F013262000 Mac 产物根实测（见提交说明）"""
import contextlib
import hashlib
import json
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import jobcase  # noqa: F401  把 pack/jobs 加进路径（同其他作业层单测）
import rewrite_refresh as rr
import sgrade_bf
from core import Failure


class AddToPack(unittest.TestCase):
    def test_rows_under_prefix_replaced_and_manifest_rewritten(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t)
            (p / "index.tsv").write_text("game.img\t1\taa\nshaders/direct/b-c/bf/lib.idx\t5\told\n", encoding="utf-8")
            (p / "manifest.json").write_text(json.dumps({"version": 2, "files": 2, "total": 6, "index_sha256": "x"}), encoding="utf-8")
            (p / "shaders/direct/b-c/bf").mkdir(parents=True); (p / "shaders/direct/b-c/bf/lib.idx").write_bytes(b"abc")
            pid = sgrade_bf.add_to_pack(p, "shaders/direct/b-c/bf/", ["shaders/direct/b-c/bf/lib.idx"])
            want = "game.img\t1\taa\nshaders/direct/b-c/bf/lib.idx\t3\t" + hashlib.sha256(b"abc").hexdigest() + "\n"
            self.assertEqual((p / "index.tsv").read_text(encoding="utf-8"), want)
            m = json.loads((p / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual((m["files"], m["total"], m["index_sha256"], m["version"]), (2, 4, hashlib.sha256(want.encode()).hexdigest(), 2))
            self.assertEqual(pid, m["index_sha256"], "返回新资源包号（game.json ios.pack，put_game 据此判要推）")


class RefreshBfIos(unittest.TestCase):
    def setUp(self):
        self.info = {"A": {"ios": {"bfGen": sgrade_bf.BF_GEN}}, "B": {"ios": {}}, "C": {"ios": {"bfGen": 0}}, "D": {"ios": {}}}
        self.events = []
        self.c = types.SimpleNamespace(emit=lambda kind, msg="", **k: self.events.append(msg),
                                       catalog=lambda: {"games": [{"id": g, "name": g + "游戏"} for g in "ABCD"]})

    def test_four_outcomes(self):
        called = []
        def up(c, g):
            called.append(g)
            if g == "D":
                raise Failure("重出失败")
            return {"B": "updated", "C": "unavailable"}[g]
        with patch.object(rr.layout, "game_info", side_effect=lambda c, g: self.info[g]), \
             patch.object(rr.layout, "update_info", side_effect=lambda c, g, **f: self.info[g].update(f)), \
             patch.object(sgrade_bf, "upgrade_ios", side_effect=up):
            self.assertEqual(rr._refresh_bf_ios(self.c, ["A", "B", "C", "D"]), ["B"])
        self.assertEqual(called, ["B", "C", "D"], "代数已是本引擎的（A）不重出")
        self.assertEqual(self.info["C"]["ios"].get("bfMissing"), sgrade_bf.BF_GEN, "取不到原料：记这一代，「更新 iPhone」不再因它重组容器")
        self.assertNotIn("bfMissing", self.info["D"]["ios"], "出错不是缺原料：不记，下次再试")
        self.assertTrue(any("C游戏" in e and "需要原件" in e and "B游戏" not in e for e in self.events), self.events)
        self.assertTrue(any(e.startswith("【红】D游戏") for e in self.events), self.events)

    def test_due(self):
        with patch.object(sgrade_bf.layout, "game_info", side_effect=lambda c, g: self.info[g]), \
             patch.object(sgrade_bf.layout, "ios_pack", return_value=Path("/nonexistent")), \
             patch.object(sgrade_bf, "lib_dir", return_value=Path("/x/b-c")):
            self.info["C"]["ios"]["bfMissing"] = sgrade_bf.BF_GEN
            self.assertEqual([g for g in "ABCD" if sgrade_bf.due(self.c, g)], ["B", "D"], "A 已是本代、C 本代缺原料试过")


class UpgradeMac(unittest.TestCase):
    def test_swap_and_manifest(self):
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); rt = t / "runtime"; (rt / "romfs").mkdir(parents=True); (rt / "shaders/direct").mkdir(parents=True)
            (rt / "shaders/direct/keys.tsv").write_text("old\n"); (rt / "shaders/direct/old_only.tsv").write_text("o")
            (rt / "manifest.json").write_text(json.dumps({"files": {"main.patched.bin": [3, ""], "shaders/direct/keys.tsv": [4, ""],
                                                                    "shaders/direct/old_only.tsv": [1, ""]}, "rewriterId": "r"}))
            new = t / "new"; (new / "b-c").mkdir(parents=True); (new / "keys.tsv").write_text("k1\nk2\n"); (new / "b-c/lib.idx").write_bytes(b"12345")
            locks = []
            @contextlib.contextmanager
            def lock():
                locks.append(1); yield True
            c = types.SimpleNamespace(emit=lambda *a, **k: None, private=t)
            with patch.object(sgrade_bf, "rebuild", return_value=new):
                self.assertTrue(sgrade_bf.upgrade_mac(c, "G", rt, lock))
                m = json.loads((rt / "manifest.json").read_text())
                self.assertEqual(m["files"], {"main.patched.bin": [3, ""], "shaders/direct/keys.tsv": [6, ""], "shaders/direct/b-c/lib.idx": [5, ""]})
                self.assertEqual((m["bfGen"], m["rewriterId"]), (sgrade_bf.BF_GEN, "r"))
                self.assertEqual(sorted(p.relative_to(rt).as_posix() for p in rt.rglob("*") if p.is_file() and "shaders" in p.parts),
                                 ["shaders/direct/b-c/lib.idx", "shaders/direct/keys.tsv"], "旧库整份换掉、不留临时目录")
                self.assertEqual(locks, [1], "换库在锁里做一次")
                self.assertFalse(sgrade_bf.upgrade_mac(c, "G", rt, lock), "代数已是本引擎的：不再重出")

    def test_busy_gives_up_without_touching(self):
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); rt = t / "runtime"; (rt / "romfs").mkdir(parents=True); (rt / "shaders/direct").mkdir(parents=True)
            (rt / "shaders/direct/keys.tsv").write_text("old\n"); m0 = json.dumps({"files": {"shaders/direct/keys.tsv": [4, ""]}})
            (rt / "manifest.json").write_text(m0)
            new = t / "new"; (new / "b-c").mkdir(parents=True); (new / "keys.tsv").write_text("k\n"); (new / "b-c/lib.idx").write_bytes(b"1")
            @contextlib.contextmanager
            def busy():
                yield False
            c = types.SimpleNamespace(emit=lambda *a, **k: None, private=t)
            with patch.object(sgrade_bf, "rebuild", return_value=new):
                self.assertFalse(sgrade_bf.upgrade_mac(c, "G", rt, busy), "玩家正在开局：这次放弃")
            self.assertEqual(((rt / "shaders/direct/keys.tsv").read_text(), (rt / "manifest.json").read_text()), ("old\n", m0), "运行版本与清单一个字节不动、不记代数")
            self.assertFalse((rt / "shaders/direct.sgbf").exists(), "不留临时目录")


class IosInputsImage(unittest.TestCase):
    def test_romfs_segment_becomes_image_byte_for_byte(self):
        # iPhone 款从 game.img 取材：标准 RomFS 段原样拷成临时产物根的 romfs.std（段内容按写进去的字节手写对比：不多不少），不展开成 romfs/ 散文件；
        #   其余条目（aoc/…）照旧放回产物根
        import os
        import struct
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); engine = Path(sgrade_bf.__file__).resolve().parents[2]
            c = types.SimpleNamespace(engine=engine)
            img = sgrade_bf._img(c)
            seg, aoc = os.urandom(70001), b"dlc payload"
            ro = img.PAGE; ao = img.up(ro + len(seg)); toc = img.toc_bytes([("aoc/1/data", ao, len(aoc))]); to = img.up(ao + len(aoc))
            pack, kit, exefs = t / "pack", t / "kit", t / "exefs"
            for d in (pack, kit, exefs): d.mkdir()
            (exefs / "main").write_bytes(b"main")
            with open(pack / "game.img", "wb") as f:
                f.write(img.HDR.pack(img.MAGIC, img.FORMAT, 0, b"0100AAAA00000000", b"pk", ro, len(seg), to, len(toc), to + len(toc)))
                f.seek(ro); f.write(seg); f.seek(ao); f.write(aoc); f.seek(to); f.write(toc)
            fake_sgrade = types.SimpleNamespace(saved_program=lambda c, g: exefs)
            with patch.object(sgrade_bf.layout, "ios_pack", return_value=pack), patch.object(sgrade_bf.layout, "ios_kit", return_value=kit), \
                 patch.object(sgrade_bf.layout, "image_mac", return_value=t / "no-mac"), patch.dict("sys.modules", {"sgrade": fake_sgrade}):
                root, how = sgrade_bf.ios_inputs(c, "0100AAAA00000000", t / "work")
            self.assertEqual(how, "game.img")
            self.assertEqual((root / "romfs.std").read_bytes(), seg, "镜像 = game.img 的 RomFS 段，逐字节相同")
            self.assertFalse((root / "romfs").exists(), "不展开 romfs/")
            self.assertEqual((root / "aoc/1/data").read_bytes(), aoc)
            self.assertTrue(sgrade_bf._has_romfs(root))


if __name__ == "__main__":
    unittest.main()
