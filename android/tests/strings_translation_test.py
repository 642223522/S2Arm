#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Every translatable string exists in both languages (device-free; lint enforces the same on APK builds)."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

RES = Path(__file__).resolve().parents[1] / 'app/src/main/res'


def names(directory, translatable_only=False):
    nodes = ET.parse(RES / directory / 'strings.xml').getroot().findall('string')
    return {n.attrib['name'] for n in nodes if not (translatable_only and n.attrib.get('translatable') == 'false')}


class StringsTranslationTest(unittest.TestCase):
    def test_simplified_chinese_covers_every_translatable_string(self):
        self.assertEqual(names('values', translatable_only=True), names('values-b+zh+Hans'))


if __name__ == '__main__':
    unittest.main()
