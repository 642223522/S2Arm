#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Switch 2 合成控制数据进安卓出包链：应用号（0x3038）不能是 0，显示版本「?」不能让 aapt 停。

不要游戏、签名、设备：用 pack/ns2_dump.py 自己合成的控制数据，喂安卓出包链读 NACP 的两处
（game_apk.nacp_info 出 APK、stage_a0.read_nacp 装机布局）和 APK 版本文字（game_apk.apk_version）。
真机上这两处是 Switch 2 款出包的硬停：
  - ctl/control.nacp has no application id（make_pack.write_artifact / game_apk / stage_a0 都按 0x3038 认游戏）
  - aapt 把 versionName「? (S2Arm …)」当主题属性引用（?attr/…），整包出不来
"""
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path

ANDROID = Path(__file__).resolve().parents[1]
REPO = ANDROID.parent
sys.path.insert(0, str(ANDROID / 'tools'))
import game_apk    # noqa: E402
import stage_a0    # noqa: E402

# pack/ns2_dump.py 按文件路径装进来，不往 sys.path 里放 pack/（那里的同名模块会盖住 android/tools 里的）
_spec = importlib.util.spec_from_file_location('ns2_dump', REPO / 'pack' / 'ns2_dump.py')
ns2_dump = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ns2_dump)

TID = 0x0400A3A01EE4C000
TITLE = f'{TID:016X}'


def write_nacp(data):
    d = tempfile.mkdtemp()
    p = os.path.join(d, 'control.nacp')
    with open(p, 'wb') as f:
        f.write(data)
    return p


class SynthNacpTest(unittest.TestCase):
    def test_synthesized_nacp_has_application_id_for_both_android_readers(self):
        p = write_nacp(ns2_dump.synth_nacp(TID, 'x'))
        self.assertEqual(game_apk.nacp_info(p)[0], TITLE)
        self.assertEqual(stage_a0.read_nacp(p)[0], TITLE)

    def test_zero_fixed_section_gets_application_id(self):
        raw = bytearray(ns2_dump.NACP_SIZE)
        raw[0:4] = b'Game'   # 只有标题、0x3000 起全 0 的控制数据（某款 Switch 2 更新包元数据带的）
        filled, changed = ns2_dump.fill_fixed(bytes(raw), TID)
        self.assertTrue(changed)
        p = write_nacp(filled)
        self.assertEqual(game_apk.nacp_info(p)[0], TITLE)
        self.assertEqual(stage_a0.read_nacp(p)[0], TITLE)

    def test_real_nacp_is_left_byte_for_byte(self):
        raw = bytearray(ns2_dump.NACP_SIZE)
        raw[0x3060:0x3065] = b'1.2.0'   # 固定段不是全零：真原件，一字不动
        same, changed = ns2_dump.fill_fixed(bytes(raw), TID)
        self.assertFalse(changed)
        self.assertEqual(same, bytes(raw))


class ApkVersionTest(unittest.TestCase):
    def test_unknown_display_version_is_not_an_aapt_reference(self):
        for unknown in ('?', '', '  ', '??'):
            with self.subTest(version=unknown):
                text = game_apk.apk_version(unknown)
                self.assertEqual(text, 'unknown')
                self.assertFalse(text.startswith(('?', '@')))

    def test_real_version_is_kept(self):
        self.assertEqual(game_apk.apk_version('1.2.0'), '1.2.0')
        self.assertEqual(game_apk.apk_version(' 1.0 '), '1.0')

    def test_synthesized_version_reaches_game_properties_as_unknown(self):
        p = write_nacp(ns2_dump.synth_nacp(TID, 'x'))
        version = game_apk.nacp_info(p)[2]
        self.assertEqual(version, '?')   # 合成件的「不知道」标记照旧（pack/jobs/community.py 靠它认合成件），只在进 APK 时换掉
        self.assertEqual(game_apk.properties_value(game_apk.apk_version(version)), 'unknown')


if __name__ == '__main__':
    unittest.main()
