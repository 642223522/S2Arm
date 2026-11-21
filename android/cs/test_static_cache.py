#!/usr/bin/env python3
"""cs/static_cache.py：静态模式 C# 产物缓存的键与存取。期望按规则手写，不跑 dotnet：
  键 ① 同内容换目录不变（门禁每次拷到新临时目录）；② 改闭包里的 C#（compat/tree 下）变；③ 改编译期读的 C 头（dmsh_chain.h）变；
     ④ 改闭包外的 C（runtime/src）不变；⑤ 额外参数（SDK 版本）不同则变；⑥ 闭包里出现认不出的 $(…) 算不出（退 3，冷编）。
  存取 ⑦ link.txt 里本次输出目录换占位、放回时换成新目录；codec 三行不存；⑧ 没存过 → restore 退 4。"""
import os, pathlib, shutil, subprocess, sys, tempfile, unittest

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[1]
SCRIPT = HERE / "static_cache.py"
sys.path.insert(0, str(HERE))
import static_cache as sc  # noqa: E402


def copy_closure(dst):
    rels = sc.closure(str(REPO)) + ["runtime/src/os.c"]
    for rel in rels:
        t = dst / rel
        t.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / rel, t)
    return rels


class KeyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = pathlib.Path(tempfile.mkdtemp(prefix="s2a-cskey-"))
        cls.a, cls.b = cls.tmp / "a", cls.tmp / "b"
        copy_closure(cls.a)
        shutil.copytree(cls.a, cls.b)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def k(self, root, extra=("sdk=1",)):
        return sc.key(str(root), list(extra))[0]

    def edit(self, rel, data=b"\n// edit\n"):
        p = self.b / rel
        old = p.read_bytes()
        p.write_bytes(old + data)
        self.addCleanup(p.write_bytes, old)

    def test_relocation_and_scope(self):
        base = self.k(self.a)
        self.assertEqual(self.k(self.b), base, "① 换目录不变")
        self.edit("runtime/src/os.c")
        self.assertEqual(self.k(self.b), base, "④ 闭包外的 C 不进键")

    def test_cs_and_read_header_change_key(self):
        base = self.k(self.a)
        self.edit("compat/tree/src/Ryujinx.Graphics.Shader/Ryujinx.Graphics.Shader.csproj", b"\n<!-- edit -->\n")
        self.assertNotEqual(self.k(self.b), base, "② compat/tree 的工程变")

    def test_generated_input_header_changes_key(self):
        base = self.k(self.a)
        self.edit("graphics/nvn/gfx/nvn/dmsh_chain.h")
        self.assertNotEqual(self.k(self.b), base, "③ 编译期 ReadAllText 读的头变")

    def test_extra_changes_key(self):
        self.assertNotEqual(self.k(self.a, ("sdk=1",)), self.k(self.a, ("sdk=2",)), "⑤ SDK 版本进键")

    def test_unresolvable_fails_closed(self):
        p = self.b / "android/cs/aot/S2A.Android.Aot.csproj"
        old = p.read_text(encoding="utf-8")
        p.write_text(old.replace("</Project>", '<ItemGroup><Compile Include="$(NoSuchProp)x.cs" /></ItemGroup></Project>'), encoding="utf-8")
        self.addCleanup(p.write_text, old, encoding="utf-8")
        r = subprocess.run([sys.executable, str(SCRIPT), "key", "--repo", str(self.b)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 3, "⑥ 认不出的 $(…) → 算不出键、冷编")


class StoreTests(unittest.TestCase):
    def test_save_restore_rewrites_paths(self):
        tmp = pathlib.Path(tempfile.mkdtemp(prefix="s2a-csstore-")); self.addCleanup(shutil.rmtree, tmp, True)
        out1, out2, cache = tmp / "s1/build/android-cs", tmp / "s2/build/android-cs", tmp / "cache"
        (out1 / "static").mkdir(parents=True); (out1 / "jniLibs/arm64-v8a").mkdir(parents=True); (out1 / "assets/licenses").mkdir(parents=True)
        (out1 / "static/libs2a_cs.a").write_bytes(b"AR")
        (out1 / "static/link.txt").write_text(f"{out1}/static/libs2a_cs.a\n-lm\n/nuget/libRuntime.a\n/cache/codecs/x/libs2a_opus.a\n", encoding="utf-8")
        (out1 / "assets/licenses/dotnet-runtime-LICENSE.TXT").write_text("L", encoding="utf-8")
        (out1 / "assets/licenses/opus-COPYING").write_text("O", encoding="utf-8")
        r = lambda *a: subprocess.run([sys.executable, str(SCRIPT), *a], capture_output=True, text=True).returncode
        self.assertEqual(r("restore", "--out", str(out2), "--cache", str(cache), "--key", "k1"), 4, "⑧ 没存过不命中")
        self.assertEqual(r("save", "--out", str(out1), "--cache", str(cache), "--key", "k1"), 0)
        self.assertEqual(r("restore", "--out", str(out2), "--cache", str(cache), "--key", "k1"), 0)
        self.assertEqual((out2 / "static/link.txt").read_text(encoding="utf-8"),
                         f"{out2}/static/libs2a_cs.a\n-lm\n/nuget/libRuntime.a\n", "⑦ 换成新目录、codec 行不存")
        self.assertEqual((out2 / "static/libs2a_cs.a").read_bytes(), b"AR")
        self.assertEqual(sorted(p.name for p in (out2 / "assets/licenses").iterdir()), ["dotnet-runtime-LICENSE.TXT"], "只存运行时许可证（codec 的由 codecs/build.sh 现拷）")
        self.assertTrue((out2 / "jniLibs/arm64-v8a").is_dir())


if __name__ == "__main__":
    unittest.main()
