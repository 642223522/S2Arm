"""装到 Apple TV / 电视存档自动备份 / 从电视拉诊断（pack/jobs/tvos.py、diag.py，11-15 tvOS 版）。devicectl 全部打桩（组里没有 Apple TV），
期望值按 TVPort 的规则与本文件里写明的输入手算，不跑被测实现推。"""
import json, plistlib, shutil, sys, unittest
import unittest.mock as um
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from core import Failure, atomic
from tests.jobcase import JobCase
import diag
import install
import layout
import tvos

G = "0100ABCD00010000"
H = "0100ABCD00020000"
TV = dict(identifier="TV-ID", hardwareProperties=dict(platform="tvOS", deviceType="appleTV", productType="AppleTV14,1", udid="TV-UDID", reality="physical"),
          deviceProperties=dict(name="客厅", osVersionNumber="26.1"), connectionProperties=dict(transportType="localNetwork", pairingState="paired"))
PHONE = dict(identifier="PH", hardwareProperties=dict(platform="iOS", productType="iPhone18,2", udid="PH-UDID", reality="physical"),
             deviceProperties=dict(name="手机"), connectionProperties=dict(transportType="wired", pairingState="paired"))
TEAM = dict(id="ABCDE12345", name="甲", free=True)
ACTION_ERROR = {"error": {"domain": "CoreDevice.ActionError"}}


class DetectTest(unittest.TestCase):
    def test_is_tv_by_device_type_or_platform(self):
        # 期望（手写）：platform=tvOS 认；只有 deviceType=appleTV（没 platform）也认；模拟器、iPhone、Mac 不认
        only_type = dict(hardwareProperties=dict(deviceType="appleTV"))
        sim = dict(hardwareProperties=dict(platform="tvOS", reality="simulated"))
        mac = dict(hardwareProperties=dict(platform="macOS", deviceType="mac"))
        self.assertEqual([diag.is_tv(d) for d in (TV, only_type, sim, PHONE, mac)], [True, True, False, False, False])
        # iPhone 装机链照旧不把电视当候选（diag.is_candidate），电视走 tvos 自己的链
        self.assertFalse(diag.is_candidate(TV))
        self.assertTrue(diag.is_candidate(PHONE))


class TvCase(JobCase):
    def setUp(self):
        super().setUp()
        for p in (um.patch.object(tvos, "RETRY_DELAYS", (0, 0)), um.patch.object(install, "LINK_RETRY_WAIT", 0)):
            p.start(); self.addCleanup(p.stop)
        atomic(self.c.library / "catalog.json", dict(schema=1, games=[dict(id=G, name="甲"), dict(id=H, name="乙")]))

    def listed(self, devices):
        import target
        return um.patch.object(target, "device_list", return_value=(devices, "", 0, ""))


class DevicesTest(TvCase):
    def test_devices_job_lists_only_tvs(self):
        with self.listed([PHONE, TV]):
            rows = tvos.devices_job(self.c)["devices"]
        self.assertEqual(rows, [dict(id="TV-ID", udid="TV-UDID", name="客厅", model="AppleTV14,1", os="26.1", kind="appleTV", online=True)])

    def test_pick(self):
        other = json.loads(json.dumps(TV)); other.update(identifier="TV2"); other["hardwareProperties"]["udid"] = "TV2-UDID"; other["deviceProperties"]["name"] = "卧室"
        with self.listed([PHONE]), self.assertRaises(Failure) as e:
            tvos.pick(self.c)
        self.assertEqual(e.exception.code, "device_not_connected")
        with self.listed([TV, other]), self.assertRaises(Failure) as e:
            tvos.pick(self.c)
        self.assertEqual(e.exception.code, "device_required")
        self.assertIn("「客厅」、「卧室」", str(e.exception))
        with self.listed([TV, other]):
            self.assertEqual(tvos.pick(self.c, "卧室")["identifier"], "TV2")
            self.assertEqual(tvos.pick(self.c, "TV-UDID")["identifier"], "TV-ID")
        with self.listed([TV]):   # 选的那台没列着、只有一台：用这一台
            self.assertEqual(tvos.pick(self.c, "gone")["identifier"], "TV-ID")


class InstallTest(TvCase):
    def setUp(self):
        super().setUp()
        for g, size in ((G, 7), (H, 5)):
            image = layout.path(self.c, g, "image", "tvos")
            (image / "kit").mkdir(parents=True); (image / "kit/main.npdm").write_bytes(b"META")
            (image / ".pack").mkdir(); (image / ".pack/manifest.json").write_text(json.dumps(dict(format="img", index_sha256="pack-" + g)))
            (image / ".pack/index.tsv").write_text("x"); (image / ".pack/game.img").write_bytes(b"i" * size)
        self.calls = []

    def run_install(self, install_replies, pack_sizes=None, rec=None):
        """install_replies：每次 devicectl device install app 的 (退出码, 原文)；pack_sizes：电视上资源包根列出的 {文件: 大小}（缺省 = 和 Mac 上一样）"""
        replies = list(install_replies)
        def devicectl(c, *a, timeout=0):
            if a[:3] == ("device", "install", "app"):
                self.calls.append(("install", a[a.index("--device") + 1]))
                rc, err = replies.pop(0)
                return rc, {}, err
            if a[:3] == ("device", "info", "files"):
                sub = a[a.index("--subdirectory") + 1]
                self.calls.append(("list", sub))
                if sub.endswith("/资源包"):
                    gid = sub.split("/")[-2]
                    pack = layout.path(self.c, gid, "image", "tvos", ".pack")
                    sizes = pack_sizes if pack_sizes is not None else {p.name: p.stat().st_size for p in pack.iterdir()}
                    return 0, {"result": {"files": [dict(relativePath=k, metadata=dict(size=v)) for k, v in sizes.items()]}}, ""
                return 1, ACTION_ERROR, "no such app"
            raise AssertionError(a)
        def assemble(c, gid, others, shell, sid):
            out = self.root / "asm"; app = out / "S2Arm.app"; app.mkdir(parents=True)
            (app / "Info.plist").write_bytes(plistlib.dumps(dict(CFBundleIdentifier="io.s2arm.games")))
            self.calls.append(("assemble", gid, tuple(sorted(others))))
            return out, app, sorted({gid, *others})
        def sign(c, app, team, bid, udid, log):
            self.calls.append(("sign", plistlib.loads((Path(app) / "Info.plist").read_bytes())["CFBundleIdentifier"], udid))
        def push_pack(c, ident, bid, pack, udid=None, docs=None, ctx=None, pack_root=None):
            self.calls.append(("push", ident, bid, docs, pack_root, udid))
            return 1, 7
        if rec:
            tvos.save_rec(self.c, "TV-UDID", rec)
        self.c.r["gameId"] = G
        with self.listed([PHONE, TV]), um.patch.object(diag, "devicectl", devicectl), um.patch.object(tvos, "assemble", assemble), \
             um.patch.object(tvos, "sign", sign), um.patch.object(tvos, "tv_shell", return_value=(self.root, "SID")), \
             um.patch.object(install, "push_pack", push_pack), um.patch.object(install, "xcode_teams", return_value=[TEAM]):
            return tvos.install_tv(self.c)

    def test_command_sequence_with_transient_retry(self):
        # 期望（手写）：签名用包名 io.s2arm.tv.abcde12345 + 电视 UDID → 装 App 第一次 3002（临时）再试成 → 推本款资源包到
        #   Library/Caches/S2Arm/games/<款>/资源包（文档根 …/games/<款>）→ 列电视上的资源包根核大小；电视记录记下这款与包名
        r = self.run_install([(1, "ERROR: The operation couldn't be completed. (com.apple.dt.CoreDeviceError error 3002.)"), (0, "")])
        docs = f"Library/Caches/S2Arm/games/{G}"
        self.assertEqual(self.calls, [("assemble", G, ()), ("sign", "io.s2arm.tv.abcde12345", "TV-UDID"), ("install", "TV-ID"), ("install", "TV-ID"),
                                      ("push", "TV-ID", "io.s2arm.tv.abcde12345", docs, docs + "/资源包", "TV-UDID"), ("list", docs + "/资源包")])
        self.assertEqual((r["deviceKind"], r["deviceName"], r["games"], r["packFiles"]), ("Apple TV", "客厅", [G], 1))
        rec = tvos.load_rec(self.c, "TV-UDID")
        self.assertEqual((rec["bundleId"], rec["games"], rec["shellId"]), ("io.s2arm.tv.abcde12345", {G: dict(pack="pack-" + G)}, "SID"))
        self.assertEqual(layout.devices(self.c), [])   # 电视记录不进 iPhone 的 devices/（「更新 iPhone 上的 S2Arm」不该列电视）

    def test_second_game_backs_up_and_pushes_only_changed(self):
        # 电视上已有 H（包号没变）：H 一起组进容器、装前先备份存档（这里电视上没有存档 = 列表 ActionError），只推这款 G
        self.run_install([(0, "")], rec=dict(bundleId="io.s2arm.tv.abcde12345", games={H: dict(pack="pack-" + H)}))
        self.assertEqual(self.calls[0], ("assemble", G, (H,)))
        self.assertIn(("list", f"Library/Caches/S2Arm/games/{H}/{install.SAVE_REL}"), self.calls)
        self.assertEqual([c[3] for c in self.calls if c[0] == "push"], [f"Library/Caches/S2Arm/games/{G}"])

    def test_non_transient_install_error_stops_at_once(self):
        with self.assertRaises(Failure) as e:
            self.run_install([(1, "MismatchedApplicationIdentifierEntitlement")])
        self.assertEqual(e.exception.code, "app_other_signer")
        self.assertEqual([c for c in self.calls if c[0] == "install"], [("install", "TV-ID")])

    def test_transient_install_error_tried_three_times(self):
        with self.assertRaises(Failure) as e:
            self.run_install([(1, "error 3002")] * 3)
        self.assertEqual(e.exception.code, "device_install_failed")
        self.assertEqual(len([c for c in self.calls if c[0] == "install"]), 3)
        self.assertFalse(any(c[0] == "push" for c in self.calls))

    def test_size_mismatch_after_push_fails(self):
        # Mac 上 game.img 7 字节，电视上列出 3 字节 → 没传完整，报 resource_transfer_failed，记录里这款不记新包号
        with self.assertRaises(Failure) as e:
            self.run_install([(0, "")], pack_sizes={"index.tsv": 1, "manifest.json": len(json.dumps(dict(format="img", index_sha256="pack-" + G))), "game.img": 3})
        self.assertEqual(e.exception.code, "resource_transfer_failed")
        self.assertIn("game.img", str(e.exception))
        self.assertEqual(tvos.load_rec(self.c, "TV-UDID")["games"], {G: dict(pack="")})

    def test_not_built_for_tv(self):
        shutil.rmtree(layout.path(self.c, G, "image", "tvos"))
        self.c.r["gameId"] = G
        with self.assertRaises(Failure) as e:
            tvos.install_tv(self.c)
        self.assertEqual(e.exception.code, "job_failed")
        self.assertFalse(tvos.tv_ready(self.c, G))
        self.assertTrue(tvos.tv_ready(self.c, H))


class ProvProjectTest(unittest.TestCase):
    def test_template_turned_into_tvos(self):
        import tempfile
        engine = Path(__file__).resolve().parents[3]
        with tempfile.TemporaryDirectory() as d:
            ents = Path(d) / "e.plist"; ents.write_bytes(plistlib.dumps({}))
            pbx = tvos.prov_project(engine, Path(d) / "p", "io.s2arm.tv.team", "TEAM", ents).read_text()
        self.assertNotIn("iphoneos", pbx)
        self.assertIn("SDKROOT = appletvos;", pbx); self.assertIn("TARGETED_DEVICE_FAMILY = 3;", pbx); self.assertIn("TVOS_DEPLOYMENT_TARGET = 17.0;", pbx)
        self.assertIn('"io.s2arm.tv.team"', pbx); self.assertNotIn("S2ABID", pbx); self.assertNotIn("S2ATEAM", pbx)


class SignTest(TvCase):
    def sign_with_log(self, text, step="dev_sign"):
        """xcodebuild 申请成功、dev_sign 那步按 text 失败（退出非 0）；→ 抛出的 Failure 与 dev_sign 收到的环境"""
        log, seen = self.root / "sign.log", {}
        def run(args, log_path=None, env=None, cwd=None, timeout=None, **kw):
            name = "dev_sign" if str(args[1]).endswith("dev_sign.py") else "xcodebuild"
            seen[name] = env
            if name == step:
                Path(log_path).write_text(text); raise Failure("tool", code="tool_exit")
        with um.patch.object(self.c, "run", run), um.patch.object(tvos, "ENTITLEMENTS", "pack/app.entitlements"), self.assertRaises(Failure) as e:
            tvos.sign(self.c, self.root, TEAM, "io.s2arm.tv.x", "TV-UDID", log)
        return e.exception, seen

    def test_paid_account_named_plainly(self):
        # 免费账号：dev_sign 报描述文件不允许扩展虚拟寻址 / Xcode 报个人团队不支持 → tvos_paid_team_required，原话里写「付费」
        for text, step in (("描述文件不允许这些权限：['com.apple.developer.kernel.extended-virtual-addressing']", "dev_sign"),
                           ('error: Personal development teams, including "甲", do not support the Extended Virtual Addressing capability.', "xcodebuild")):
            e, seen = self.sign_with_log(text, step)
            self.assertEqual(e.code, "tvos_paid_team_required")
            self.assertIn("付费", str(e))
            if step == "dev_sign":   # dev_sign 按 tvOS 挑描述文件、核两项权限
                self.assertEqual(seen["dev_sign"]["S2A_SIGN_PLATFORM"], "tvos")
        e, _ = self.sign_with_log("No signing certificate for team")   # 别的签名失败照旧按原文归码
        self.assertEqual(e.code, "signing_certificate_missing")

    def test_missing_entitlements_file(self):
        with um.patch.object(tvos, "ENTITLEMENTS", "pack/no-such.entitlements"), self.assertRaises(Failure) as e:
            tvos.sign(self.c, self.root, TEAM, "io.s2arm.tv.x", "TV-UDID", self.root / "l.log")
        self.assertEqual(e.exception.code, "engine_incomplete")


class BackupTest(TvCase):
    """假电视：files = {存档相对路径: (内容, 修改时刻)}；on_copy 每拉一个文件后调一次（模拟拉的时候游戏在存档）"""
    BID = "io.s2arm.tv.abcde12345"

    def setUp(self):
        super().setUp()
        self.files = {"0000000000000001/0/save.dat": (b"AAAA", 1), "0000000000000001/0/meta": (b"m", 1)}
        self.copies, self.on_copy, self.stamps = 0, None, iter(f"20261115-1200{i:02d}" for i in range(60))

    def devicectl(self, c, *a, timeout=0):
        if a[:3] == ("device", "info", "files"):
            if self.files is None:
                return 1, ACTION_ERROR, "no app"
            return 0, {"result": {"files": [dict(relativePath="0000000000000001", resources=dict(isDirectory=True))] +
                                  [dict(relativePath=k, metadata=dict(size=len(v), lastModDate=t)) for k, (v, t) in self.files.items()]}}, ""
        if a[:3] == ("device", "copy", "from"):
            src = a[a.index("--source") + 1]
            self.assertTrue(src.startswith(f"Library/Caches/S2Arm/games/{G}/{install.SAVE_REL}/"))
            Path(a[a.index("--destination") + 1]).write_bytes(self.files[src.split(install.SAVE_REL + "/", 1)[1]][0])
            self.copies += 1
            if self.on_copy: self.on_copy()
            return 0, {}, ""
        raise AssertionError(a)

    def round(self):
        stamp = next(self.stamps)
        with um.patch.object(diag, "devicectl", self.devicectl), um.patch.object(tvos.time, "strftime", return_value=stamp):
            return tvos.backup_game(self.c, "TV-ID", self.BID, G)

    def place(self):
        return layout.path(self.c, G, "save_backup")

    def kept(self):
        return sorted(p.name for p in self.place().iterdir() if p.is_dir())

    def test_dedup_and_listing_shortcut(self):
        first = self.round()
        self.assertEqual((first["state"], first["files"]), ("backed-up", 2))
        self.assertEqual((Path(first["folder"]) / "0000000000000001/0/save.dat").read_bytes(), b"AAAA")
        self.assertEqual(self.copies, 2)
        # 电视上没变：清单相同 → 不拉、不新建
        self.assertEqual(self.round()["state"], "unchanged"); self.assertEqual(self.copies, 2)
        # 重写成同样内容（修改时刻变了）：拉回比对逐字节相同 → 不新建，记下新清单；再下一轮不用拉
        self.files = {k: (v, 2) for k, (v, _) in self.files.items()}
        self.assertEqual(self.round()["state"], "unchanged"); self.assertEqual(self.copies, 4)
        self.assertEqual(self.round()["state"], "unchanged"); self.assertEqual(self.copies, 4)
        self.assertEqual(self.kept(), ["tv-20261115-120000"])
        # 内容变了 → 新一份
        self.files["0000000000000001/0/save.dat"] = (b"BBBB", 3)
        self.assertEqual(self.round()["state"], "backed-up")
        self.assertEqual(self.kept(), ["tv-20261115-120000", "tv-20261115-120004"])

    def test_listing_changed_during_copy_is_discarded(self):
        # 第一次拉到一半游戏存了档（清单变了）→ 这份作废；第二次清单稳定 → 只留第二次拉的那份，内容是新的
        def saved_once():
            self.files["0000000000000001/0/save.dat"] = (b"NEW!", 9); self.on_copy = None
        self.on_copy = saved_once
        r = self.round()
        self.assertEqual(r["state"], "backed-up")
        self.assertEqual((Path(r["folder"]) / "0000000000000001/0/save.dat").read_bytes(), b"NEW!")
        self.assertEqual(self.kept(), ["tv-20261115-120000"])   # 没有残留的临时目录 / 半份备份

    def test_always_changing_gives_busy_without_backup(self):
        tick = iter(range(100, 200))
        def always():
            self.files["0000000000000001/0/meta"] = (b"m", next(tick))
        self.on_copy = always
        self.assertEqual(self.round()["state"], "busy")
        self.assertEqual(self.kept(), [])
        self.assertEqual(self.copies, 3 * 2)   # 试 3 次，每次 2 个文件

    def test_keep_newest_ten_and_leave_iphone_backups(self):
        iphone = self.place() / "20261101-080000"; iphone.mkdir(parents=True)   # iPhone 装机前的备份（不带 tv- 前缀）不归自动备份管
        for i in range(12):
            self.files["0000000000000001/0/save.dat"] = (b"v%d" % i, 10 + i)
            self.assertEqual(self.round()["state"], "backed-up")
        self.assertEqual(self.kept(), ["20261101-080000"] + [f"tv-20261115-1200{i:02d}" for i in range(2, 12)])

    def test_no_app_on_tv(self):
        self.files = None
        self.assertEqual(self.round()["state"], "none")
        self.assertEqual(self.copies, 0)

    def test_autobackup_job_rounds_recorded_games(self):
        tvos.save_rec(self.c, "TV-UDID", dict(bundleId=self.BID, games={G: {}}))
        with self.listed([PHONE, TV]), um.patch.object(diag, "devicectl", self.devicectl):
            out = tvos.autobackup(self.c)
        self.assertEqual(out["state"], "done")
        self.assertEqual(out["devices"][0]["games"][G]["state"], "backed-up")
        with self.listed([PHONE]):   # 没连电视：不算错
            self.assertEqual(tvos.autobackup(self.c), dict(state="unreachable", devices=[]))


class PullDiagTest(TvCase):
    def test_pull_from_tv_uses_caches_root(self):
        # 期望（手写）：电视上的诊断按 Library/Caches/S2Arm 根拉（iOS 的 Documents/<x> → Library/Caches/S2Arm/<x>），每款解包日志在 …/games/<款>/unpack.log
        apps = {"result": {"apps": [{"bundleIdentifier": "io.s2arm.tv.abcde12345", "name": "S2Arm"}]}}
        sources = []
        def fake(c, *a, timeout=120):
            if a[:2] == ("list", "devices"): return 0, {"result": {"devices": [TV]}}, ""
            if a[:3] == ("device", "info", "apps"): return 0, apps, ""
            src = a[a.index("--source") + 1]; sources.append(src)
            if src == "Library/Caches/S2Arm/host.log":
                Path(a[a.index("--destination") + 1]).write_text("log"); return 0, {}, ""
            return 1, {}, "no"
        with um.patch.object(diag, "devicectl", fake):
            out = diag.pull(self.c)
        self.assertEqual(out["apps"][0]["files"], 1)
        self.assertIn("Library/Caches/S2Arm/diag", sources)
        self.assertIn(f"Library/Caches/S2Arm/games/{G}/unpack.log", sources)
        self.assertFalse(any(s.startswith("Documents") for s in sources))


class ExportPlanTest(unittest.TestCase):
    def test_appletv_platform_order(self):
        import batch
        items = batch.create([dict(gameId=G, name="甲", platforms=["appletv", "iphone", "mac"])])
        self.assertEqual(items["items"][0]["platforms"] if isinstance(items, dict) else items[0]["platforms"], ["mac", "iphone", "appletv"])


class DeriveTest(TvCase):
    """出 Apple TV 包（tvos.derive，ipa 作业 platform = tvos）：从 image/ios 派生，ASTC 包进 tvOS 资源包清单，game.json 记 tvos。期望手写"""
    def make_ios(self):
        img = layout.path(self.c, G, "image", "ios")
        (img / "kit").mkdir(parents=True); (img / "kit/main.npdm").write_bytes(b"npdm")
        pack = img / ".pack"; pack.mkdir()
        (pack / "game.img").write_bytes(b"IMG")
        (pack / "index.tsv").write_text("game.img\t3\tabc\n", encoding="utf-8")
        (pack / "manifest.json").write_text(json.dumps(dict(version=3, files=1, total=3, index_sha256="old")), encoding="utf-8")
        return img

    def test_derive_clones_and_adds_astc(self):
        img = self.make_ios()
        ex = self.root / "extract"; (ex / "romfs").mkdir(parents=True)
        runs = []
        def run(argv, log, env=None, **k):
            runs.append([str(a) for a in argv])
            if "astc_pack.py" in str(argv[4]): Path(argv[7]).write_bytes(b"ASTC" * 4)   # 16 字节假包（argv = python -X utf8 -B 脚本 build romfs 输出）
        shell = self.root / "run/s2arm/cache/shell-tvos/sid1"; shell.mkdir(parents=True); (shell / "manifest.json").write_text("{}")
        with um.patch.object(self.c, "run", side_effect=run), um.patch.object(tvos, "tv_shell_id", return_value="sid1"), \
             um.patch.dict("os.environ", {"S2A_RUN_ROOT": str(self.root / "run")}), um.patch.object(self.c, "env", return_value={"S2A_RUN_ROOT": str(self.root / "run")}):
            tvos.derive(self.c, G, ex)
        tv = layout.path(self.c, G, "image", "tvos", create=False)
        # ① kit / 资源包派生出来，iPhone 那份清单不动
        self.assertEqual((tv / "kit/main.npdm").read_bytes(), b"npdm")
        self.assertEqual((img / ".pack/index.tsv").read_text(), "game.img\t3\tabc\n")
        # ② ASTC 预转读解开的 romfs、写进 tvOS 资源包，清单多一行 astc.pack（16 字节，SHA-256 手算），index_sha256 = 新 index.tsv 的 SHA-256
        self.assertEqual([r[4:8] for r in runs if "astc_pack.py" in r[4]], [[str(self.c.engine / "pack/astc_pack.py"), "build", str(ex / "romfs"), str(tv / ".pack/astc.pack")]])
        import hashlib
        row = "astc.pack\t16\t" + hashlib.sha256(b"ASTC" * 4).hexdigest()
        ix = "game.img\t3\tabc\n" + row + "\n"
        self.assertEqual((tv / ".pack/index.tsv").read_text(), ix)
        m = json.loads((tv / ".pack/manifest.json").read_text())
        self.assertEqual((m["files"], m["total"], m["index_sha256"]), (2, 19, hashlib.sha256(ix.encode()).hexdigest()))
        # ③ 壳已在本机缓存：不出壳；④ game.json 记 tvos
        self.assertFalse([r for r in runs if "shell_build.sh" in " ".join(r)])
        info = layout.game_info(self.c, G)["tvos"]
        self.assertEqual((info["shellId"], info["pack"], info["astc"]), ("sid1", m["index_sha256"], True))

    def test_derive_on_windows_copies_without_cp_and_uses_given_shell(self):
        """Windows（没有 cp）：kit / 资源包整份拷贝，不调 cp；启动器给了 tvShellDir 就不现出壳"""
        img = self.make_ios()
        ex = self.root / "extract"; (ex / "romfs").mkdir(parents=True)
        runs = []
        def run(argv, log, env=None, **k):
            runs.append([str(a) for a in argv])
            if "astc_pack.py" in str(argv[4]): Path(argv[7]).write_bytes(b"ASTC" * 4)
        real = tvos.subprocess.run
        def no_cp(argv, *a, **k):
            if argv and argv[0] == "cp": raise AssertionError("Windows 上不该调 cp")
            return real(argv, *a, **k)
        given = self.root / "Shell-tvOS"; given.mkdir(); (given / "manifest.json").write_text("{}")
        self.c.r["tvShellDir"] = str(given)
        with um.patch.object(tvos.sys, "platform", "win32"), um.patch.object(tvos.subprocess, "run", side_effect=no_cp), \
             um.patch.object(self.c, "run", side_effect=run), um.patch.object(tvos, "tv_shell_id", return_value="sid1"), \
             um.patch.object(self.c, "env", return_value={"S2A_RUN_ROOT": str(self.root / "run")}):
            tvos.derive(self.c, G, ex)
        tv = layout.path(self.c, G, "image", "tvos", create=False)
        self.assertEqual((tv / "kit/main.npdm").read_bytes(), b"npdm")
        self.assertEqual((tv / ".pack/game.img").read_bytes(), b"IMG")
        (tv / ".pack/game.img").write_bytes(b"CHANGED")   # 整份拷贝：改 tvOS 这份不动 iPhone 那份
        self.assertEqual((img / ".pack/game.img").read_bytes(), b"IMG")
        self.assertFalse([r for r in runs if "shell_build.sh" in " ".join(r)])

    def test_derive_on_windows_without_tv_shell_stops(self):
        """Windows 安装包没带 Shell-tvOS：明说出不了，不去现出壳（要 Xcode）"""
        self.make_ios()
        ex = self.root / "extract"; (ex / "romfs").mkdir(parents=True)
        runs = []
        def run(argv, log, env=None, **k):
            runs.append([str(a) for a in argv])
            if "astc_pack.py" in str(argv[4]): Path(argv[7]).write_bytes(b"ASTC" * 4)
        with um.patch.object(tvos.sys, "platform", "win32"), um.patch.object(self.c, "run", side_effect=run), \
             um.patch.object(tvos, "tv_shell_id", return_value="sid1"), \
             um.patch.object(self.c, "env", return_value={"S2A_RUN_ROOT": str(self.root / "run")}), self.assertRaises(Failure) as e:
            tvos.derive(self.c, G, ex)
        self.assertEqual(e.exception.code, "engine_incomplete")
        self.assertFalse([r for r in runs if "shell_build.sh" in " ".join(r)])

    def test_derive_needs_ios_first(self):
        with self.assertRaises(Failure) as e:
            tvos.derive(self.c, G, self.root / "extract")
        self.assertEqual(e.exception.code, "package_failed")


class PlatformTest(unittest.TestCase):
    """镜像包 Mach-O 平台（ios/macho_dylib.py：iOS 2、tvOS 3，tvOS 的 dyld 不加载标成 iOS 的库）与壳编号按平台分（pack/shell/manifest.py）。期望手写"""
    def test_dylib_platform(self):
        import struct, tempfile
        root = Path(__file__).resolve().parents[3]
        sys.path.insert(0, str(root / "ios")); import macho_dylib
        def build_version(**k):
            with tempfile.TemporaryDirectory() as t:
                p = Path(t) / "x.dylib"
                macho_dylib.write(p, "@rpath/x.dylib", text=[("__swcode", 14, macho_dylib.PURE_INSTRUCTIONS, [b"\x1f\x20\x03\xd5" * 4])], **k)
                d = p.read_bytes(); n, off = struct.unpack_from("<I", d, 16)[0], 32
                for _ in range(n):
                    cmd, size = struct.unpack_from("<II", d, off)
                    if cmd == 0x32: return struct.unpack_from("<III", d, off + 8)   # platform, minos, sdk
                    off += size
        self.assertEqual(build_version(), (2, 18 << 16, 18 << 16))
        self.assertEqual(build_version(minos=(26, 0), platform=3), (3, 26 << 16, 26 << 16))

    def test_shell_id_per_platform(self):
        root = Path(__file__).resolve().parents[3]
        sys.path.insert(0, str(root)); from pack.shell import manifest as m
        with um.patch.object(m, "inputs_key", return_value="K"), um.patch.dict("os.environ", {}, clear=False):
            import os; os.environ.pop("S2A_APPLE_OS", None)
            ios, tv = m.current_id(), m.current_id("tvos")
            os.environ["S2A_APPLE_OS"] = "tvos"; via_env = m.current_id(); os.environ.pop("S2A_APPLE_OS")
        _, _, chain, im, sdk = m._defaults("ios")
        self.assertEqual(ios, m.shell_id("K", chain, im, sdk))   # iOS 壳编号口径不变（不带前缀）
        self.assertNotEqual(ios, tv); self.assertEqual(tv, via_env)
        self.assertTrue(m._defaults("tvos")[3].startswith("tvos") and m._defaults("tvos")[4].startswith("tvos"))


if __name__ == "__main__":
    unittest.main()
