"""游戏库布局（pack/jobs/layout.py）单测：命名规则、旧布局迁移、中断续做。期望值按设计文档的规则手写，不跑被测实现推导。"""
import hashlib
import json
import os
import unittest
from unittest.mock import patch

from jobcase import JobCase

import layout
from core import atomic

A, B, C = "0100000000010000", "0100000000020000", "0100000000030000"


class FolderNameTests(unittest.TestCase):
    def test_rules(self):
        cases = [
            (("The Legend of Zelda: Tears of the Kingdom", A, ()), "The Legend of Zelda Tears of the Kingdom"),   # 冒号删掉、空格合一
            (("  Pokémon™  Scarlet. ", A, ()), "Pokmon Scarlet"),                                                   # 非 ASCII 删、首尾空格和点去掉
            (("塞尔达传说", A, ()), A),                                                                               # 没有可用字符 → 游戏号
            (("CON", A, ()), A), (("nul.txt", A, ()), A),                                                           # Windows 保留名
            (("x" * 60, A, ()), "x" * 48),                                                                           # 最长 48
            (("Hades", B, ("hades",)), "Hades [0000]"),                                                              # 重名（不分大小写）→ 加号后 4 位
            (("Hades", "01000000000ABCD0", ("Hades",)), "Hades [BCD0]"),
            (("", A.lower(), ()), A),                                                                                # 游戏号统一大写
        ]
        for args, want in cases:
            with self.subTest(args=args):
                self.assertEqual(layout.folder_name(*args), want)


class MigrateTests(JobCase):
    def old_library(self):
        """v0.1.7 布局：A 有 Mac 现行 + 上一版运行版本、出包缓存、存档、着色器缓存、键位；B 只有封面和存档；C 名字全中文"""
        L = self.c.library
        (L / ".s2arm-layout.json").unlink(missing_ok=True)  # 删掉新库标记，模拟旧布局
        atomic(L / "catalog.json", dict(schema=1, games=[dict(id=A, name="Super Game: Deluxe"), dict(id=B, name="Other"), dict(id=C, name="中文游戏")]))
        rel = L / "games" / A / "releases"
        for name, host in (("k1-old", b"old host"), ("k2-cur", b"current host")):
            exe = rel / name / "S2ArmGame.app/Contents/MacOS/s2arm-host"; exe.parent.mkdir(parents=True); exe.write_bytes(host)
            (rel / name / "romfs").mkdir(); (rel / name / "romfs/data.bin").write_bytes(name.encode())
            atomic(rel / name / "manifest.json", dict(schema=1, files={"romfs/data.bin": [1, "x"], "S2ArmGame.app/Contents/MacOS/s2arm-host": [1, "y"]}))
        (L / "games" / A / "current").symlink_to("releases/k2-cur")
        (L / "games" / A / "cover.jpg").write_bytes(b"jpgA")
        (L / "games" / A / "custom.json").write_text('{"name":"我的"}')
        (L / "cache" / A / "key").mkdir(parents=True); (L / "cache" / A / "key/x").write_text("c")
        (L / "saves" / A / "bis").mkdir(parents=True); (L / "saves" / A / "bis/s.dat").write_text("saveA")
        (L / "save-backups" / A).mkdir(parents=True)
        (L / "runtime-cache" / A / "shaders").mkdir(parents=True)
        (L / "mappings").mkdir(); (L / "mappings" / (A + ".json")).write_text('{"k":1}')
        (L / "games" / B).mkdir(parents=True); (L / "games" / B / "cover.jpg").write_bytes(b"jpgB")
        (L / "saves" / B).mkdir(parents=True); (L / "saves" / B / "s").write_text("saveB")
        (L / "saves" / C).mkdir(parents=True)
        return L

    def test_migrates_per_game_and_splits_mac_host(self):
        L = self.old_library()
        self.assertTrue(layout.migrate(self.c))
        a, b, c = L / "games/Super Game Deluxe", L / "games/Other", L / ("games/" + C)
        self.assertEqual({p.name for p in (L / "games").iterdir()}, {a.name, b.name, c.name})
        for d, gid in ((a, A), (b, B), (c, C)):
            self.assertEqual(json.loads((d / "game.json").read_text())["id"], gid)
        self.assertEqual((a / "image/mac/romfs/data.bin").read_bytes(), b"k2-cur")      # 现行那份变成镜像
        self.assertFalse((a / "image/mac/S2ArmGame.app").exists())                     # 宿主拆出去了
        sha = hashlib.sha256(b"current host").hexdigest()[:12]
        self.assertEqual((L / "hosts/mac" / sha / "S2ArmGame.app/Contents/MacOS/s2arm-host").read_bytes(), b"current host")
        self.assertEqual(json.loads((a / "game.json").read_text())["hostMac"], sha)
        self.assertEqual(json.loads((a / "image/mac/manifest.json").read_text())["files"], {"romfs/data.bin": [1, "x"]})
        self.assertFalse((a / "releases").exists()); self.assertFalse((a / "current").exists())   # 上一版删掉
        self.assertEqual((a / "build/key/x").read_text(), "c")
        self.assertEqual((a / "saves/bis/s.dat").read_text(), "saveA")
        self.assertTrue((a / "save-backups").is_dir()); self.assertTrue((a / "shader-cache/shaders").is_dir())
        self.assertEqual((a / "input.json").read_text(), '{"k":1}')
        self.assertEqual((a / "cover.jpg").read_bytes(), b"jpgA"); self.assertEqual((a / "custom.json").read_text(), '{"name":"我的"}')
        self.assertEqual((b / "saves/s").read_text(), "saveB"); self.assertEqual((b / "cover.jpg").read_bytes(), b"jpgB")
        for gone in ("cache", "saves", "save-backups", "runtime-cache", "mappings"):
            self.assertFalse((L / gone).exists(), gone)
        self.assertEqual(json.loads((L / ".s2arm-layout.json").read_text())["version"], layout.VERSION)
        self.assertFalse(layout.migrate(self.c))                                        # 再跑：已迁完，什么都不动

    def test_interrupted_migration_resumes(self):
        L = self.old_library()
        real = layout._split_release
        def boom(c, gid, d):
            if gid == B:
                raise OSError("断电")
            return real(c, gid, d)
        with patch.object(layout, "_split_release", side_effect=boom), self.assertRaises(OSError):
            layout.migrate(self.c)
        self.assertEqual(json.loads((L / ".s2arm-layout.json").read_text()), dict(version=1, games=[A]))
        self.c._layout_idx = None
        layout.migrate(self.c)
        self.assertEqual((L / "games/Other/saves/s").read_text(), "saveB")
        self.assertEqual((L / "games/Super Game Deluxe/saves/bis/s.dat").read_text(), "saveA")
        self.assertEqual(json.loads((L / ".s2arm-layout.json").read_text())["version"], layout.VERSION)

    def test_game_dir_found_by_game_json_not_folder_name(self):
        L = self.old_library(); layout.migrate(self.c)
        os.rename(L / "games/Other", L / "games/玩家改的名字")
        self.c._layout_idx = None
        self.assertEqual(layout.game_dir(self.c, B), L / "games/玩家改的名字")
        d = layout.game_dir(self.c, "0100000000040000", english="Other")   # 新款撞了别人原来的名字也行（按现存文件夹判重）
        self.assertEqual(d.name, "Other")


class LocationTests(JobCase):
    """游戏库结构 v3：多个存放位置 + 索引表。期望按设计文档的规则手写"""
    def setUp(self):
        super().setUp()
        atomic(self.c.library / "catalog.json", dict(schema=1, games=[dict(id=A, name="Alpha"), dict(id=B, name="Beta")]))
        self.disk = self.root / "移动硬盘" / "S2Arm"

    def fresh(self):
        self.c._layout_idx = None   # 新作业进程：索引从磁盘读
        return self.c

    def test_game_in_second_location_found_through_index(self):
        d = layout.game_dir(self.c, A, location=self.disk)
        self.assertEqual(d, self.disk / "games" / "Alpha")
        self.assertEqual(json.loads((self.disk / ".s2arm-location.json").read_text())["schema"], 1)
        self.assertEqual(layout.state(self.fresh(), A), ("ok", d))
        self.assertEqual(layout.root_of(self.c, A), self.disk)
        layout.game_dir(self.c, B)   # 没指定位置、没用过别的位置 → 默认位置
        self.assertEqual(layout.find_game(self.fresh(), B), self.c.library / "games" / "Beta")

    def test_renamed_folder_offline_location_and_missing_folder(self):
        d = layout.game_dir(self.c, A, location=self.disk)
        os.rename(d, d.with_name("改过的名字"))
        self.assertEqual(layout.state(self.fresh(), A), ("ok", self.disk / "games" / "改过的名字"))   # 扫这个位置认回来
        os.rename(self.disk, self.disk.with_name("拔掉了"))
        self.assertEqual(layout.state(self.fresh(), A), ("offline", self.disk))
        with self.assertRaises(Exception):
            layout.game_dir(self.c, A)                                                             # 位置没连上不新建
        os.rename(self.disk.with_name("拔掉了"), self.disk)
        os.rename(self.disk / "games" / "改过的名字", self.root / "挪走了")
        self.assertEqual(layout.state(self.fresh(), A), ("missing", self.disk))
        with self.assertRaises(Exception):
            layout.relink(self.c, B, self.root / "挪走了")                                         # 游戏号对不上：拒
        back = layout.relink(self.c, A, self.root / "挪走了")                                      # 在 games 外：搬回原来的位置
        self.assertEqual(back, self.disk / "games" / "挪走了"); self.assertFalse((self.root / "挪走了").exists())
        self.assertEqual(layout.state(self.fresh(), A), ("ok", back))
        (self.c.library / "games").mkdir(exist_ok=True)
        os.rename(back, self.c.library / "games" / "Alpha 副本")
        layout.relink(self.c, A, self.c.library / "games" / "Alpha 副本")                         # 已在某个位置的 games 下：原地认
        self.assertEqual(layout.state(self.fresh(), A), ("ok", self.c.library / "games" / "Alpha 副本"))

    def test_move_same_volume_and_cross_volume_with_check(self):
        d = layout.game_dir(self.c, A)
        (d / "saves").mkdir(); (d / "saves" / "s.dat").write_text("存档")
        moved = layout.move_game(self.c, A, self.disk)                                            # 同卷：改名
        self.assertEqual((moved / "saves" / "s.dat").read_text(), "存档"); self.assertFalse(d.exists())
        self.assertEqual(layout.find_game(self.fresh(), A), moved)
        with patch.object(layout, "_same_volume", return_value=False):                            # 跨卷：拷、核对、删旧
            back = layout.move_game(self.c, A, self.c.library)
        self.assertEqual((back / "saves" / "s.dat").read_text(), "存档"); self.assertFalse(moved.exists())
        self.assertEqual(layout.find_game(self.fresh(), A), back)

    def test_last_used_location_is_default_for_new_games(self):
        layout.use_location(self.c, self.disk)
        self.assertEqual(layout.game_dir(self.fresh(), B).parent.parent, self.disk)


class VolumeNameTests(unittest.TestCase):
    """存放位置下拉框 / 「未连接」里的盘名：Windows 按盘符（原先只认 Mac 的 /Volumes，Windows 每个盘都叫系统盘）"""
    def test_windows_and_mac_names(self):
        import library
        cases = [("C:\\S2Arm", "", "系统盘"), ("D:\\S2Arm", "Games", "Games（D:）"), ("e:\\x", "", "E 盘"), ("\\\\nas\\share\\S2Arm", "", "\\\\nas\\share")]
        for path, label, want in cases:
            with self.subTest(path=path), patch.object(library.os, "name", "nt"), patch.dict(os.environ, {"SystemDrive": "C:"}), \
                 patch.object(library, "_win_volume_label", return_value=label):
                self.assertEqual(library._volume(path), want)
        self.assertEqual(library._volume("/Volumes/移动硬盘/S2Arm"), "移动硬盘")


if __name__ == "__main__":
    unittest.main()
