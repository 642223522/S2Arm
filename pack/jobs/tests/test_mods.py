# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""资源替换类 mod 导入（pack/jobs/mods.py）与装机推送（install.push_mods）：游戏库换成临时目录，期望手写"""
import tempfile
import types
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import jobcase  # noqa: F401
import install
import layout
import mods
from core import Failure

GID = "0100ABCD00010000"


class ModsTests(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())
        (self.t / "priv").mkdir()
        self.c = types.SimpleNamespace(private=self.t / "priv", msgs=[], diags=[])
        self.c.emit = lambda k, m, **_: self.c.msgs.append(m)
        self.c.diagnostic = lambda m, **k: self.c.diags.append((m, k.get("code")))
        p = patch.object(layout, "path", side_effect=lambda c, gid, *parts, create=True: self.t.joinpath("lib", gid.upper(), *parts))
        p.start(); self.addCleanup(p.stop)
        self.game = {"id": GID}

    def tree(self, files, root="src"):
        r = self.t / root
        for rel, data in files.items():
            f = r / rel; f.parent.mkdir(parents=True, exist_ok=True); f.write_bytes(data)
        return r

    def zip(self, files, name="pack.zip", extra=()):
        z = self.t / name
        with zipfile.ZipFile(z, "w") as w:
            for rel, data in files.items():
                w.writestr(rel, data)
            for info, data in extra:
                w.writestr(info, data)
        return z

    def test_atmosphere_zip(self):
        z = self.zip({f"atmosphere/contents/{GID}/romfs/Data/a.bin": b"AA", f"atmosphere/contents/{GID}/romfs/b.txt": b"B"}, "HD Textures.zip")
        r = mods.import_paths(self.c, self.game, [str(z)])
        self.assertEqual(r["imported"], ["HD Textures"])
        d = self.t / "lib" / GID / "mods" / "HD Textures" / "romfs"
        self.assertEqual(((d / "Data/a.bin").read_bytes(), (d / "b.txt").read_bytes()), (b"AA", b"B"))
        self.assertEqual(mods.listing(self.c, self.game), [{"name": "HD Textures", "enabled": True, "files": 2, "bytes": 3, "code": 0}])

    def test_variants_and_other_game_and_exefs(self):
        # Ryujinx 结构 <程序号>/<名字>/romfs：同一包里两个变体各成一份；标了别的程序号的不收；exefs 代码补丁跟着那份 mod 收进 exefs/、报一句「重新打包后生效」（11-15）
        src = self.tree({f"{GID}/Blue/romfs/x.bin": b"1", f"{GID}/Red/romfs/x.bin": b"2",
                         "0100FFFF00000000/Other/romfs/y.bin": b"3", f"{GID}/Blue/exefs/1.pchtxt": b"@nsobid-00"}, "Colors")
        r = mods.import_paths(self.c, self.game, [str(src)])
        self.assertEqual(sorted(r["imported"]), ["Colors - Blue", "Colors - Red"])
        self.assertTrue(any("0100FFFF00000000" in n for n in r["notes"]))
        self.assertIn("「Colors - Blue」带 1 份代码补丁：重新打包这款（或 S 级优化升级）后生效", r["notes"])
        self.assertFalse((self.t / "lib" / GID / "mods" / "Colors - Other").exists())
        self.assertEqual([(m["name"], m["files"], m["code"]) for m in mods.listing(self.c, self.game)], [("Colors - Blue", 1, 1), ("Colors - Red", 1, 0)])
        self.assertEqual((self.t / "lib" / GID / "mods" / "Colors - Blue" / "exefs" / "1.pchtxt").read_bytes(), b"@nsobid-00")

    def test_code_only_mod_index_and_digest(self):
        # 只带代码补丁的 mod（60 帧 / 去黑边这类）：exefs/ 与 exefs_patches/<名>/ 都收进 mods/<名>/exefs；README 等别的文件不收。
        # code_index：开着、关着的都进索引（运行时按文件夹在不在开关），路径 = <mod 名>/<文件>；code_digest：内容变才变，开关不变，没有代码补丁 = "-"
        self.assertEqual(mods.code_digest(self.c, GID), "-")
        self.assertIsNone(mods.code_index(self.c, self.game))
        src = self.tree({f"atmosphere/exefs_patches/x/{'AB' * 16}.ips": b"PATCHEOF", "readme.txt": b"r",
                         f"atmosphere/contents/{GID}/exefs/60fps.pchtxt": b"@nsobid-AB"}, "Smooth")
        r = mods.import_paths(self.c, self.game, [str(src)])
        self.assertEqual(sorted(r["imported"]), ["Smooth", "Smooth - x"])   # Atmosphere exefs_patches/<名>/ 也认，单成一份
        home = self.t / "lib" / GID / "mods"
        self.assertEqual([p.name for p in (home / "Smooth - x" / "exefs").iterdir()], [f"{'AB' * 16}.ips"])
        mods.remove(self.c, self.game, ["Smooth - x"])
        self.assertEqual(sorted(p.relative_to(home / "Smooth").as_posix() for p in (home / "Smooth").rglob("*") if p.is_file()), ["exefs/60fps.pchtxt"])
        d1 = mods.code_digest(self.c, GID)
        mods.set_enabled(self.c, self.game, {"Smooth": False})
        self.assertEqual(mods.code_digest(self.c, GID), d1)   # 只关掉：记号不变（运行时开关，不用重编）
        out = Path(mods.code_index(self.c, self.game))
        self.assertEqual(out, self.t / "priv" / "community-cache" / "games" / GID / "mod")
        rows = [l.split("\t") for l in (out / "INDEX.tsv").read_text(encoding="utf-8").splitlines()]
        import hashlib
        self.assertEqual(rows, [["game", "title_id", "path", "type", "source", "license", "in_pack", "sha256", "mod", "origin"],
                                ["", GID, "Smooth/60fps.pchtxt", "pchtxt", "mod", "", "yes", hashlib.sha256(b"@nsobid-AB").hexdigest(), "Smooth", "Smooth/60fps.pchtxt"]])
        self.assertEqual((out / "Smooth" / "60fps.pchtxt").read_bytes(), b"@nsobid-AB")
        (home / ".off-Smooth" / "exefs" / "60fps.pchtxt").write_bytes(b"@nsobid-CD")
        self.assertNotEqual(mods.code_digest(self.c, GID), d1)   # 内容变了：要重编
        mods.remove(self.c, self.game, ["Smooth"])
        self.assertEqual((mods.code_digest(self.c, GID), mods.code_index(self.c, self.game), out.exists()), ("-", None, False))   # 删光：索引目录也清掉

    def test_bare_romfs_folder_and_replace(self):
        src = self.tree({"romfs/a.bin": b"old"}, "Fix")
        mods.import_paths(self.c, self.game, [str(src / "romfs")])
        self.assertEqual([m["name"] for m in mods.listing(self.c, self.game)], ["Fix"])   # 直接选 romfs 文件夹：名字取上一级
        src2 = self.tree({"romfs/a.bin": b"new", "romfs/c.bin": b"c"}, "Fix2")
        mods.import_paths(self.c, self.game, [str(src2)])
        mods.import_paths(self.c, self.game, [str(src2)])   # 同名再导入 = 整份替换，不叠旧文件
        self.assertEqual((self.t / "lib" / GID / "mods" / "Fix2" / "romfs" / "a.bin").read_bytes(), b"new")
        self.assertEqual([(m["name"], m["files"]) for m in mods.listing(self.c, self.game)], [("Fix", 1), ("Fix2", 2)])   # 按名字升序

    def test_rejects(self):
        with self.assertRaises(Failure):   # 没有 romfs
            mods.import_paths(self.c, self.game, [str(self.zip({"readme.txt": b"x"}))])
        with self.assertRaises(Failure):   # 不是 zip 也不是文件夹
            (self.t / "a.7z").write_bytes(b"7z"); mods.import_paths(self.c, self.game, [str(self.t / "a.7z")])
        # 逃出目录的条目不解开
        z = self.zip({f"{GID}/m/romfs/ok.bin": b"ok"}, "evil.zip", extra=[("../../escape.bin", b"x")])
        mods.import_paths(self.c, self.game, [str(z)])
        self.assertFalse((self.t / "escape.bin").exists())
        self.assertEqual([m["name"] for m in mods.listing(self.c, self.game)], ["evil"])

    def test_remove(self):
        mods.import_paths(self.c, self.game, [str(self.tree({"romfs/a": b"a"}, "One"))])
        mods.remove(self.c, self.game, ["One"])
        self.assertEqual(mods.listing(self.c, self.game), [])
        with self.assertRaises(Failure):
            mods.remove(self.c, self.game, ["Nope"])

    def test_toggle_off_on_reimport_and_remove(self):
        # 关掉 = 文件夹改名为 .off-<名字>（起局不叠、装机不推）；打开改回；关着时同名再导入 = 新的开着、旧的关着那份删掉；关着也能删。期望手写
        home = self.t / "lib" / GID / "mods"
        mods.import_paths(self.c, self.game, [str(self.tree({"romfs/a": b"a"}, "One"))])
        mods.set_enabled(self.c, self.game, {"One": False})
        self.assertEqual(([p.name for p in home.iterdir()], mods.listing(self.c, self.game)[0]["enabled"]), ([".off-One"], False))
        mods.set_enabled(self.c, self.game, {"One": True})
        self.assertEqual([p.name for p in home.iterdir()], ["One"])
        mods.set_enabled(self.c, self.game, {"One": False})
        mods.import_paths(self.c, self.game, [str(self.tree({"romfs/a": b"new"}, "One"))])
        self.assertEqual(([p.name for p in home.iterdir()], (home / "One/romfs/a").read_bytes()), (["One"], b"new"))
        mods.set_enabled(self.c, self.game, {"One": False})
        mods.remove(self.c, self.game, ["One"])
        self.assertEqual(list(home.iterdir()), [])
        with self.assertRaises(Failure):
            mods.set_enabled(self.c, self.game, {"Nope": True})

    def test_push_follows_toggle(self):
        # 关掉后装机：机上那份删掉；再打开：重新推
        mods.import_paths(self.c, self.game, [str(self.tree({"romfs/a": b"a"}, "One"))])
        calls = []
        cl = types.SimpleNamespace(put=lambda src, rel: calls.append(("put", rel)), rm=lambda rel: (calls.append(("rm", rel)) or (True, "")))
        ph = types.SimpleNamespace(client=lambda w: cl)
        had = install.push_mods(self.c, ph, GID, {})
        mods.set_enabled(self.c, self.game, {"One": False}); calls.clear()
        had = install.push_mods(self.c, ph, GID, had)
        base = f"Documents/games/{GID}/mods"
        self.assertEqual((calls, had), ([("rm", f"{base}/One")], {}))
        mods.set_enabled(self.c, self.game, {"One": True}); calls.clear()
        install.push_mods(self.c, ph, GID, had)
        self.assertEqual(calls, [("put", f"{base}/One/romfs/a")])

    def test_push_only_changed_and_removed(self):
        mods.import_paths(self.c, self.game, [str(self.tree({"romfs/a": b"a", "romfs/d/b": b"b"}, "Keep"))])
        mods.import_paths(self.c, self.game, [str(self.tree({"romfs/n": b"n"}, "New"))])
        keep = mods.fingerprint(self.t / "lib" / GID / "mods" / "Keep")
        calls = []
        cl = types.SimpleNamespace(put=lambda src, rel: calls.append(("put", rel)), rm=lambda rel: (calls.append(("rm", rel)) or (True, "")))
        ph = types.SimpleNamespace(client=lambda w: cl)
        now = install.push_mods(self.c, ph, GID, {"Keep": keep, "Gone": "x"})
        base = f"Documents/games/{GID}/mods"
        self.assertEqual(calls, [("rm", f"{base}/Gone"), ("put", f"{base}/New/romfs/n")])   # Keep 没变不推；Gone 电脑上删了机上也删
        self.assertEqual(set(now), {"Keep", "New"})
        calls.clear()
        self.assertEqual(install.push_mods(self.c, ph, GID, now), now)
        self.assertEqual(calls, [])

    def test_push_failure_is_warning(self):
        mods.import_paths(self.c, self.game, [str(self.tree({"romfs/a": b"a"}, "A"))])
        def bad(src, rel): raise RuntimeError("断开")
        ph = types.SimpleNamespace(client=lambda w: types.SimpleNamespace(put=bad, rm=lambda rel: (True, "")))
        self.assertEqual(install.push_mods(self.c, ph, GID, {}), {})   # 没推成：不记，下次再推
        self.assertEqual([d[1] for d in self.c.diags], ["resource_transfer_failed"])


if __name__ == "__main__":
    unittest.main()
