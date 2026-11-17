"""一款一份资源（0.6.0，pack/jobs/onerom.py）：Mac 运行版本改用 iPhone 资源包那份 game.img（硬链接），romfs.std 删掉。期望全部手写：
  ① 开关开、两边 RomFS 相同 → linked：image/mac/game.img 与 .pack/game.img 是同一个文件（同 inode），romfs.std 没了，清单 files 去掉 romfs.std、
     记上 game.img 的大小；build.has_runtime_romfs 认它；再跑一次 → done、什么都不动
  ② 开关关 → skip，一个字节不动（0.5.x 行为不变）
  ③ RomFS 内容差一个字节 / 长度不同 → skip，原样不动
  ④ 建好链后断了（romfs.std 还在、清单还是旧的）→ 再跑接着做完（linked）
  ⑤ 中途放弃（stop 为真）→ stopped，原样不动
  ⑥ iPhone 重出包（新文件改名过去）：Mac 那个名字仍是旧数据（内容不变）；新包 RomFS 相同 → 换链到新包（同 inode）；不同 → 原样留着旧的
  ⑦ 只有 Mac（没有 iPhone 资源包）→ skip，romfs.std 留着
  ⑧ 起局包装 during：游戏跑满 delay 后台合并；游戏先退出 → 停下、原样不动"""
import json
import os
import struct
import time
import unittest
from pathlib import Path
from unittest import mock

from jobcase import JobCase  # noqa: I001（先导入：它把作业层目录加进模块路径）
import build  # noqa: E402
import layout  # noqa: E402
import library  # noqa: E402
import onerom  # noqa: E402

GID = "0100ABCD00000000"
PAGE = 16384


def write_img(path, romfs, gid=GID):
    """IMG v1 的头 + RomFS 段（pack/img.py 布局；目录表空）：头里 RomFS 段 [PAGE, PAGE + len)、整个文件长"""
    import importlib.util
    spec = importlib.util.spec_from_file_location("img_t", Path(build.__file__).parents[1] / "img.py")
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    total = PAGE + len(romfs)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".new")
    with open(tmp, "wb") as f:
        f.write(m.HDR.pack(m.MAGIC, 1, 0, gid.encode(), b"", PAGE, len(romfs), total, 0, total).ljust(PAGE, b"\0"))
        f.write(romfs)
    os.replace(tmp, path)



class OneRom(JobCase):
    def setUp(self):
        super().setUp()
        library.atomic(self.c.library / "catalog.json", dict(schema=1, games=[dict(id=GID, name="一款", packages=[])]))
        self.romfs = bytes(range(256)) * 4096 + b"tail"   # 1 MB 多一点，跨几块（CHUNK 4 MB 以内也覆盖收尾）
        self.mac = layout.image_mac(self.c, GID)
        (self.mac / "exefs").mkdir(parents=True)
        (self.mac / "exefs/main").write_bytes(b"MAIN")
        (self.mac / "romfs.std").write_bytes(self.romfs)
        self.manifest = dict(schema=1, engine="S2Arm", target="macos-arm64", files={"exefs/main": [4, ""], "romfs.std": [len(self.romfs), ""]})
        (self.mac / "manifest.json").write_text(json.dumps(self.manifest))
        self.img = layout.ios_pack(self.c, GID) / "game.img"
        write_img(self.img, self.romfs)
        on = mock.patch.dict(os.environ, {"S2A_UNIVERSAL_SHELL": "1"}); on.start(); self.addCleanup(on.stop)

    def manifest_files(self):
        return json.loads((self.mac / "manifest.json").read_text())["files"]

    def test_links_and_drops_std(self):
        r = onerom.dedupe(self.c, GID)
        self.assertEqual(r[0], "linked", r)
        link = self.mac / "game.img"
        self.assertTrue(os.path.samefile(link, self.img))
        self.assertFalse((self.mac / "romfs.std").exists())
        self.assertEqual(self.manifest_files(), {"exefs/main": [4, ""], "game.img": [PAGE + len(self.romfs), ""]})
        self.assertTrue(build.has_runtime_romfs(self.mac))
        self.assertEqual(onerom.dedupe(self.c, GID)[0], "done")

    def test_switch_off_touches_nothing(self):
        with mock.patch.dict(os.environ, {"S2A_UNIVERSAL_SHELL": "0"}):
            self.assertEqual(onerom.dedupe(self.c, GID)[0], "skip")
        self.assertTrue((self.mac / "romfs.std").is_file()); self.assertFalse((self.mac / "game.img").exists())
        self.assertEqual(self.manifest_files(), self.manifest["files"])

    def test_different_romfs_left_alone(self):
        changed = bytearray(self.romfs); changed[-1] ^= 1
        write_img(self.img, bytes(changed))
        self.assertEqual(onerom.dedupe(self.c, GID)[0], "skip")
        write_img(self.img, self.romfs + b"x")
        self.assertEqual(onerom.dedupe(self.c, GID)[0], "skip")
        self.assertEqual((self.mac / "romfs.std").read_bytes(), self.romfs); self.assertFalse((self.mac / "game.img").exists())
        self.assertEqual(self.manifest_files(), self.manifest["files"])

    def test_resume_after_link(self):
        os.link(self.img, self.mac / "game.img")   # 上次建好链就断了：romfs.std 还在、清单还是旧的
        self.assertEqual(onerom.dedupe(self.c, GID)[0], "linked")
        self.assertFalse((self.mac / "romfs.std").exists())
        self.assertIn("game.img", self.manifest_files()); self.assertNotIn("romfs.std", self.manifest_files())

    def test_stop_midway(self):
        self.assertEqual(onerom.dedupe(self.c, GID, stop=lambda: True)[0], "stopped")
        self.assertTrue((self.mac / "romfs.std").is_file()); self.assertFalse((self.mac / "game.img").exists())

    def test_iphone_repack(self):
        self.assertEqual(onerom.dedupe(self.c, GID)[0], "linked")
        old_ino = (self.mac / "game.img").stat().st_ino
        write_img(self.img, self.romfs)   # iPhone 重出包：新文件改名过去（RomFS 相同）
        self.assertNotEqual(self.img.stat().st_ino, old_ino)
        self.assertEqual((self.mac / "game.img").stat().st_ino, old_ino)   # Mac 那个名字仍连着旧数据
        self.assertEqual(onerom.dedupe(self.c, GID)[0], "linked")          # RomFS 相同 → 换链到新包
        self.assertTrue(os.path.samefile(self.mac / "game.img", self.img))
        changed = bytearray(self.romfs); changed[0] ^= 1
        write_img(self.img, bytes(changed))   # 再出一次、RomFS 变了（换了游戏版本）
        keep = (self.mac / "game.img").stat().st_ino
        self.assertEqual(onerom.dedupe(self.c, GID)[0], "skip")
        self.assertEqual((self.mac / "game.img").stat().st_ino, keep)   # Mac 留着它自己那份旧的，和它的程序配套

    def test_mac_only_keeps_std(self):
        self.img.unlink()
        self.assertEqual(onerom.dedupe(self.c, GID)[0], "skip")
        self.assertTrue((self.mac / "romfs.std").is_file())

    def test_during_launch(self):
        stop = onerom.background(self.c, GID, delay=0)   # 游戏跑过加载期：后台做完
        for _ in range(100):
            if not (self.mac / "romfs.std").exists():
                break
            time.sleep(0.05)
        stop()
        self.assertTrue(os.path.samefile(self.mac / "game.img", self.img))
        self.assertFalse((self.mac / "romfs.std").exists())

    def test_during_exit_before_delay(self):
        stop = onerom.background(self.c, GID, delay=60)
        stop()   # 游戏马上退出：后台还没开始就停下
        self.assertTrue((self.mac / "romfs.std").is_file()); self.assertFalse((self.mac / "game.img").exists())


if __name__ == "__main__":
    unittest.main()
