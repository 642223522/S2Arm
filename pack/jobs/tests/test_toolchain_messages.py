# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Synthetic preflight probes keep Metal and Xcode status text consistent."""
import os
from pathlib import Path
from unittest.mock import patch

from jobcase import JobCase
import install
import ipa
import toolchain


class ToolchainMessageTests(JobCase):
    def preflight(self, *, has_xcode=True, metal=(True, "Apple metal version fixture"), sdk=True, developer_dir=None):
        developer = self.root / "synthetic-Xcode/Contents/Developer"
        xcodebuild = developer / "usr/bin/xcodebuild"
        xcodebuild.parent.mkdir(parents=True, exist_ok=True)
        if has_xcode:
            xcodebuild.touch()
        else:
            xcodebuild.unlink(missing_ok=True)
        self.c.r["developerDir"] = str(developer) if developer_dir is None else developer_dir

        def probe(c, args, timeout=15):
            if "metal" in args:
                return metal
            if "--show-sdk-path" in args:
                return sdk, "synthetic-sdk" if sdk else ""
            return True, "10.0.403"

        with patch.object(toolchain, "probe", side_effect=probe), \
             patch.object(toolchain, "ios_platform", return_value=(None, "", "synthetic", None)), \
             patch.object(install, "xcode_account", return_value=(False, [])), \
             patch.object(toolchain, "reader", return_value=Path("fixture.dll")), \
             patch.object(toolchain, "input_interface", return_value=(True, "fixture")), \
             patch.object(ipa, "dotnet_sdk", return_value=(developer, developer / "dotnet")), \
             patch("platform.mac_ver", return_value=("26.0", (), "")):
            return {row["name"]: row for row in toolchain.preflight(self.c)["checks"]}

    def test_success_messages_match_success_states(self):
        rows = self.preflight()
        for name, expected in (("Metal 编译组件", "Xcode 的 Metal 编译组件已就绪。"),
                               ("Xcode", "已找到完整的 Xcode。")):
            with self.subTest(name=name):
                row = rows[name]
                self.assertTrue(row["ok"])
                self.assertEqual(row["message"], expected)
                self.assertEqual(row["help"], expected)
                self.assertEqual(set(row), {"id", "name", "ok", "message", "requiredFor", "group", "action", "help"})
                self.assertEqual(row["requiredFor"], ["prepare"])
                self.assertEqual(row["group"], "system")
        self.assertEqual(rows["Metal 编译组件"]["action"], "downloadMetal")
        self.assertEqual(rows["Xcode"]["action"], "appStoreXcode")

    def test_missing_xcode_with_empty_developer_dir_is_not_found(self):
        # 只装命令行工具、没装 Xcode：启动器找不到 Xcode 时 developerDir 传空串；从 Finder 打开的 App 工作目录是 /，
        # Path("") 拼出相对路径 usr/bin/xcodebuild，会落到系统自带的 /usr/bin/xcodebuild 空壳上，不能算装了 Xcode（#109）
        self.assertTrue(Path("/usr/bin/xcodebuild").is_file(), "前提：系统自带 /usr/bin/xcodebuild")
        cwd = os.getcwd()
        os.chdir("/")
        self.addCleanup(os.chdir, cwd)
        rows = self.preflight(developer_dir="",
                              metal=(True, "xcode-select: error: tool 'metal' requires Xcode, but active developer directory "
                                           "'/Library/Developer/CommandLineTools' is a command line tools instance"))
        self.assertFalse(rows["Xcode"]["ok"])
        self.assertEqual(rows["Xcode"]["diagnostic"]["code"], "xcode_unavailable")
        self.assertFalse(rows["Metal 编译组件"]["ok"])
        self.assertIsNone(rows["Metal 编译组件"]["action"])   # 没 Xcode 不给「一键下载」（xcodebuild -downloadComponent 必失败）
        self.assertEqual(rows["Metal 编译组件"]["diagnostic"]["code"], "xcode_unavailable")
        self.assertNotIn("iOS 平台组件", rows)
        self.assertNotIn("Apple ID 团队", rows)

    def test_failure_messages_and_diagnostics_unchanged(self):
        cases = [
            (dict(metal=(False, "license agreement not accepted")), "Metal 编译组件",
             "Xcode 还没完成首次设置：点「打开 Xcode」，同意许可后回来点重新检查。", "openXcode", "xcode_setup_required"),
            (dict(metal=(False, "component unavailable")), "Metal 编译组件",
             "缺 Xcode 的 Metal 编译组件：点「一键下载」自动安装（约 1 GB），下完自动重新检查。", "downloadMetal", "metal_unavailable"),
            (dict(has_xcode=False, metal=(False, "not found")), "Metal 编译组件",
             "准备游戏需要 Xcode 的 Metal 编译组件；先安装 Xcode。", None, "xcode_unavailable"),
            (dict(has_xcode=False, sdk=False), "Xcode",
             "没找到完整的 Xcode：点「去 App Store 安装」，装好打开一次后回来点重新检查；S2Arm 会自动找到它。", "appStoreXcode", "xcode_unavailable"),
            (dict(sdk=False), "Xcode",
             "没找到完整的 Xcode：点「去 App Store 安装」，装好打开一次后回来点重新检查；S2Arm 会自动找到它。", "appStoreXcode", "xcode_unavailable"),
        ]
        for options, name, message, action, code in cases:
            with self.subTest(options=options, name=name):
                row = self.preflight(**options)[name]
                self.assertFalse(row["ok"])
                self.assertEqual(row["message"], message)
                self.assertEqual(row["help"], message)
                self.assertEqual(row["action"], action)
                self.assertEqual(row["diagnostic"]["code"], code)
                self.assertEqual(row["requiredFor"], ["prepare"])
                self.assertEqual(row["group"], "system")
                self.assertEqual(set(row), {"id", "name", "ok", "message", "requiredFor", "group", "action", "help", "diagnostic"})
                self.assertEqual(row["id"], {"Metal 编译组件": "metal", "Xcode": "xcode"}[name])   # 稳定英文 id（剃刀 M11），前端按它分组，不按中文名



class AppleIdCheckFollowsPlumesign(ToolchainMessageTests.__bases__[0]):
    """0.6.0 Mac：推到 iPhone 的「Apple ID 团队」看随包 plumesign 登录的账号（install.mac_plume），不看 Xcode；
    Apple TV / 独立 App 方案仍用 Xcode 团队，单列 xcode_team（只标 appleTV，不挡推到 iPhone）；证书模式不出 iPhone 那一项。期望手写"""
    TV = "Apple TV / 独立 App 方案用的 Xcode 团队"

    def rows(self, plume, acct):
        with patch.object(install, "mac_plume", lambda c: plume), patch.object(install, "win_install_mod", lambda c: None), \
             patch.object(install, "plume_account", lambda c, W: acct):
            return ToolchainMessageTests.preflight(self)

    def test_not_signed_in(self):
        rows = self.rows(True, None)
        row = rows["Apple ID 团队"]
        self.assertEqual((row["id"], row["ok"], row["action"], row["message"], row["requiredFor"], row["diagnostic"]["code"]),
                         ("apple_team", False, "appleLogin", install.APPLE_SIGN_IN, ["install"], "apple_not_signed_in"))
        tv = rows[self.TV]   # preflight 夹具里 Xcode 没登录（xcode_account → (False, [])）
        self.assertEqual((tv["id"], tv["ok"], tv["action"], tv["requiredFor"], tv["diagnostic"]["code"]),
                         ("xcode_team", False, "openXcode", ["appleTV"], "xcode_account_missing"))

    def test_signed_in(self):
        row = self.rows(True, dict(account="a@example.com", team="T", teamName="甲"))["Apple ID 团队"]
        self.assertEqual((row["ok"], row["action"]), (True, "appleLogin"))
        self.assertNotIn("diagnostic", row)

    def test_devcert_has_no_iphone_item(self):
        rows = self.rows(False, None)   # 用自己的开发者证书：mac_plume 为假
        self.assertNotIn("Apple ID 团队", rows)
        self.assertIn(self.TV, rows)
