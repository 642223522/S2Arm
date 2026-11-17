"""出包可重建缓存（aoc / unpack / bake / srcver，11-16 起加 NativeAOT nxaot、出壳镜像 shell_src）总量上限（cache_retention.trim_build_caches，11-15）。合成目录夹具，期望在各断言旁手算：
上限 = 比例 ×（盘剩余 + 缓存现有），超了按最久没用删；1 小时内用过的、本次出包这款的、半成品 .tmp 不删"""
import os
import tempfile
import time
import unittest
from pathlib import Path

import jobcase  # noqa: F401
import cache_retention as cr


class BuildCacheCap(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); self.run = Path(self.t.name) / "s2arm"
        self.now = time.time()

    def tearDown(self):
        self.t.cleanup()

    def entry(self, rel, name, age_s, size=4096):
        d = self.run / rel / name; d.mkdir(parents=True)
        (d / "blob").write_bytes(b"x" * size)
        ts = self.now - age_s; os.utime(d, (ts, ts))
        return d

    def test_oldest_cold_removed_until_under_cap(self):
        unit = cr._tree_bytes(self.entry("cache/aoc", "probe", 99999)); (self.run / "cache/aoc/probe/blob").unlink(); (self.run / "cache/aoc/probe").rmdir()
        a = self.entry("cache/aoc", "0100aaaa00000000-k1", 40000)        # 最旧
        b = self.entry("cache/unpack", "0100BBBB00000000-k2", 30000)     # 第二旧，但是本款 → 保护
        c = self.entry("cache/bake", "0100cccc00000000-k3", 20000)       # 第三旧
        d = self.entry("cache/srcver", "t0100dddd00000000-k4", 60)       # 1 分钟前用过 → 热，保护
        tmp = self.entry("cache/aoc", "0100eeee00000000-k5.tmp.123", 50000)   # 半成品不算、不删
        free = 3 * unit   # 上限 = 0.25 ×（3 + 4）× unit = 1.75 unit → 要删到 ≤ 1.75：只能删 a、c（b 本款、d 热），剩 b + d = 2 unit，仍超但已无可删
        r = cr.trim_build_caches(self.run, current_gid="0100BBBB00000000", share=0.25, now=self.now, free_bytes=lambda: free)
        self.assertEqual(r["removedEntries"], 2)
        self.assertFalse(a.exists()); self.assertFalse(c.exists())
        self.assertTrue(b.exists() and d.exists() and tmp.exists())
        self.assertEqual(r["totalBytes"], 2 * unit)

    def test_under_cap_removes_nothing(self):
        a = self.entry("cache/aoc", "0100aaaa00000000-k1", 40000)
        r = cr.trim_build_caches(self.run, share=0.25, now=self.now, free_bytes=lambda: 10 ** 12)
        self.assertEqual(r["removedEntries"], 0); self.assertTrue(a.exists())

    def test_cap_follows_free_space(self):
        """同样两份缓存：盘宽松时不删，盘紧时删最旧的一份（上限随盘剩余变，不写死）"""
        a = self.entry("cache/aoc", "0100aaaa00000000-k1", 40000); b = self.entry("cache/aoc", "0100bbbb00000000-k2", 30000)
        unit = cr._tree_bytes(a)
        self.assertEqual(cr.trim_build_caches(self.run, share=0.5, now=self.now, free_bytes=lambda: 10 * unit)["removedEntries"], 0)   # 上限 0.5 × 12 = 6 unit ≥ 2
        r = cr.trim_build_caches(self.run, share=0.5, now=self.now, free_bytes=lambda: 0)   # 上限 0.5 × 2 = 1 unit → 删最旧的 a
        self.assertEqual(r["removedEntries"], 1); self.assertFalse(a.exists()); self.assertTrue(b.exists())

    def test_nxaot_and_shell_mirrors_count_locks_untouched(self):
        """11-16：NativeAOT 整机缓存与出壳按树镜像也进总量、最久没用的先删；.lock-* 取用锁目录不算、不删"""
        a = self.entry("cache/nxaot", "ios-arm64-old", 40000)           # 最旧
        b = self.entry("shell_src", "3f2a1b0c9d8e", 30000)               # 别的树的镜像，第二旧
        c = self.entry("cache/nxaot", "ios-arm64-new", 60)               # 刚用过 → 热
        lock = self.entry("cache/nxaot", ".lock-ios-arm64-new", 50000)   # 锁目录：再旧也不碰
        unit = cr._tree_bytes(a)
        r = cr.trim_build_caches(self.run, share=0.5, now=self.now, free_bytes=lambda: 0)   # 上限 0.5 ×（0 + 3）= 1.5 unit → 删 a、b 到 1 unit
        self.assertEqual(r["removedEntries"], 2); self.assertFalse(a.exists()); self.assertFalse(b.exists())
        self.assertTrue(c.exists() and lock.exists()); self.assertEqual(r["totalBytes"], unit)

    def test_roots_only_counts_given_dir(self):
        """另指的缓存目录（门禁共用 S2A_CS_CACHE）：只算它自己，运行区里的别的缓存不动"""
        other = self.entry("cache/aoc", "0100aaaa00000000-k1", 90000)
        shared = Path(self.t.name) / "nxaot_shared"; old = shared / "ios-arm64-a"; old.mkdir(parents=True); (old / "blob").write_bytes(b"x" * 4096)
        ts = self.now - 40000; os.utime(old, (ts, ts))
        r = cr.trim_build_caches(self.run, share=0.5, now=self.now, free_bytes=lambda: 0, roots=[shared])   # 上限 0.5 × 1 份 → 删它
        self.assertEqual(r["removedEntries"], 1); self.assertFalse(old.exists()); self.assertTrue(other.exists())


if __name__ == "__main__":
    unittest.main()
