#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""launchers/shared/pil_prune.py：随包 Pillow 瘦身。假 site-packages，期望手写：
  ① 删 _avif / _imagingtk 两个扩展（.so / .pyd 都认），其余扩展与 .py 不动；画字 _imagingft 留着（#1570：下游做包工具用 ImageFont）；
  ② 给了依赖函数：.dylibs 里没人引用的库删掉，且是传递的（只被删掉的库引用的库也删）；被留下的扩展引用的库保留；
  ③ 没给依赖函数（Windows）：不碰 .dylibs；没有 PIL 目录 → 空。"""
import sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "launchers/shared"))
import pil_prune

DEPS = {   # 文件名 → 它依赖的库名（照真实 Mac 轮子的形状）
    "_avif.cpython-312-darwin.so": ["libavif.dylib"],
    "_imagingft.cpython-312-darwin.so": ["libfreetype.dylib", "libharfbuzz.dylib"],
    "_imaging.cpython-312-darwin.so": ["libjpeg.dylib", "libz.dylib"],
    "_webp.cpython-312-darwin.so": ["libwebp.dylib"],
    "libfreetype.dylib": ["libfreetype.dylib", "libpng16.dylib", "libz.dylib", "libbrotlidec.dylib"],
    "libharfbuzz.dylib": ["libharfbuzz.dylib", "libfreetype.dylib"],
    "libbrotlidec.dylib": ["libbrotlidec.dylib", "libbrotlicommon.dylib"],
    "libpng16.dylib": ["libpng16.dylib", "libz.dylib"],
}


class Prune(unittest.TestCase):
    def site(self, names, libs=()):
        d = Path(tempfile.mkdtemp()); self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        (d / "PIL/.dylibs").mkdir(parents=True)
        for n in names: (d / "PIL" / n).write_bytes(b"x")
        for n in libs: (d / "PIL/.dylibs" / n).write_bytes(b"x")
        return d

    def test_mac_transitive(self):
        mods = ["_avif.cpython-312-darwin.so", "_imagingft.cpython-312-darwin.so", "_imaging.cpython-312-darwin.so", "_webp.cpython-312-darwin.so", "Image.py"]
        libs = ["libavif.dylib", "libfreetype.dylib", "libharfbuzz.dylib", "libbrotlidec.dylib", "libbrotlicommon.dylib", "libpng16.dylib", "libjpeg.dylib", "libz.dylib", "libwebp.dylib"]
        d = self.site(mods, libs)
        pil_prune.prune(d, lambda p: DEPS.get(p.name, []))
        self.assertEqual(sorted(p.name for p in (d / "PIL").iterdir() if p.is_file()), ["Image.py", "_imaging.cpython-312-darwin.so", "_imagingft.cpython-312-darwin.so", "_webp.cpython-312-darwin.so"])
        self.assertEqual(sorted(p.name for p in (d / "PIL/.dylibs").iterdir()), ["libbrotlicommon.dylib", "libbrotlidec.dylib", "libfreetype.dylib", "libharfbuzz.dylib", "libjpeg.dylib", "libpng16.dylib", "libwebp.dylib", "libz.dylib"])

    def test_windows_no_deps(self):
        d = self.site(["_avif.cp312-win_amd64.pyd", "_imagingtk.cp312-win_amd64.pyd", "_imaging.cp312-win_amd64.pyd"], ["keep.dll"])
        gone = pil_prune.prune(d)
        self.assertEqual(gone, ["PIL/_avif.cp312-win_amd64.pyd", "PIL/_imagingtk.cp312-win_amd64.pyd"])
        self.assertTrue((d / "PIL/.dylibs/keep.dll").exists())

    def test_no_pil(self):
        self.assertEqual(pil_prune.prune(Path(tempfile.mkdtemp())), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
