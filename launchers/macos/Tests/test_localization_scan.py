"""Host-only localization audit/regression tests; no AppKit or game resources."""
import json
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CommunityTranslationTest(unittest.TestCase):
    def test_community_translations(self):
        entries = json.loads((ROOT / 'adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json').read_text())
        actual = {entry['source']: entry['en'] for entry in entries}
        expected = {
            '社区资源': 'Community resources',
            '社区资源说明': 'About community resources',
            '这款没有宽屏表': 'No widescreen table for this game',
        }
        for source, english in expected.items():
            with self.subTest(source=source):
                self.assertEqual(actual.get(source), english)


    def test_community_remaining_missing_literals(self):
        entries = json.loads((ROOT / 'adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json').read_text())
        actual = {entry['source']: entry['en'] for entry in entries}
        expected = {
            '宽屏': 'Widescreen',
            '60 帧': '60 FPS',
            '这款没有 60 帧表': 'No 60 FPS table for this game',
            '宽屏和 60 帧会提高系统负载和耗电，换取更好的游玩体验，低配设备请谨慎选择。': 'Widescreen and 60 FPS improve the experience but increase system load and power use. Use with care on less powerful devices.',
            '改完下次启动生效，不用重新打包。': 'Changes take effect on the next launch. No rebuild needed.',
            '打包时命中社区或你导入的着色器缓存会自动并入，首次进游戏更顺。': 'Matching community or imported shader caches are included automatically when building, for a smoother first launch.',
            '导入自己的 yuzu / Ryujinx 着色器缓存…': 'Import your yuzu / Ryujinx shader cache…',
            '缓存要和你的游戏版本一致才有用。': 'The cache must match your game version to be useful.',
            '选 yuzu / Eden / suyu / sudachi 的 vulkan.bin、opengl.bin，或 Ryujinx 的着色器缓存目录（含 shared.toc / guest.toc）': 'Choose vulkan.bin or opengl.bin from yuzu / Eden / suyu / sudachi, or a Ryujinx shader cache folder containing shared.toc / guest.toc.',
            '已导入：': 'Imported: ',
            '，下次打包时并入': '; will be included in the next build',
            '没导入 ': 'Not imported: ',
            'S2Arm 已验证': 'Verified by S2Arm',
            '社区：': 'Community: ',
            ' 等': ' and others',
            '版本与你的游戏不同，打包时按特征跨版本定位': 'The version differs from your game. Matching across versions is performed during the build.',
            '画面': 'Graphics',
            '没有可用补丁': 'No patches available',
            '已验证': 'Verified',
            '社区未验证': 'Not verified by the community',
            '补丁一律打进包里，宽屏和 60 帧在这里（或 iPhone 的 App 设置）开关，下次启动生效，不用重新打包。': 'All patches are included in the build. Toggle widescreen and 60 FPS here (or in the iPhone app settings). Changes take effect on the next launch without rebuilding.',
        }
        for source, english in expected.items():
            with self.subTest(source=source):
                self.assertEqual(actual.get(source), english)

    def test_community_has_no_missing_literal(self):
        entries = json.loads((ROOT / 'adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json').read_text())
        entries += scan.shared_entries(json.loads((ROOT.parent / 'shared/experience.v1.json').read_text()))
        rows = scan.audit((ROOT / 'Sources/S2ArmLauncher/CommunityView.swift').read_text(), entries)
        self.assertEqual([r['source'] for r in rows if r['status'] == 'missing'], [])


spec = importlib.util.spec_from_file_location('check_localization', ROOT / 'check_localization.py')
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)


class ScannerTest(unittest.TestCase):
    def statuses(self, text, entries=None):
        return [(row['source'], row['status']) for row in scan.audit(text, entries or [])]

    def test_exact_and_missing_negative_control(self):
        text = 'L("社区资源")'
        entry = {'source': '社区资源', 'en': 'Community resources'}
        self.assertEqual(self.statuses(text, [entry]), [('社区资源', 'covered')])
        self.assertEqual(self.statuses(text), [('社区资源', 'missing')])
        self.assertEqual(self.statuses(text, [dict(entry, source='社区')]), [('社区资源', 'missing')])

    def test_comments_strings_and_member_calls(self):
        text = '\n// L("假一")\n/* L("假二") /* L("假三") */ */\nlet s = "L(\\"假四\\")"; object.L("假五"); func L(_ x: String) {}\nL("真")'
        rows = scan.audit(text, [])
        self.assertEqual([(x['line'], x['source'], x['status']) for x in rows], [(5, '真', 'missing')])

    def test_fallback_is_manual_not_coverage(self):
        entries = [{'source': '错误：{0}', 'en': 'Error: {0}'}]
        self.assertEqual(self.statuses('L("错误：中文")', entries), [('错误：中文', 'manual')])
        self.assertEqual(self.statuses('L("甲；乙")'), [('甲；乙', 'manual')])
        self.assertEqual(self.statuses(r'L("甲\n乙")'), [('甲\n乙', 'manual')])
        self.assertEqual(self.statuses('L("其他错误")', entries), [('其他错误', 'missing')])

    def test_dynamic_raw_multiline_and_concat_are_manual(self):
        for text in ('L(value)', 'L("甲" + value)', r'L("甲\(value)")',
                     'L(#"甲"#)', 'L("""甲""")', r'L("甲\(f("内"))尾")'):
            with self.subTest(text=text):
                self.assertEqual(self.statuses(text), [(None, 'manual')])

    def test_unicode_and_escaped_quotes(self):
        self.assertEqual(self.statuses(r'L("\u{7532}\"乙")'), [('甲"乙', 'missing')])
        self.assertEqual(self.statuses('L("English")'), [('English', 'unchanged')])
        self.assertEqual(self.statuses(r'L("\q")'), [(None, 'manual')])

    def test_intentional_empty_translation_is_valid_exact(self):
        self.assertEqual(self.statuses('L(" 完成")', [{'source': ' 完成', 'en': ''}]), [(' 完成', 'covered')])

    def test_shared_runtime_subset_not_all_bilingual_objects(self):
        spec = json.loads((ROOT.parent / 'shared/experience.v1.json').read_text())
        actual = {entry['source'] for entry in scan.shared_entries(spec)}
        self.assertIn('直连', actual)
        self.assertIn('运行中', actual)
        self.assertNotIn('空闲', actual)  # idle.title exists but is not registered by Swift

    def test_malformed_catalog_rejected(self):
        for entries in ({}, [{'source': '已知'}], [{'source': '已知', 'en': 3}]):
            with self.subTest(entries=entries), self.assertRaises(ValueError):
                scan.audit('L("已知")', entries)
        with tempfile.TemporaryDirectory() as directory:
            catalog = Path(directory) / 'catalog.json'
            source = Path(directory) / 'synthetic.swift'
            source.write_text('L("已知")')
            catalog.write_text('[{"source": "已知", "en": 3}]')
            result = subprocess.run([sys.executable, '-B', str(ROOT / 'check_localization.py'),
                                     '--catalog', str(catalog), str(source)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('source/en string', result.stderr)

    def test_missing_inventory_matches_reviewed_baseline(self):
        entries = json.loads((ROOT / 'adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json').read_text())
        entries += scan.shared_entries(json.loads((ROOT.parent / 'shared/experience.v1.json').read_text()))
        sources = {str(path.relative_to(ROOT)): path.read_text()
                   for path in sorted((ROOT / 'Sources/S2ArmLauncher').rglob('*.swift'))}
        baseline = json.loads((ROOT / 'Tests/localization_missing_baseline.json').read_text())
        self.assertEqual(scan.missing_inventory(sources, entries), baseline,
                         'New OR resolved localization gaps: review the exact baseline; do not auto-accept.')

    def test_inventory_negative_controls(self):
        baseline = [{'path': 'View.swift', 'source': '旧缺译', 'count': 1}]
        self.assertEqual(scan.missing_inventory({'View.swift': 'L("旧缺译")'}, []), baseline)
        # Line shifts are harmless; an added/replaced/moved/duplicated gap is not.
        self.assertEqual(scan.missing_inventory({'View.swift': '\n\nL("旧缺译")'}, []), baseline)
        for sources in ({'View.swift': 'L("旧缺译"); L("新缺译")'},
                        {'View.swift': 'L("新缺译")'},  # same count must not conceal replacement
                        {'Other.swift': 'L("旧缺译")'},
                        {'View.swift': 'L("旧缺译"); L("旧缺译")'}):
            with self.subTest(sources=sources), self.assertRaises(AssertionError):
                self.assertEqual(scan.missing_inventory(sources, []), baseline)
        # A resolved gap must shrink the reviewed baseline, not retain a stale exemption.
        with self.assertRaises(AssertionError):
            self.assertEqual(scan.missing_inventory({'View.swift': 'L("旧缺译")'},
                             [{'source': '旧缺译', 'en': 'Translated'}]), baseline)

    def test_cli_exit_codes_and_synthetic_input(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'synthetic.swift'
            source.write_text('L("社区资源")')
            command = [sys.executable, '-B', str(ROOT / 'check_localization.py'), str(source)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['counts']['covered'], 1)
            source.write_text('L("合成的未登记文本")')
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)['counts']['missing'], 1)
            source.write_text('L("unterminated')
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('input error', result.stderr)


if __name__ == '__main__':
    unittest.main()
