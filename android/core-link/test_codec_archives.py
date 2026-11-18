#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""game 模式的编解码静态库从哪来（android/core-link/CodecArchives.cmake，经 cmake -P 真跑）。

静态服务（S2A_CS_SERVICES=static）时，cs/build.sh 已把本次刚编的三份库写进 link.txt、并核过恰好三份；
自动探测不能再从共享缓存里另挑一份加到链接行最前面——缓存目录名是配方哈希，按名排序取最后一个是
任意一代，旧的那份会抢先提供 s2a_avc_* / s2a_vp9_* / s2a_opus_* 的定义。非静态（链接探针 / ctest_link
的 game 档没有 link.txt）照旧按缓存约定找。
"""
import argparse
from pathlib import Path
import subprocess
import tempfile
import unittest

CMAKE = "cmake"
HELPER = Path(__file__).with_name("CodecArchives.cmake")

# 每种库两代：名字排在后面的那代是旧的（不是本次 cs/build.sh 写进 link.txt 的那份）。
GENERATIONS = {
    "avc": ("codecs/avc-1a2b/libs2a_avc.a", "codecs/avc-f00d/libs2a_avc.a"),
    "opus": ("codecs/opus-1.6.1-77aa/s2a-1111/libs2a_opus.a", "codecs/opus-1.6.1-77aa/s2a-eeee/libs2a_opus.a"),
    "vpx": ("codecs/vpx-1.17.0-31bc/s2a-2222/libs2a_vpx.a", "codecs/vpx-1.17.0-31bc/s2a-dddd/libs2a_vpx.a"),
}


class CodecArchiveTests(unittest.TestCase):
    def pick(self, cs_services):
        with tempfile.TemporaryDirectory(prefix="s2a-codec-pick-") as work:
            root = Path(work)
            cache = root / "cache"
            for pair in GENERATIONS.values():
                for rel in pair:
                    (cache / rel).parent.mkdir(parents=True, exist_ok=True)
                    (cache / rel).write_bytes(b"!<arch>\n")
            output, script = root / "picked.txt", root / "pick.cmake"
            script.write_text(
                'set(S2A_CS_SERVICES "${CS}")\n'
                'include("${HELPER}")\n'
                's2a_android_codec_archives(picked "${CACHE}")\n'
                'file(WRITE "${OUTPUT}" "")\n'
                'foreach(entry IN LISTS picked)\n'
                '  file(APPEND "${OUTPUT}" "${entry}\\n")\n'
                'endforeach()\n', encoding="utf-8")
            result = subprocess.run([CMAKE, f"-DHELPER={HELPER}", f"-DCACHE={cache}", f"-DCS={cs_services}",
                                     f"-DOUTPUT={output}", "-P", str(script)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            picked = [str(Path(p).relative_to(cache)) for p in output.read_text(encoding="utf-8").splitlines()]
            return picked, result.stdout + result.stderr

    def test_static_services_take_codecs_from_link_txt_only(self):
        picked, log = self.pick("static")
        self.assertEqual(picked, [], "静态服务时仍从缓存另挑了编解码库（会排在 link.txt 那份前面）：%s\n%s" % (picked, log))
        self.assertIn("link.txt", log)

    def test_non_static_game_config_keeps_cache_convention(self):
        picked, _ = self.pick("0")
        self.assertEqual(picked, [GENERATIONS["avc"][1], GENERATIONS["opus"][1], GENERATIONS["vpx"][1]])


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cmake", default=CMAKE)
    parser.add_argument("--helper", type=Path, default=HELPER)
    args, remaining = parser.parse_known_args()
    CMAKE, HELPER = args.cmake, args.helper.resolve()
    unittest.main(argv=[__file__, *remaining])
