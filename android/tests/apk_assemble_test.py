#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""预编引擎 APK 组装（apk_assemble.py / axml.py / apk_sign.py / engine_template.icon_entries）：
引擎 APK 由真 SDK 的 aapt2 compile + link 造（占位身份、@string 显示名、@mipmap 图标、派生自包名的 taskAffinity / authorities），
组装结果交给 SDK 自己的 aapt2 dump 与 apksigner verify 判；期望全部来自本测试的输入，不跑被测实现推导。没有 SDK 时跳过（不冒充通过）。"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
import zlib

ANDROID = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ANDROID / 'tools'))
sys.path.insert(0, str(ANDROID.parent))
import apk_assemble  # noqa: E402
import engine_template  # noqa: E402
import game_apk  # noqa: E402

TEMPLATE = 'org.s2arm.game.t0000000000000000'
DENSITIES = ('mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi')


def png(size, rgb):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    raw = b''.join(b'\0' + bytes(rgb) * size for _ in range(size))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def sdk_tools():
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if not sdk:
        return None
    aapt2 = Path(sdk) / 'build-tools/36.0.0/aapt2'
    jar = Path(sdk) / 'platforms/android-36/android.jar'
    signer = Path(sdk) / 'build-tools/36.0.0/apksigner'
    return (aapt2, jar, signer) if aapt2.is_file() and jar.is_file() else None


@unittest.skipUnless(sdk_tools(), 'real SDK (ANDROID_HOME build-tools 36.0.0 + platform 36) required')
class AssembleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.aapt2, self.jar, self.signer = sdk_tools()
        self.engine = self.tmp / 'engine'
        self.engine.mkdir()
        self.placeholder = {d: png(48 + 24 * i, (200, 200, 200)) for i, d in enumerate(DENSITIES)}
        res = self.tmp / 'res'
        (res / 'values').mkdir(parents=True)
        (res / 'values/strings.xml').write_text('<resources><string name="game_name">S2Arm</string></resources>')
        for d, data in self.placeholder.items():
            (res / f'mipmap-{d}').mkdir()
            (res / f'mipmap-{d}/game_icon.png').write_bytes(data)
        manifest = self.tmp / 'AndroidManifest.xml'
        manifest.write_text(
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
            f'package="{TEMPLATE}" android:versionCode="1" android:versionName="0 (S2Arm 0.1.0-dev)">'
            '<uses-sdk android:minSdkVersion="29" android:targetSdkVersion="36"/>'
            '<application android:label="@string/game_name" android:icon="@mipmap/game_icon">'
            f'<activity android:name="org.s2arm.android.GameActivity" android:taskAffinity="{TEMPLATE}.game" android:exported="false"/>'
            f'<provider android:name="org.s2arm.android.DiagnosticShareProvider" android:authorities="{TEMPLATE}.diag" android:exported="false"/>'
            '</application></manifest>')
        compiled = self.tmp / 'res.zip'
        subprocess.run([self.aapt2, 'compile', '--dir', res, '-o', compiled], check=True, capture_output=True)
        apk = self.engine / 'engine.apk'
        linked = self.tmp / 'linked.apk'
        subprocess.run([self.aapt2, 'link', '-I', self.jar, '--manifest', manifest, '-o', linked, compiled], check=True, capture_output=True)
        # 同 AGP 正式构建：资源路径缩短（res/xx.png），组装不能按 res/mipmap-*/ 路径找图标
        subprocess.run([self.aapt2, 'optimize', '--shorten-resource-paths', '-o', apk, linked], check=True, capture_output=True)
        with zipfile.ZipFile(apk, 'a') as z:   # 原生库（STORED，组装要按 16 KB 对齐）与 dex 照搬
            z.writestr(zipfile.ZipInfo('lib/arm64-v8a/libs2arm_android.so'), b'\x7fELF' + b'\0' * 5000)
            z.writestr('classes.dex', b'dex\n035\0' + b'\1' * 300, compress_type=zipfile.ZIP_DEFLATED)
        (self.engine / 'identity.json').write_text('{}')
        icons = engine_template.icon_entries(apk, self.placeholder)
        (self.engine / 'engine.json').write_text(json.dumps(dict(
            schema=apk_assemble.ENGINE_SCHEMA, package=TEMPLATE, versionNameSuffix=' (S2Arm 0.1.0-dev)', icons=icons,
            apkSha256=hashlib.sha256(apk.read_bytes()).hexdigest())))
        self.icons = icons
        self.game = self.tmp / 'game'
        (self.game / 'res/values').mkdir(parents=True)
        (self.game / 'assets/game/modules').mkdir(parents=True)
        props = 'titleId=0100000000ABCDEF\nname=Test\nversion=1.2\nversionCode=7\nlauncherIcon=game\nmodules=main\n'
        (self.game / 'game.properties').write_text(props)
        (self.game / 'assets/game/game.properties').write_text(props)
        self.module = os.urandom(70000)
        (self.game / 'assets/game/modules/main.patched.bin').write_bytes(self.module)
        (self.game / 'res/values/game_name.xml').write_text(   # game_apk.resource_string 写法：XML 转义 + aapt 反斜杠转义
            '<resources><string name="game_name" translatable="false">测试 \\"A&amp;B\\" S2Arm</string></resources>', encoding='utf-8')
        self.game_png = {d: png(48 + 24 * i, (10 * i, 120, 30)) for i, d in enumerate(DENSITIES)}
        for d, data in self.game_png.items():
            (self.game / f'res/mipmap-{d}').mkdir()
            (self.game / f'res/mipmap-{d}/game_icon.png').write_bytes(data)
        self.key = self.tmp / 'key.json'

    def badging(self, apk):
        return subprocess.run([self.aapt2, 'dump', 'badging', apk], check=True, capture_output=True, text=True).stdout

    def test_assembled_identity_signature_and_entries(self):
        out = self.tmp / 'game.apk'
        result = apk_assemble.assemble(self.engine, self.game, out, self.key)
        badging = self.badging(out)
        self.assertIn("package: name='org.s2arm.game.t0100000000abcdef' versionCode='7' versionName='1.2 (S2Arm 0.1.0-dev)'", badging)
        self.assertIn('application-label:\'测试 "A&B" S2Arm\'', badging.replace('\\"', '"'))
        tree = subprocess.run([self.aapt2, 'dump', 'xmltree', '--file', 'AndroidManifest.xml', out], check=True, capture_output=True, text=True).stdout
        self.assertIn('org.s2arm.game.t0100000000abcdef.game', tree)
        self.assertIn('org.s2arm.game.t0100000000abcdef.diag', tree)
        self.assertNotIn(TEMPLATE, tree)
        self.assertIn('org.s2arm.android.GameActivity', tree, '类名不是包名派生的，不能被换')
        with zipfile.ZipFile(out) as z:
            for entry, density in self.icons.items():
                self.assertEqual(z.read(entry), self.game_png[density], entry)
            self.assertEqual(z.read('assets/game/modules/main.patched.bin'), self.module)
            infos = {i.filename: i for i in z.infolist()}
        data = out.read_bytes()
        for name, align in (('assets/game/modules/main.patched.bin', 4), ('lib/arm64-v8a/libs2arm_android.so', 16384)):
            info = infos[name]
            self.assertEqual(info.compress_type, zipfile.ZIP_STORED, name)
            start = info.header_offset + 30 + struct.unpack_from('<HH', data, info.header_offset + 26)[0] + struct.unpack_from('<HH', data, info.header_offset + 26)[1]
            self.assertEqual(start % align, 0, name)
        cert = hashlib.sha256(bytes.fromhex(json.loads(self.key.read_text())['cert'])).hexdigest()
        self.assertEqual(game_apk.apk_signer_sha256(out), cert)
        self.assertEqual(result['signingCertSha256'], cert)
        self.assertEqual(game_apk.apk_identity(out), ('org.s2arm.game.t0100000000abcdef', 7, False))
        java = subprocess.run(['bash', str(ANDROID / 'tools/jdk17.sh')], capture_output=True, text=True).stdout.strip()
        if not self.signer.is_file() or not java:
            self.skipTest('apksigner / JDK 17 not found: v2 signature not checked by the SDK verifier')
        env = dict(os.environ, JAVA_HOME=str(Path(java).parent.parent))
        verify = subprocess.run([self.signer, 'verify', '-v', out], capture_output=True, text=True, env=env)
        self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)
        self.assertIn('Verified using v2 scheme (APK Signature Scheme v2): true', verify.stdout)

    def test_same_key_reused_across_builds(self):
        a, b = self.tmp / 'a.apk', self.tmp / 'b.apk'
        first = apk_assemble.assemble(self.engine, self.game, a, self.key)
        second = apk_assemble.assemble(self.engine, self.game, b, self.key)
        self.assertEqual(first['signingCertSha256'], second['signingCertSha256'], '同一台机器再出包要同一把钥，才能覆盖装保住存档')

    def test_no_game_icon_keeps_template_icon(self):
        props = (self.game / 'game.properties').read_text().replace('launcherIcon=game', 'launcherIcon=default')
        (self.game / 'game.properties').write_text(props)
        out = self.tmp / 'game.apk'
        apk_assemble.assemble(self.engine, self.game, out, self.key)
        with zipfile.ZipFile(out) as z, zipfile.ZipFile(self.engine / 'engine.apk') as t:
            for entry in self.icons:
                self.assertEqual(z.read(entry), t.read(entry))

    def test_modified_engine_refused(self):
        with zipfile.ZipFile(self.engine / 'engine.apk', 'a') as z:
            z.writestr('extra.txt', b'x')
        with self.assertRaisesRegex(ValueError, 'SHA-256'):
            apk_assemble.assemble(self.engine, self.game, self.tmp / 'x.apk', self.key)

    def test_missing_modules_refused(self):
        (self.game / 'assets/game/modules/main.patched.bin').unlink()
        with self.assertRaisesRegex(ValueError, 'modules'):
            apk_assemble.assemble(self.engine, self.game, self.tmp / 'x.apk', self.key)
        self.assertFalse((self.tmp / 'x.apk').exists())


if __name__ == '__main__':
    unittest.main()
