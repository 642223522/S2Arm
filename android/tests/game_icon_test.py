#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""游戏 APK 输入的图标：全部使用本测试生成的合成数据。"""
import hashlib
import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

try:
    from PIL import Image
except ImportError:
    Image = None

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / 'android' / 'tools'
spec = importlib.util.spec_from_file_location('make_pack_icon_test', TOOLS / 'make_pack.py')
make_pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(make_pack)


def synthetic_png():
    def chunk(kind, payload):
        return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))
    raw = b'\0' + bytes((32, 96, 192)) * 4
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 4, 1, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


class GameIconTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def make_pack(self, icon):
        source = self.root / 'source'
        source.mkdir()
        nacp = bytearray(0x4000)
        nacp[:9] = b'Synthetic'
        struct.pack_into('<Q', nacp, 0x3038, 0x0100000000001234)
        nacp[0x3060:0x3063] = b'1.0'
        files = {'ctl/control.nacp': bytes(nacp), 'exefs/main.npdm': b'META' + bytes(0x94),
                 'modules/main.patched.bin': b'synthetic',
                 'modules/main.fixups.tsv': b'# TARGET\tandroid\n# REWRITE_ABI\tandroid-sp-safe-v1\n',
                 'modules/main.gates.tsv': b'# synthetic\n'}
        if icon is not None:
            files['icon.jpg'] = icon
        entries = []
        for name, data in files.items():
            path = source / name.replace('/', '_')
            path.write_bytes(data)
            entries.append((name, str(path)))
        pack = self.root / 'pack'
        make_pack.write_pack(str(pack), entries, False, None)
        return pack

    def run_game_apk(self, pack, out):
        return subprocess.run([sys.executable, str(TOOLS / 'game_apk.py'), str(pack), str(out)],
                              capture_output=True, text=True)

    @unittest.skipIf(Image is None, 'Pillow 不在，无法检查图标像素与缩放')
    def test_synthetic_icon_is_rendered_for_each_launcher_density(self):
        source_icon = self.root / 'synthetic.jpg'
        Image.new('RGB', (13, 17), (32, 96, 192)).save(source_icon, format='JPEG')
        pack = self.make_pack(source_icon.read_bytes())
        first, second = self.root / 'first', self.root / 'second'
        for out in (first, second):
            result = self.run_game_apk(pack, out)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for density, size in (('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)):
            a = first / 'res' / f'mipmap-{density}' / 'game_icon.png'
            b = second / 'res' / f'mipmap-{density}' / 'game_icon.png'
            self.assertTrue(a.is_file(), f'缺少 {density} 游戏图标')
            self.assertEqual(hashlib.sha256(a.read_bytes()).hexdigest(), hashlib.sha256(b.read_bytes()).hexdigest())
            data = a.read_bytes()
            self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
            chunks = []
            offset = 8
            while offset < len(data):
                length = struct.unpack_from('>I', data, offset)[0]
                chunks.append(data[offset + 4:offset + 8])
                offset += length + 12
            self.assertEqual(offset, len(data))
            self.assertNotIn(b'tIME', chunks)
            with Image.open(a) as image:
                self.assertEqual((image.format, image.size), ('PNG', (size, size)))
                pixel = image.convert('RGB').getpixel((size // 2, size // 2))
                for actual, expected in zip(pixel, (32, 96, 192)):
                    self.assertLessEqual(abs(actual - expected), 2)
        for out in (first, second):
            self.assertIn('launcherIcon=game\n', (out / 'game.properties').read_text())
            self.assertEqual((out / 'game.properties').read_bytes(), (out / 'assets/game/game.properties').read_bytes())

    def assert_fallback(self, data, reason):
        pack = self.make_pack(data)
        out = self.root / 'out'
        result = self.run_game_apk(pack, out)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('【黄】', result.stdout)
        self.assertIn(reason, result.stdout)
        self.assertIn('launcherIcon=default\n', (out / 'game.properties').read_text())
        self.assertFalse(list((out / 'res').glob('mipmap-*/game_icon.png')))

    def test_missing_icon_warns_and_uses_default(self):
        self.assert_fallback(None, '没有游戏图标')

    def test_empty_icon_warns_and_uses_default(self):
        self.assert_fallback(b'', '游戏图标为空')

    @unittest.skipIf(Image is None, 'Pillow 不在，无法验证坏图解码')
    def test_corrupt_icon_warns_and_uses_default(self):
        self.assert_fallback(b'not an image', '游戏图标打不开')

    def test_icon_symlink_is_rejected(self):
        pack = self.make_pack(None)
        target = self.root / 'synthetic.jpg'
        target.write_bytes(synthetic_png())
        (pack / 'icon.jpg').symlink_to(target)
        result = self.run_game_apk(pack, self.root / 'out')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('【红】拒绝图标链接', result.stderr)
        self.assertFalse((self.root / 'out').exists())

    def test_dangling_icon_symlink_preserves_previous_output(self):
        pack = self.make_pack(None)
        (pack / 'icon.jpg').symlink_to(self.root / 'missing.jpg')
        out = self.root / 'out'
        out.mkdir()
        (out / 'game.properties').write_text('old game')
        (out / 'sentinel').write_bytes(b'preserve')
        result = self.run_game_apk(pack, out)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('【红】拒绝图标链接', result.stderr)
        self.assertEqual((out / 'sentinel').read_bytes(), b'preserve')

    def test_missing_pillow_warns_and_keeps_default(self):
        pack = self.make_pack(synthetic_png())
        out = self.root / 'out'
        result = subprocess.run([sys.executable, '-S', str(TOOLS / 'game_apk.py'), str(pack), str(out)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('【黄】缺少 Pillow', result.stdout)
        self.assertIn('launcherIcon=default\n', (out / 'game.properties').read_text())


if __name__ == '__main__':
    unittest.main()
