"""装机前清单按钮落点契约，用后端真实产生的清单核（11-19：Windows 证书项后端从来不带 action，落点测试却手造了一个后端产生不了的
id「devcert:install」去驱动，测试绿着、真实清单上没有按钮）。落点表唯一来源：launchers/shared/experience.v1.json 的 install_landing。
期望手写：每个场景都跑真实的 readiness_windows / readiness，每个没好、不在等前一步的项——
  ① 它的 id 在表里登记过（没登记 = 新清单项忘了定落点，红）；
  ② 表里是动作名：项上的 action 必须是其中之一；表里写 @url：项上带 https 的 url；表里 null：既不带 action 也不带 url（只能人做）；
  ③ 项上的 action 都在 install_landing.actions 动作表里。
另核 launchers/windows/launcher/UI.Snapshots/landing_items.json（Windows 落点探针的清单）逐项等于后端真实产生的清单：
  手造的项（如旧的 devcert:install）进不去。改了清单项先跑 S2A_REGEN_LANDING=1 python3 -m unittest test_landing_contract 重新生成。
负对照（手跑核过）：devcert_items 的 action="devCertSettings" 删掉 → W3 / M1 红；夹具里加一项 devcert:install → 夹具一致性红。"""
import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_install  # noqa: E402
import test_win_jobs  # noqa: E402
from test_win_jobs import FakeW  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
TABLE = json.loads((ROOT / "launchers/shared/experience.v1.json").read_text(encoding="utf-8"))["install_landing"]
FIXTURE = ROOT / "launchers/windows/launcher/UI.Snapshots/landing_items.json"
# Mac 清单里还没接落点的项（开发甲 fix/mac-appleid-login-ui 接：package / appleId / connected / trusted / developerMode）。那支合入时删掉这个集合
MAC_PENDING = {"package", "appleId", "connected", "trusted", "developerMode"}


def violations(items, platform, pending=frozenset()):
    table, bad = TABLE["items"][platform], []
    for i in items:
        if i["ok"] or i.get("waiting") or i["id"] in pending:
            continue
        iid, act, url = i["id"], i.get("action"), i.get("url")
        if iid not in table:
            bad.append(f"{iid}：落点表 install_landing.items.{platform} 没登记"); continue
        want = table[iid]
        opts = want.split("|") if want else []
        if act is not None and act not in TABLE["actions"]:
            bad.append(f"{iid}：action {act!r} 不在动作表")
        if not opts:
            if act is not None or url:
                bad.append(f"{iid}：只能人做、不该有按钮 → action {act!r} url {url!r}")
        elif act in opts:
            pass
        elif "@url" in opts and str(url or "").startswith("https://") and act is None:
            pass
        else:
            bad.append(f"{iid}：应为 {want} → action {act!r} url {url!r}")
    return bad


class Windows(unittest.TestCase):
    setUp = test_win_jobs.WinInstall.setUp   # 只借现成的造法（假 Windows 环境），不继承它的用例

    def real(self, w, pack_ok=True, cert=None):
        ps = [patch.object(self.m, "win_install_mod", return_value=w)]
        if not pack_ok:
            ps.append(patch.object(self.m, "ios_pack", side_effect=self.m.Failure("没做好")))
        if cert is not None:
            import devcert
            d = self.t / "devcert"; d.mkdir(exist_ok=True); (d / "cert.p12").write_bytes(b"p12")
            (d / "state.json").write_text(json.dumps(dict(active=True, certSha1="0" * 40, bundleId="io.s2arm.games.abcde12345", teamId="ABCDE12345", teamName="T")))
            ps.append(patch.object(devcert, "summary", lambda c, udid=None: dict(cert, udid=udid)))
        for p in ps:
            p.start()
        try:
            return self.m.readiness_windows(self.c, self.gid)["items"]
        finally:
            for p in reversed(ps):
                p.stop()

    def scenes(self):
        import impactor
        out = {}
        out["W1 没出包、Impactor 没随包、没连手机"] = self.real(FakeW([], impactor="missing"), pack_ok=False)
        res = self.t / "launcher"; d = res / impactor.BUNDLE_DIR; d.mkdir(parents=True, exist_ok=True)
        for n in impactor.BUNDLED: (d / n).write_bytes(b"x")
        self.c.r["resources"] = str(res)
        w = FakeW([("U1", "USB", 3)], impactor="missing"); w.logged = False
        out["W2 随包 Impactor 没登录"] = self.real(w)
        self.c.r.pop("resources", None)
        bad_cert = dict(blocking=[dict(text="证书已过期")], warnings=[], allDevices=False, deviceListed=False, teamName="T")
        out["W3 证书模式：证书有问题、设备不在描述文件里"] = self.real(FakeW([("U1", "USB", 3)]), cert=bad_cert)
        return out

    def test_real_checklists_follow_table(self):
        for name, items in self.scenes().items():
            with self.subTest(name):
                self.assertTrue(any(not i["ok"] for i in items), f"{name}：场景没造出没好的项")
                self.assertEqual(violations(items, "windows"), [])

    def test_probe_fixture_is_real_backend_output(self):
        got = {k: [{f: i.get(f) for f in ("id", "ok", "waiting", "who", "action", "url")} for i in v] for k, v in self.scenes().items()}
        if os.environ.get("S2A_REGEN_LANDING"):
            FIXTURE.write_text(json.dumps(got, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        self.assertEqual(json.loads(FIXTURE.read_text(encoding="utf-8")), got,
                         "Windows 落点探针的清单不是后端当前真实产生的（手造的项 / 后端改了没重新生成）：S2A_REGEN_LANDING=1 重新生成")


class Mac(unittest.TestCase):
    setUp = test_install.FlowTests.setUp   # 只借现成的造法（假设备 / 账号），不继承它的用例
    _fixture, _ready, _dev = test_install.FlowTests._fixture, test_install.FlowTests._ready, staticmethod(test_install.FlowTests.__dict__["_dev"].__func__)

    def test_devcert_items_follow_table(self):
        import devcert
        gid = "0100535012974000"; self._fixture(gid); self.c.r.update(gameId=gid, device="测试设备2")
        d = Path(self.c.private) / "devcert"; d.mkdir(parents=True, exist_ok=True); (d / "cert.p12").write_bytes(b"p12")
        (d / "state.json").write_text(json.dumps(dict(active=True, certSha1="0" * 40, bundleId="io.s2arm.games.abcde12345", teamId="ABCDE12345", teamName="T")))
        bad_cert = dict(blocking=[dict(text="证书已过期")], warnings=[], allDevices=False, deviceListed=False, teamName="T")
        with patch.object(devcert, "summary", lambda c, udid=None: dict(bad_cert, udid=udid)):
            r, it = self._ready([dict(self._dev(), hardwareProperties=dict(self._dev()["hardwareProperties"], udid="U1"))])
        self.assertIn("devcert", it); self.assertIn("devcertDevice", it)
        self.assertEqual(violations(r["items"], "mac", pending=MAC_PENDING), [])


if __name__ == "__main__":
    unittest.main()
