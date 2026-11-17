#!/usr/bin/env python3
"""Mac 作业固定用应用自带的 dotnet（#441 D-NDRE）：发版运行时（Runtime/versions.json runtimeSchema 3 / 4）下 env() 设 DOTNET = Runtime/dotnet/dotnet。
   不设时 translator/dmsh_chain.py 等按「DOTNET → ~/.dotnet/dotnet → PATH」找，玩家自己在 ~/.dotnet 装了别的版本就抢在自带运行时前面，
   .NET 10 的翻译器跑不起来、指纹读成空，出库前核工具失败（报成「翻译器不是从仓库源码编的」）。期望手写。"""
import json
import unittest
import unittest.mock as um

import test_jobs


class DotnetPinned(unittest.TestCase):
    setUp, tearDown = test_jobs.JobsTests.setUp, test_jobs.JobsTests.tearDown

    def test_release_runtime_pins_dotnet(self):
        res = self.root / "res"; (res / "Runtime").mkdir(parents=True)
        (res / "Runtime/versions.json").write_text(json.dumps({"runtimeSchema": 4}))
        self.c.r.update(resources=str(res))
        engine = self.root / "engine"; engine.mkdir()   # 源码树（没有 engine.json）：不涉内置宿主
        with um.patch.object(self.c, "engine", engine):
            env = self.c.env()
        self.assertEqual(env["DOTNET"], str(res / "Runtime/dotnet/dotnet"))
        self.assertEqual(env["DOTNET_ROOT"], str(res / "Runtime/dotnet"))


if __name__ == "__main__":
    unittest.main()
