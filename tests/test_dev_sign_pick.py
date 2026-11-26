"""pack/dev_sign.py 挑描述文件（11-17 #1447 / #1448：0.5.2 先用本机已有的描述文件签，签得出来、手机报 0xe8008015）。
夹具是真实开发描述文件的字段（AppIDName / ApplicationIdentifierPrefix / Platform / DeveloperCertificates / Entitlements / ExpirationDate /
Name / ProvisionedDevices / TeamIdentifier / TimeToLive / UUID），假 security（cms -D 原样吐 plist、find-identity 列身份）+ 假 codesign。
期望手写：同包名几份描述文件里，逐项（没过期、平台、含这台、本机有身份、权限都允许）全过的取到期最晚的；
  ① 到期最晚的那份不含这台、另一份含 → 用另一份（原先只核最晚那份 → 退 3 也罢，更糟的是不给设备号时直接用它）
  ② 到期最晚的已过期之外、只剩一份没过期的 → 用它
  ③ 到期最晚的不允许「提高内存上限」→ 用允许的那份
  ④ 到期最晚的证书本机没有 → 用有证书的那份
  ⑤ 一份都不全过 → 退 3，原因里点名每份为什么不行
  ⑥ S2A_DEV_SIGN_PICKED 给了 → 把用的那份路径记进去
  ⑦ tvOS 的描述文件不拿来签 iPhone 包
"""
import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
TEAM, BID, UDID = "TEAM-T1", "io.example.games.t1", "PHONE-THIS"
IML = "com.apple.developer.kernel.increased-memory-limit"
CERT_A, CERT_B = b"cert-A-der", b"cert-B-der"
SHA_A, SHA_B = (hashlib.sha1(x).hexdigest().upper() for x in (CERT_A, CERT_B))


def profile(name, *, days=6, devices=(UDID,), cert=CERT_A, iml=True, platform=("iOS", "xrOS", "visionOS")):
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None, microsecond=0)
    ents = {"application-identifier": f"{TEAM}.{BID}", "com.apple.developer.team-identifier": TEAM, "get-task-allow": True,
            "keychain-access-groups": [f"{TEAM}.*"]}
    if iml:
        ents[IML] = True
    return dict(AppIDName="XC io s2arm games", ApplicationIdentifierPrefix=[TEAM], CreationDate=now - datetime.timedelta(days=1), Platform=list(platform),
                IsXcodeManaged=True, DeveloperCertificates=[cert], Entitlements=ents, ExpirationDate=now + datetime.timedelta(days=days),
                Name=f"iOS Team Provisioning Profile: {BID}", ProvisionedDevices=list(devices), TeamIdentifier=[TEAM], TeamName="Player",
                TimeToLive=7, UUID=name, Version=1)


class DevSignPick(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory(); self.t = Path(self.td.name)
        self.pd = self.t / "home/Library/MobileDevice/Provisioning Profiles"; self.pd.mkdir(parents=True)
        self.app = self.t / "S2Arm.app"; self.app.mkdir()
        (self.app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": BID, "CFBundleSupportedPlatforms": ["iPhoneOS"]}))
        self.ents = self.t / "app.entitlements"; self.ents.write_bytes(plistlib.dumps({IML: True}))
        b = self.t / "bin"; b.mkdir()
        self.idents = [SHA_A]
        (b / "security").write_text('#!/bin/bash\n[ "$1 $2 $3" = "cms -D -i" ] && exec cat "$4"\n'
                                    '[ "$1" = find-identity ] && { cat "$IDS"; exit 0; }\nexit 1\n'); (b / "security").chmod(0o755)
        (b / "codesign").write_text('#!/bin/bash\n[ "$1" = -d ] && { echo "<plist><dict><key>' + IML + '</key><true/></dict></plist>"; exit 0; }\nexit 0\n')
        (b / "codesign").chmod(0o755)
        self.bin = b

    def tearDown(self): self.td.cleanup()

    def put(self, name, **kw):
        (self.pd / f"{name}.mobileprovision").write_bytes(plistlib.dumps(profile(name, **kw)))

    def run_sign(self, need=UDID, picked=None):
        ids = self.t / "ids.txt"
        ids.write_text("".join(f'  {i + 1}) {h} "Apple Development: Player ({TEAM})"\n' for i, h in enumerate(self.idents)) + f"     {len(self.idents)} valid identities found\n")
        env = dict(os.environ, HOME=str(self.t / "home"), PATH=f"{self.bin}:{os.environ['PATH']}", IDS=str(ids), S2A_PROFILE_NEED_UDIDS=need)
        env.pop("S2A_SIGN_PLATFORM", None)
        if picked:
            env["S2A_DEV_SIGN_PICKED"] = str(picked)
        return subprocess.run([sys.executable, str(REPO / "pack/dev_sign.py"), str(self.app), BID, TEAM, str(self.ents)], env=env, capture_output=True, text=True)

    def used(self, r):
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        line = [l for l in r.stdout.splitlines() if l.startswith("开发签名：")][-1]
        return line.split("：", 1)[1].split(".mobileprovision")[0]

    def test_newest_without_this_phone_is_skipped(self):
        self.put("old-has-phone", days=3); self.put("new-other-phone", days=6, devices=("PHONE-OTHER",))
        self.assertEqual(self.used(self.run_sign()), "old-has-phone")

    def test_expired_is_skipped(self):
        self.put("expired", days=-1); self.put("almost", days=0); self.put("good", days=2)
        self.assertEqual(self.used(self.run_sign()), "good")

    def test_missing_entitlement_is_skipped(self):
        self.put("new-no-iml", days=6, iml=False); self.put("older-iml", days=3)
        self.assertEqual(self.used(self.run_sign()), "older-iml")

    def test_cert_not_in_keychain_is_skipped(self):
        self.put("new-other-cert", days=6, cert=CERT_B); self.put("older-my-cert", days=3)
        self.assertEqual(self.used(self.run_sign()), "older-my-cert")

    def test_none_usable_exits_3_with_reasons(self):
        self.put("p1", days=6, devices=("PHONE-OTHER",)); self.put("p2", days=-2); self.put("p3", days=5, iml=False)
        r = self.run_sign()
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        for want in ("p1.mobileprovision 不含测试设备", "p2.mobileprovision 已过期", "p3.mobileprovision 不允许权限"):
            self.assertIn(want, r.stdout)

    def test_records_picked_profile(self):
        self.put("only", days=4)
        pk = self.t / "picked.txt"
        self.used(self.run_sign(picked=pk))
        self.assertEqual(pk.read_text().splitlines(), [str(self.pd / "only.mobileprovision")])

    def test_tvos_profile_not_used_for_iphone(self):
        self.put("tv", days=6, platform=("tvOS",)); self.put("phone", days=2)
        self.assertEqual(self.used(self.run_sign()), "phone")


if __name__ == "__main__":
    unittest.main()
