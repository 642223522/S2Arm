"""Shared synthetic identity contract; never read local Switch key files."""
from collections import defaultdict
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import redact

CASES = Path(__file__).parent / 'fixtures' / 'redact_cases.tsv'
CATEGORIES = {'email', 'team', 'bundle', 'udid', 'udid_legacy', 'device_name'}


def load_cases(path=CASES):
    lines = path.read_text(encoding='utf-8').splitlines()
    if not lines or lines[0] != 'category\tinput\texpected':
        raise ValueError('invalid redaction fixture header')
    rows = []
    for number, line in enumerate(lines[1:], 2):
        if not line or line.startswith('#'):
            continue
        fields = line.split('\t')
        if len(fields) != 3 or fields[0] not in CATEGORIES:
            raise ValueError(f'invalid redaction fixture line {number}')
        rows.append((number, *fields))
    return rows


class PathReasonTests(unittest.TestCase):
    """路径脱敏保留系统错误原因（11-09 旷野之息 Mac 出包「拷字体失败」前 7 行 cp 报错整行变成 [PRIVATE_PATH]，看不出是没权限还是别的）。
    期望手写：路径换成占位，末尾「: <系统错误原文>」原样保留；不在原文表里的冒号尾巴照旧算路径的一部分（免得漏出名字）"""
    def test_keeps_errno_reason(self):
        cases = [
            ("cp: /private/var/Game Disk/S2Arm 库/systemdata/fonts/a.bfttf: Operation not permitted", "cp: [PRIVATE_PATH]: Operation not permitted"),
            ("cp: /private/var/joe/Downloads/字体/a.bfttf: Permission denied", "cp: [PRIVATE_PATH]: Permission denied"),
            ("cp: /private/var/joe/S2Arm/游戏库/cache/x/systemdata/fonts/nintendo_ext2_003.bfttf: clonefile failed: Cross-device link",
             "cp: [PRIVATE_PATH]: clonefile failed: Cross-device link"),   # #290 原文形态（旧 macOS cp -c 跨卷不退回普通复制）
            ("cp: /private/var/joe/a.bfttf: /private/var/X/b.bfttf: No space left on device", "cp: [PRIVATE_PATH]: No space left on device"),
            ("cp: /private/var/joe/Library/x: No such file or directory", "cp: [PRIVATE_PATH]: No such file or directory"),
            ("cp: /private/var/joe/My Game: Director Cut/a.xci", "cp: [PRIVATE_PATH]"),
            ("cp: /private/var/joe/Secret Name: Operation not permitted here", "cp: [PRIVATE_PATH]"),
        ]
        for original, expected in cases:
            with self.subTest(original=original):
                self.assertEqual(redact.redact_text(original, key_values=()), expected)

    def test_keeps_measurement_tail(self):
        """路径后面我方日志接着写的读数（耗时 / 大小 / 百分比）只抹路径、读数留下：诊断#343862 里「存档提交 #N：<路径> 克隆 + 原子交换 X ms」
        整段成了「存档提交 #1：[PRIVATE_PATH]」，查存档耗时拿不到数。期望手写：路径换占位，「 克隆 + 原子交换 25.5 ms」原样保留；
        尾巴里只许中文词、符号、数字和单位，英文单词与斜杠照旧算路径（免得漏出带空格的目录名）"""
        ios = "/var/mobile/Containers/Data/Application/0F4E7C1A-2B3D-4E5F-8A9B-C0D1E2F3A4B5/Documents/S2A/ryujinx/bis/system/save/8000000000000000"
        cases = [
            (f"00:00:00.110 |I| ServiceFs CommitLocked: 存档提交 #1：{ios} 克隆 + 原子交换 25.5 ms",
             "00:00:00.110 |I| ServiceFs CommitLocked: 存档提交 #1：[PRIVATE_PATH] 克隆 + 原子交换 25.5 ms"),
            ("存档提交 #12：/private/var/Game Disk/S2Arm/games/0100A/SaveData 克隆 + 原子交换 3.0 ms",
             "存档提交 #12：[PRIVATE_PATH] 克隆 + 原子交换 3.0 ms"),
            ("写盘 /private/var/Game Disk/S2Arm 库/x.img 1,024 MB", "写盘 [PRIVATE_PATH] 1,024 MB"),
            ("/private/var/joe/My Game 2/a.xci", "[PRIVATE_PATH]"),
            ("/private/var/joe smith/Movie Night 12 ms", "[PRIVATE_PATH] 12 ms"),   # 只有数字 + 单位能留在外面：英文单词「Night」照旧在占位里
            ("/private/var/joe/a.img 用时 1.5 秒", "[PRIVATE_PATH] 用时 1.5 秒"),
            ("pipeline prewarm list /var/mobile/x/pso.tsv: 1834 lines", "pipeline prewarm list [PRIVATE_PATH] 1834 lines"),   # nvn_mtl.m 的形态
            ("写入 /private/var/X/S2Arm/a.img（12.5 MB）", "写入 [PRIVATE_PATH]（12.5 MB）"),
        ]
        for original, expected in cases:
            with self.subTest(original=original):
                self.assertEqual(redact.redact_text(original, key_values=()), expected)


class ExactNameAllowTests(unittest.TestCase):
    """按确切名字放行两样不是机密的值（维护者 11-19 定：不放宽密钥名规则本身）：key=（着色器 / 管线缓存键，代码内容的哈希；
    诊断里 17 万行全成了 key=[REDACTED]）和 binaryUUID（我们自己二进制的构建号，崩溃符号化要用）。
    期望手写：放行项原样留下；真 prod.keys / title.keys 行、密钥原值、别的密钥名照旧抹掉"""
    def test_allowed_exact_names_kept(self):
        kept = [
            "[pass] F3600 K 10728 st5 key=1cdff916cd3c5dab nb=8",                    # nvn_mtl.m PD("K %llu st%d key=%s nb=%d")
            "[s2a] direct attempt finish: held=1 normal=0 key=0100A00019DE0000-9f2c",  # selection.c
            '        "binaryUUID" : "6C1E8F2A-1B3C-4D5E-8F9A-0B1C2D3E4F5A",',          # MetricKit 崩溃报告
            '{"binaryUUID":"6C1E8F2A-1B3C-4D5E-8F9A-0B1C2D3E4F5A","offsetIntoBinaryTextSegment":4812}',
        ]
        for line in kept:
            with self.subTest(line=line):
                self.assertEqual(redact.redact_text(line, key_values=()), line)

    def test_real_key_files_and_other_names_still_redacted(self):
        hex32, hex64 = "0123456789abcdef" * 2, "fedcba9876543210" * 4
        cases = [
            (f"header_key = {hex64}", "header_key = [REDACTED]"),                                  # prod.keys
            (f"master_key_0f = {hex32}", "master_key_0f = [REDACTED]"),                           # prod.keys
            (f"aes_kek_generation_source = {hex32}", "aes_kek_generation_source = [REDACTED]"),   # prod.keys
            (f"0100a1b2c3d4e5f60000000000000003 = {hex32}", "0100a1b2c3d4e5f60000000000000003 = [REDACTED]"),   # title.keys：权利号 = 标题密钥
            ("writer_key=1cdff916cd3c5dab", "writer_key=[REDACTED]"),
            (f"titlekey={hex32}", "titlekey=[REDACTED]"),   # 标题密钥是 32 位十六进制
            ("titlekey=1cdff916cd3c5dab", "titlekey=[REDACTED]"),   # 截断显示的半个标题密钥也算泄漏：不管多长都抹
            ("titleKey: 1cdff916", "titleKey: [REDACTED]"),
            ('"uuid":"6C1E8F2A-1B3C-4D5E-8F9A-0B1C2D3E4F5A"', '"uuid":"[REDACTED]"'),
            ("deviceUUID=6C1E8F2A-1B3C-4D5E-8F9A-0B1C2D3E4F5A", "deviceUUID=[REDACTED]"),
        ]
        for original, expected in cases:
            with self.subTest(original=original):
                self.assertEqual(redact.redact_text(original, key_values=()), expected)
        # 放行的是名字、不是值：真密钥原值写在 key= 后面照样按值抹（启动器打包诊断时带本机 prod.keys 的值）
        self.assertEqual(redact.redact_text(f"key={hex32}", key_values=(hex32,)), "key=[REDACTED]")


class RedactCasesTests(unittest.TestCase):
    def test_shared_cases(self):
        coverage = defaultdict(list)
        with patch.object(redact, 'load_key_values', side_effect=AssertionError('must not read keys')):
            for number, category, original, expected in load_cases():
                with self.subTest(line=number, category=category):
                    self.assertEqual(redact.redact_text(original, key_values=()), expected)
                    self.assertEqual(redact.redact_text(original, key_values=(), preserve_identity=True), expected)
                coverage[category].append(original != expected)
        self.assertEqual(set(coverage), CATEGORIES)
        for category, values in coverage.items():
            with self.subTest(coverage=category):
                self.assertGreaterEqual(len(values), 2)
                self.assertIn(True, values)
                self.assertIn(False, values)

    def test_legacy_context_does_not_cross_lines(self):
        value = '0123456789abcdef0123456789abcdef01234567'
        for newline in ('\n', '\r', '\r\n'):
            original = 'device connected' + newline + 'commit ' + value
            self.assertEqual(redact.redact_identity(original), original)
            original = 'device ' + value + newline + 'commit ' + value
            self.assertEqual(redact.redact_identity(original),
                             'device [DEVICE_ID]' + newline + 'commit ' + value)

    def test_unquoted_secret_keeps_bracket_inside_the_value(self):
        # A literal ']' is not a delimiter in an unquoted secret token.
        for key in ('password', 'token', 'serial'):
            with self.subTest(key=key):
                self.assertEqual(redact.redact_assignments(key + '=ab]PrivateTail'),
                                 key + '=[REDACTED]')
                self.assertEqual(redact.redact_text(key + '=ab]PrivateTail', key_values=()),
                                 key + '=[REDACTED]')

    def test_known_key_values_still_win(self):
        known = 'synth@example.invalid'
        self.assertEqual(redact.redact_text(known, key_values={known}), '[REDACTED]')


if __name__ == '__main__':
    unittest.main()
