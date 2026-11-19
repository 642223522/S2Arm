#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""android/host/prepare.sh 的编排（无网络、不碰真缓存）：真 prepare.sh + 真 cache-identity.py，其余打桩。

要证的事：缓存里还没有固定 .NET SDK 时（首次准备），准备脚本先引导 SDK、再算依赖清单，
所以构建前后两次清单一致、写出完成标记。修前清单在 SDK 引导之前就算了（dotnet 记成 None），
构建引导完 SDK 后再算就变了，首次准备必然报「准备期间依赖清单变化」退出 1。
"""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ANDROID = HERE.parent
SDK_VERSION = '1.2.3'

spec = importlib.util.spec_from_file_location('cache_identity', ANDROID / 'docker/cache-identity.py')
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)

# 桩 dotnet：固定版本输出；每次被问版本记一笔，用来核「先引导、后算清单」。
DOTNET = '#!/bin/sh\necho "dotnet $*" >> "$TEST_BASE/order.log"\necho %s\n' % SDK_VERSION

# 桩 cs/build.sh：和真脚本同一行 sdk_version、同一个 SDK 落点；不在就「下载」（写桩 dotnet），
# --prepare-sdk 引导完即退出（真脚本 :53）。SDK_EXIT=1 模拟下载 / 校验失败。
CS_BUILD = r'''#!/usr/bin/env bash
sdk_version=%s   # compat/tree/global.json
set -eu
dotnet=${S2A_ANDROID_DOTNET:-$S2A_BUILD_CACHE/dotnet/$sdk_version/dotnet}
if [ -z "${S2A_ANDROID_DOTNET:-}" ] && [ ! -x "$dotnet" ]; then
    echo "bootstrap" >> "$TEST_BASE/order.log"
    [ "${SDK_EXIT:-0}" = 0 ] || { echo "download failed" >&2; exit 1; }
    mkdir -p "$(dirname "$dotnet")"
    cp "$TEST_BASE/dotnet-stub" "$dotnet"; chmod +x "$dotnet"
fi
case "${1:-}" in --prepare-sdk) exit 0 ;; esac
"$dotnet" build >/dev/null
''' % SDK_VERSION


class HostPrepareTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='s2a-host-prepare-test-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.repo = self.base / 'repo'
        android = self.repo / 'android'
        (android / 'host').mkdir(parents=True)
        (android / 'docker').mkdir(parents=True)
        shutil.copy2(ANDROID / 'host/prepare.sh', android / 'host/prepare.sh')
        shutil.copy2(ANDROID / 'docker/cache-identity.py', android / 'docker/cache-identity.py')
        stubs = {
            'android/tools/ndk_toolchain.sh':
                's2a_ndk_resolve() { echo "$TEST_BASE/ndk"; }\ns2a_ndk_host_bin() { echo "$1/bin"; }\n',
            'android/host/hostenv.sh':
                'export ANDROID_HOME=$TEST_BASE/sdk JAVAC=$TEST_BASE/javac S2A_BUILD_CACHE=${S2A_BUILD_CACHE:-$TEST_BASE/cache}\n'
                'mkdir -p "$S2A_BUILD_CACHE"\n',
            'android/cs/build.sh': CS_BUILD,
            'android/codecs/build.sh': '#!/usr/bin/env bash\nexit 0\n',
            'android/host/build.sh': '#!/usr/bin/env bash\nset -e\nbash cs/build.sh\n',
            'android/docker/gate-audit.py': 'import sys\nsys.exit(0)\n',
        }
        for rel, text in stubs.items():
            path = self.repo / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        for rel in identity.REQUIRED['host']:
            path = self.repo / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists():
                path.write_text(rel + '\n')
        for rel in identity.PROJECTS:
            path = self.repo / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('<Project/>')
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        subprocess.run(['git', '-C', str(self.repo), 'add', '.'], check=True)
        (self.base / 'dotnet-stub').write_text(DOTNET)
        (self.base / 'sdk').mkdir()
        (self.base / 'ndk').mkdir()
        javac = self.base / 'javac'
        javac.write_text('#!/bin/sh\necho "javac 17"\n')
        javac.chmod(0o755)
        self.cache = self.base / 'cache'
        self.env = {k: v for k, v in os.environ.items()
                    if k not in ('S2A_BUILD_CACHE', 'S2A_ANDROID_DOTNET', 'ANDROID_HOME', 'ANDROID_SDK_ROOT')}
        self.env.update(HOME=str(self.base), TEST_BASE=str(self.base), S2A_BUILD_CACHE=str(self.cache))

    def run_prepare(self, **env):
        return subprocess.run(['bash', str(self.repo / 'android/host/prepare.sh')],
                              env={**self.env, **env}, capture_output=True, text=True, timeout=120)

    def order(self):
        log = self.base / 'order.log'
        return log.read_text().split('\n')[:-1] if log.exists() else []

    def receipts(self):
        return sorted(self.cache.glob('s2a-apk-gate-receipt-*.json'))

    def test_cold_cache_prepares_and_certifies(self):
        result = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('准备期间依赖清单变化', result.stderr)
        self.assertEqual(len(self.receipts()), 1, result.stdout + result.stderr)
        self.assertTrue((self.cache / 'dotnet' / SDK_VERSION / 'dotnet').is_file())

    def test_sdk_is_bootstrapped_before_the_first_identity(self):
        result = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        order = self.order()
        self.assertIn('bootstrap', order)
        versions = [i for i, line in enumerate(order) if line == 'dotnet --version']
        self.assertTrue(versions, order)
        self.assertLess(order.index('bootstrap'), versions[0], order)

    def test_warm_cache_still_certifies(self):
        self.assertEqual(self.run_prepare().returncode, 0)
        (self.base / 'order.log').unlink()
        result = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('bootstrap', self.order())
        self.assertEqual(len(self.receipts()), 1)

    def test_explicit_sdk_is_not_bootstrapped(self):
        own = self.base / 'own-dotnet'
        own.write_text(DOTNET)
        own.chmod(0o755)
        result = self.run_prepare(S2A_ANDROID_DOTNET=str(own))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('bootstrap', self.order())
        self.assertFalse((self.cache / 'dotnet').exists())

    def test_sdk_bootstrap_failure_is_reported_and_leaves_no_receipt(self):
        result = self.run_prepare(SDK_EXIT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('.NET SDK 准备失败', result.stderr)
        self.assertEqual(self.receipts(), [])


if __name__ == '__main__':
    unittest.main()
