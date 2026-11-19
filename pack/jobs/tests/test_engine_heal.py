# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""#304：已装的内置引擎副本被外部改过（玩家机上宿主 S2ArmGame.app 的 Info.plist 大小和清单对不上，出包一直报 runtime_invalid）→
用前复核、对不上就从 App 包重解；App 包本身坏了才让玩家重装。期望按规则手写，夹具是合成的引擎包（同发布快照，不带 .git）。"""
import hashlib
import json
import os
import subprocess
from pathlib import Path

from jobcase import JobCase

import embedded
from core import Context, Failure

PLIST = "Binaries/S2ArmGame.app/Contents/Info.plist"
EXE = "Binaries/S2ArmGame.app/Contents/MacOS/s2arm-host"


class EngineHealTests(JobCase):
    def setUp(self):
        super().setUp()
        self.bundle = self.root / "App.app/Contents/Resources/Engine"
        source = [(rel, b"") for rel in ("runtime/include/s2a_native.h", "runtime/rewriter/rewriter.c", "services/nxaot.sh", "pack/nx_unpack/nx_unpack.csproj",
                                         "tools/safe_killpg.sh")]   # core.require_source 认的源码件（空文件即可）
        for rel, body in ((PLIST, b"<plist>original</plist>"), (EXE, b"\x7fhost"), ("pack/jobs/x.py", b"print(1)\n"), *source):
            (self.bundle / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.bundle / rel).write_bytes(body)
        files = {p.relative_to(self.bundle).as_posix(): [p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest()]
                 for p in self.bundle.rglob("*") if p.is_file() and not p.is_symlink()}
        (self.bundle / "engine.json").write_text(json.dumps(dict(schema=1, id="e" * 64, files=files)))

    def context(self):
        self.sequence += 1
        return Context(dict(self.request, taskId=f"heal-{self.sequence}", operation="build", engineBundle=str(self.bundle)))

    def installed(self):
        c = self.context(); embedded.install(c)
        return c

    def test_installed_copy_is_used_without_rechecking_and_heals_when_artifact_used(self):
        # 11-19 维护者（「每次启动都很慢……这种校验是不是自己给自己挖的坑」）：装好的副本每个作业直接用，出包 / 起局 / 探测都不逐文件复核；
        #   #304 那种被外部改了大小的宿主文件，真用到宿主（artifact）时当场从 App 包重解。期望手写：改过的副本下一个作业原样留着、标记 inode 不变，
        #   artifact 之后变回 App 包里的原样
        from unittest.mock import patch
        c = self.installed()
        stamp = (c.engine / ".installed.json").stat().st_ino
        (c.engine / PLIST).write_bytes(b"<plist>rewritten by something else</plist>")   # 玩家机上的现象：大小变了
        for operation in ("launch", "build", "installCheck"):
            job = Context(dict(self.request, taskId=f"use-{operation}", operation=operation, engineBundle=str(self.bundle)))
            with patch.object(embedded, "_intact", side_effect=AssertionError(f"{operation} 作业开头去逐文件复核了")):
                embedded.install(job)
            self.assertEqual(job.engine, c.engine)
        self.assertEqual((c.engine / PLIST).read_bytes(), b"<plist>rewritten by something else</plist>")   # 没用到宿主前不动副本
        self.assertEqual((c.engine / ".installed.json").stat().st_ino, stamp)   # 没重解
        self.assertEqual(embedded.artifact(job, "S2ArmGame.app"), c.engine / "Binaries/S2ArmGame.app")
        self.assertEqual((c.engine / PLIST).read_bytes(), b"<plist>original</plist>")   # 用到时重解
        self.assertEqual(list(c.engine.parent.glob("*.broken")), [])   # 坏副本挪开后删掉

    def test_size_changed_artifact_is_reinstalled_when_used(self):
        # v0.2.3 清理：用到产物时也只核大小（原先按摘要逐字节核，同大小改写现实里没出现过，#304 是大小变了）；大小变了照样从 App 包重解
        c = self.installed()
        (c.engine / PLIST).write_bytes(b"<plist>changed size</plist>")
        self.assertEqual(embedded.artifact(c, "S2ArmGame.app"), c.engine / "Binaries/S2ArmGame.app")
        self.assertEqual((c.engine / PLIST).read_bytes(), b"<plist>original</plist>")

    def test_negative_control_copy_untouched_keeps_identity(self):
        c = self.installed()
        stamp = (c.engine / ".installed.json").stat().st_ino
        c2 = self.installed()
        self.assertEqual((c2.engine / ".installed.json").stat().st_ino, stamp)   # 副本没坏：不重解

    def test_concurrent_jobs_install_same_copy_without_moving_each_other(self):
        """启动时几个作业同时初始化同一份副本（preflight + setup + catalog）：都成功、只留一份、没有作业把别人的挪走；随后同一份副本连用两次也不重解"""
        import concurrent.futures, sys
        script = (
            "import sys, json; sys.path.insert(0, sys.argv[1]); from core import Context; import embedded\n"
            "c = Context(json.loads(sys.argv[2])); embedded.install(c); embedded.artifact(c, 'S2ArmGame.app'); print('OK', c.engine)\n")
        def job(n):
            self.sequence += 1
            request = dict(self.request, taskId=f"race-{n}", operation="preflight", engineBundle=str(self.bundle))
            return subprocess.run([sys.executable, "-B", "-c", script, str(Path(embedded.__file__).parent), json.dumps(request)],
                                  capture_output=True, text=True, timeout=120)
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            results = list(pool.map(job, range(4)))
        for r in results:
            self.assertEqual(r.returncode, 0, r.stdout[-800:] + r.stderr[-1500:])
        engine = embedded.engines_root(self.context()) / ("e" * 64)
        self.assertEqual(sorted(p.name for p in engine.parent.iterdir() if p.is_dir()), ["e" * 64])   # 没留 .partial / .broken
        stamp = (engine / ".installed.json").stat().st_ino
        for _ in range(2):   # 同一份副本连用两次（连出两次包的前半段）
            c = self.installed(); embedded.artifact(c, "S2ArmGame.app")
        self.assertEqual((engine / ".installed.json").stat().st_ino, stamp)

    def test_artifact_relocates_when_copy_vanished_mid_job(self):
        """本作业在用的副本被收走了（并发建库时发生过）：artifact 重新定位，不当成「没有内置产物」返回 None"""
        c = self.installed()
        os.rename(c.engine, c.engine.with_name("moved-away"))
        got = embedded.artifact(c, "S2ArmGame.app")
        self.assertIsNotNone(got)
        self.assertTrue((got / "Contents/Info.plist").is_file())

    def test_broken_app_bundle_warns_and_continues(self):
        """App 包本身和清单对不上（11-17 维护者：校验不过不整个拒绝）：黄字提示是哪个文件、建议重装，照样装上用；
        对不上的记进安装标记，下次用不再判「被改过」重解（标记的 inode 不变），用到这件产物也不报"""
        c = self.installed()
        (c.engine / PLIST).write_bytes(b"x")
        (self.bundle / PLIST).write_bytes(b"also broken")   # App 包本身也坏了
        c2 = self.installed()
        embedded.artifact(c2, "S2ArmGame.app")   # 用到宿主时发现副本被改过 → 重解；App 包也对不上 → 不抛、黄字
        warned = [d for d in c2.job["diagnostics"] if d.get("code") == "engine_incomplete"]
        self.assertEqual(len(warned), 1)
        self.assertEqual(warned[0].get("severity"), "warning")
        self.assertIn(PLIST, warned[0].get("message") or warned[0].get("summary") or "")
        mark = json.loads((c2.engine / ".installed.json").read_text())
        self.assertEqual(mark.get("bundleMismatch"), [PLIST])
        self.assertEqual((c2.engine / PLIST).read_bytes(), b"also broken")   # 照 App 包原样解出
        stamp = (c2.engine / ".installed.json").stat().st_ino
        c3 = self.installed()
        self.assertEqual((c3.engine / ".installed.json").stat().st_ino, stamp)   # 不反复重解
        self.assertEqual(embedded.artifact(c3, "S2ArmGame.app"), c3.engine / "Binaries/S2ArmGame.app")


class SharedHostHealTests(JobCase):
    """新布局的公共宿主 hosts/mac/<摘要>/S2ArmGame.app：已有的一份被改过（文件大小变了 / 少了文件）就从内置宿主重放，没变不动"""

    def setUp(self):
        super().setUp()
        self.app = self.root / "src/S2ArmGame.app"
        for rel, body in (("Contents/Info.plist", b"<plist/>"), ("Contents/MacOS/s2arm-host", b"\x7fhost"), ("Contents/MacOS/libs2a_vaguard.dylib", b"guard")):
            (self.app / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.app / rel).write_bytes(body)

    def test_changed_copy_is_replaced_untouched_copy_kept(self):
        import host_update
        sha = host_update.install_host(self.c, self.app)
        copy = host_update.layout.hosts_mac(self.c) / sha / "S2ArmGame.app"
        ino = (copy / "Contents/Info.plist").stat().st_ino
        self.assertEqual(host_update.install_host(self.c, self.app), sha)
        self.assertEqual((copy / "Contents/Info.plist").stat().st_ino, ino)   # 负对照：没变不重放
        (copy / "Contents/Info.plist").write_bytes(b"<plist>changed outside</plist>")
        (copy / "Contents/MacOS/libs2a_vaguard.dylib").unlink()
        self.assertEqual(host_update.install_host(self.c, self.app), sha)
        self.assertEqual((copy / "Contents/Info.plist").read_bytes(), b"<plist/>")
        self.assertTrue((copy / "Contents/MacOS/libs2a_vaguard.dylib").is_file())
