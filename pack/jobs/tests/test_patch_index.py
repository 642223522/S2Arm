"""补丁索引生成（tools/patch_index.py，11-13：压缩包里的补丁与金手指、按内容去重）。临时镜像目录，期望按规则手写"""
import hashlib, io, json, os, shutil, sys, tempfile, unittest, unittest.mock, zipfile
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tools"))
import patch_index
os.environ["S2A_PATCH_INDEX_NO_GH"] = "1"   # 单测不联网


class PatchIndexTests(unittest.TestCase):
    def setUp(self):
        self.m = Path(tempfile.mkdtemp())
        ws = b"@nsobid-FF1D1C05670DB6021C85B624A710B963\n@enabled\n"
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("[21x9 Ultrawide]/exefs/1.0.pchtxt", ws)
            z.writestr("[60FPS]/cheats/FF1D1C05670DB602.txt", b"[x]\n04000000 00000010 00000001\n")
            z.writestr("[HD Textures]/romfs/ui.bfres", b"data")             # 游戏数据：不收（另一个 mod，不带 exefs）
            z.writestr("readme.md", b"hi")
        for repo in ("orig__mods", "ADEMOLA200__mods"):                   # 合集库里是同一个包
            d = self.m / repo / "Game [01006F8002326000]"; d.mkdir(parents=True)
            (d / "mods.zip").write_bytes(buf.getvalue())
        (self.m / "SOURCES.tsv").write_text("来源\tURL\t提交号\n" + "".join(f"{r}\tu\t{'c' * 40}\n" for r in ("orig__mods", "ADEMOLA200__mods")))
        self.ws = ws

    def tearDown(self):
        shutil.rmtree(self.m, ignore_errors=True)

    def test_classify_ignores_urls_and_knows_unlock(self):
        # 期望手写（11-13 实例）：署名网址里的「60fps」不算帧率；「Unlock / Uncap FPS」不带数字也是帧率（目标空）；带数字的照旧取数字
        foot = "\n@StevensND\nhttps://github.com/StevensND/ue4-emuswitch-60fps\n"
        self.assertEqual(patch_index.classify("G/[0100D7C01F254000]/Disable AA (Anti-Aliasing)/1.0.1.pchtxt", "// Disable AA\n@enabled\n" + foot), ("gfx", "", ""))
        self.assertEqual(patch_index.classify("G/FPS/Uncap FPS/exefs/1.0.1.pchtxt", foot), ("fps", "", ""))
        self.assertEqual(patch_index.classify("010093801237C000/2.1.0 by x/Unlock FPS/exefs/2.1.0.pchtxt"), ("fps", "", ""))
        self.assertEqual(patch_index.classify("G/FPS/60FPS/1.0.1.pchtxt", foot), ("fps", "60", ""))
        self.assertEqual(patch_index.classify("Mods/Graphics - Disable Dynamic resolution when low FPS/exefs/1.0.0.pchtxt"), ("gfx", "", ""))

    def test_archive_members_and_dedupe(self):
        rows = patch_index.dedupe(patch_index.scan(str(self.m)))
        got = sorted((r["repo"], r["member"], r["kind"], r["cat"], r["aspect"], tuple(r["gids"]), tuple(r["bids"])) for r in rows)
        self.assertEqual(got, [
            ("orig/mods", "[21x9 Ultrawide]/exefs/1.0.pchtxt", "pchtxt", "widescreen", "21:9", ("01006F8002326000",), ("FF1D1C05670DB6021C85B624A710B963",)),
            ("orig/mods", "[60FPS]/cheats/FF1D1C05670DB602.txt", "cheat", "cheat", "", ("01006F8002326000",), ("FF1D1C05670DB602",)),
        ])                                                                # 合集库那份去掉、原作者库留下；romfs / readme 不收
        r = next(r for r in rows if r["kind"] == "pchtxt")
        self.assertEqual((r["path"], r["sha256"], r["archive_sha256"]),
                         ("Game [01006F8002326000]/mods.zip", hashlib.sha256(self.ws).hexdigest(), hashlib.sha256((self.m / "orig__mods/Game [01006F8002326000]/mods.zip").read_bytes()).hexdigest()))

    def test_mod_with_romfs_companion_is_not_half_indexed(self):
        # 11-16 D-Q3QJ（王国之泪 1800p：exefs 改分辨率 + romfs 调大显存堆，只收 exefs 半边 → 按 1800p 建缓冲分配失败崩溃）。期望手写：
        #   ① 包里 1800p/ 有 exefs 补丁、romfs 配套是显存堆配置（HeapSize）→ 它的补丁不收；② 散文件 Big/exefs + Big/romfs/System/HeapSize → 不收；
        #   ③ 别的库里单独放着同一份 1800p 补丁（内容一样）→ 也不收；④ 同包里不带 romfs 的 Plain/exefs → 照收；
        #   ⑤ 配套只是界面布局（Wide/romfs/UI/LayoutArchive，缺了只是界面没拉宽、不崩；维护者定：超宽屏不一刀切）→ 照收
        p1800 = b"@nsobid-AABBCCDDEEFF00112233445566778899\n@enabled\n"
        plain = b"@nsobid-AABBCCDDEEFF00112233445566778899\n// plain\n@enabled\n"
        big = b"@nsobid-AABBCCDDEEFF00112233445566778899\n// big\n@enabled\n"
        wide = b"@nsobid-AABBCCDDEEFF00112233445566778899\n// wide\n@enabled\n"
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("1800p/exefs/1.2.1.pchtxt", p1800)
            z.writestr("1800p/romfs/System/HeapSize/Product.HeapDef.byml.zs", b"heap")
            z.writestr("Plain/exefs/1.2.1.pchtxt", plain)
            z.writestr("Wide/exefs/1.2.1.pchtxt", wide)
            z.writestr("Wide/romfs/UI/LayoutArchive/Common.Product.blarc.zs", b"ui")
        g = self.m / "orig__mods" / "Zelda [0100F2C0115B6000]"; g.mkdir(parents=True)
        (g / "res.zip").write_bytes(buf.getvalue())
        (g / "Big/exefs").mkdir(parents=True); (g / "Big/exefs/1.2.1.pchtxt").write_bytes(big)
        (g / "Big/romfs/System/HeapSize").mkdir(parents=True); (g / "Big/romfs/System/HeapSize/x.zs").write_bytes(b"x")
        (g / "Wide2/exefs").mkdir(parents=True); (g / "Wide2/exefs/1.2.1.pchtxt").write_bytes(wide + b"// 2\n")
        (g / "Wide2/romfs/UI").mkdir(parents=True); (g / "Wide2/romfs/UI/x.blarc").write_bytes(b"ui")
        o = self.m / "other__mods" / "Zelda [0100F2C0115B6000]/1800p/exefs"; o.mkdir(parents=True)
        (o / "1.2.1.pchtxt").write_bytes(p1800)
        (self.m / "SOURCES.tsv").write_text("来源\tURL\t提交号\n" + "".join(f"{r}\tu\t{'c' * 40}\n" for r in ("orig__mods", "ADEMOLA200__mods", "other__mods")))
        got = sorted(r["sha256"] for r in patch_index.dedupe(patch_index.scan(str(self.m))) if "0100F2C0115B6000" in r["gids"])
        self.assertEqual(got, sorted(hashlib.sha256(x).hexdigest() for x in (plain, wide, wide + b"// 2\n")))
        self.assertEqual(sorted(h for _, _, h in patch_index.HALVES), sorted(hashlib.sha256(x).hexdigest() for x in (p1800, big)))

    def test_widescreen_that_raises_render_resolution_is_not_indexed(self):
        # 11-16 #b824d1（阿尔宙斯「3440x1440」变体把内部渲染分辨率提到 3440×1440，渲染目标放大、堆放不下 → 空指针崩）。期望手写：
        #   ① pchtxt 写 movz w8,#3440 / movz w9,#1440 → 不收；② IPS 写同样两条 → 不收；③ 只改画幅的（movz #1920 / #1080、浮点画幅）→ 照收；
        #   ④ 名字带 3440x1440、正文没写分辨率常数 → 照收（名字只是目标显示器）；⑤ 注释掉的行不算
        mz = lambda rd, imm: (0x52800000 | (imm << 5) | rd).to_bytes(4, "little").hex().upper()
        up = f"@nsobid-CCDDEEFF00112233445566778899AABB\n@enabled\n00001000 {mz(8, 3440)}\n00001004 {mz(9, 1440)}\n".encode()
        ok = f"@nsobid-CCDDEEFF00112233445566778899AABB\n@enabled\n00001000 {mz(8, 1920)}\n00001004 {mz(9, 1080)}\n00002000 3F2AAAAB\n".encode()
        named = b"@nsobid-CCDDEEFF00112233445566778899AABB\n@enabled\n00002000 3F2AAAAB\n"
        commented = f"@nsobid-CCDDEEFF00112233445566778899AABB\n@enabled\n//00001000 {mz(8, 3440)}\n//00001004 {mz(9, 1440)}\n00002000 3F2AAAAC\n".encode()
        ips = b"PATCH" + (0x1100).to_bytes(3, "big") + (8).to_bytes(2, "big") + bytes.fromhex(mz(8, 2560) + mz(9, 1440)) + b"EOF"
        g = self.m / "orig__mods" / "Arceus [01001F5010DFA000]"
        for d, data in (("[3440x1440 Ultrawide]/exefs/1.1.1.pchtxt", up), ("[21x9 Ultrawide]/exefs/1.1.1.pchtxt", ok), ("[21.9 (3440x1440)]/exefs/1.1.1.pchtxt", named),
                        ("[21x9 Commented]/exefs/1.1.1.pchtxt", commented), ("[2560x1440 Ultrawide]/exefs/CCDDEEFF00112233.ips", ips)):
            (g / d).parent.mkdir(parents=True, exist_ok=True); (g / d).write_bytes(data)
        o = self.m / "other__mods" / "Arceus [01001F5010DFA000]/[4K Docked]/exefs"; o.mkdir(parents=True)   # ⑥ 同一份内容在别的库里被分成画面类 → 也不收
        (o / "1.1.1.pchtxt").write_bytes(up)
        (self.m / "SOURCES.tsv").write_text("来源\tURL\t提交号\n" + "".join(f"{r}\tu\t{'c' * 40}\n" for r in ("orig__mods", "ADEMOLA200__mods", "other__mods")))
        rows = [r for r in patch_index.dedupe(patch_index.scan(str(self.m))) if "01001F5010DFA000" in r["gids"]]
        self.assertEqual(sorted(r["sha256"] for r in rows if r["cat"] == "widescreen"), sorted(hashlib.sha256(x).hexdigest() for x in (ok, named, commented)))
        self.assertNotIn(hashlib.sha256(up).hexdigest(), {r["sha256"] for r in rows})
        self.assertEqual(sorted(x[2] for x in patch_index.UPRES), [(2560, 1440), (3440, 1440)])

    def test_known_bad_patches_are_not_indexed(self):
        # 11-16：已定因会崩的单份补丁按内容编号（sha256 前 16 位）不收，别的照收。期望手写：表里那份不在索引里、旁边那份在
        bad, good = b"@nsobid-AABBCCDDEEFF00112233445566778899\n@enabled\n00001000 1F2003D5\n", b"@nsobid-AABBCCDDEEFF00112233445566778899\n@enabled\n00001004 1F2003D5\n"
        g = self.m / "orig__mods" / "Odyssey [0100000000010000]"
        (g / "GQ3/exefs").mkdir(parents=True); (g / "GQ3/exefs/1.3.0.pchtxt").write_bytes(bad)
        (g / "Other/exefs").mkdir(parents=True); (g / "Other/exefs/1.3.0.pchtxt").write_bytes(good)
        with unittest.mock.patch.dict(patch_index.KNOWN_BAD, {hashlib.sha256(bad).hexdigest()[:16]: "测试"}):
            got = {r["sha256"] for r in patch_index.dedupe(patch_index.scan(str(self.m))) if "0100000000010000" in r["gids"]}
        self.assertEqual(got, {hashlib.sha256(good).hexdigest()})
        self.assertEqual(set(patch_index.KNOWN_BAD), {"e8b51176ead1bcd3"})

    def test_cheat_libraries_are_not_indexed_twice(self):
        os.rename(self.m / "orig__mods", self.m / "ChanseyIsTheBest__NX-60FPS-RES-GFX-Cheats")
        (self.m / "SOURCES.tsv").write_text("来源\tURL\t提交号\n" + "".join(f"{r}\tu\t{'c' * 40}\n" for r in ("ChanseyIsTheBest__NX-60FPS-RES-GFX-Cheats", "ADEMOLA200__mods")))
        kinds = {(r["repo"], r["kind"]) for r in patch_index.scan(str(self.m))}
        self.assertNotIn(("ChanseyIsTheBest/NX-60FPS-RES-GFX-Cheats", "cheat"), kinds)   # 金手指专门通道已取的库：不重复收金手指
        self.assertIn(("ADEMOLA200/mods", "cheat"), kinds)


class CaseTests(unittest.TestCase):
    def test_fix_case_by_git_blob(self):
        data = b"zip"; sha = hashlib.sha1(b"blob 3\0zip").hexdigest()
        tree = {sha: ["Some Game/a.zip"], "0" * 40: ["SOME GAME/a.zip"]}
        self.assertEqual(patch_index.fix_case("SOME GAME/a.zip", data, tree), "Some Game/a.zip")   # 同内容那条
        self.assertEqual(patch_index.fix_case("x/b.zip", data, tree), "x/b.zip")                                     # 对不上照本地
        self.assertEqual(patch_index.fix_case("x/b.zip", data, None), "x/b.zip")


class PatchPackTests(unittest.TestCase):
    """统一包（tools/patch_pack.py）：按程序号 / 构建号分包、条目字节同上游、汇总库 JSON 拆成按构建号的金手指、同输入同输出"""
    def setUp(self):
        self.m = Path(tempfile.mkdtemp()); self.o = Path(tempfile.mkdtemp())
        a = self.m / "orig__mods"; (a / "G [01006F8002326000]/exefs").mkdir(parents=True); (a / "loose/cheats").mkdir(parents=True)
        self.ws = b"@nsobid-FF1D1C05670DB6021C85B624A710B963\n// 21:9 ultrawide\n@enabled\n"
        (a / "G [01006F8002326000]/exefs/1.0.pchtxt").write_bytes(self.ws)
        (a / "loose/cheats/AAAABBBBCCCCDDDD.txt").write_bytes(b"[x]\n04000000 00000010 00000001\n")   # 没写程序号：按构建号分包
        h = self.m / "HamletDuFromage__switch-cheats-db/cheats"; h.mkdir(parents=True)
        (h / "01006F8002326000.json").write_text(json.dumps({"FF1D1C05670DB602": {"[A]": "[A]\n04000000 0 1\n", "[B]": "[B]\n04000000 4 1\n"}, "attribution": {"x": "someone"}}))
        (self.m / "SOURCES.tsv").write_text("来源\tURL\t提交号\n" + "".join(f"{r}\tu\t{'c' * 40}\n" for r in ("orig__mods", "HamletDuFromage__switch-cheats-db")))
        import patch_pack; self.pp = patch_pack

    def tearDown(self):
        shutil.rmtree(self.m, ignore_errors=True); shutil.rmtree(self.o, ignore_errors=True)

    def test_bundles(self):
        import base64, gzip, json as js
        idx = self.pp.build(str(self.m), str(self.o))
        self.assertEqual(sorted(idx["bundles"]), ["b/AAAABBBBCCCCDDDD", "g/01006F8002326000"])
        g = js.loads(gzip.decompress((self.o / "g/01006F8002326000.json.gz").read_bytes()))["items"]
        self.assertEqual(sorted((i["kind"], i["cat"], tuple(i["bids"])) for i in g),
                         [("cheat", "cheat", ("FF1D1C05670DB602",)), ("pchtxt", "widescreen", ("FF1D1C05670DB6021C85B624A710B963",))])
        ws = next(i for i in g if i["kind"] == "pchtxt")
        self.assertEqual(base64.b64decode(ws["data"]), self.ws)                                   # 字节同上游、不转格式
        ch = next(i for i in g if i["kind"] == "cheat")
        self.assertEqual((base64.b64decode(ch["data"]), ch["author"], ch["source"]["member"]), (b"[A]\n04000000 0 1\n[B]\n04000000 4 1\n", "someone", "FF1D1C05670DB602"))
        # 管线种子目录（<目录>/<程序号>/*.tsv）：进这款 g/ 包、kind = cat = pso、字节原样；不算上游；不是程序号的目录 / 非 .tsv 不收
        sd = self.m / "seeds"; (sd / "01006F8002326000").mkdir(parents=True); (sd / "notagame").mkdir()
        seed = b"R\t" + b"00" * 432 + b"\n"
        (sd / "01006F8002326000/run1.tsv").write_bytes(seed); (sd / "01006F8002326000/x.txt").write_bytes(b"x"); (sd / "notagame/a.tsv").write_bytes(b"S\tx\t0\n")
        so = Path(tempfile.mkdtemp())
        try:
            sidx = self.pp.build(str(self.m), str(so), str(sd))
            self.assertEqual(sorted(sidx["bundles"]), ["b/AAAABBBBCCCCDDDD", "g/01006F8002326000"])
            self.assertEqual(sidx["upstreams"], idx["upstreams"])
            sg = js.loads(gzip.decompress((so / "g/01006F8002326000.json.gz").read_bytes()))["items"]
            ps = [i for i in sg if i["kind"] == "pso"]
            self.assertEqual([(i["cat"], i["gids"], i["name"], base64.b64decode(i["data"])) for i in ps], [("pso", ["01006F8002326000"], "run1.tsv", seed)])
        finally:
            shutil.rmtree(so, ignore_errors=True)
        first = {k: (self.o / (k + ".json.gz")).read_bytes() for k in idx["bundles"]}
        self.pp.build(str(self.m), str(self.o))
        self.assertEqual(first, {k: (self.o / (k + ".json.gz")).read_bytes() for k in idx["bundles"]})   # 同输入同输出：只传变了的
        # 快照：同输入同字节；自洽核得过；放进启动器资源（S2A_PATCH_SNAPSHOT 指本机文件）；改坏一个字节就不放
        s1 = open(self.pp.snapshot(str(self.o)), "rb").read(); s2 = open(self.pp.snapshot(str(self.o)), "rb").read()
        self.assertEqual(s1, s2)
        res = Path(tempfile.mkdtemp())
        os.environ["S2A_PATCH_SNAPSHOT"] = str(self.o / "snapshot.tar")
        try:
            self.assertIsNone(self.pp.stage_snapshot(str(res / "CommunityPatches")))
            # 随包放 v3（11-16 安装包瘦身）：v2 中间件不留；v3 同输入同字节、自洽；各包原文与 v2 里 gz 解出来的逐字节相同
            self.assertEqual(sorted(p.name for p in (res / "CommunityPatches").iterdir()), ["patches-v3.tar"])
            v3 = (res / "CommunityPatches/patches-v3.tar").read_bytes()
            self.assertIsNone(self.pp.stage_snapshot(str(res / "again")))
            self.assertEqual((res / "again/patches-v3.tar").read_bytes(), v3)
            idx3, why = self.pp.check_v3(str(res / "CommunityPatches/patches-v3.tar"))
            self.assertIsNone(why); self.assertEqual(idx3["schema"], 3); self.assertEqual(sorted(idx3["bundles"]), sorted(idx["bundles"]))
            for k, v in idx3["bundles"].items():
                self.assertEqual(v["sha256"], idx["bundles"][k]["sha256"])   # 和云端比用的 gz sha 原样保留
                self.assertEqual(v["raw_sha256"], hashlib.sha256(gzip.decompress((self.o / (k + ".json.gz")).read_bytes())).hexdigest())
            bad = bytearray(s1); i = bad.index(b"\x1f\x8b"); bad[i + 40] ^= 0xFF; (self.o / "bad.tar").write_bytes(bytes(bad))
            os.environ["S2A_PATCH_SNAPSHOT"] = str(self.o / "bad.tar")
            self.assertIsNotNone(self.pp.stage_snapshot(str(res / "x")))
            self.assertFalse((res / "x/patches-v2.tar").exists()); self.assertFalse((res / "x/patches-v3.tar").exists())
        finally:
            os.environ.pop("S2A_PATCH_SNAPSHOT", None); shutil.rmtree(res, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
