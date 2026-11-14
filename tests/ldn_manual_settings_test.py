# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""跨平台可跑的最小接线检查；不代替 Apple 设置单测或双机联机。"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ManualLdnWiring(unittest.TestCase):
    def test_ios_applies_global_multiplayer_before_service_start(self):
        source = (ROOT / 'ios/settings.m').read_text(encoding='utf-8')
        self.assertIn('void s2a_ios_apply_ldn_settings(NSUserDefaults *defaults)', source)
        self.assertIn('s2a_ios_apply_ldn_settings(NSUserDefaults.standardUserDefaults);', source)
        for key in ('S2ALdnMode', 'S2ALdnHost', 'S2ALdnAddress',
                    'S2A_LDN_SERVER', 'S2A_LDN_RELAY', 'S2A_LDN_LISTEN'):
            self.assertIn(key, source)

    def test_relay_has_independent_listen_address(self):
        source = (ROOT / 'services/S2A.Services/Host.cs').read_text(encoding='utf-8')
        self.assertIn('Environment.GetEnvironmentVariable("S2A_LDN_LISTEN")', source)
        self.assertIn('System.Net.IPAddress.TryParse(listen, out address)', source)


if __name__ == '__main__':
    unittest.main()
