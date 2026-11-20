#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""裁剪状态及负控；S2A_WINDOW_CROP_A64=1 时另验生产汇编和两个转发负控。

A64 模式用 CC 指定交叉编译器，S2A_WINDOW_CROP_RUNNER 指定接收本地二进制路径、
在设备执行并返回原退出码的执行器；未设置执行器时直接运行（原生 A64 宿主）。
android/test.sh 登记的是同一入口；默认宿主模式不代表 A64 ABI 验证。
"""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
a64 = os.environ.get('S2A_WINDOW_CROP_A64') == '1'
runner = shlex.split(os.environ.get('S2A_WINDOW_CROP_RUNNER', ''))
compiler = shlex.split(os.environ.get('CC', 'cc'))
with tempfile.TemporaryDirectory(prefix='s2a-native-window-') as tmp:
    tmp = Path(tmp)
    source = ROOT / 'android/native/nvn/guest_window_crop.c'
    assembly = ROOT / 'android/native/nvn/guest_window_crop.S'
    cmd = [*compiler, '-std=c11', '-O1', '-Wall', '-Wextra', '-Werror',
           '-DS2A_WINDOW_CROP_TEST=1',
           '-I' + str(ROOT / 'android/native/nvn'),
           '-I' + str(ROOT / 'runtime/include'), '-I' + str(ROOT / 'graphics/nvn/replay'),
           str(ROOT / 'android/tests/guest_window_crop_test.c')]
    if not a64:
        cmd.append('-DS2A_WINDOW_CROP_HOST_TEST=1')

    def check(name, c_source, asm_source=None, expected_error=None):
        out = tmp / name
        sources = [str(c_source)] if c_source else []
        if a64:
            sources.append(str(asm_source or assembly))
        # Android 的 pthread 在 bionic 内，没有独立的 libpthread。
        threads = [] if a64 else ['-lpthread']
        subprocess.run([*cmd, *sources, *threads, '-o', str(out)], check=True)
        result = subprocess.run([*runner, str(out)], text=True, capture_output=True, timeout=30)
        output = result.stdout + result.stderr
        if expected_error is None:
            print(output, end='')
            if result.returncode:
                raise RuntimeError(f'{name}: rc={result.returncode}')
        elif result.returncode == 0 or expected_error not in output:
            raise RuntimeError(f'{name}: negative control missed expected failure: {output}')
        else:
            print(f'PASS negative {name}: {output.strip()}')

    check('positive', source if source.is_file() else None)
    original = source.read_text()
    mutations = {
        'withdraw-watch': ('void nvn_plat_guest_window_watch(void *window) {\n',
                           'void nvn_plat_guest_window_watch(void *window) {\n    return;\n',
                           'FAIL: native crop did not reach present state'),
        'ignore-original-error': ('if (rc) return rc;', 'if (0) return rc;',
                                  '==-EIO && crop_calls==before'),
        'withdraw-clear': ('h_vi_set_layer_crop(window,0,0,0,0);', '(void)window;',
                           '!memcmp(last_crop,(int[]){0,0,0,0}')}
    for name, (before, after, error) in mutations.items():
        if before not in original:
            raise RuntimeError(f'{name}: mutation anchor missing')
        variant = tmp / f'{name}.c'
        variant.write_text(original.replace(before, after, 1))
        check(name, variant, expected_error=error)
    if a64:
        original_asm = assembly.read_text()
        for name, before, after in (
                ('swap-integer-restore', 'ldp x2,x3,[sp,#16]', 'ldp x3,x2,[sp,#16]'),
                ('swap-float-restore', 'ldp q0,q1,[sp,#80]', 'ldp q1,q0,[sp,#80]')):
            if before not in original_asm:
                raise RuntimeError(f'{name}: mutation anchor missing')
            variant = tmp / f'{name}.S'
            variant.write_text(original_asm.replace(before, after, 1))
            check(name, source, variant, 'FAIL line')
    else:
        print('A64 production assembly: not run (set S2A_WINDOW_CROP_A64=1 with compiler/runner)')
