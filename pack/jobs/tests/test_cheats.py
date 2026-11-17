"""金手指（pack/jobs/cheats.py，11-12）：出包时查公开库、玩家导入、启动器列出与开关。不联网：库函数换成桩。期望按规则手写"""
import json, shutil, sys, tempfile, unittest
from pathlib import Path
from unittest import mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cheats
import community
from core import Failure

GID = "01001B300B9BE000"
BID = "2607A74F5DF7754C"
REPO = Path(__file__).resolve().parents[3]
TEXT = "{Master}\n040E0000 00BE1238 D503201F\n\n[Infinite Health]\n080E0000 00C72FB0 17E8B62C B9000D17\n\n[Gold x2]\n040E0000 00C72FB8 00000002\n"


class Ctx:
    def __init__(self, root):
        self.library, self.engine, self.private, self.r = root / "lib", root / "engine", root / "priv", {"gameId": GID}
        table = self.engine / community.SETTINGS_TABLE
        table.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(REPO / community.SETTINGS_TABLE, table)
    def begin(self, *a): pass


class CheatsTests(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.c = Ctx(self.t)
        p = self.c.library / "catalog.json"; p.parent.mkdir(parents=True)
        p.write_text(json.dumps({"games": [{"id": GID, "packages": [{"type": "base", "version": 0, "display": "1.0.0", "builds": {"main": BID.lower() + "c0357b5df7e49693"}}]}]}))
        self.game = community.game_of(self.c, GID)
        self.d = cheats.cheats_dir(self.c, GID)
        self.real = cheats.main_build
        cheats.main_build = lambda c, g: self.bid   # 真构建号取自解包目录（单测不解包）：按用例给
        self.bid = BID

    def tearDown(self):
        cheats.main_build = self.real
        shutil.rmtree(self.t, ignore_errors=True)

    def test_fetch_writes_header_and_source_skips_failures(self):
        calls = []
        def ok(gid, bids): calls.append((gid, bids)); return [(BID, dict(text=TEXT, path=f"x/{BID}.txt", author="bad1dea", license="MIT"))]
        def boom(gid, bids): raise OSError("离线")
        def none(gid, bids): return []
        got = cheats.fetch(self.c, self.game, (("a/one", "one", ok), ("b/two", "two", boom), ("c/three", "three", none)))
        self.assertEqual((got, calls), (["a/one"], [(GID, {BID})]))                    # 按程序号 + 真构建号前 16 位取；离线 / 没有静默跳过
        text = (self.d / f"{BID}.one.txt").read_text()
        self.assertTrue(text.startswith(f"[a/one BID={BID}]\n"))                       # 文件头补上 BID（出包与运行时都按它核版本）
        src = json.loads((self.d / "sources.json").read_text())[f"{BID}.one.txt"]
        self.assertEqual((src["from"], src["repo"], src["author"], src["license"]), ("library", "a/one", "bad1dea", "MIT"))

    def test_fetch_other_build_not_written(self):
        other = "[x BID=0000000000000000]\n[A]\n04000000 00000010 00000001\n"
        cheats.fetch(self.c, self.game, (("a/one", "one", lambda g, b: [(BID, dict(text=other, path="p", author="", license=""))]),))
        self.assertFalse((self.d / f"{BID}.one.txt").exists())                         # 文件头构建号与库里的文件名不符：不收

    def test_unknown_build_fetches_all_versions_list_hides_others(self):
        self.bid = ""                                                                  # 还没解过包：各版本都取
        seen = []
        def lib(gid, bids):
            seen.append(bids)
            return [(BID, dict(text=TEXT, path="a", author="", license="")), ("0000000000000000", dict(text=TEXT, path="b", author="", license=""))]
        cheats.fetch(self.c, self.game, (("a/one", "one", lib),))
        self.assertEqual((seen, sorted(p.name for p in self.d.glob("*.one.txt"))), ([set()], ["0000000000000000.one.txt", f"{BID}.one.txt"]))
        self.bid = BID                                                                 # 解过包后：库里别的版本不列
        self.assertEqual({it["file"] for it in cheats.listing(self.c, self.game)["items"]}, {f"{BID}.one.txt"})

    def test_listing_save_and_version_reason(self):
        self.d.mkdir(parents=True, exist_ok=True)
        (self.d / f"{BID}.txt").write_text(TEXT)
        (self.d / "old.txt").write_text("[D BID=1111111111111111]\n[A]\n04000000 00000010 00000001\n")
        r = cheats.listing(self.c, self.game)
        keys = [(it["key"], it["ok"], it["from"]) for it in r["items"]]
        self.assertEqual(keys, [(f"{BID}.txt/Infinite Health", True, "player"), (f"{BID}.txt/Gold x2", True, "player"), ("old.txt/A", False, "player")])   # 主代码不列
        self.assertEqual(r["items"][2]["reason"], f"版本不对：金手指是 1111111111111111，这份游戏是 {BID}。")
        cheats.save(self.c, self.game, {f"{BID}.txt/Infinite Health": True})
        self.assertEqual((self.d / "enabled.txt").read_text(), f"{BID}.txt/Infinite Health\n")
        cheats.save(self.c, self.game, {f"{BID}.txt/Gold x2": True, f"{BID}.txt/Infinite Health": False})
        self.assertEqual((self.d / "enabled.txt").read_text(), f"{BID}.txt/Gold x2\n")
        with self.assertRaises(Failure):
            cheats.save(self.c, self.game, {"nope.txt/X": True})

    def test_no_build_id_unusable_on_windows_only(self):
        # #1321：文件名不是 16 位构建号、首行也没 BID= → Windows（只能出 iPhone 包，出包核不了版本、整份不收）列成用不了并写原因；
        #   Mac 本机运行时照常认（Cheats.cs BuildMatches 不核），照常可开。期望手写
        from types import SimpleNamespace
        from unittest import mock
        self.d.mkdir(parents=True, exist_ok=True)
        (self.d / "mine.txt").write_text("[A]\n04000000 00000010 00000001\n")
        with mock.patch.object(cheats, "os", SimpleNamespace(name="nt")):
            it = cheats.listing(self.c, self.game)["items"][0]
        self.assertEqual((it["key"], it["ok"], it["reason"]),
                         ("mine.txt/A", False, "没写构建号：文件名改成「<16 位构建号>.txt」或首行加 BID=<构建号> 才能编进 iPhone 包。"))
        with mock.patch.object(cheats, "os", SimpleNamespace(name="posix")):
            it = cheats.listing(self.c, self.game)["items"][0]
        self.assertEqual((it["ok"], it["reason"]), (True, ""))

    def test_fixed_address_by_opcode(self):
        # 期望按 Atmosphere 指令表手判：0 / 1 型第 3 位区号非 0、5 型区号非 0 且第 5 位（以寄存器为基址）为 0 → 写死地址
        text = ("[Coins]\n02100000 5C27B318 0000270f\n\n[Health]\n11160000 5C3BE7DC 00000000\n01100000 5C3BE7DC 00000006\n20000000\n\n"
                "[Moonjump]\n80000002\n580F0000 0149D940\n580F1000 00000090\n780F0000 00000038\n640F0000 00000000 42000000\n20000000\n\n"
                "[Wide]\n041F0000 73759AC8 401851EC\n\n[Code]\n040E0000 00C72FB8 00000002\n\n[HeapPtr]\n58100000 00001000\n")
        self.assertEqual([(n, fx) for n, _, _, fx in cheats.parse(text)[1]],
                         [("Coins", True), ("Health", True), ("Moonjump", False), ("Wide", True), ("Code", False), ("HeapPtr", True)])
        self.d.mkdir(parents=True, exist_ok=True)
        (self.d / f"{BID}.txt").write_text(text)
        self.assertEqual({it["name"]: it["fixed"] for it in cheats.listing(self.c, self.game)["items"]},
                         {"Coins": True, "Health": True, "Moonjump": False, "Wide": True, "Code": False, "HeapPtr": True})

    def test_no_cheats_reason(self):
        self.assertEqual(cheats.listing(self.c, self.game), dict(items=[], reason="这个版本没有现成的金手指。"))

    def test_import_via_community_save(self):
        src = self.t / "mine.txt"; src.write_text(TEXT)
        bad = self.t / "bad.txt"; bad.write_text("hello\n")
        self.c.r = {"gameId": GID, "cheatsImport": [str(src)], "cheats": {"mine.txt/Gold x2": True}, "cheatsShare": False}
        r = community.save(self.c)
        self.assertEqual([(it["key"], it["enabled"]) for it in r["cheats"]["items"]], [("mine.txt/Infinite Health", False), ("mine.txt/Gold x2", True)])
        self.assertEqual(json.loads((self.d / "sources.json").read_text())["mine.txt"]["from"], "player")
        self.c.r = {"gameId": GID, "cheatsImport": [str(bad)], "cheatsShare": False}
        with self.assertRaises(Failure):
            community.save(self.c)

    def test_import_share(self):
        # 11-15 玩家分享：勾了「分享给其他玩家」逐份上传原文 + 程序号 + 构建号（只这些，不带设备 / 账号）；没勾不传；传失败不挡导入。
        #   补丁库「玩家分享」上游来的条目标 shared（开之前提示一句可能坏存档）。期望手写
        src = self.t / "mine.txt"; src.write_text(TEXT)
        sent = []
        class Resp:
            def __init__(self, body): self.body = body
            def __enter__(self): return self
            def __exit__(self, *a): return False
            def read(self): return self.body
        def ok(req, timeout=0):
            sent.append((req.full_url, json.loads(req.data), req.get_header("X-s2arm-client")))
            return Resp(b'{"sha":"x","duplicate":false}')
        with mock.patch.object(cheats, "main_build", return_value=BID), mock.patch.object(cheats.urllib.request, "urlopen", ok):
            self.c.r = {"gameId": GID, "cheatsImport": [str(src)], "cheatsShare": True}
            r = community.save(self.c)
        self.assertEqual(r["cheatsImported"], [{"name": "mine.txt", "shared": "shared"}])
        self.assertEqual((sent[0][0], sent[0][1], sent[0][2].split("/")[0]),
                         (cheats.SHARE_URL, {"gid": GID.upper(), "bid": BID, "name": "mine.txt", "text": TEXT}, "mac"))
        with mock.patch.object(cheats.urllib.request, "urlopen", side_effect=AssertionError("不该上传")):
            self.c.r = {"gameId": GID, "cheatsImport": [str(src)], "cheatsShare": False}
            self.assertEqual(community.save(self.c)["cheatsImported"], [{"name": "mine.txt", "shared": "off"}])
            self.c.r = {"gameId": GID, "cheatsImport": [str(src)]}   # 没给勾选值 = 缺省（11-15 维护者「金手指分享缺省不勾」）：不上传
            self.assertEqual(community.save(self.c)["cheatsImported"], [{"name": "mine.txt", "shared": "off"}])
        def down(req, timeout=0): raise OSError("网络不通")
        with mock.patch.object(cheats, "main_build", return_value=BID), mock.patch.object(cheats.urllib.request, "urlopen", down):
            self.c.r = {"gameId": GID, "cheatsImport": [str(src)], "cheatsShare": True}
            r = community.save(self.c)
        self.assertEqual((r["cheatsImported"], (self.d / "mine.txt").is_file()), ([{"name": "mine.txt", "shared": "failed"}], True))
        src_json = json.loads((self.d / "sources.json").read_text()); src_json["mine.txt"]["repo"] = cheats.PLAYER_REPO
        (self.d / "sources.json").write_text(json.dumps(src_json))
        self.assertEqual({it["shared"] for it in cheats.listing(self.c, self.game)["items"] if it["file"] == "mine.txt"}, {True})

    def test_crash_turns_them_off_then_notice_is_acknowledged(self):
        # 11-13 维护者改定：异常退出时开着的几条当场关掉、记下来；下次开始时启动器只通知（不问），看过（ack）清记录、开关不再动
        self.d.mkdir(parents=True, exist_ok=True)
        (self.d / f"{BID}.txt").write_text(TEXT)
        cheats.save(self.c, self.game, {f"{BID}.txt/Infinite Health": True, f"{BID}.txt/Gold x2": True})
        cheats.note_crash(self.c, self.game)
        self.c.r = {"gameId": GID}
        r = community.listing(self.c)
        self.assertEqual([(x["kind"], x["name"]) for x in r["crashed"]], [("cheat", "Gold x2"), ("cheat", "Infinite Health")])
        self.assertEqual(sum(it["enabled"] for it in r["cheats"]["items"]), 0)                                              # 已当场关掉
        cheats.save(self.c, self.game, {f"{BID}.txt/Gold x2": True})                                                         # 玩家看到通知后自己又打开一条
        self.c.r = {"gameId": GID, "crashAnswer": "ack"}
        r = community.save(self.c)
        self.assertEqual((r["crashed"], sum(it["enabled"] for it in r["cheats"]["items"])), ([], 1))                       # 看过：记录清掉、玩家重开的不动
        self.c.r = {"gameId": GID, "crashAnswer": "keep"}
        with self.assertRaises(Failure):
            community.save(self.c)

    def test_crash_turns_off_default_on_patches(self):
        # 11-13 起社区补丁没选过 = 默认开：崩溃时包里编进去、玩家没关过的补丁都算开着，一并关掉并记下名字；玩家本来就关了的不再记
        #   期望（手算）：包里 widescreen:A1（满屏）、gfx:B1（画面）两份，玩家关过 B1 → 只关 A1，launch.json A1 = False，通知列「满屏 A」
        from layout import image_mac
        tsv = image_mac(self.c, GID) / "cpatch.tsv"; tsv.parent.mkdir(parents=True, exist_ok=True)
        head = "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅\t模式"
        tsv.write_text(head + "\nwidescreen:A1\tmain\t0\twidescreen\t满屏 A\tMIT\to/r\t\t1\t\t\t\ngfx:B1\tmain\t1\tgfx\t画面 B\tMIT\to/r\t\t1\t\t\t\n", encoding="utf-8")
        data = community.load_launch(self.c, GID); data["patches"]["gfx:B1"] = False
        p = community.launch_path(self.c, GID); p.parent.mkdir(parents=True, exist_ok=True); p.write_text(json.dumps(data))
        cheats.note_crash(self.c, self.game)
        self.assertEqual([(x["kind"], x["key"], x["name"]) for x in cheats.crashed(self.c, self.game)], [("patch", "widescreen:A1", "满屏 A")])
        self.assertEqual(community.load_launch(self.c, GID)["patches"], {"gfx:B1": False, "widescreen:A1": False})

    def _fps_pack(self):
        from layout import image_mac
        tsv = image_mac(self.c, GID) / "cpatch.tsv"; tsv.parent.mkdir(parents=True, exist_ok=True)
        tsv.write_text("编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅\t模式\nfps:F1\tmain\t0\tfps\t120 帧\tMIT\to/r\t\t1\t120\t\t\n", encoding="utf-8")

    def test_crash_turns_off_fps_patches_too(self):
        # 帧率补丁跟「60 帧 / 帧率」开关走、不在 packed_patches 里：包里有帧率补丁、开关没关时崩了 → 开关一并关、通知列「帧率」（kind fps）。期望手写
        self._fps_pack()
        cheats.note_crash(self.c, self.game)
        self.assertIs(community.load_launch(self.c, GID)["settings"].get("fps60"), False)
        self.assertEqual([x["kind"] for x in cheats.crashed(self.c, self.game)], ["fps"])

    def test_stall_marker_turns_fps_off_once(self):
        # 停帧救场（runtime cpatch.c 写 S2A_DOCS/cpatch_stall_off）：收局读到 → 「帧率」写关、通知列 fps、标记删掉；没标记 → 不动。期望手写
        docs = self.t / "docs"; docs.mkdir()
        self.assertFalse(cheats.note_stall(self.c, self.game, docs))
        (docs / "cpatch_stall_off").write_text("fps\n")
        self.assertTrue(cheats.note_stall(self.c, self.game, docs))
        self.assertFalse((docs / "cpatch_stall_off").exists())
        self.assertIs(community.load_launch(self.c, GID)["settings"].get("fps60"), False)
        self.assertEqual([x["kind"] for x in cheats.crashed(self.c, self.game)], ["fps"])

    def _two_patches(self, verified_b):
        from layout import image_mac
        tsv = image_mac(self.c, GID) / "cpatch.tsv"; tsv.parent.mkdir(parents=True, exist_ok=True)
        head = "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅\t模式"
        tsv.write_text(head + f"\nwidescreen:A1\tmain\t0\twidescreen\t满屏 A\tMIT\to/r\t\t1\t\t\t\ngfx:B1\tmain\t1\tgfx\t画面 B\tMIT\to/r\t\t{verified_b}\t\t\t\n"
                       "fps:F1\tmain\t2\tfps\t60 帧\tMIT\to/r\t\t1\t60\t\t\n", encoding="utf-8")
        self.d.mkdir(parents=True, exist_ok=True)
        (self.d / f"{BID}.txt").write_text(TEXT)

    def _on(self):
        launch = community.load_launch(self.c, GID)
        cheats_on = sorted(it["key"] for it in cheats.listing(self.c, self.game)["items"] if it["enabled"])
        return cheats_on, sorted(k for k in ("widescreen:A1", "gfx:B1") if launch["patches"].get(k) is not False), launch["settings"].get("fps60", True) is not False

    def test_crash_turns_off_only_what_was_newly_turned_on(self):
        # v0.4.1：上次好好收局时开着 A1、B1、帧率；这局新开一条金手指后崩了 → 只关那条金手指，补丁与帧率不动。期望手写
        self._two_patches(1)
        cheats.note_good(self.c, self.game)
        cheats.save(self.c, self.game, {f"{BID}.txt/Gold x2": True})
        cheats.note_crash(self.c, self.game)
        self.assertEqual(self._on(), ([], ["gfx:B1", "widescreen:A1"], True))
        self.assertEqual([(x["kind"], x["name"]) for x in cheats.crashed(self.c, self.game)], [("cheat", "Gold x2")])

    def test_crash_escalates_unverified_then_all(self):
        # 没有新开的：先关没验过的（B1 缺省开 = 0、金手指），再崩才全关（验过的 A1、帧率）。期望手写
        self._two_patches(0)
        cheats.save(self.c, self.game, {f"{BID}.txt/Gold x2": True})
        cheats.note_good(self.c, self.game)
        cheats.note_crash(self.c, self.game)                                        # 第 1 次：和上次收局一样，没有新开的 → 没验过的
        self.assertEqual(self._on(), ([], ["widescreen:A1"], True))
        cheats.note_crash(self.c, self.game)                                        # 第 2 次：剩下的都验过 → 全关
        self.assertEqual(self._on(), ([], [], False))
        self.assertEqual(sorted(x["kind"] for x in cheats.crashed(self.c, self.game)), ["fps", "patch"])

    def test_crash_without_good_record_and_all_verified_turns_all_off(self):
        # 从没好好收过局（第一次开就崩）、开着的都验过 → 全关（与原做法一致）。期望手写
        self._two_patches(1)
        cheats.note_crash(self.c, self.game)
        self.assertEqual(self._on(), ([], [], False))

    def test_crash_turns_off_adaptive_fullscreen_switch(self):
        # 11-15 候选自测：自适应满屏一族（wsauto:）跟「满屏」开关、不在 packed_patches 里，原先崩了不关。现在算一条 kind fs，关 = 满屏开关写关。期望手写
        from layout import image_mac
        tsv = image_mac(self.c, GID) / "cpatch.tsv"; tsv.parent.mkdir(parents=True, exist_ok=True)
        tsv.write_text("编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅\t模式\n"
                       "wsauto:ab12:w\tmain\t0\twidescreen\t自适应满屏\tMIT\to/r\t\t0\t\t\t\nwsauto:ab12:n\tmain\t1\twidescreen\t自适应满屏\tMIT\to/r\t\t0\t\t\t\n", encoding="utf-8")
        cheats.note_crash(self.c, self.game)
        self.assertIs(community.load_launch(self.c, GID)["settings"].get("widescreen"), False)
        self.assertEqual([x["kind"] for x in cheats.crashed(self.c, self.game)], ["fs"])

    def test_host_crash_spares_first_then_turns_off(self):
        # 11-15：运行时写的落点是 host（两头都在宿主代码）= 多半是 S2Arm 自己的毛病：第一次不关、只记；同一组开关再崩才关。落点 game 照常关。期望手写
        self._two_patches(1)
        docs = self.t / "docs"; docs.mkdir()
        (docs / "crash_where").write_text("host\n")
        cheats.note_crash(self.c, self.game, docs)
        self.assertEqual(self._on(), ([], ["gfx:B1", "widescreen:A1"], True))           # 第一次：没关
        self.assertFalse((docs / "crash_where").exists())                              # 落点读完删
        self.assertEqual(cheats.crashed(self.c, self.game), [])
        (docs / "crash_where").write_text("host\n")
        cheats.note_crash(self.c, self.game, docs)
        self.assertEqual(self._on(), ([], [], False))                                  # 同组再崩：照常关（都验过、没收局记录 → 全关）
        self._two_patches(1); community.launch_path(self.c, GID).unlink()
        (docs / "crash_where").write_text("game\n")
        cheats.note_crash(self.c, self.game, docs)
        self.assertEqual(self._on(), ([], [], False))                                  # 落点在游戏：第一次就关

    def test_auto_off_comes_back_after_update(self):
        # 自动关时记下引擎版本；换了版本起局前重开一次（只开当时关的），记录删掉；同版本不动。期望手写
        self._two_patches(1)
        (self.c.engine / "engine.json").write_text(json.dumps({"version": "0.4.1"}))
        cheats.note_crash(self.c, self.game)
        self.assertEqual(self._on(), ([], [], False))
        self.assertEqual(cheats.restore_after_update(self.c, self.game), [])           # 同版本：不动
        (self.c.engine / "engine.json").write_text(json.dumps({"version": "0.4.2"}))
        back = cheats.restore_after_update(self.c, self.game)
        self.assertEqual(back, [("fps", "fps60")])                                      # 社区补丁按内容编号、换版本改不了：不重开（#1257）
        self.assertEqual(self._on(), ([], [], True))
        self.assertEqual(cheats.restore_after_update(self.c, self.game), [])           # 只重开一次
        (self.c.engine / "engine.json").write_text(json.dumps({"version": "0.4.3"}))
        self.assertEqual(cheats.restore_after_update(self.c, self.game), [])           # 再换版本，补丁也不重开
        self.assertEqual(self._on(), ([], [], True))

    def test_crash_with_nothing_on_records_nothing(self):
        cheats.note_crash(self.c, self.game)
        self.assertEqual(cheats.crashed(self.c, self.game), [])


if __name__ == "__main__":
    unittest.main()
