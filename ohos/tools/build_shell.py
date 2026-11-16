# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Build the unsigned OHOS shell from source without a game or private engine."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--studio', type=Path, required=True, help='DevEco Studio installation')
    parser.add_argument('--out', type=Path, required=True, help='New, empty build directory')
    args = parser.parse_args()
    studio, out = args.studio.resolve(), args.out.resolve()
    source = Path(__file__).resolve().parents[1] / 'app'
    suffix = '.exe' if sys.platform == 'win32' else ''
    node = studio / ('tools/node/node' + suffix)
    ohpm = studio / 'tools/ohpm/bin/pm-cli.js'
    hvigor = studio / 'tools/hvigor/bin/hvigorw.js'
    for tool in (node, ohpm, hvigor):
        if not tool.is_file():
            parser.error('Missing installed tool: ' + str(tool))
    if out.exists() and any(out.iterdir()):
        parser.error('Use an empty output directory; existing builds are preserved.')
    out.mkdir(parents=True, exist_ok=True)
    stage = out / 'app'
    shutil.copytree(source, stage, ignore=shutil.ignore_patterns(
        'build', '.hvigor', '.idea', 'oh_modules', 'node_modules', 'local.properties',
        '*.hap', '*.hsp', '*.so', '*.p12', '*.p7b', '*.cer', '*.pem', '*.keystore'))
    env = dict(os.environ, JAVA_HOME=str(studio / 'jbr'), DEVECO_SDK_HOME=str(studio / 'sdk'))
    env['PATH'] = os.pathsep.join([str(node.parent), str(studio / 'jbr/bin'), env['PATH']])
    for name, command in (
        ('dependencies', [str(node), str(ohpm), 'install']),
        ('build', [str(node), str(hvigor), '--mode', 'module', '-p', 'product=default',
                   '-p', 'module=entry@default', 'assembleHap', '--no-daemon']),
    ):
        with (out / (name + '.log')).open('w', encoding='utf8') as log:
            result = subprocess.run(command, cwd=stage, env=env, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            print((out / (name + '.log')).read_text(encoding='utf8', errors='replace')[-10000:])
            return result.returncode
    packages = list((stage / 'entry/build').rglob('*unsigned.hap'))
    if len(packages) != 1:
        raise RuntimeError('Expected exactly one newly built unsigned HAP')
    hap = packages[0]
    report = {'scope': 'shell only; no engine, game, signing or device validation',
              'hap': str(hap), 'sha256': hashlib.sha256(hap.read_bytes()).hexdigest()}
    (out / 'result.json').write_text(json.dumps(report, indent=2), encoding='utf8')
    print(json.dumps(report, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
