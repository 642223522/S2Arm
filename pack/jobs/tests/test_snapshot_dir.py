"""即时快照（0.6.0）在 Mac 上的落点：起局给 S2A_SNAPSHOT_DIR = 这款游戏文件夹里的 snapshot/（宿主 runtime/src/snapshot.c s2a_snap_dir_for 读）。
不放 temp/（总览里可清的临时件），删这款时随游戏文件夹一起删。期望手写"""
import os
import unittest
from unittest.mock import patch

from jobcase import JobCase
import build
import layout

GID = "0100000000000000"


class SnapshotDirTests(JobCase):
    def test_mac_launch_puts_snapshot_in_the_game_folder(self):
        game = dict(id=GID, name="Title 0", display="1.0", hidden=False, packages=[])
        with patch.dict(os.environ):
            env = build.runtime_env(self.c, game, self.root / "runtime")
        self.assertEqual(env["S2A_SNAPSHOT_DIR"], str(layout.game_dir(self.c, GID) / "snapshot"))
        self.assertNotIn(str(self.c.library / "temp"), env["S2A_SNAPSHOT_DIR"])


if __name__ == "__main__":
    unittest.main()
