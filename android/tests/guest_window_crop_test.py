#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""标准窗口裁剪的宿主合同；A64 回调寄存器/栈转发另在设备用同夹具验证。"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='s2a-native-window-') as tmp:
    out = Path(tmp) / 'test'
    source = ROOT / 'android/native/nvn/guest_window_crop.c'
    cmd = [os.environ.get('CC', 'cc'), '-std=c11', '-O1', '-Wall', '-Wextra', '-Werror',
           '-DS2A_WINDOW_CROP_TEST=1', '-DS2A_WINDOW_CROP_HOST_TEST=1',
           '-I' + str(ROOT / 'android/native/nvn'),
           '-I' + str(ROOT / 'runtime/include'), '-I' + str(ROOT / 'graphics/nvn/replay'),
           str(ROOT / 'android/tests/guest_window_crop_test.c')]
    if source.is_file():
        cmd.append(str(source))
    subprocess.run([*cmd, '-lpthread', '-o', str(out)], check=True)
    subprocess.run([str(out)], check=True, timeout=10)
