#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Release LDN settings contract: real Java policy plus Android startup wiring."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ANDROID = Path(__file__).resolve().parents[1]
JAVA = ANDROID / 'app/src/main/java/org/s2arm/android'


class LdnSettingsTest(unittest.TestCase):
    def test_release_startup_wiring(self):
        main = (JAVA / 'MainActivity.java').read_text(encoding='utf-8')
        self.assertIn('AndroidLdnSettings.apply(this, getIntent());', main)
        self.assertLess(main.index('AndroidLdnSettings.apply(this, getIntent());'), main.index('NativeBridge.createGame()'))
        activity = (JAVA / 'GameActivity.java').read_text(encoding='utf-8')
        self.assertIn('AndroidLdnSettings.copyToLaunch(context, intent);', activity)
        library = (JAVA / 'LibraryActivity.java').read_text(encoding='utf-8')
        self.assertIn('AndroidLdnSettings.show(this)', library)

    def test_cold_snapshot_and_resume_contract(self):
        adapter = (JAVA / 'AndroidLdnSettings.java').read_text(encoding='utf-8')
        self.assertIn('intent.putExtra(MODE, settings.mode)', adapter)
        self.assertIn('intent.putExtra(ADDRESS, settings.address)', adapter)
        self.assertIn('intent.getStringExtra(MODE), intent.getStringExtra(ADDRESS)', adapter)
        self.assertIn('if (applied) return;', adapter)
        self.assertIn('Os.setenv(key, value, true)', adapter)
        self.assertNotIn('BuildConfig.DEBUG', adapter)
        main = (JAVA / 'MainActivity.java').read_text(encoding='utf-8')
        self.assertNotIn('AndroidLdnSettings.apply', main[main.index('@Override protected void onNewIntent'):])
        icon = (JAVA / 'IconEntryActivity.java').read_text(encoding='utf-8')
        self.assertNotIn('AndroidLdnSettings', icon)
        self.assertIn('ICON_RESUME_EXTRA', icon)

    def run_policy(self, mutation=None):
        source = (JAVA / 'LdnSettings.java').read_text(encoding='utf-8')
        if mutation:
            self.assertIn(mutation[0], source)
            source = source.replace(*mutation)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            policy = root / 'LdnSettings.java'
            policy.write_text(source, encoding='utf-8')
            subprocess.run(['javac', '-encoding', 'UTF-8', '-d', tmp, str(policy), str(ANDROID / 'tests/LdnSettingsTest.java')], check=True)
            return subprocess.run(['java', '-ea', '-cp', tmp, 'org.s2arm.android.LdnSettingsTest'], capture_output=True, text=True)

    def test_policy(self):
        result = self.run_policy()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_ipv4_negative_control(self):
        result = self.run_policy(('if (value > 255) return AddressError.INVALID;', 'if (value > 999) return AddressError.INVALID;'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('invalid IPv4 accepted: 256.1.2.3', result.stderr)

    def test_tcp_port_negative_control(self):
        result = self.run_policy(('connector.connect(address, 30456, 3000);', 'connector.connect(address, 30457, 3000);'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('probe must use relay TCP port', result.stderr)

    def test_client_relay_negative_control(self):
        result = self.run_policy(('env.set("S2A_LDN_RELAY", "0");', 'env.set("S2A_LDN_RELAY", "1");'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('client environment', result.stderr)


if __name__ == '__main__':
    unittest.main()
