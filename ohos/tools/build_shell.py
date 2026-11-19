# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Build the unsigned OHOS shell from source without a game or private engine.

Two modes: --studio uses an installed DevEco Studio (HarmonyOS SDK, ohpm);
--public-sdk uses the public OpenHarmony SDK and pinned hvigor laid out by
ohos/tools/emu/setup.sh, adapting only the build copy.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

SDK_API = '26.0.0'
HVIGOR_VERSION = '6.26.20'


def replace_once(path, old, new):
    text = path.read_text(encoding='utf8')
    if text.count(old) != 1:
        raise RuntimeError(f'Expected exactly one {old!r} in {path}')
    path.write_text(text.replace(old, new), encoding='utf8')


def adapt_for_public_sdk(stage):
    """Apply the three public-SDK adaptations to the staged copy only."""
    profile = stage / 'build-profile.json5'
    replace_once(profile, '"runtimeOS": "HarmonyOS"', '"runtimeOS": "OpenHarmony"')
    replace_once(profile, '"targetSdkVersion"', f'"compileSdkVersion": "{SDK_API}",\n        "targetSdkVersion"')
    # The public SDK has no phone syscap set.
    replace_once(stage / 'entry/src/main/module.json5', '"deviceTypes": ["phone"]', '"deviceTypes": ["default"]')
    # Without ohpm, place the N-API typings where ArkTS resolves 'libs2aprobehost.so'.
    shutil.copytree(stage / 'entry/src/main/cpp/types/libs2aprobehost',
                    stage / 'entry/oh_modules/libs2aprobehost.so')


def link_dir(target, link):
    if sys.platform == 'win32':
        import _winapi  # Junctions need no symlink privilege.
        _winapi.CreateJunction(str(target), str(link))
    else:
        link.symlink_to(target, target_is_directory=True)


def studio_setup(parser, studio):
    suffix = '.exe' if sys.platform == 'win32' else ''
    node = studio / ('tools/node/node' + suffix)
    ohpm = studio / 'tools/ohpm/bin/pm-cli.js'
    hvigor = studio / 'tools/hvigor/bin/hvigorw.js'
    for tool in (node, ohpm, hvigor):
        if not tool.is_file():
            parser.error('Missing installed tool: ' + str(tool))
    env = dict(os.environ, JAVA_HOME=str(studio / 'jbr'), DEVECO_SDK_HOME=str(studio / 'sdk'))
    env['PATH'] = os.pathsep.join([str(node.parent), str(studio / 'jbr/bin'), env['PATH']])
    return env, [('dependencies', [str(node), str(ohpm), 'install'])], [str(node), str(hvigor)]


def public_setup(parser, sdk_root, hvigor_dir):
    for component in ('ets', 'js', 'native', 'previewer', 'toolchains'):
        if not (sdk_root / SDK_API / component / 'oh-uni-package.json').is_file():
            parser.error(f'Missing OpenHarmony SDK {SDK_API}/{component} under {sdk_root}; run ohos/tools/emu/setup.sh')
    package = hvigor_dir / 'node_modules/@ohos/hvigor/package.json'
    if not package.is_file():
        parser.error('Missing hvigor under ' + str(hvigor_dir) + '; run ohos/tools/emu/setup.sh')
    version = json.loads(package.read_text(encoding='utf8'))['version']
    if version != HVIGOR_VERSION:
        parser.error(f'hvigor {version} found; expected {HVIGOR_VERSION}')
    node = shutil.which('node')
    java_home = os.environ.get('JAVA_HOME')
    if not node:
        parser.error('Put Node.js on PATH')
    if not java_home or not (Path(java_home) / 'bin').is_dir():
        parser.error('Set JAVA_HOME to a JDK 17+')
    env = dict(os.environ, OHOS_BASE_SDK_HOME=str(sdk_root))
    env.pop('DEVECO_SDK_HOME', None)
    env['PATH'] = os.pathsep.join([str(Path(java_home) / 'bin'), env['PATH']])
    return env, [], [node, 'node_modules/@ohos/hvigor/bin/hvigor.js']


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--studio', type=Path, help='DevEco Studio installation')
    mode.add_argument('--public-sdk', action='store_true',
                      help='Public OpenHarmony SDK + pinned hvigor (no DevEco/HMS); needs node on PATH and JAVA_HOME')
    emu_home = Path(os.environ.get('OHOS_EMU_HOME', Path.home() / '.cache/s2arm-ohos-emu'))
    parser.add_argument('--sdk-root', type=Path, default=emu_home / 'sdk',
                        help='--public-sdk: directory containing ' + SDK_API + '/ (default $OHOS_EMU_HOME/sdk)')
    parser.add_argument('--hvigor-dir', type=Path, default=emu_home / 'hvigor',
                        help='--public-sdk: directory containing node_modules/@ohos/hvigor (default $OHOS_EMU_HOME/hvigor)')
    parser.add_argument('--out', type=Path, required=True, help='New, empty build directory')
    args = parser.parse_args()
    out = args.out.resolve()
    source = Path(__file__).resolve().parents[1] / 'app'
    if args.studio:
        env, steps, hvigor = studio_setup(parser, args.studio.resolve())
    else:
        env, steps, hvigor = public_setup(parser, args.sdk_root.resolve(), args.hvigor_dir.resolve())
    if out.exists() and any(out.iterdir()):
        parser.error('Use an empty output directory; existing builds are preserved.')
    out.mkdir(parents=True, exist_ok=True)
    stage = out / 'app'
    shutil.copytree(source, stage, ignore=shutil.ignore_patterns(
        'build', '.hvigor', '.idea', 'oh_modules', 'node_modules', 'local.properties',
        '*.hap', '*.hsp', '*.so', '*.p12', '*.p7b', '*.cer', '*.pem', '*.keystore'))
    if not args.studio:
        adapt_for_public_sdk(stage)
        link_dir(args.hvigor_dir.resolve() / 'node_modules', stage / 'node_modules')
    steps.append(('build', hvigor + ['--mode', 'module', '-p', 'product=default',
                                     '-p', 'module=entry@default', 'assembleHap', '--no-daemon']))
    for name, command in steps:
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
              'mode': 'deveco' if args.studio else 'public-sdk',
              'hap': str(hap), 'sha256': hashlib.sha256(hap.read_bytes()).hexdigest()}
    (out / 'result.json').write_text(json.dumps(report, indent=2), encoding='utf8')
    print(json.dumps(report, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
