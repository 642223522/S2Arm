"""S 级按类状态（pack/jobs/sgrade.py state / reenable，11-15）：临时游戏库 + 手写 cpatch.tsv / 启动设置 / 上一局状态，期望按规则手写"""
import json, os, shutil, sys, tempfile, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cheats, community, sgrade, layout

GID = "01001B300B9BE000"
REPO = Path(__file__).resolve().parents[3]
HEAD = "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅\t模式"


class Ctx:
    def __init__(self, root):
        self.library, self.engine, self.private, self.r = root / "lib", root / "engine", root / "priv", {"gameId": GID}
        self.work_root = root / "work"   # 程序缓存 cache/programs（pack/jobs/programs.py）
        table = self.engine / community.SETTINGS_TABLE
        table.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(REPO / community.SETTINGS_TABLE, table)
    def begin(self, *a): pass


class SgradeStateTests(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.c = Ctx(self.t)
        self._base = os.environ.get("S2A_PATCH_BASE"); os.environ["S2A_PATCH_BASE"] = str(self.t / "no_cloud")   # 不联网：云端换成空目录
        p = self.c.library / "catalog.json"; p.parent.mkdir(parents=True)
        p.write_text(json.dumps({"games": [{"id": GID, "packages": [{"type": "base", "version": 0, "display": "1.0.0", "builds": {"main": "aa" * 16}}]}]}))
        self.game = community.game_of(self.c, GID)
        self.img = layout.image_mac(self.c, GID); (self.img / "exefs").mkdir(parents=True, exist_ok=True); (self.img / "exefs" / "main").write_bytes(b"x")
        self.real = cheats.main_build; cheats.main_build = lambda c, g: "AAAAAAAAAAAAAAAA"
        self.m = {"build": "AAAAAAAAAAAAAAAA", "version": "1.0.0", "exact": {}, "others": [], "port": False}

    def tearDown(self):
        cheats.main_build = self.real; shutil.rmtree(self.t, ignore_errors=True)
        if self._base is None: os.environ.pop("S2A_PATCH_BASE", None)
        else: os.environ["S2A_PATCH_BASE"] = self._base

    def tsv(self, *rows):
        (self.img / "cpatch.tsv").write_text(HEAD + "\n" + "".join(r + "\n" for r in rows), encoding="utf-8")

    def ws_pack(self):
        self.tsv("wsauto:f1:w\tmain\t0\twidescreen\t宽\tMIT\to/r\t\t1\t\t\tboth", "wsauto:f1:n\tmain\t1\twidescreen\t窄\tMIT\to/r\t\t1\t\t\tboth",
                 "fps:F1\tmain\t2\tfps\t60 帧\tMIT\to/r\t\t1\t60\t\t", "gfx:G1\tmain\t3\tgfx\t画面\tMIT\to/r\t\t1\t\t\t")

    def st(self):
        return sgrade.state(self.c, self.game, match=self.m)

    def test_patch_on_then_auto_off_then_user_then_reenable(self):
        # 包里有自适应满屏 + 帧率 + 画面：缺省 on（满屏来源 patch、自适应）；崩溃自动关 → off_auto（原因 crash）；玩家自己关 → off_user（自动关记录清掉）；一键重开 → on
        self.ws_pack()
        s = self.st()
        self.assertEqual((s["widescreen"]["state"], s["widescreen"]["source"], s["widescreen"]["active"], s["fps"]["state"], s["gfx"]["state"], s["cheats"]["state"]),
                         ("on", "patch", "adaptive", "on", "on", "none"))
        cheats.note_crash(self.c, self.game)     # 都验过、没收局记录 → 全关
        s = self.st()
        self.assertEqual((s["widescreen"]["state"], s["fps"]["state"], s["gfx"]["state"]), ("off_auto", "off_auto", "off_auto"))
        self.assertEqual(s["widescreen"]["autoOff"]["cause"], "crash")
        self.c.r = {"gameId": GID, "settings": {"widescreen": False}}
        community.save(self.c)
        s = self.st()
        self.assertEqual((s["widescreen"]["state"], s["widescreen"]["autoOff"], s["fps"]["state"]), ("off_user", None, "off_auto"))
        self.c.r = {"gameId": GID, "key": "fps"}
        s = sgrade.reenable(self.c)
        self.assertEqual((s["fps"]["state"], s["fps"]["autoOff"]), ("on", None))

    def test_own_widen_version_ineffective_opted_out(self):
        # 11-15 维护者「没补丁的游戏手动打开满屏就走咱们通用方案」：没有满屏补丁 → 来源 own（不看已验证名单），缺省关（off_user），玩家明确开 → on
        self.tsv("fps:F1\tmain\t2\tfps\t60 帧\tMIT\to/r\t\t1\t60\t\t")
        s = self.st()
        self.assertEqual((s["widescreen"]["state"], s["widescreen"]["source"]), ("off_user", "own"))
        self.c.r = {"gameId": GID, "settings": {"widescreen": True}}; community.save(self.c)
        s = self.st()
        self.assertEqual((s["widescreen"]["state"], s["widescreen"]["source"]), ("on", "own"))
        # 补丁库只有别的版本的满屏：照旧是 own（这一版能开通用满屏），可用版本照列（升级页提示）
        self.m["others"] = [{"version": "1.2.0", "cats": ["widescreen", "fps"]}]
        s = self.st()
        self.assertEqual((s["widescreen"]["state"], s["widescreen"]["source"], s["widescreen"]["versions"]["available"]), ("on", "own", ["1.2.0"]))
        # 上一局帧率补丁开着、实测只有 40 帧（目标 60）→ ineffective
        tmp = self.c.library / "temp" / GID; tmp.mkdir(parents=True); (tmp / "cpatch_status.tsv").write_text("fps:F1\t开\tfps=40\n")
        self.assertEqual(self.st()["fps"]["state"], "ineffective")
        # 出包时选了不打入 → 四类都 opted_out
        layout.update_info(self.c, GID, sgradeOff=True)
        s = self.st()
        self.assertEqual({s[k]["state"] for k in ("widescreen", "fps", "gfx", "cheats")}, {"opted_out"})

    def test_own_widen_auto_off_and_fi_source(self):
        # 11-15 维护者：没补丁的款手动开满屏走我方通用满屏，失败 / 崩了下一局自动关；帧率解锁没补丁时用补帧。期望手写：
        #   ① 运行时自检退回留下 widen_auto_off → 收局 note_widen：满屏写关、状态 off_auto、原因 widen_fit、标记删掉
        #   ② 再手动开满屏、这局崩了（落点在游戏）→ note_crash 把满屏算进开着的项、关掉（原因 crash）
        #   ③ 没有帧率补丁：来源 fi；这台能补帧时缺省 off_user（Mac 今天缺省不补），明确开 → on；不能补帧 → unsupported
        self.tsv("gfx:G1\tmain\t1\tgfx\t画面\tMIT\to/r\t\t1\t\t\t")
        self.c.r = {"gameId": GID, "settings": {"widescreen": True}}; community.save(self.c)
        docs = self.t / "docs"; docs.mkdir(); (docs / "widen_auto_off").write_text("1\n")
        self.assertTrue(cheats.note_widen(self.c, self.game, docs))
        s = self.st()
        self.assertEqual((s["widescreen"]["state"], s["widescreen"]["source"], s["widescreen"]["autoOff"]["cause"], (docs / "widen_auto_off").exists()),
                         ("off_auto", "own", "widen_fit", False))
        self.c.r = {"gameId": GID, "settings": {"widescreen": True}}; community.save(self.c)
        (docs / "crash_where").write_text("game\n")
        cheats.note_crash(self.c, self.game, docs)
        self.assertEqual((self.st()["widescreen"]["state"], community.load_launch(self.c, GID)["settings"].get("widescreen")), ("off_auto", False))
        real = sgrade.fi_supported
        try:
            sgrade.fi_supported = lambda: True
            f = self.st()["fps"]; self.assertEqual((f["source"], f["fiSupported"], f["state"]), ("fi", True, "off_user"))
            self.c.r = {"gameId": GID, "settings": {"fps60": True}}; community.save(self.c)
            self.assertEqual(self.st()["fps"]["state"], "on")
            sgrade.fi_supported = lambda: False
            self.assertEqual(self.st()["fps"]["state"], "unsupported")
        finally:
            sgrade.fi_supported = real

    def test_kit_state_for_iphone(self):
        # 出 iPhone 包写的底料：kit 里有自适应满屏 → 来源 patch；没有补丁、带宽屏已验证标记 → own；版本对照照 match 抄；画面类 mac_only。期望手写
        kit = self.t / "kit"; kit.mkdir()
        (kit / "cpatch.tsv").write_text(HEAD + "\nwsauto:f1:w\tmain\t0\twidescreen\t宽\tMIT\to/r\t\t1\t\t\tboth\n", encoding="utf-8")
        real = sgrade._match; sgrade._match = lambda c, gid: dict(self.m, others=[{"version": "1.2.0", "cats": ["fps"]}])
        try:
            sgrade.write_kit_state(self.c, GID, kit)
            j = json.loads((kit / "sgrade_state.json").read_text())
            self.assertEqual((j["widescreen"]["source"], j["fps"]["versions"]["available"], j["gfx"]["state"], j["optedOut"]), ("patch", ["1.2.0"], "mac_only", False))
            (kit / "cpatch.tsv").write_text(HEAD + "\n", encoding="utf-8"); (kit / "widen_verified.tsv").write_text("x\n")
            sgrade.write_kit_state(self.c, GID, kit)
            self.assertEqual(json.loads((kit / "sgrade_state.json").read_text())["widescreen"]["source"], "own")
        finally:
            sgrade._match = real

    def test_own_widen_counts_for_card_badge_upgrade(self):
        # 维护者 11-15「两者合成一套」：这一版在宽屏已验证名单 → patches.own_widen 真（出包页 / 升级页用）；包里带 widen_verified.tsv 就亮金色 S。期望手写
        import patches, library
        vt = self.c.engine / "graphics/widen/tables/verified.tsv"; vt.parent.mkdir(parents=True, exist_ok=True)
        vt.write_text("# x\n" + GID + "\t" + "aa" * 16 + "\tcensus\tapple\t2026-11-15\tx\n0100000000000001\t" + "bb" * 16 + "\tcensus\tandroid\t2026-11-15\tx\n")
        self.assertEqual((patches.own_widen(self.c, GID, "AAAAAAAAAAAAAAAA"), patches.own_widen(self.c, GID, "CCCCCCCCCCCCCCCC"),
                          patches.own_widen(self.c, "0100000000000001", "BBBBBBBBBBBBBBBB"), patches.own_widen(self.c, GID, "")), (True, False, False, False))
        self.assertFalse(library.sgrade_badge(self.c, GID, self.img))      # 包里什么都没有
        (self.img / "widen_verified.tsv").write_text("x\n")
        self.assertTrue(library.sgrade_badge(self.c, GID, self.img))       # 只有我方通用满屏也亮

    def test_local_patches_collects_other_versions(self):
        # 升级页拆「没有 / 是别的版本的」：本地补丁库里这款别的版本的条目按类收版本号；本版的照常计数。期望手写
        import patches
        items = [{"cat": "widescreen", "bids": ["AAAAAAAAAAAAAAAA"], "source": {"path": "G/1.0.0/a.pchtxt"}},
                 {"cat": "fps", "bids": ["BBBBBBBBBBBBBBBB"], "source": {"path": "G/1.2.0/60fps.pchtxt"}},
                 {"cat": "fps", "bids": ["CCCCCCCCCCCCCCCC"], "source": {"path": "G/1.3.0/60fps.pchtxt"}}]
        real_s, real_b = patches._snapshot, patches.bundle
        patches._snapshot = lambda c: ({}, None); patches.bundle = lambda c, k, cloud, snap, get: items if k.startswith("g/") else []
        try:
            oth = {}
            got = sgrade.local_patches(self.c, GID, "AAAAAAAAAAAAAAAA", oth)
            self.assertEqual((got["widescreen"], got["fps"], sorted(oth["fps"])), (1, 0, ["1.2.0", "1.3.0"]))
        finally:
            patches._snapshot, patches.bundle = real_s, real_b


    def test_fps_patch_failed_shows_reason(self):
        # 11-15 #934：补丁库有这一版的帧率补丁、出包时一份都没打进去（FPSLocker 配置不支持）→ fps 状态 failed、带原因键，
        #   不说成开着生效（也不说成「不能补帧」）；包里有帧率补丁时照旧按补丁走（failed 只在一份没进时出）。期望手写
        self.tsv("gfx:G1\tmain\t1\tgfx\t画面\tMIT\to/r\t\t1\t\t\t")
        layout.update_info(self.c, GID, sgradeResult={"mac": {"applied": [], "failed": [
            {"id": "fps:ab", "cat": "fps", "name": "FPSLocker", "why": "result.why.unsupported", "detail": "FPSLocker 配置不支持：…"}]}})
        f = self.st()["fps"]
        self.assertEqual((f["state"], f["failed"]), ("failed", [{"name": "FPSLocker", "why": "result.why.unsupported"}]))
        self.tsv("fps:F1\tmain\t2\tfps\t60 帧\tMIT\to/r\t\t1\t60\t\t")
        f = self.st()["fps"]
        self.assertEqual((f["state"], "failed" in f), ("on", False))


if __name__ == "__main__":
    unittest.main()
