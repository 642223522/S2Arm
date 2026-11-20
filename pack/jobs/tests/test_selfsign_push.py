# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""别的工具（AltStore / SideStore …）装的 S2Arm 的电脑推送（11-19 自签走查结构 4，pack/jobs/install.py）。期望按场景手写：
  ① s2arm_owner：手机上装着什么 → 启动器的 / 别的工具的（包名） / 没装 / 列不出
  ② push_phone（Mac）：别的工具装的 → ExternalPhone（不要 Apple ID，包名 = 手机上那个）；启动器装的 → 照旧 mac_phone
  ③ push_game：别的工具装的手机不查壳号、不签名（phone_signing）、不顺带交身份（deliver_identity），程序包不签，设备记录记下 externalBundleId，
     结果带 installedBy: external；启动器装的手机照旧签名
  ④ push_programs 团队号为空：不调 program_pack.sign，清单团队号为空、其余字段按未签名包现算；push_program 记录里 team 为空（原先 cat["team"] KeyError）
反证：去掉 push_game 里的 ext 分路 → ③ 红（phone_signing 被调用 / 报 shell_install_required）；push_programs 不分 team → ④ 红（sign 被调用）"""
import contextlib
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install  # noqa: E402
import program_pack  # noqa: E402
from core import Failure  # noqa: E402

GID = "0100000000010000"
ALT = "io.s2arm.games.example01"


def owner(rows, rec):
    with tempfile.TemporaryDirectory() as d:
        c = types.SimpleNamespace(private=d)
        cl = types.SimpleNamespace(apps=lambda: rows, get=lambda rel, dst: False)   # 手机上读不到签名身份文件（多份时择优用）
        with patch.object(install, "devpush_client", lambda c, udid, bid, w: cl), patch.object(install, "main_executable", lambda c: "S2Arm"), \
                patch.object(install, "trace", lambda *a, **k: None):
            return install.s2arm_owner(c, "UDID1", rec)


class Owner(unittest.TestCase):
    def test_owner(self):
        launcher = dict(shellId="S1", bundleId="io.s2arm.games.team1")
        self.assertEqual(owner(None, launcher), (None, None), "列不出")
        self.assertEqual(owner([("com.other.app", "Other", "T")], launcher), ("none", None), "一个 S2Arm 都没装")
        self.assertEqual(owner([("io.s2arm.games.team1", "S2Arm", "TEAM1")], launcher), ("launcher", "io.s2arm.games.team1"))
        self.assertEqual(owner([(ALT, "S2Arm", "TEAMALT")], {}), ("external", ALT), "没有设备记录：AltStore 装的")
        self.assertEqual(owner([(ALT, "S2Arm", "TEAMALT")], launcher), ("external", ALT), "启动器装过、手机上只剩 AltStore 那份")
        self.assertEqual(owner([("io.s2arm.games.team1", "S2Arm", "TEAM1")], dict(bundleId="io.s2arm.games.team1")), ("external", "io.s2arm.games.team1"),
                         "设备记录没有壳号（启动器没装过）：同名包也算别的工具装的")
        self.assertEqual(owner([("io.s2arm.games.b", "S2Arm", None), ("com.esign.x", "S2Arm", None)], {}), ("external", "com.esign.x"), "多份取包名排序第一个")


class PickExternal(unittest.TestCase):
    """维护者评审：别的工具装的 S2Arm 不止一份时，优先已导入签名身份的、其中团队对得上的再优先；都没有才按包名排序第一个"""
    def pick(self, apps, metas):
        with patch.object(install, "phone_identity_meta", lambda c, u, b: metas.get(b)), patch.object(install, "trace", lambda *a, **k: None):
            return install.pick_external(types.SimpleNamespace(), "UDID1", [dict(bundleId=b, team=t) for b, t in apps])

    def test_pick(self):
        apps = [("io.s2arm.games.a", "TA"), ("io.s2arm.games.b", "TB"), ("io.s2arm.games.c", "TC")]
        self.assertEqual(self.pick(apps, {}), "io.s2arm.games.a", "都没身份：包名排序第一个")
        self.assertEqual(self.pick(apps, {"io.s2arm.games.c": dict(team="TC")}), "io.s2arm.games.c", "只有一份导入了身份")
        self.assertEqual(self.pick(apps, {"io.s2arm.games.a": dict(team="XX"), "io.s2arm.games.b": dict(team="TB")}), "io.s2arm.games.b",
                         "两份有身份：团队对得上的优先")
        self.assertEqual(self.pick([("io.s2arm.games.z", "TZ")], {}), "io.s2arm.games.z", "只有一份：不读手机文件直接用")


class PushPhoneMac(unittest.TestCase):
    def phone(self, who):
        dev = dict(id="DEV1", name="备用手机", productType="iPhone17,1")
        def no_account(*a, **k):
            raise Failure(install.APPLE_SIGN_IN, code="apple_not_signed_in")
        with patch.object(install.os, "name", "posix"), patch.object(install, "phone", lambda c: dev), \
                patch.object(install, "udid_of", lambda c, d: "UDID1"), patch.object(install.layout, "load_device", lambda c, k: {}), \
                patch.object(install, "s2arm_owner", lambda c, u, r: who), patch.object(install, "mac_phone", no_account):
            return install.push_phone(types.SimpleNamespace(r={}))

    def test_external_needs_no_apple_id(self):
        ph = self.phone(("external", ALT))
        self.assertIsInstance(ph, install.ExternalPhone)
        self.assertEqual((ph.bid, ph.key, ph.external, ph.info["deviceName"]), (ALT, "UDID1", True, "备用手机"))

    def test_launcher_goes_old_way(self):
        with self.assertRaises(Failure) as e:
            self.phone(("launcher", "io.s2arm.games.team1"))
        self.assertEqual(e.exception.code, "apple_not_signed_in", "启动器装的照旧 mac_phone（要账号）")


class PushGameRoute(unittest.TestCase):
    def run_push(self, external, rec, meta=None, app_team="TEAMALT"):
        """meta：手机上 App 导入的签名身份（current.json 内容；None = 没导入）；app_team：手机上这个包的签名团队（installed_s2arm 读到的）"""
        store = {"UDID1": dict(rec)}
        calls = dict(sign=0, identity=0, team=[])
        ph = types.SimpleNamespace(key="UDID1", udid="UDID1", bid=ALT if external else "io.s2arm.games.team1", info=dict(device="d"), pending=None,
                                   pull_kept=lambda g: 0, before_push=lambda packs: None, push=lambda g, p: (3, 30), client=lambda w: object())
        if external:
            ph.external = True
        def signing(c, ph_):
            calls["sign"] += 1; return "TEAM1", ph_.bid, object()
        def programs(c, cl, games, rec_, team, bundle, signer):
            calls["team"].append(team); return {GID: dict(sha="s", team=team, dir="v-s-s2arm")}
        lock = lambda c, g: contextlib.nullcontext()
        c = types.SimpleNamespace(r={}, private=tempfile.gettempdir(), begin=lambda *a, **k: None)
        import ipa as packer
        import rewrite_refresh
        import sgrade_bf
        with patch.object(install, "ios_pack", lambda c, g: "/pack"), patch.object(install.layout, "load_device", lambda c, k: dict(store.get(k, {}))), \
                patch.object(install.layout, "save_device", lambda c, k, r: store.__setitem__(k, r)), patch.object(packer, "current_shell_id", lambda c: "SNOW"), \
                patch.object(packer, "program_locks", lock), patch.object(install, "snapshot_phone_saves", lambda c, ph, g: {}), \
                patch.object(install, "phone_signing", signing), patch.object(install, "push_programs", programs), \
                patch.object(install, "deliver_identity", lambda c, ph: calls.__setitem__("identity", calls["identity"] + 1)), \
                patch.object(rewrite_refresh, "refresh_ios", lambda c, g: None), patch.object(sgrade_bf, "rechain_ios", lambda c, g: "skip"), \
                patch.object(install, "push_mods", lambda c, ph, g, m: m), patch.object(install, "pack_id", lambda p: "P1"), \
                patch.object(install, "pull_shader_counts", lambda c, ph, g: None), patch.object(install, "await_import", lambda c, ph, g, w: None), \
                patch.object(install, "phone_identity_meta", lambda c, u, b: meta), \
                patch.object(install, "installed_s2arm", lambda c, ph_: [dict(bundleId=ALT, team=app_team)]):
            out = install.push_game(c, GID, ph, steps=False)
        return out, calls, store["UDID1"]

    def test_external_no_signing_no_identity(self):
        out, calls, rec = self.run_push(True, {}, meta=dict(cert_sha1="ab", team="TEAMALT"))
        self.assertEqual((calls["sign"], calls["identity"], calls["team"]), (0, 0, [None]), "不签名、不交身份、程序包团队号为空")
        self.assertEqual((out["installedBy"], out["bundleId"], rec["externalBundleId"], rec["games"][GID]["program"]["team"]), ("external", ALT, ALT, None))
        self.assertNotIn("unpackPending", out, "手机上有对得上的签名身份：照常报装好")
        self.assertNotIn("phoneIdentity", out)

    def test_external_without_phone_identity_not_reported_done(self):
        """维护者评审：导入不签名、起局才签——手机上的 S2Arm 还没导入签名证书，推完不报「装好了」"""
        out, _, _ = self.run_push(True, {}, meta=None)
        self.assertEqual((out["phoneIdentity"], out["unpackPending"]), ("phone_identity_missing", install.EXTERNAL_NO_IDENTITY))

    def test_external_identity_team_mismatch(self):
        out, _, _ = self.run_push(True, {}, meta=dict(cert_sha1="ab", team="OTHERTEAM"))
        self.assertEqual(out["phoneIdentity"], "phone_identity_team_mismatch")
        self.assertEqual(out["unpackPending"], install.EXTERNAL_IDENTITY_TEAM.format("OTHERTEAM", "TEAMALT"))
        out2, _, _ = self.run_push(True, {}, meta=dict(cert_sha1="ab", team="OTHERTEAM"), app_team=None)
        self.assertNotIn("phoneIdentity", out2, "读不到 App 的团队：不凭空判对不上")

    def test_launcher_still_signs(self):
        out, calls, rec = self.run_push(False, dict(shellId="SNOW", bundleId="io.s2arm.games.team1"))
        self.assertEqual((calls["sign"], calls["identity"], calls["team"]), (1, 1, ["TEAM1"]))
        self.assertNotIn("installedBy", out); self.assertNotIn("externalBundleId", rec)

    def test_launcher_without_shell_asks_install(self):
        with self.assertRaises(Failure) as e:
            self.run_push(False, {})
        self.assertEqual(e.exception.code, "shell_install_required", "不是别的工具装的、也没装过：照旧报先装 S2Arm")


class UnsignedPrograms(unittest.TestCase):
    def test_team_none_builds_unsigned(self):
        with tempfile.TemporaryDirectory() as d:
            pkg = Path(d) / "package"; pkg.mkdir()
            (pkg / program_pack.META).write_text(json.dumps(dict(name="游戏", display_version="1.0", host_abi=2, chain="CH", rewriter_id="RID")), encoding="utf-8")
            (pkg / program_pack.image_name(GID)).write_bytes(b"dylib-adhoc")
            got = {}
            def no_sign(*a, **k):
                raise AssertionError("团队号为空不签")
            def fake_push(cl, g, p, inbox, custom=None, cat=None):
                got["cat"] = cat; return dict(team=cat.get("team"))
            import ipa as packer
            with patch.object(program_pack, "sign", no_sign), patch.object(program_pack, "build", lambda c, g: str(pkg)), \
                    patch.object(packer, "container_custom", lambda c: {}), patch.object(install, "import_inbox", lambda cl, docs="Documents": "Documents/inbox"), \
                    patch.object(install, "push_program", fake_push), patch.object(install, "note", lambda *a, **k: None):
                out = install.push_programs(types.SimpleNamespace(r={}), object(), [GID], {}, None, ALT, None)
            cat = got["cat"]
            self.assertEqual((cat["team"], cat["title_id"], cat["host_abi"], cat["chain"], cat["image"]), (None, GID, 2, "CH", program_pack.image_name(GID)))
            self.assertEqual(out[GID]["team"], None)

    def test_push_program_without_team_key(self):
        """未签名清单没有 team 键也不 KeyError（原先 cat["team"]）"""
        with tempfile.TemporaryDirectory() as d:
            pkg = Path(d) / "package"; pkg.mkdir()
            (pkg / "S2AImages-x.dylib").write_bytes(b"x")
            cat = dict(image_sha256="ab" * 32, host_abi=2, chain="CH", rewriter_id="RID", image="S2AImages-x.dylib", name="n")
            sent = []
            cl = types.SimpleNamespace(head=lambda dest, n: None, put=lambda src, dest: sent.append(dest))
            import programs
            with patch.object(programs, "zstd_writer", lambda out, checksum=True: open(out, "wb")):
                r = install.push_program(cl, GID, pkg, "Documents/inbox", cat=cat)
            self.assertEqual((r["team"], sent), (None, [f"Documents/inbox/{GID}.s2arm"]))


if __name__ == "__main__":
    unittest.main()
