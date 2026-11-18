#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Run real model and mutation checks with an installed JDK; never download tools."""
from pathlib import Path
import shutil
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
javac = shutil.which('javac')
if not javac:
    print('NOT RUN: javac required; JRE alone cannot compile the model checks')
    raise SystemExit(75)
java = str(Path(javac).with_name('java'))
package = root / 'android/app/src/main/java/org/s2arm/android'
with tempfile.TemporaryDirectory(prefix='touch-appearance-') as tmp:
    temp = Path(tmp)
    def run(model, name):
        out = temp / name
        out.mkdir()
        sources = [package / 'Json.java', package / 'TouchPad.java', model, root / 'android/tests/TouchAppearanceModelTest.java']
        subprocess.run([javac, '--release', '11', '-encoding', 'UTF-8', '-Xlint:all', '-Werror',
                        '-d', str(out), *map(str, sources)], check=True, timeout=60)
        return subprocess.run([java, '-cp', str(out), 'org.s2arm.android.TouchAppearanceModelTest'],
                              capture_output=True, text=True, timeout=30)
    model = package / 'TouchLayout.java'
    result = run(model, 'positive')
    print(result.stdout, end='')
    if result.returncode:
        raise RuntimeError(result.stderr)
    source = model.read_text()
    mutations = [
        ('scale_disabled', 'factor = Math.max(lower, Math.min(upper, factor));', 'factor = 1;', 'AssertionError'),
        ('roundoff_unclamped', 'double width = Math.max(0.04, Math.min(0.4, b.width * factor));',
         'double width = b.width * factor;', 'IllegalArgumentException'),
    ]
    for name, old, new, expected in mutations:
        assert source.count(old) == 1, 'mutation anchor changed: ' + name
        mutant = temp / name / 'TouchLayout.java'
        mutant.parent.mkdir()
        mutant.write_text(source.replace(old, new))
        result = run(mutant, name + '_classes')
        if result.returncode == 0 or expected not in result.stderr:
            raise RuntimeError('negative control did not fail as intended: ' + name + '\n' + result.stderr)
        print('negative control ' + name + ': RED (' + expected + ')')
