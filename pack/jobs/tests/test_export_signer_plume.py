# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""导出 .s2arm 签程序包的团队与签名器（install.export_signer）：Mac 通用壳 Apple ID（mac_plume）要和装 App / 推游戏同一个 plumesign 账号，
不能取 Xcode 钥匙串里的团队。团队号、包名、签名器都是替身，期望直接写出来"""
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))
import install  # noqa: E402
import program_pack  # noqa: E402
from core import Failure  # noqa: E402


class ExportSignerMacPlume(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.c = types.SimpleNamespace(r={}, env=lambda: {}, private=Path(self.tmp.name))
        self.W = types.SimpleNamespace(impactor=types.SimpleNamespace(selected_team=lambda: "TEAMPLUME", bundled=lambda r: {"plumesign": "p"}),
                                       plumesign_path=lambda given=None: "/x/plumesign")
        self.selfsign = object()

    def run_signer(self, plume, team="TEAMPLUME"):
        self.W.impactor.selected_team = lambda: team
        with patch.object(install.os, "name", "posix"), patch.object(install, "mac_plume", lambda c: plume), patch.object(install, "plume_home", lambda c: None), \
                patch.object(install, "win_install_mod", lambda c: self.W), patch.object(install, "win_cert_gate", lambda c, W, exe: None), \
                patch.object(install, "win_selfsign_signer", lambda c, W, exe, t: self.selfsign), \
                patch.object(install, "xcode_teams", lambda env: [dict(id="TEAMXCODE", name="Xcode 付费", free=False)]):
            return install.export_signer(self.c, "appleId")

    def test_mac_plume_uses_plumesign_account(self):
        team, bundle, signer, who = self.run_signer(True)
        self.assertEqual((team, bundle, who), ("TEAMPLUME", "io.s2arm.games.teamplume", "TEAMPLUME"))
        self.assertIs(signer, self.selfsign, "同推游戏：s2a-selfsign 用 plumesign 的私钥签")

    def test_mac_plume_not_signed_in(self):
        with self.assertRaises(Failure) as e:
            self.run_signer(True, team=None)
        self.assertEqual(e.exception.code, "apple_not_signed_in")

if __name__ == "__main__":
    unittest.main()
