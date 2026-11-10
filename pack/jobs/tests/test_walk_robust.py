"""v0.2.3 遍历清理的行为单测（#343 同类）：期望按规则手写，不复述实现。
① core.read：路径中间一级是文件（games/.DS_Store/game.json）→ 当「没有」返回缺省，不抛；
② host_update.prune：games/ 里混着 .DS_Store、._x、desktop.ini 这类文件 → 照常清掉没人用的宿主、在用的留着，不抛；
③ host_update.tidy：收尾步骤抛错 → 不抛、提示一句「…没做完（不影响这次结果）」，返回 None；
④ scan_import 不把 exFAT 留下的 ._游戏.nsp 当原件"""
import json
from pathlib import Path
import unittest

from jobcase import JobCase
from core import atomic, read
import host_update
import layout


class WalkRobust(JobCase):
    def test_read_through_a_file_is_missing(self):
        f = self.root / "games"; f.mkdir(); (f / ".DS_Store").write_bytes(b"\0")
        self.assertEqual(read(f / ".DS_Store" / "game.json", {}), {})

    def test_prune_ignores_junk_entries(self):
        hosts = layout.hosts_mac(self.c); (hosts / "used").mkdir(parents=True); (hosts / "stale").mkdir()
        g = layout.games_root(self.c, self.c.library); (g / "Hades").mkdir(parents=True)
        atomic(g / "Hades" / layout.GAME_JSON, dict(schema=1, id="0100000000000001", hostMac="used"))
        for junk in (".DS_Store", "._Hades", "desktop.ini"): (g / junk).write_bytes(b"x")
        host_update.prune(self.c)
        self.assertEqual(sorted(p.name for p in hosts.iterdir() if p.is_dir()), ["used"])

    def test_tidy_swallows_and_says(self):
        said = []; self.c.emit = lambda kind, msg="", **k: said.append(msg)
        def boom(): raise NotADirectoryError("games/.DS_Store/game.json")
        self.assertIsNone(host_update.tidy(self.c, "清理不再用的旧运行层", boom))
        self.assertTrue(any("清理不再用的旧运行层没做完（不影响这次结果）" in m for m in said), said)

    def test_scan_import_skips_appledouble(self):   # exFAT 盘上访达留下的 ._Hades.nsp 不是原件；真原件照收
        import library
        d = self.root / "pick"; d.mkdir(); (d / "Hades.nsp").write_bytes(b"x"); (d / "._Hades.nsp").write_bytes(b"x")
        files, *_ = library.scan_import(self.c, d, partial=False)
        self.assertEqual(sorted(Path(f).name for f in files), ["Hades.nsp"])


if __name__ == "__main__":
    unittest.main()
