"""iPhone 随包新功能介绍（pack/feature_bundle.py）：期望按规则手写——只取标了 ios 的页（页上的 platforms 优先，没写看顶层）、
文字中英缺一或图不在的页不要、图只认 docs/site 里面的、一页不剩什么都不写。"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "pack"))
import feature_bundle  # noqa: E402

T = {"zh-Hans": "中", "en": "en"}
TEXTS = {k: T for k in feature_bundle.TEXTS}


class FeatureBundleTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.site, self.out = self.root / "site", self.root / "out"
        (self.site / "feature").mkdir(parents=True)
        for n in ("a.jpg", "a_en.jpg", "b.jpg"):
            (self.site / "feature" / n).write_bytes(n.encode())

    def write(self, pages, platforms=("mac", "windows")):
        (self.site / "feature.json").write_text(json.dumps({"schema": 1, "id": "v0.6.0", "platforms": list(platforms), "badge": T, "pages": pages}), encoding="utf-8")

    def test_only_ios_pages_with_both_languages_and_images(self):
        self.write([
            dict(TEXTS, image={"zh-Hans": "feature/a.jpg", "en": "feature/a_en.jpg"}, platforms=["mac", "windows", "ios"], labels={"where": {"zh-Hans": "要知道", "en": "Good to know"}}),
            dict(TEXTS, image="feature/b.jpg", platforms=["mac", "windows"]),           # 电脑才有
            dict(TEXTS, image="feature/none.jpg", platforms=["ios"]),                   # 图不在
            dict(TEXTS, title={"zh-Hans": "只有中文"}, image="feature/b.jpg", platforms=["ios"]),   # 缺英文
            dict(TEXTS, image="../outside.jpg", platforms=["ios"]),                     # 不在 docs/site 里
        ])
        self.assertEqual(feature_bundle.bundle(self.site, self.out), 1)
        data = json.loads((self.out / "feature.json").read_text(encoding="utf-8"))
        self.assertEqual(data["id"], "v0.6.0")
        self.assertEqual(data["pages"][0]["image"], {"zh-Hans": "a.jpg", "en": "a_en.jpg"})
        self.assertEqual(data["pages"][0]["labels"], {"where": {"zh-Hans": "要知道", "en": "Good to know"}})
        self.assertEqual(sorted(p.name for p in self.out.iterdir()), ["a.jpg", "a_en.jpg", "feature.json"])   # 只拷用到的图

    def test_top_level_platforms_when_page_has_none_and_nothing_written_without_ios(self):
        self.write([dict(TEXTS, image="feature/b.jpg")], platforms=("mac", "ios"))
        self.assertEqual(feature_bundle.bundle(self.site, self.out), 1)
        out2 = self.root / "out2"
        self.write([dict(TEXTS, image="feature/b.jpg")])                                 # 这一期不给 iPhone
        self.assertEqual(feature_bundle.bundle(self.site, out2), 0)
        self.assertFalse(out2.exists())


if __name__ == "__main__":
    unittest.main()
