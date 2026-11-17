"""游玩时间（运行时 runtime/src/playtime.c）在作业层的两处：Mac 起局给 S2A_PLAYTIME = 这款游戏文件夹里的 playtime.json（不放 temp/：
那是总览里可清的临时件，清了不能把累计时长一起清掉）；catalog 把它原样带给界面（GameSummary.playtime），没玩过 / 0 秒 / 坏文件不给。期望手写"""
import json
import os
import unittest
from unittest.mock import patch

from jobcase import JobCase
import build
import layout
import library

GID, NEVER, ZERO = "0100000000000000", "0100000000000001", "0100000000000002"


class PlaytimeTests(JobCase):
    def game(self, gid=GID):
        return dict(id=gid, name="Title " + gid[-1], display="1.0", hidden=False, packages=[])

    def test_mac_launch_writes_into_the_game_folder(self):
        with patch.dict(os.environ):
            env = build.runtime_env(self.c, self.game(), self.root / "runtime")
        self.assertEqual(env["S2A_PLAYTIME"], str(layout.path(self.c, GID, "playtime.json")))
        self.assertNotIn(str(self.c.library / "temp"), env["S2A_PLAYTIME"])

    def test_catalog_passes_playtime_of_played_games_only(self):
        library.atomic(self.c.library / "catalog.json", dict(schema=1, games=[self.game(GID), self.game(NEVER), self.game(ZERO)]))
        layout.path(self.c, GID, "playtime.json").write_text(json.dumps(dict(schema=1, seconds=5400, lastPlayed=1794790800)) + "\n")
        layout.path(self.c, ZERO, "playtime.json").write_text(json.dumps(dict(schema=1, seconds=0, lastPlayed=1)) + "\n")
        layout.game_dir(self.c, NEVER)
        got = {g["id"]: g.get("playtime") for g in library.catalog(self.c)["games"]}
        self.assertEqual(got[GID], dict(seconds=5400, lastPlayed=1794790800))
        self.assertIsNone(got[NEVER])   # 没玩过：没有这项，界面不显示
        self.assertIsNone(got[ZERO])    # 0 秒同没玩过


if __name__ == "__main__":
    unittest.main()
