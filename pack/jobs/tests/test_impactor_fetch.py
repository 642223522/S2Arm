# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""自编产物从固定来源下载（impactor.own_artifact）：网络中途断开要重下、半截文件不留。
替身下载器先写一段再抛错（同 urlretrieve 的 retrieval incomplete），期望的次数与文件直接写出来"""
import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))
import impactor  # noqa: E402

BODY = b"plumesign-bytes"
WANT = hashlib.sha256(BODY).hexdigest()


class OwnArtifactFetch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.cache = Path(self.tmp.name)

    def test_retry_after_truncated_download(self):
        calls = []
        def fetch(url, to):
            calls.append(url); Path(to).write_bytes(BODY[:5])
            if len(calls) == 1:
                raise OSError("retrieval incomplete: got only 5 out of 15 bytes")
            Path(to).write_bytes(BODY)
        got = impactor.own_artifact("p.exe", WANT, self.cache, fetch)
        self.assertEqual(calls, [impactor.OWN_RELEASE + "p.exe"] * 2)
        self.assertEqual(Path(got).read_bytes(), BODY)
        self.assertEqual(sorted(p.name for p in self.cache.iterdir()), ["p.exe"])

    def test_gives_up_after_three_and_leaves_no_partial(self):
        calls = []
        def fetch(url, to):
            calls.append(url); Path(to).write_bytes(BODY[:5]); raise OSError("retrieval incomplete")
        with self.assertRaises(impactor.OwnBuildError) as e:
            impactor.own_artifact("p.exe", WANT, self.cache, fetch)
        self.assertEqual(len(calls), 3)
        self.assertIn("3 次", str(e.exception)); self.assertIn("retrieval incomplete", str(e.exception))
        self.assertEqual(list(self.cache.iterdir()), [], "半截 .part 不留")


if __name__ == "__main__":
    unittest.main()
