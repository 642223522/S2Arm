# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""0.6.0 通用壳两件套导出的小游戏包 .s2arm（pack/jobs/install.py export_s2arm，《文件与程序管理体系》B 项、⑦ ①）。
游戏库、资源包目录是真的（library.setup + jobcase.ios_fixture），程序包出包与改写核对用替身；导出的 .s2arm 解开逐项核，期望按夹具手写。"""
import hashlib
import io
import json
import sys
import tarfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install  # noqa: E402
import layout  # noqa: E402
import program_pack  # noqa: E402
import programs  # noqa: E402
import rewrite_refresh  # noqa: E402
import tests.test_jobs as tj  # noqa: E402
from tests.jobcase import ios_fixture  # noqa: E402

DYLIB = b"\xcf\xfa\xed\xfe unsigned dylib bytes"


class S2armExport(unittest.TestCase):
    setUp = tj.JobsTests.setUp; tearDown = tj.JobsTests.tearDown
    A, B = "0100000000010000", "0100000000020000"

    def fixture(self, names=None):
        names = names or {self.A: "测试游戏", self.B: "别的游戏"}
        self.c.catalog = lambda: {"games": [{"id": g, "name": n} for g, n in names.items()]}
        ios_fixture(self.c, self.A, compat=dict(rewriterId="RID", hostAbi=1, dmshChain="chain1"))
        self.pack = layout.image_ios(self.c, self.A) / ".pack"
        (self.pack / "game.img").write_bytes(b"BIG" * 1000)
        (self.pack / "shaders").mkdir(); (self.pack / "shaders/lib.bin").write_bytes(b"shader")
        pkg = Path(self.root) / "pkg"
        (pkg / "Games" / self.A).mkdir(parents=True)
        (pkg / program_pack.image_name(self.A)).write_bytes(DYLIB)
        (pkg / "Games" / self.A / "main.npdm").write_bytes(b"META")
        (pkg / program_pack.META).write_text(json.dumps(dict(name="测试游戏", display_version="1.0", host_abi=1, chain="chain1", rewriter_id="RID")))
        (pkg / program_pack.KEY).write_text("k")
        self.pkg = pkg

    def export(self, on=True):
        self.c.r.update(gameId=self.A, mode="export")
        with patch.object(program_pack, "enabled", lambda c: on), patch.object(program_pack, "build", lambda c, g, **k: self.pkg), \
                patch.object(rewrite_refresh, "refresh_ios", lambda c, games, **k: []):
            return install.export_s2arm(self.c, self.A)

    def members(self, path):
        raw = programs._decompress(Path(path).read_bytes())
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as t:
            ms = t.getmembers()
            assert all(m.type == tarfile.REGTYPE for m in ms), "只有普通文件条目"
            assert not any(m.pax_headers for m in ms), "不用 pax 头"
            return [m.name for m in ms], {m.name: t.extractfile(m).read() for m in ms}, t

    def test_s2arm_contents(self):
        self.fixture()
        r = self.export()
        out = Path(self.c.library) / "S2Arm 游戏包" / "测试游戏.s2arm"
        raw = out.read_bytes()
        self.assertEqual(raw[:4], b"\x28\xb5\x2f\xfd", "zstd 帧")
        self.assertTrue(raw[4] & 0x04, "zstd 帧头带内容校验标记（Content_Checksum_flag）")
        self.assertEqual(r["s2armPath"], str(out))
        names, data, t = self.members(out)
        self.assertEqual(names[0], "s2arm.json", "第一个条目是清单（手机读到它就能先显示）")
        head = json.loads(data["s2arm.json"])
        want_sha = hashlib.sha256(DYLIB).hexdigest()
        rest = sum(len(v) for k, v in data.items() if k != "s2arm.json")
        self.assertEqual(head, dict(format="s2arm", schema=1, title_id=self.A, name="测试游戏", display_version="1.0", host_abi=1, chain="chain1",
                                    rewriter_id="RID", image=program_pack.image_name(self.A), image_sha256=want_sha, source_sha256=want_sha,
                                    pack="cafe01", bytes=rest, signer=None))
        self.assertEqual(set(names), {"s2arm.json", "program/catalogue.json", f"program/{program_pack.image_name(self.A)}",
                                      f"program/Games/{self.A}/main.npdm", "pack/index.tsv", "pack/manifest.json", "pack/romfs/a", "pack/shaders/lib.bin"})
        self.assertEqual(data[f"program/{program_pack.image_name(self.A)}"], DYLIB)
        self.assertNotIn("pack/game.img", names, "资源本体不进 .s2arm")
        self.assertEqual(json.loads(data["program/catalogue.json"])["team"], None, "程序未签名，留给手机签")
        self.assertEqual(r["resourcePath"], str(self.pack / "game.img"), "资源本体给原位置，不拷")

    def test_folder_shared_and_recreated(self):
        # 只换这一款的 .s2arm，同文件夹别的东西不动；玩家删了整个文件夹，下次导出重新建
        self.fixture()
        folder = Path(self.c.library) / "S2Arm 游戏包"
        folder.mkdir(); (folder / "别的东西.txt").write_text("留着")
        self.export()
        self.assertTrue((folder / "别的东西.txt").is_file())
        import shutil
        shutil.rmtree(folder)
        self.export()
        self.assertTrue((folder / "测试游戏.s2arm").is_file())
        self.assertEqual([p.name for p in folder.iterdir() if p.name.endswith(".partial")], [], "不留临时文件")

    def test_same_name_gets_game_id(self):
        self.fixture({self.A: "同名", self.B: "同名"})
        self.assertTrue(self.export()["s2armPath"].endswith(f"同名 [{self.A[-4:]}].s2arm"))

    def test_existing_folder_kept_across_ui_language(self):
        # 固定文件夹：库根已有英文那个（第一次建时是英文界面），之后换中文界面也写进它，不建第二个
        self.fixture()
        en = Path(self.c.library) / "S2Arm Game Packs"; en.mkdir()
        self.c.r["uiLanguage"] = "zh-Hans"
        self.assertEqual(Path(self.export()["s2armPath"]).parent, en)
        self.assertFalse((Path(self.c.library) / "S2Arm 游戏包").exists())

    def test_english_ui_first_time_uses_english_name(self):
        self.fixture()
        self.c.r["uiLanguage"] = "ja"
        self.assertEqual(Path(self.export()["s2armPath"]).parent.name, "S2Arm Game Packs")

    def test_path_too_long_for_ustar_is_reported(self):
        # 只用 ustar（手机只认它）：放不下的路径不改用 pax 长名，报错
        self.fixture()
        deep = self.pkg / "Games" / self.A / ("x" * 120) / ("y" * 120)
        deep.mkdir(parents=True); (deep / ("z" * 60)).write_bytes(b"1")
        from core import Failure
        with self.assertRaises(Failure):
            self.export()

    def test_install_export_routes_by_switch(self):
        # 导出一款：开关开 → .s2arm；开关关 → 照旧的自签导出（export_phone）
        self.fixture()
        self.c.r.update(gameId=self.A, mode="export")
        calls = []
        with patch.object(install, "export_s2arm", lambda c, g: calls.append(("s2arm", g)) or {}), \
                patch.object(install, "export_phone", lambda c, g=None: calls.append(("phone", g)) or {}), \
                patch.object(install, "ios_pack", lambda c, g: self.pack), patch("downstream.requested", lambda c, g: None, create=True):
            for on in (True, False):
                with patch.object(program_pack, "enabled", lambda c, on=on: on):
                    install._install(self.c)
        self.assertEqual(calls, [("s2arm", self.A), ("phone", self.A)])


if __name__ == "__main__":
    unittest.main()
