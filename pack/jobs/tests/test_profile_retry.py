"""装机：本机描述文件签得出、手机仍拒（0xe8008015，11-17 #1447 / #1448）的处理（pack/jobs/install.py）。期望手写：
  ① 不知道这台手机的 UDID：不先用本机描述文件签，第一步就是申请（ensure_profile.sh），再签（0.5.1 的做法）
  ② 知道 UDID：先签；dev_sign 带 S2A_PROFILE_NEED_UDIDS = 这台、S2A_DEV_SIGN_PICKED = 记录文件
  ③ set_aside_profiles：记录文件里列的描述文件挪进 <产物根>/.stale_profiles/，没列的不动
  ④ sign_and_install：手机第一次报 0xe8008015 → 挪开用过的描述文件、按「先申请」重签一次、再装一次；第二次装成 → 不报错；
     第二次仍拒 → 照常报装不上（只重来一次）
"""
import json
from pathlib import Path
import shutil
import subprocess
import unittest
from unittest import mock

from jobcase import JobCase
import install

REJECT = "Failed to verify code signature of /var/installd/.../S2Arm.app : 0xe8008015 (A valid provisioning profile for this executable was not found.)"


class SignOrRequest(JobCase):
    def setUp(self):
        super().setUp()
        self.calls = []
        def run(args, log=None, env=None, ok_codes=(0,), **k):
            a = [str(x) for x in args]
            self.calls.append((Path(a[1]).name if len(a) > 1 else a[0], dict(env or {})))
            self.c.last_rc = 0
        self.c.run = run
        self.c.begin = lambda *a, **k: None

    def test_no_udid_requests_first(self):
        install._sign_or_request(self.c, ["py", "/e/pack/dev_sign.py", "app", "b", "T", "e"], "b", dict(id="T"), "e", "", Path("/l"), None, False)
        self.assertEqual([n for n, _ in self.calls], ["ensure_profile.sh", "dev_sign.py"])

    def test_udid_signs_first_with_need_and_picked(self):
        self.c.profile_picked = self.root / "picked.txt"
        install._sign_or_request(self.c, ["py", "/e/pack/dev_sign.py", "app", "b", "T", "e"], "b", dict(id="T"), "e", "U1", Path("/l"), None, False)
        self.assertEqual([n for n, _ in self.calls], ["dev_sign.py"])
        env = self.calls[0][1]
        self.assertEqual((env.get("S2A_PROFILE_NEED_UDIDS"), env.get("S2A_DEV_SIGN_PICKED")), ("U1", str(self.root / "picked.txt")))


class SetAside(JobCase):
    def test_moves_listed_only(self):
        pd = self.root / "profiles"; pd.mkdir()
        a, b = pd / "a.mobileprovision", pd / "b.mobileprovision"; a.write_text("A"); b.write_text("B")
        pk = self.root / "picked.txt"; pk.write_text(f"{a}\n{a}\n")
        roots = self.root / "roots"
        self.c.env = lambda: dict(S2A_ROOTS=str(roots))
        self.assertEqual(install.set_aside_profiles(self.c, pk), [str(a)])
        self.assertEqual(((roots / ".stale_profiles/a.mobileprovision").read_text(), a.exists(), b.exists()), ("A", False, True))


class RetryOnReject(JobCase):
    def setUp(self):
        super().setUp()
        work = self.root / "ipa"; (work / "Payload/S2Arm.app").mkdir(parents=True)
        (work / "Payload/S2Arm.app/Info.plist").write_bytes(__import__("plistlib").dumps({"CFBundleIdentifier": "x"}))
        self.ipa = self.root / "S2Arm.ipa"
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(work / "Payload"), str(self.ipa)], check=True)
        self.signs, self.installs = [], []
        prof = self.root / "used.mobileprovision"; prof.write_text("P"); self.prof = prof
        def sign(c, app, team, bid, ents, udid, log, steps, vision=False, widget=False):
            self.signs.append(bool(getattr(c, "profile_force_request", False)))
            Path(c.profile_picked).open("a").write(f"{prof}\n") if prof.exists() else None
        self.results = []
        def devicectl(c, *args, timeout=None):
            if args[:3] == ("device", "install", "app"):
                self.installs.append(1); return self.results.pop(0)
            return 0, {}, ""
        self.c.env = lambda: dict(S2A_ROOTS=str(self.root / "roots"))
        self.c.begin = lambda *a, **k: None
        for p in (mock.patch.object(install, "sign_with_apple_id", sign), mock.patch("diag.devicectl", devicectl), mock.patch("diag.is_vision", lambda dev: False),
                  mock.patch.object(install, "check_shell_sdk", lambda c, app, dev: None), mock.patch.object(install, "widget_prepare", lambda c, app, bid, devcert=False: False),
                  mock.patch.object(install, "container_display_name", lambda app: ""), mock.patch.object(install.devcert, "active", lambda c: False)):
            p.start(); self.addCleanup(p.stop)

    def go(self):
        install.sign_and_install(self.c, self.ipa, dict(id="T", name="T", free=True), dict(id="D1", name="iPhone"), "U1", "io.b", [], steps=False)

    def test_retry_once_then_ok(self):
        self.results = [(1, {}, REJECT), (0, {}, "")]
        self.go()
        self.assertEqual((self.signs, len(self.installs)), ([False, True], 2), "先照常签；被拒后按「先申请」重签一次、再装一次")
        self.assertFalse(self.prof.exists()); self.assertTrue((self.root / "roots/.stale_profiles/used.mobileprovision").is_file())
        self.assertFalse(getattr(self.c, "profile_force_request", False))

    def test_second_reject_reports(self):
        self.results = [(1, {}, REJECT), (1, {}, REJECT)]
        with self.assertRaises(install.Failure):
            self.go()
        self.assertEqual(len(self.installs), 2, "只重来一次")

    def test_other_install_error_no_retry(self):
        self.results = [(1, {}, "ERROR: device is locked")]
        with self.assertRaises(install.Failure):
            self.go()
        self.assertEqual((self.signs, len(self.installs)), ([False], 1))


if __name__ == "__main__":
    unittest.main()
