# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""只重跑改写阶段（pack/jobs/rewrite_refresh.py）的接线：改写器换成按模块打统计行的假程序，游戏库换成内存里的 game.json。
真改写器上的读数（11-11）：路易吉洋馆 3 命中 main、换进的产物等于改写器直接输出；两款反例 kit 一个字节不动；改写器崩的款抛错、kit 不动。"""
import os
import stat
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import jobcase  # noqa: F401  把 pack/jobs 加进路径（同其他作业层单测）
import rewrite_refresh as rr
from core import Failure


def fake_rewriter(d, hits):
    """假改写器：<NSO> <输出目录> <模块> [宽屏表] → 写 <模块>.patched.bin（内容 = 模块名 + new），统计行里 x18_spdyn 按 hits 给"""
    p = Path(d) / "fake-rewrite"
    p.write_text("#!/bin/sh\nprintf 'new-%s' \"$3\" > \"$2/$3.patched.bin\"\nprintf 'fx' > \"$2/$3.fixups.tsv\"\n"
                 "case \" " + " ".join(hits) + " \" in *\" $3 \"*) n=38;; *) n=0;; esac\n"
                 "echo \"$3 {'plain': 1, 'x18_spdyn': $n}\"\n")
    p.chmod(p.stat().st_mode | stat.S_IEXEC)
    return str(p)


class RewriteRefreshTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.exefs = self.tmp / "exefs"; self.exefs.mkdir()
        for m in ("main", "sdk", "subsdk0", "main.npdm", "rtld"):
            (self.exefs / m).write_bytes(b"x")
        self.info = {}
        self.events = []
        self.c = types.SimpleNamespace(private=self.tmp, emit=lambda kind, text, **_: self.events.append(text),
                                       catalog=lambda: {"games": [{"id": g} for g in ("0100A", "0100B")]})

    def kit(self, gid):
        k = self.tmp / ("kit-" + gid); k.mkdir(exist_ok=True)
        for m in ("main", "sdk", "subsdk0"):
            (k / f"{m}.patched.bin").write_bytes(b"old-" + m.encode()); (k / f"{m}.fixups.tsv").write_bytes(b"old")
        return k

    def run_refresh(self, games, hits, fail=()):
        binary = fake_rewriter(self.tmp, hits)
        real = rr.rewrite_modules   # 真的那份：桩里只在「这款要失败」时拦，其余照真函数跑假改写器
        cur = {}
        def exefs_of(c, game, work):
            cur["g"] = game["id"]; return self.exefs
        def rewrite(binary_, env, exefs, out, widen):
            if cur.get("g") in fail:
                raise Failure("fixture rewriter crashed")
            return real(binary_, env, exefs, out, widen)
        kits = {g: self.kit(g) for g in games}
        with patch.object(rr, "rewriter_id", return_value="rid-new"), patch.object(rr, "rewriter_bin", return_value=binary), \
             patch.object(rr, "rewrite_env", return_value=dict(os.environ)), patch.object(rr, "original_exefs", side_effect=exefs_of), \
             patch.object(rr.layout, "ios_kit", side_effect=lambda c, g: kits[g]), \
             patch.object(rr.layout, "game_info", side_effect=lambda c, g: self.info.get(g, {})), \
             patch.object(rr.layout, "update_info", side_effect=lambda c, g, **f: self.info.setdefault(g, {}).update(f)), \
             patch.object(rr, "rewrite_modules", side_effect=rewrite):
            return rr.refresh_ios(self.c, games), kits

    def test_affected_module_replaced_others_untouched_and_id_recorded(self):
        self.info["0100A"] = {"ios": {"shellId": "s1", "pack": "p1"}}
        updated, kits = self.run_refresh(["0100A"], hits=["main"])
        self.assertEqual(updated, ["0100A"])
        k = kits["0100A"]
        self.assertEqual((k / "main.patched.bin").read_bytes(), b"new-main", "命中的模块换成新产物")
        self.assertEqual((k / "main.fixups.tsv").read_bytes(), b"fx")
        self.assertEqual((k / "sdk.patched.bin").read_bytes(), b"old-sdk", "没命中的模块一个字节不动")
        self.assertEqual(self.info["0100A"]["ios"], {"shellId": "s1", "pack": "p1", "rewriterId": "rid-new"}, "记下改写器指纹，原有字段保留")

    def test_unaffected_game_keeps_kit_but_is_marked_checked(self):
        updated, kits = self.run_refresh(["0100A"], hits=[])
        self.assertEqual(updated, [])
        self.assertEqual((kits["0100A"] / "main.patched.bin").read_bytes(), b"old-main")
        self.assertEqual(self.info["0100A"]["ios"]["rewriterId"], "rid-new")

    def test_same_rewriter_is_skipped_without_running_it(self):
        self.info["0100A"] = {"ios": {"rewriterId": "rid-new"}}
        with patch.object(rr, "check_and_update", side_effect=AssertionError("不该核")):
            updated, _ = self.run_refresh(["0100A"], hits=["main"])
        self.assertEqual(updated, [])

    def test_one_game_failing_does_not_block_the_rest(self):
        updated, kits = self.run_refresh(["0100A", "0100B"], hits=["main"], fail=("0100A",))
        self.assertNotIn("0100A", updated)
        self.assertEqual((kits["0100A"] / "main.patched.bin").read_bytes(), b"old-main", "核不了的款保留原产物")
        self.assertNotIn("rewriterId", self.info.get("0100A", {}).get("ios", {}), "核不了不记指纹：下次再核")
        self.assertTrue(any("【黄】0100A" in e for e in self.events))


    def test_mac_runtime_updates_files_and_manifest(self):
        import json
        rt = self.tmp / "mac"; (rt / "exefs").mkdir(parents=True)
        for m in ("main", "sdk"):
            (rt / "exefs" / m).write_bytes(b"x"); (rt / f"{m}.patched.bin").write_bytes(b"old-" + m.encode() + b"-longer")
        files = {f"{m}.patched.bin": [len(b"old-" + m.encode() + b"-longer"), ""] for m in ("main", "sdk")}
        (rt / "manifest.json").write_text(json.dumps({"schema": 1, "files": files, "gameId": "0100A"}))
        binary = fake_rewriter(self.tmp, ["main"])
        with patch.object(rr, "rewriter_id", return_value="rid-new"), patch.object(rr, "rewriter_bin", return_value=binary), \
             patch.object(rr, "rewrite_env", return_value=dict(os.environ)):
            self.assertTrue(rr.refresh_mac(self.c, "0100A", rt))
            m = json.loads((rt / "manifest.json").read_text())
            self.assertEqual((rt / "main.patched.bin").read_bytes(), b"new-main")
            self.assertEqual(m["files"]["main.patched.bin"], [len(b"new-main"), ""], "清单大小跟着换：起局前按清单核文件")
            self.assertEqual(m["files"]["main.fixups.tsv"], [2, ""])
            self.assertEqual(m["files"]["sdk.patched.bin"], files["sdk.patched.bin"], "没命中的模块清单不动")
            self.assertEqual(m["rewriterId"], "rid-new")
            with patch.object(rr, "rewrite_modules", side_effect=AssertionError("同一改写器不该再核")):
                self.assertFalse(rr.refresh_mac(self.c, "0100A", rt))

if __name__ == "__main__":
    unittest.main()
