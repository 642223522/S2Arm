# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""0.6.0 通用壳 Mac 的 Apple ID（方案 A，pack/jobs/apple_login.py + install.mac_plume / PlumeMacPhone / signerSwitched）。
plumesign 用一个 Python 小脚本替身：照同版 v2.7.2 account.rs login 的交互（stdin 读密码 → 提示「Enter 2FA code:」→ stdin 读验证码 → 写账号存档 →
「Successfully logged in」），把自己收到的命令行与环境记进文件，测试据此核「密码只走标准输入」。账号、团队号、密码都是假的；期望由写进去的值直接得出。"""
import json
import os
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch

JOBS = Path(__file__).resolve().parents[1]
ROOT = JOBS.parents[1]
sys.path.insert(0, str(JOBS))
sys.path.insert(0, str(JOBS / "tests"))
import apple_login  # noqa: E402
import install  # noqa: E402
import jobcase  # noqa: E402
from core import Failure  # noqa: E402

PASSWORD = "Pw-Unit-7f3a9c"   # 测试密码：不许出现在日志、作业记录、子进程参数 / 环境里
ACCOUNT = "player@example.com"
TEAM = "FAKE" + "TEAMAB"   # 拆开写：公开仓扫描把「TEAM = 十位字母数字」当真团队号

FAKE = textwrap.dedent('''\
    import json, os, sys
    rec = os.environ["FAKE_PLUME_RECORD"]
    json.dump(dict(argv=sys.argv[1:], env=dict(os.environ)), open(rec, "w"))
    mode = os.environ.get("FAKE_PLUME_MODE", "ok")
    if sys.argv[1:3] != ["account", "login"]:
        sys.exit(2)
    sys.stdout.write("Enter password: "); sys.stdout.flush()
    pw = sys.stdin.readline().strip()
    open(rec + ".stdin", "w").write(pw + "\\n")
    if mode == "echo":
        print("Enter password: " + pw)   # 回显密码（终端交互登录时 plumesign 会显示）：作业层要抹掉
        print("Error: Authentication failed: -20101 Your Apple ID or password was entered incorrectly."); sys.exit(1)
    if mode == "badpw":
        print("Error: Authentication failed: -20101 Your Apple ID or password was entered incorrectly."); sys.exit(1)
    print("Logging in...")
    print("[INFO plumesign::commands::account] Enter 2FA code: ", flush=True)
    code = sys.stdin.readline().strip()
    open(rec + ".stdin", "a").write(code + "\\n")
    if mode == "badcode":
        print("Error: -21669 Incorrect verification code"); sys.exit(1)
    home = os.path.join(os.environ["XDG_CONFIG_HOME"], "PlumeImpactor"); os.makedirs(home, exist_ok=True)
    user = sys.argv[sys.argv.index("-u") + 1]
    json.dump(dict(selected_account=user, accounts={user: dict(email=user, first_name="Tester", adsid="x", xcode_gs_token="y", team_id=os.environ["FAKE_PLUME_TEAM"])}),
              open(os.path.join(home, "accounts.json"), "w"))
    print("[INFO plumesign::commands::account] Successfully logged in and account saved.")
''')


@unittest.skipIf(os.name == "nt", "Mac 通用壳专用")
class AppleLogin(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp(prefix="s2arm-login ")); self.addCleanup(__import__("shutil").rmtree, self.t, True)
        fake = self.t / "plumesign"
        fake.write_text(f"#!{sys.executable}\n" + FAKE, encoding="utf-8"); fake.chmod(0o755)
        self.rec = self.t / "record.json"
        env = patch.dict(os.environ, {"S2A_UNIVERSAL_SHELL": "1", "S2A_PLUMESIGN": str(fake), "FAKE_PLUME_RECORD": str(self.rec), "FAKE_PLUME_TEAM": TEAM})
        env.start(); self.addCleanup(env.stop)
        os.environ.pop("S2A_PLUME_HOME", None)
        (self.t / "logs").mkdir(); (self.t / "private").mkdir()
        self.keys = []
        self.c = jobcase.fake_context(self.t, r=dict(account=ACCOUNT), engine=ROOT, task="login1", apple_password=PASSWORD)
        self.c.begin = lambda stage, number=1, count=1, key=None, keychain=False: self.keys.append(key)

    def code(self, digits="123456"):
        d = self.t / "private/login"; d.mkdir(parents=True, exist_ok=True)
        (d / "login1.code").write_text(digits, encoding="utf-8")   # 界面填好的验证码（作业问到时读、读完删）

    def test_login_password_only_on_stdin(self):
        self.code()
        got = apple_login.login(self.c)
        self.assertEqual(got, dict(account=ACCOUNT, team=TEAM, teamName="Tester", enabled=True))
        self.assertEqual(self.keys, ["appleLogin", "appleLogin.needCode", "appleLogin"])
        self.assertIn(("progress", ""), self.c.events)
        seen = json.loads(self.rec.read_text())
        self.assertEqual(seen["argv"], ["account", "login", "-u", ACCOUNT])
        self.assertEqual(Path(str(self.rec) + ".stdin").read_text(), PASSWORD + "\n123456\n")   # 密码与验证码都从标准输入进
        self.assertEqual(seen["env"]["XDG_CONFIG_HOME"], str(self.t / "private/plumesign"))   # 账号存档落私有目录
        self.assertNotIn(PASSWORD, json.dumps(seen["env"]))
        self.assertNotIn(PASSWORD, json.dumps(self.c.r))
        for f in self.t.rglob("*"):
            if f.is_file() and not f.name.endswith(".stdin"):
                self.assertNotIn(PASSWORD, f.read_text(encoding="utf-8", errors="replace"), f)
        self.assertFalse((self.t / "private/login/login1.code").exists())   # 验证码读完即删
        self.assertIsNone(self.c.apple_password)
        self.assertEqual(apple_login.account(self.c), dict(account=ACCOUNT, team=TEAM, teamName="Tester", enabled=True))

    def test_wrong_password_and_code(self):
        for mode, want in (("badpw", "apple_id_wrong"), ("badcode", "two_factor_wrong")):
            with self.subTest(mode=mode), patch.dict(os.environ, {"FAKE_PLUME_MODE": mode}):
                self.c.apple_password = PASSWORD; self.code()
                with self.assertRaises(Failure) as e:
                    apple_login.login(self.c)
                self.assertEqual(e.exception.code, want)
                self.assertNotIn(PASSWORD, str(e.exception) + e.exception.internal)

    def test_echoed_password_scrubbed(self):
        with patch.dict(os.environ, {"FAKE_PLUME_MODE": "echo"}):
            with self.assertRaises(Failure) as e:
                apple_login.login(self.c)
        self.assertEqual(e.exception.code, "apple_id_wrong")
        log = (self.t / "logs/login1-login.log").read_text(encoding="utf-8")
        self.assertIn("Enter password: ***", log)
        self.assertNotIn(PASSWORD, log + str(e.exception) + e.exception.internal)

    def test_switch_off_touches_nothing(self):
        with patch.dict(os.environ, {"S2A_UNIVERSAL_SHELL": "0"}):
            self.assertEqual(apple_login.login(self.c), dict(enabled=False))
            self.assertEqual(apple_login.account(self.c), dict(enabled=False, account=None))
        self.assertFalse(self.rec.exists())
        self.assertFalse((self.t / "private/plumesign").exists())

    def test_not_signed_in(self):
        self.assertEqual(apple_login.account(self.c), dict(account=None, team=None, teamName="", enabled=True))
        with patch.object(install, "phone", lambda c: dict(id="dev", name="iPhone")), patch.object(install, "udid_of", lambda c, d: "UDID-1"):
            with self.assertRaises(Failure) as e:
                install.phone_for(self.c)
        self.assertEqual(e.exception.code, "apple_not_signed_in")


class SignerSwitched(unittest.TestCase):
    """换签名方式后第一次装才带 signerSwitched：老记录没 signer 字段时按当时只有的签法推"""

    def test_last_signer(self):
        self.assertIsNone(install.last_signer({}))
        self.assertEqual(install.last_signer(dict(signer="plumesign", bundleId="b")), "plumesign")
        self.assertEqual(install.last_signer(dict(bundleId="b", signed=dict(mode="devCert"))), "devCert")
        self.assertEqual(install.last_signer(dict(bundleId="b", signed=dict(mode="appleId"))), "plumesign" if os.name == "nt" else "xcode")


@unittest.skipIf(os.name == "nt", "Mac 打包")
class BundlePlumesign(unittest.TestCase):
    def test_hash_pinned(self):
        # 随包的是自编修改版：只从缓存取（不再下载），缓存缺 / 哈希不符都拒打；补丁原文与「修改版」说明随包
        sys.path.insert(0, str(ROOT / "launchers/macos"))
        import build_app
        import impactor
        import hashlib
        t = Path(tempfile.mkdtemp()); self.addCleanup(__import__("shutil").rmtree, t, True)
        with self.assertRaises(SystemExit) as e:
            build_app.bundle_plumesign(t / "res0", cache=t / "empty")
        self.assertIn("plumesign_build.py", str(e.exception))
        (t / "cache").mkdir(); (t / "cache/plumesign-macos-universal").write_bytes(b"not it")
        with patch.object(impactor, "BUNDLED_MAC", {"plumesign-macos-universal": "00" * 32}):
            with self.assertRaises(SystemExit) as e:
                build_app.bundle_plumesign(t / "res", cache=t / "cache")
            self.assertIn("拒打", str(e.exception))
        body = b"fake plumesign"
        (t / "cache/plumesign-macos-universal").write_bytes(body)
        with patch.object(impactor, "BUNDLED_MAC", {"plumesign-macos-universal": hashlib.sha256(body).hexdigest()}):
            build_app.bundle_plumesign(t / "res2", cache=t / "cache")
        d = t / "res2" / impactor.BUNDLE_DIR
        out = d / "plumesign-macos-universal"
        self.assertEqual(out.read_bytes(), body)
        self.assertTrue(os.access(out, os.X_OK))
        self.assertEqual(impactor.bundled(str(t / "res2")), {"plumesign": str(out)})
        self.assertTrue((d / "0001-anisette-v3-server.patch").is_file())
        self.assertIn("修改版", (d / "README-来源与许可.txt").read_text(encoding="utf-8"))

    def test_pinned_mac_hash_is_own_build(self):
        import impactor
        self.assertEqual(impactor.BUNDLED_MAC, {"plumesign-macos-universal": "d3ca590e1e92a1e7416f1c27c1ec6749c4ad05389c9c8724faaa53bbf63ce511"})


if __name__ == "__main__":
    unittest.main()
