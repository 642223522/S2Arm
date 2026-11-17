# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Completion must cover every discovered module, including dependency-package tests."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check_xctest.py"


class XCTestCompletionTests(unittest.TestCase):
    def check(self, discovery, execution):
        with tempfile.TemporaryDirectory(prefix="s2arm-xctest-check-") as temporary:
            root = Path(temporary)
            (root / "discovery.log").write_text(discovery)
            (root / "execution.log").write_text(execution)
            return subprocess.run([sys.executable, str(SCRIPT), str(root / "discovery.log"),
                                   str(root / "execution.log")], text=True, capture_output=True)

    def test_frontend_modules_are_counted(self):
        result = self.check("NXCoreTests.LanguageTests/testLanguage\nNXLauncherTests.LayoutTests/testLayout\n",
                            "Test Case '-[NXCoreTests.LanguageTests testLanguage]' passed (0.01 seconds).\n"
                            "Test Case '-[NXLauncherTests.LayoutTests testLayout]' passed (0.01 seconds).\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("发现 2，完成 2", result.stdout)

    def test_missing_apple_frontend_test_cannot_hide_behind_legacy_success(self):
        result = self.check("S2ArmLauncherTests.HomeTests/testHome\nS2ArmAppleTests.HomeTests/testHome\n",
                            "Test Case '-[S2ArmLauncherTests.HomeTests testHome]' passed (0.01 seconds).\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("未完成：S2ArmAppleTests.HomeTests/testHome", result.stderr)

    def test_debug_output_glued_to_the_result_line_still_counts(self):
        # 用例自己打的调试输出没换行，结局行接在它后面（11-17 SettingsLayoutTests 明明 passed 却被判「未完成」，门禁假红）
        result = self.check("S2ArmAppleTests.SettingsLayoutTests/testLayout\n",
                            "row widths: [312, 312, 298]Test Case '-[S2ArmAppleTests.SettingsLayoutTests testLayout]' passed (0.02 seconds).\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("发现 1，完成 1", result.stdout)

    def test_identical_case_names_in_different_modules_are_distinct(self):
        result = self.check("S2ArmLauncherTests.HomeTests/testHome\nS2ArmAppleTests.HomeTests/testHome\n",
                            "Test Case '-[S2ArmLauncherTests.HomeTests testHome]' passed (0.01 seconds).\n"
                            "Test Case '-[S2ArmAppleTests.HomeTests testHome]' passed (0.01 seconds).\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("发现 2，完成 2", result.stdout)

    def test_failure_names_the_module_and_assertion(self):
        result = self.check("NXLauncherTests.LayoutTests/testLayout\n",
                            "fixture.swift:1: error: -[NXLauncherTests.LayoutTests testLayout] : control is outside the window\n"
                            "Test Case '-[NXLauncherTests.LayoutTests testLayout]' failed (0.01 seconds).\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("失败：NXLauncherTests.LayoutTests/testLayout", result.stderr)
        self.assertIn("control is outside the window", result.stderr)

    def test_skip_duplicate_unexpected_and_zero_test_footer_are_not_completion(self):
        for name, execution in {
            "skip": "Test Case '-[NXLauncherTests.LayoutTests testLayout]' skipped (0.01 seconds).\n",
            "duplicate": "Test Case '-[NXLauncherTests.LayoutTests testLayout]' passed (0.01 seconds).\n" * 2,
            "unexpected": "Test Case '-[NXLauncherTests.LayoutTests testOther]' passed (0.01 seconds).\n",
            "zero footer": "Test run with 0 tests in 0 suites passed after 0.001 seconds.\n",
        }.items():
            with self.subTest(name=name):
                result = self.check("NXLauncherTests.LayoutTests/testLayout\n", execution)
                self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(self.check("", "").returncode, 0)


if __name__ == "__main__":
    unittest.main()
