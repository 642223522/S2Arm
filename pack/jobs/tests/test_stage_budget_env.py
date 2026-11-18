# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""GUI 自动并发不能以通用 J 覆盖阶段内存预算；只运行真实环境生成与 shell 参数赋值，不出包。"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'pack/jobs'))
sys.path.insert(0, str(ROOT))
from core import Context
import ipa
from pack.orch import oneclick_win


class StageBudgetEnv(unittest.TestCase):
    def gui_env(self, root, inherited=None):
        context = SimpleNamespace(work_root=root / 'work', r={}, default_developer=None,
                                  logs=root / 'logs', task='budget-test', private=root, engine=ROOT)
        with patch.dict(os.environ, inherited or {}, clear=True), patch('core.os.cpu_count', return_value=8):
            return Context.env(context)

    def budgets(self, env, memory, lanes=1, explicit=None, cpu=8, avail=None):
        # 执行生产阶段的实际参数赋值，避免测试自己复制 J 的优先级。
        extract = re.search(r'^J=\$\{J:-.*?;', (ROOT / 'pack/stage_extract.sh').read_text(), re.M).group()[:-1]
        direct = re.findall(r'CT=\$\{J:-[^\n;]+', (ROOT / 'pack/refresh.sh').read_text())
        self.assertEqual(len(direct), 2)  # Android 与 Apple 的两处消费者。
        script = 'source "$1/tools/cores.sh"; s2a_lanes() { echo "$S2A_LANES"; }; s2a_cores || exit; ( ' + extract + '; printf "%s " "$J" ); '
        script += '; '.join(x + '; printf "%s " "$CT"' for x in direct)
        env = dict(env, S2A_NICE='0', S2A_CORES_QUIET='1', S2A_NCPU=str(cpu),
                   S2A_MEM_TOTAL_GB=str(memory), S2A_LANES=str(lanes),
                   S2A_MEM_AVAIL_MB=str(memory * 1024 if avail is None else avail))   # 此刻可用内存：缺省 = 整机空闲
        env.pop('S2A_JOBS', None)  # 实跑 cores 的 CPU/道数分配；只替换活跃道数探测，不写真实登记。
        if explicit is not None:
            env['J'] = str(explicit)
        result = subprocess.run(['/bin/bash', '-c', script, 'budget-test', str(ROOT), str(explicit)],
                                env=env, capture_output=True, text=True, check=True)
        return tuple(map(int, result.stdout.split()))

    def test_gui_automatic_stage_budgets(self):
        with tempfile.TemporaryDirectory() as d:
            env = self.gui_env(Path(d))
            # 内存预算 am = min(物理 × 3/4 ÷ 道数, 可用 ÷ 2)；重活 = min(核, am ÷ 1536)；直连 = min(核, 1 + (am − 2805) ÷ 420)，都下限 1（手算见各行）
            #   8 GB：am = min(6144, 4096) = 4096 → 重活 2、直连 1 + 1291 // 420 = 4；16 GB：am = 8192 → 5、8；48 GB：am = 24576 → 8、8；
            #   8 GB 两道：am = min(3072, 4096) = 3072 → 2、1 + 267 // 420 = 1
            for memory, lanes, expected in [(8, 1, (2, 4, 4)), (16, 1, (5, 8, 8)),
                                             (48, 1, (8, 8, 8)), (8, 2, (2, 1, 1))]:
                with self.subTest(memory=memory, lanes=lanes):
                    self.assertEqual(self.budgets(env, memory, lanes), expected)

    def test_gui_auto_budget_can_exceed_legacy_eight(self):
        with tempfile.TemporaryDirectory() as d:
            env = self.gui_env(Path(d))
            # 10 核 16 GB：am = 8192 → 重活 5、直连 1 + 5387 // 420 = 13 → 10；16 核 48 GB 全空：am = 24576 → 16、16
            for cpu, memory, expected in [(10, 16, (5, 10, 10)), (16, 48, (16, 16, 16))]:
                with self.subTest(cpu=cpu, memory=memory):
                    self.assertEqual(self.budgets(env, memory, cpu=cpu), expected)

    def test_budget_follows_available_memory(self):
        # #1439 / #1442 / #1443：路数按此刻可用内存封顶（别的出包 / 玩家的程序已占的不算本单的）。期望手算：
        #   16 核 48 GB、可用 40 GB：am = min(36864, 20480) = 20480 → 重活 13、直连 1 + 17675 // 420 = 43 → 16
        #   16 核 48 GB、另一单已占、可用 20 GB：am = 10240 → 重活 6、直连 1 + 7435 // 420 = 18 → 16
        #   8 核 8 GB、可用 2.5 GB：am = 1280 → 重活 0 → 下限 1、直连 1 + (1280 − 2805) // 420 < 1 → 1
        #   10 核 32 GB（#1439 那台）、可用 24 GB：am = 12288 → 重活 8、直连 1 + 9483 // 420 = 23 → 10
        with tempfile.TemporaryDirectory() as d:
            env = self.gui_env(Path(d))
            for cpu, memory, avail, expected in [(16, 48, 40960, (13, 16, 16)), (16, 48, 20480, (6, 16, 16)),
                                                 (8, 8, 2560, (1, 1, 1)), (10, 32, 24576, (8, 10, 10))]:
                with self.subTest(cpu=cpu, memory=memory, avail=avail):
                    self.assertEqual(self.budgets(env, memory, cpu=cpu, avail=avail), expected)

    def test_gui_ignores_unrelated_inherited_j(self):
        with tempfile.TemporaryDirectory() as d:
            for value in ['True', '0', '-1', '9999', '2']:
                with self.subTest(value=value):
                    env = self.gui_env(Path(d), {'J': value})
                    self.assertNotIn('J', env)
                    self.assertEqual(self.budgets(env, 8), (2, 4, 4))

    def test_direct_cli_explicit_j_is_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            env = {}  # 直接 CLI 调用，完全不经过 GUI 环境生成边界。
            for jobs in [2, 12]:
                with self.subTest(jobs=jobs):
                    self.assertEqual(self.budgets(env, 8, explicit=jobs), (jobs, jobs, jobs))

    def test_windows_gui_adapter_does_not_require_j(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            env = self.gui_env(root)
            context = SimpleNamespace(engine=ROOT, run=Mock(), keys=root / 'keys/prod.keys')
            with patch.object(ipa, 'bundled_shell', return_value=root / 'shell'):
                ipa.win_oneclick(context, None, root / 'extract', root / 'fonts', root / 'out',
                                 root / 'events', root / 'log', env, None)
            args, kwargs = context.run.call_args
            self.assertIn('pack.orch.oneclick_win', args[0])
            self.assertNotIn('--jobs', args[0])  # GUI 未提供此接口，继续由 Windows CLI 选默认值。
            self.assertNotIn('J', args[2])

    def test_windows_direct_receives_explicit_cli_jobs(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            run = SimpleNamespace(out=root, step=lambda label, action: action(), sh=Mock(), say=Mock())
            (root / 'metal').mkdir(); (root / 'metal' / 'metal.exe').write_bytes(b'')
            with patch.object(oneclick_win, 'WIN', True), \
                 patch.object(oneclick_win, 'prebuilt', return_value=root / 'prebuilt'), \
                 patch.object(oneclick_win, 'metal_bin', return_value=root / 'metal'), \
                 patch.object(oneclick_win, 'metal_exe', return_value=root / 'metal' / 'metal.exe'), \
                 patch.object(oneclick_win, 'pso_sources', return_value=None), \
                 patch.object(oneclick_win, 'bash_exe', return_value='/bin/bash'), \
                 patch.dict(os.environ, {'S2A_MEM_TOTAL_GB': '16'}, clear=True):
                # #711：按内存封顶（同 tools/cores.sh）。16 GB：抽取 12 × 2 // 3 = 8 路、直连库 1 + (12288 − 2805) // 420 = 23 路，再与核数取小
                for jobs, bake, j in [(2, 2, 2), (12, 8, 12), (32, 8, 23)]:
                    with self.subTest(jobs=jobs):
                        oneclick_win.direct(run, root / 'input', 'ios', jobs)
                        actual = run.sh.call_args.kwargs['env']
                        self.assertEqual(actual['J'], str(j))
                        self.assertEqual(actual['S2A_CPU_BAKE'], str(bake))

    def test_windows_without_metal_packs_without_shader_library(self):
        # 诊断#9478d5（11-14）：Windows 没找到 Metal 开发工具时原先整单退 75、什么都不出。物理上做得下去（product 收 dlib=None，游戏里现编），
        #   期望手写：direct 返回 None、直连库脚本一次都没跑、说一行【黄】（带没找到的目录和「装好后重新出包」）、事件记 direct_skipped
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            run = SimpleNamespace(out=root, step=lambda label, action: action(), sh=Mock(), say=Mock(), ev=Mock())
            with patch.object(oneclick_win, 'WIN', True), \
                 patch.object(oneclick_win, 'metal_exe', return_value=root / 'nometal' / 'metal.exe'):
                self.assertIsNone(oneclick_win.direct(run, root / 'input', 'ios', 4))
            run.sh.assert_not_called()
            said = [c.args[0] for c in run.say.call_args_list]
            self.assertEqual(len(said), 1)
            self.assertTrue(said[0].startswith('【黄】') and str(root / 'nometal') in said[0] and '重新出包' in said[0], said[0])
            run.ev.assert_called_once_with('direct_skipped', reason='metal_missing')


if __name__ == '__main__':
    unittest.main()
