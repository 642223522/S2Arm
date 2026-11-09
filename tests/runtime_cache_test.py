#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""随包运行时下载件缓存：命中不联网、未命中才下、哈希不符拒打；期望按规则手写。"""
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "launchers/shared"))
import runtime_cache  # noqa: E402

GOOD = b"official bytes"
SHA = hashlib.sha256(GOOD).hexdigest()


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.cache = Path(self.tmp.name)
        self.files = dict(runtime_cache.FILES); self.wheels = dict(runtime_cache.WHEELS)
        self.addCleanup(lambda: setattr(runtime_cache, "FILES", self.files)); self.addCleanup(lambda: setattr(runtime_cache, "WHEELS", self.wheels))
        runtime_cache.FILES = {"a.zip": ("https://example.invalid/a.zip", SHA)}
        runtime_cache.WHEELS = {"p": {"x==1": ("x-1.whl", SHA)}}

    def test_hit_does_not_fetch(self):
        (self.cache / "a.zip").write_bytes(GOOD)
        def no_network(url, to): raise AssertionError("命中缓存不该联网")
        self.assertEqual(runtime_cache.fetch_file("a.zip", self.cache, no_network).read_bytes(), GOOD)

    def test_miss_fetches_once_and_then_hits(self):
        calls = []
        def fake(url, to): calls.append(url); Path(to).write_bytes(GOOD)
        runtime_cache.fetch_file("a.zip", self.cache, fake); runtime_cache.fetch_file("a.zip", self.cache, fake)
        self.assertEqual(calls, ["https://example.invalid/a.zip"])

    def test_wrong_hash_rejected_and_removed(self):
        (self.cache / "a.zip").write_bytes(b"tampered")
        with self.assertRaisesRegex(SystemExit, "拒打"): runtime_cache.fetch_file("a.zip", self.cache, lambda u, t: None)
        self.assertFalse((self.cache / "a.zip").exists())

    def test_download_failure_is_named(self):
        def down(url, to): raise OSError("reset")
        with self.assertRaisesRegex(SystemExit, "取不到"): runtime_cache.fetch_file("a.zip", self.cache, down)
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_unpinned_file_rejected(self):
        with self.assertRaisesRegex(SystemExit, "没有钉版哈希"): runtime_cache.fetch_file("other.zip", self.cache)

    def test_wheel_hit_skips_download(self):
        folder = self.cache / "wheels/p"; folder.mkdir(parents=True); (folder / "x-1.whl").write_bytes(GOOD)
        def no_download(*_): raise AssertionError("命中缓存不该下载")
        self.assertEqual(runtime_cache.wheelhouse(["x==1"], "p", no_download, self.cache), folder)

    def test_wheel_miss_downloads_only_missing(self):
        got = []
        def fake(folder, missing): got.append(missing); (folder / "x-1.whl").write_bytes(GOOD)
        runtime_cache.wheelhouse(["x==1"], "p", fake, self.cache); self.assertEqual(got, [["x==1"]])

    def test_wheel_wrong_hash_rejected(self):
        with self.assertRaisesRegex(SystemExit, "拒打"):
            runtime_cache.wheelhouse(["x==1"], "p", lambda f, m: (f / "x-1.whl").write_bytes(b"bad"), self.cache)

    def test_pin_change_requires_table_update(self):
        with self.assertRaisesRegex(SystemExit, "不一致"): runtime_cache.wheelhouse(["x==2"], "p", lambda f, m: None, self.cache)


class RealTables(unittest.TestCase):
    def test_tables_match_requirements_file(self):
        text = (ROOT / "launchers/macos/requirements-runtime.txt").read_text(encoding="utf-8").splitlines()
        pins = {l.strip() for l in text if "==" in l and not l.startswith("#")}
        for platform in ("win_amd64", "macos_arm64"):
            self.assertEqual(set(runtime_cache.WHEELS[platform]), pins, platform)


if __name__ == "__main__":
    unittest.main()
