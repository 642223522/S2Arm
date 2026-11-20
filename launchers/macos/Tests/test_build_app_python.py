# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""build_app.py 交给出壳等子脚本的 Python（S2A_PY）。

不出壳、不联网：把 bundle_shell 换成记录器，真跑 build_app.main --shells-only，核 iOS / tvOS 两次出壳拿到的 S2A_PY。
pack/shell_build.sh 用 ${S2A_PY:-python3} 跑 tv_icon.py（要 Pillow）等脚本：build_app 不交 S2A_PY 时退到 PATH 上的 python3，
那份不一定装了钉版依赖（11-20：PATH 上是 Homebrew python3 3.15、没有 PIL，tvOS 壳红）。
取法同出包链（tools/machine.sh get）：调用方环境 → tools/machine.local → 跑 build_app 的解释器。
"""
import contextlib
import io
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "launchers/macos"))
sys.path.insert(0, str(ROOT))   # main 里 from pack.shell.manifest import current_id；下面 mock.patch 也按点路径从这里导入

import build_app  # noqa: E402

XCODE = "/Applications/Xcode.app/Contents/Developer"   # 只当参数传；bundle_shell 换成了记录器，不碰 Xcode


class BuildAppChildPythonTest(unittest.TestCase):
    def shells_only(self, **extra):
        """跑 build_app.main --shells-only，回 [(apple_os, 交给该次出壳的 S2A_PY)]。"""
        seen = []

        def record(engine_json, dest, env, apple_os="ios", sid=None):
            seen.append((apple_os, env.get("S2A_PY")))
            return pathlib.Path(tempfile.gettempdir()) / str(sid)

        environ = {k: v for k, v in os.environ.items() if k not in ("S2A_PY", "S2A_MACHINE_LOCAL", "S2A_MACHINE_NO_LOCAL")}
        environ.update(extra)
        with mock.patch.dict(os.environ, environ, clear=True), \
                mock.patch.object(sys, "argv", ["build_app.py", "--shells-only", "--developer-dir", XCODE]), \
                mock.patch.object(build_app, "bundle_shell", side_effect=record), \
                mock.patch("pack.shell.manifest.current_id", side_effect=lambda apple_os: f"test-{apple_os}"), \
                contextlib.redirect_stdout(io.StringIO()):
            build_app.main()
        return seen

    def machine_local(self, text):
        """写一份临时 machine.local，回路径（交给 S2A_MACHINE_LOCAL，不读本机那份）。"""
        d = tempfile.TemporaryDirectory(prefix="s2a-machine-local-")
        self.addCleanup(d.cleanup)
        path = pathlib.Path(d.name, "machine.local")
        path.write_text(text)
        return str(path)

    def test_unset_uses_build_interpreter(self):
        """环境和 machine.local 都没指定：用跑 build_app 的解释器，不让子脚本退到 PATH 上的 python3。"""
        self.assertEqual(self.shells_only(S2A_MACHINE_NO_LOCAL="1"),
                         [("ios", sys.executable), ("tvos", sys.executable)])

    def test_machine_local_before_build_interpreter(self):
        """只有 tools/machine.local 指定：照用它（同出包链 tools/machine.sh get 的取法）。"""
        local = self.machine_local("S2A_PY=/opt/s2a-test/machine-local/bin/python3\n")
        self.assertEqual(self.shells_only(S2A_MACHINE_LOCAL=local),
                         [("ios", "/opt/s2a-test/machine-local/bin/python3"),
                          ("tvos", "/opt/s2a-test/machine-local/bin/python3")])

    def test_explicit_env_wins(self):
        """调用方环境里指定了：原样交下去，machine.local 也盖不掉它。"""
        local = self.machine_local("S2A_PY=/opt/s2a-test/machine-local/bin/python3\n")
        self.assertEqual(self.shells_only(S2A_PY="/opt/s2a-test/env/bin/python3", S2A_MACHINE_LOCAL=local),
                         [("ios", "/opt/s2a-test/env/bin/python3"), ("tvos", "/opt/s2a-test/env/bin/python3")])


if __name__ == "__main__":
    unittest.main()
