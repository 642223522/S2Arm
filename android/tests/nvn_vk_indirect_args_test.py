#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""间接参数的权威字节：真实帧队列源码 + Vulkan 替身；三个变异各去掉一条规则，必须被测试抓到。
不需要设备、NDK 或游戏数据；只需要宿主 cc。"""
import shutil, subprocess, sys, tempfile, unittest
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SOURCE = HERE.parent / 'native/nvn/nvn_vk_first_draw.c'
MUTATIONS = {
    # 本帧可写影子：不先等本帧在途工作完成就读影子（读到 GPU 还没写完的字节）。
    'no_sync_before_shadow': (
        'if (nvn_vk_first_draw_pass_break(1) != 0) {\n            fail(why, why_size, "indirect arguments are GPU-written',
        'if (0) {\n            fail(why, why_size, "indirect arguments are GPU-written'),
    # 在途延迟帧的可写影子：不先退休回写就让调用方读 guest（旧字节）。
    'no_retire_inflight': (
        'if (nvn_vk_first_draw_retire_all() != 0) {\n                fail(why, why_size, "indirect arguments were written by a frame still in flight',
        'if (0) {\n                fail(why, why_size, "indirect arguments were written by a frame still in flight'),
    # 只读影子（guest 的拷贝）被当成权威：触发无谓的同步，并可能读到比 guest 旧的拷贝。
    'readonly_shadow_authority': (
        '    if (!w->writable || !w->guest) return 0;\n    for (uint32_t j',
        '    if (!w->guest) return 0;\n    if (addr < w->guest + w->size && w->guest < addr + len) return 1;\n    for (uint32_t j'),
}
class IndirectArgsTest(unittest.TestCase):
    def test_authority_and_mutants(self):
        cc = shutil.which('cc')
        self.assertIsNotNone(cc)
        includes = [HERE/'vkhost', HERE/'hostvk', HERE.parent/'native', HERE.parent/'native/direct', HERE.parent/'native/nvn', ROOT/'runtime/include', ROOT/'graphics/nvn/gfx/nvn', ROOT/'graphics/nvn/gfx/nvn/include', ROOT/'graphics/nvn/gfx/tex', ROOT/'graphics/nvn/third_party/vulkan-headers/include']
        source = SOURCE.read_text()
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            targets = [('production', SOURCE, True)]
            for name, (old, new) in MUTATIONS.items():
                self.assertEqual(source.count(old), 1, name)
                mutant = td/(name + '.c')
                mutant.write_text(source.replace(old, new))
                targets.append((name, mutant, False))
            for name, target, expect_success in targets:
                with self.subTest(name=name):
                    binary = td/name
                    cmd = [cc, '-std=gnu11', '-ffunction-sections', '-fdata-sections'] + [f'-I{x}' for x in includes] + [f'-DFIRST_DRAW_SOURCE="{target}"', str(HERE/'nvn_vk_indirect_args_test.c'), ('-Wl,-dead_strip' if sys.platform == 'darwin' else '-Wl,--gc-sections'), '-o', str(binary)]
                    if sys.platform == 'darwin': cmd.append('-Wl,-undefined,dynamic_lookup')
                    subprocess.run(cmd, check=True, capture_output=True)
                    result = subprocess.run([str(binary)], capture_output=True, text=True)
                    if expect_success:
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    else:
                        self.assertNotEqual(result.returncode, 0, name + ' escaped the indirect-args assertions')
                    print(name, result.returncode, (result.stdout or result.stderr).strip().splitlines()[-1:])
if __name__ == '__main__': unittest.main()
