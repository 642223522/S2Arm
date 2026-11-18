# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Intel Mac packaging-only launcher configuration.

No game files, no network: assert that the x86_64 build path selects matching
toolchain pins and RIDs, while the Apple Silicon path stays unchanged.
"""
import pathlib
import re
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "launchers/macos"))
sys.path.insert(0, str(ROOT / "launchers/shared"))

import bundle_engine  # noqa: E402
import bundle_runtime  # noqa: E402
import prepare_build  # noqa: E402
import runtime_cache  # noqa: E402
import runtime_sources  # noqa: E402


class IntelPackagingConfigTest(unittest.TestCase):
    def test_x86_python_pin(self):
        with mock.patch.object(runtime_sources.platform, "machine", return_value="x86_64"):
            spec = runtime_sources.python_spec()
        self.assertIn("x86_64-apple-darwin", spec["url"])
        self.assertEqual(spec["sha256"], "37c38fda76fec1fbf310adcbafb7f0d96af13b5511bf8ea954c3aa8eec185734")

    def test_arm_python_pin_unchanged(self):
        with mock.patch.object(runtime_sources.platform, "machine", return_value="arm64"):
            spec = runtime_sources.python_spec()
        self.assertIn("aarch64-apple-darwin", spec["url"])
        self.assertEqual(spec["sha256"], "353d5f1b4fd2715e7053f12f068435d5bbad16b91e057006b5d01e0925709a7e")

    def test_arm_wheel_table_unchanged(self):
        table = runtime_cache.WHEELS["macos_arm64"]
        self.assertEqual(set(table), {
            "capstone==5.0.7", "lz4==4.4.5", "numpy==2.4.2",
            "Pillow==12.3.0", "zstandard==0.25.0",
        })
        self.assertEqual(table["numpy==2.4.2"][0], "numpy-2.4.2-cp312-cp312-macosx_14_0_arm64.whl")

    def test_x86_wheel_table(self):
        table = runtime_cache.WHEELS["macos_x64"]
        self.assertEqual(set(table), {
            "capstone==5.0.7", "lz4==4.4.5", "numpy==2.4.2",
            "Pillow==12.3.0", "zstandard==0.25.0",
        })
        self.assertIn("x86_64", table["numpy==2.4.2"][0])
        for _, (_, digest) in table.items():
            self.assertRegex(digest, r"^[0-9a-f]{64}$")

    def test_x86_arch_helpers(self):
        with mock.patch.object(runtime_sources.platform, "machine", return_value="x86_64"):
            self.assertEqual(runtime_sources.host_arch(), "x86_64")
            self.assertEqual(runtime_sources.wheel_platform(), "macos_x64")
            self.assertEqual(bundle_engine.host_rid(), "osx-x64")
            self.assertEqual(bundle_engine.host_slice(), "x86_64")

    def test_arm_arch_helpers_unchanged(self):
        with mock.patch.object(runtime_sources.platform, "machine", return_value="arm64"):
            self.assertEqual(runtime_sources.host_arch(), "arm64")
            self.assertEqual(runtime_sources.wheel_platform(), "macos_arm64")
            self.assertEqual(bundle_engine.host_rid(), "osx-arm64")
            self.assertEqual(bundle_engine.host_slice(), "arm64")

    def test_prepare_build_accepts_both_macs(self):
        self.assertTrue(prepare_build.can_build_on("Darwin", "arm64"))
        self.assertTrue(prepare_build.can_build_on("Darwin", "x86_64"))
        self.assertFalse(prepare_build.can_build_on("Darwin", "ppc64"))
        self.assertFalse(prepare_build.can_build_on("Linux", "x86_64"))

    def test_intel_shell_build_includes_ios_library_ui(self):
        """Intel 出 iPhone 壳必须带库界面：通用容器 App 打开就要显示游戏库。"""
        text = (ROOT / "pack/shell_build.sh").read_text()
        self.assertIn('uname -m', text)
        self.assertIn('x86_64', text)
        self.assertIn('"$OS" = tvos', text)   # 只在 tvOS 平台组件没装时跳过；iOS 不再整段跳过
        self.assertIn('SHELLUI=0', text)
        self.assertIn('S2A_SHELLUI:-', text)

    def test_intel_shellui_builds_without_xcodebuild_sandbox(self):
        """Intel 出壳的库界面走 swift build --disable-sandbox：xcodebuild 的 SwiftPM 在临时镜像里 sandbox_apply 会被拦。"""
        text = (ROOT / "runtime/build.mk").read_text()
        self.assertIn('uname -m', text)
        self.assertIn('swift build --disable-sandbox', text)
        self.assertIn('-force_load,$(SHELLUI_PRODUCTS)/libS2ArmShellHost.a', text)

    def test_runtime_versions_probe_covers_every_pin(self):
        pins = [line.split('==')[0] for line in (ROOT / "launchers/macos/requirements-runtime.txt").read_text().splitlines()
                if '==' in line and not line.startswith('#')]
        code = bundle_runtime.installed_versions_probe(pins)
        for name in pins:
            self.assertIn(name, code)

    def test_sdk_major_follows_installed_xcode(self):
        text = (ROOT / "tools/toolchain.env").read_text()
        ios = re.search(r"^IPHONEOS_SDK_MAJOR=(\d+)$", text, re.M)
        tvos = re.search(r"^TVOS_SDK_MAJOR=(\d+)$", text, re.M)
        self.assertEqual(ios.group(1), "26")
        self.assertEqual(tvos.group(1), "26")

    def test_build_app_rename_tolerates_proxy_double_execution(self):
        """宿主代理已把 staging 改成目标却回报失败时，构建不能误报失败。"""
        text = (ROOT / "launchers/macos/build_app.py").read_text()
        self.assertIn("if not app.exists() and destination.exists():", text)
        self.assertIn("pass", text)

    def test_declared_minimum_follows_bundled_binaries(self):
        import runtime_audit
        with tempfile.TemporaryDirectory() as folder:
            binary = pathlib.Path(folder) / "bash"
            binary.write_bytes(b"\xcf\xfa\xed\xfe")
            info = "cmd LC_BUILD_VERSION\n platform MACOS\n    minos 26.0\n"
            with mock.patch.object(runtime_audit.subprocess, "check_output", return_value=info):
                self.assertEqual(runtime_audit.declared_minimum_macos(folder, "15.0"), "26.0")
                self.assertEqual(runtime_audit.declared_minimum_macos(folder, "27.0"), "27.0")


if __name__ == "__main__":
    unittest.main()
