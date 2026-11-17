# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""0.6.0 电脑侧用 s2a-selfsign 签程序库（pack/jobs/program_pack.py selfsign_path / selfsign_signer，install.py win_selfsign_signer）。
s2a-selfsign 用替身脚本（记下参数、读到的证书字节），期望按参数手写；Windows 的 plumesign 身份用替身模块。"""
import json
import os
import stat
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


class SelfsignSigner(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp()); self.addCleanup(__import__("shutil").rmtree, self.t, True)
        self.c = types.SimpleNamespace(engine=self.t / "engine", private=self.t / "private", logs=self.t, task="t1")
        self.c.private.mkdir()
        self.tool = self.t / "fake-selfsign"
        self.tool.write_text("#!/usr/bin/env python3\nimport json,sys,os\nargs=sys.argv[1:]\n"
                             "cert=open(args[args.index('--cert')+1],'rb').read()\n"
                             "open(os.environ['SS_LOG'],'a').write(json.dumps(dict(args=args,cert=cert.hex()))+'\\n')\n"
                             "if os.environ.get('SS_FAIL'): sys.stderr.write('私钥和证书对不上\\n'); sys.exit(1)\n")
        self.tool.chmod(self.tool.stat().st_mode | stat.S_IEXEC)
        self.log = self.t / "calls.jsonl"; os.environ["SS_LOG"] = str(self.log); self.addCleanup(os.environ.pop, "SS_LOG", None)

    def calls(self):
        return [json.loads(l) for l in self.log.read_text().splitlines()] if self.log.is_file() else []

    def test_path_order(self):
        exe = "s2a-selfsign.exe" if os.name == "nt" else "s2a-selfsign"
        self.assertIsNone(program_pack.selfsign_path(self.c))
        built = self.c.engine / "build/selfsign/release" / exe; built.parent.mkdir(parents=True); built.write_text("x")
        self.assertEqual(program_pack.selfsign_path(self.c), str(built))
        shipped = self.c.engine / "Binaries/Prepare/selfsign" / exe; shipped.parent.mkdir(parents=True); shipped.write_text("x")
        self.assertEqual(program_pack.selfsign_path(self.c), str(shipped), "随包的优先于源码树编出的")
        with patch.dict(os.environ, S2A_SELFSIGN=str(self.tool)):
            self.assertEqual(program_pack.selfsign_path(self.c), str(self.tool), "S2A_SELFSIGN 最优先")

    def test_signer_args_and_failure(self):
        key = self.t / "key.pem"; key.write_text("k")
        run = program_pack.selfsign_signer(self.c, str(self.tool), key, b"\x30\x82CERT")
        run(self.t / "S2AImages-X.dylib", "TEAMFAKE01", "io.example.app")
        (call,) = self.calls()
        self.assertEqual(call["args"][:2], ["--key", str(key)])
        self.assertEqual(call["args"][4:], ["--bundle-id", "io.example.app", "--team", "TEAMFAKE01", str(self.t / "S2AImages-X.dylib")])
        self.assertEqual(call["cert"], b"\x30\x82CERT".hex(), "证书字节原样交给工具")
        self.assertEqual(list(self.c.private.iterdir()), [], "证书临时文件用完就删")
        with patch.dict(os.environ, SS_FAIL="1"), self.assertRaises(Failure) as e:
            run(self.t / "S2AImages-X.dylib", "TEAMFAKE01", "io.example.app")
        self.assertIn("私钥和证书对不上", str(e.exception))

    def win(self, fp="fp1", ident=True):
        key = self.t / "keys/TEAMFAKE01/key.pem"; key.parent.mkdir(parents=True, exist_ok=True); key.write_text("k")
        listed = []
        def plume_identity(exe, team, log=None):
            listed.append(team); return dict(key=b"K", cert=b"CERT-" + fp.encode(), created="2026-01-01", key_fp=fp) if ident else None
        return types.SimpleNamespace(plume_key_path=lambda team: key, key_fingerprint=lambda team: fp, plume_identity=plume_identity), listed

    def test_win_cert_cached_by_key(self):
        W, listed = self.win()
        with patch.dict(os.environ, S2A_SELFSIGN=str(self.tool)), patch.object(install, "trace", lambda *a, **k: None):
            for _ in range(2):
                install.win_selfsign_signer(self.c, W, "plumesign.exe", "TEAMFAKE01")(self.t / "a.dylib", "TEAMFAKE01", "io.example.app")
            self.assertEqual(listed, ["TEAMFAKE01"], "私钥没换：第二次不再联网列证书")
            self.assertEqual([c["cert"] for c in self.calls()], [b"CERT-fp1".hex()] * 2)
            W2, listed2 = self.win(fp="fp2")
            install.win_selfsign_signer(self.c, W2, "plumesign.exe", "TEAMFAKE01")(self.t / "a.dylib", "TEAMFAKE01", "io.example.app")
            self.assertEqual((listed2, self.calls()[-1]["cert"]), (["TEAMFAKE01"], b"CERT-fp2".hex()), "换了私钥：重新列、用新证书")

    def test_win_falls_back_when_missing(self):
        W, _ = self.win()
        with patch.object(install, "trace", lambda *a, **k: None):
            self.assertIsNone(install.win_selfsign_signer(self.c, W, "plumesign.exe", "TEAMFAKE01"), "源码树没编工具")
            with patch.dict(os.environ, S2A_SELFSIGN=str(self.tool)):
                W.plume_key_path = lambda team: self.t / "nokey.pem"
                self.assertIsNone(install.win_selfsign_signer(self.c, W, "plumesign.exe", "TEAMFAKE01"), "还没有这个团队的私钥")
                W3, _ = self.win(ident=False)
                self.assertIsNone(install.win_selfsign_signer(self.c, W3, "plumesign.exe", "TEAMFAKE01"), "列不出证书")


if __name__ == "__main__":
    unittest.main()
