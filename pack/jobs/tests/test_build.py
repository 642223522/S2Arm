"""Mac 准备（pack/jobs/build.py）单测（从 test_error_recovery.py 拆出，10-26；夹具 jobcase.JobCase）。"""
import os
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch

from jobcase import JobCase, ROOT


class BuildTests(JobCase):
    def test_player_launch_disables_iphone_va_in_real_child_only(self):
        import build
        game = dict(id="0100000000000000", name="Test title")
        for inherited in (None, "0", "1"):
            with self.subTest(inherited=inherited), patch.dict(os.environ):
                os.environ.pop("S2A_IPHONE_VA", None)
                if inherited is not None:
                    os.environ["S2A_IPHONE_VA"] = inherited
                self.assertNotIn("S2A_IPHONE_VA", self.c.env())
                env = build.runtime_env(self.c, game, self.root / "runtime")
                lines = []
                self.c.run([sys.executable, "-c",
                            "import os; print(os.getenv('S2A_IPHONE_VA', 'unset'))"],
                           env=env, on_line=lines.append)
                self.assertEqual(lines, ["0"])
                self.assertEqual(os.environ.get("S2A_IPHONE_VA"), inherited)
                self.assertNotIn("S2A_IPHONE_VA", self.c.env())

    @unittest.skipUnless(sys.platform == "darwin", "Mac development launch adapter")
    def test_developer_run_mac_preserves_iphone_va_default_and_overrides(self):
        # Run the real adapter with a synthetic host; no game, saves or GPU.
        repo = self.root / "dev repo"
        for directory in ("runtime", "tools", "build", "input", "home"):
            (repo / directory).mkdir(parents=True)
        shutil.copyfile(ROOT / "runtime/run_mac.sh", repo / "runtime/run_mac.sh")
        (repo / "input/main.patched.bin").touch()
        fixtures = {
            "tools/mac_chain_check.py": "raise SystemExit(0)\n",
            "tools/mac_save.sh": "mac_save_prep() { :; }\n",
            "tools/phys_footprint.py": "print('0 0')\n",
            "build/s2arm-host": "#!/bin/sh\nprintf '%s\\n' \"${S2A_IPHONE_VA-unset}\"\n",
        }
        for name, content in fixtures.items():
            (repo / name).write_text(content)
        (repo / "build/s2arm-host").chmod(0o755)
        for override in (None, "0", "1"):
            with self.subTest(override=override):
                env = dict(PATH=os.defpath, HOME=str(repo / "home"),
                           S2A_PY=sys.executable, S2A_IN=str(repo / "input"),
                           S2A_HOST_PREBUILT="1", S2A_MAC_SLOT_HELD="1")
                if override is not None:
                    env["S2A_IPHONE_VA"] = override
                run = repo / ("run-" + str(override))
                result = subprocess.run(["/bin/bash", str(repo / "runtime/run_mac.sh"),
                                         "synthetic", str(run), "5"],
                                        env=env, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((run / "host.log").read_text().strip(),
                                 "unset" if override is None else override)


if __name__ == "__main__":
    unittest.main()
