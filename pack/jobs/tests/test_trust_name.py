# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""装机完成页「信任开发者」要点的名字（pack/jobs/install.py profile_trust_name）：签好的 App 里描述文件第一张证书的 CN。
证书用 openssl 现生成（CN 手写已知），只把 security cms 解描述文件那一步替成直接给 plist；期望手写。"""
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install  # noqa: E402

CN = "Apple Development: tester@example.com (ABCDE12345)"


@unittest.skipUnless(Path("/usr/bin/openssl").exists() and sys.platform == "darwin", "要 macOS 自带的 security / openssl")
class TrustNameTest(unittest.TestCase):
    def cert(self):
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", d]))
        key, der = os.path.join(d, "k.pem"), os.path.join(d, "c.der")
        subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-outform", "DER", "-out", der,
                        "-days", "1", "-subj", "/CN=" + CN + "/OU=ABCDE12345"], check=True, capture_output=True)
        return Path(der).read_bytes()

    def run_with(self, plist_bytes, rc=0):
        real = subprocess.run
        def fake(cmd, *a, **k):
            if cmd[0] == "security":
                return subprocess.CompletedProcess(cmd, rc, plist_bytes, b"")
            return real(cmd, *a, **k)
        with mock.patch.object(install.subprocess, "run", fake):
            return install.profile_trust_name("/nonexistent/embedded.mobileprovision")

    def test_first_certificate_common_name(self):
        self.assertEqual(self.run_with(plistlib.dumps({"DeveloperCertificates": [self.cert()], "TeamName": "Tester"})), CN)

    def test_unreadable_gives_empty(self):
        self.assertEqual(self.run_with(b"", rc=1), "", "解不开描述文件：界面退回不带名字的说法")
        self.assertEqual(self.run_with(plistlib.dumps({"TeamName": "x"})), "", "没有证书")
        self.assertEqual(self.run_with(plistlib.dumps({"DeveloperCertificates": [b"not a cert"]})), "", "证书坏了")


if __name__ == "__main__":
    unittest.main()
