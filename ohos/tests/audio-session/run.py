#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Offline .NET test of the actual managed session, plus two rejected old-code controls."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SESSION = REPO / 'ohos/cs/audio/OHAudioHardwareDeviceSession.cs'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError('Negative-control edit no longer matches exactly once; review test against new source')
    return text.replace(old, new, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dotnet', default='dotnet')
    parser.add_argument('--build-root', type=Path, default=REPO / 'build/ohos/audio-session-tests')
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    build = args.build_root.resolve()
    evidence = (args.evidence or build / 'evidence').resolve()
    build.mkdir(parents=True, exist_ok=True)
    evidence.mkdir(parents=True, exist_ok=True)
    commands = []
    env = dict(os.environ, DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1')

    def run(name, command):
        result = subprocess.run(command, cwd=HERE, env=env, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=60)
        log = evidence / (name + '.log')
        log.write_text(result.stdout + result.stderr, encoding='utf-8')
        commands.append({'name': name, 'argv': command, 'cwd': str(HERE), 'exit_code': result.returncode, 'log': str(log), 'log_sha256': sha(log)})
        return result

    source = SESSION.read_text(encoding='utf-8')
    pause = replace_once(source, '            Exception? pauseError = null;\n            try { Stop(); }\n            catch (Exception error) { pauseError = error; }', '            Stop();')
    pause = replace_once(pause, '            if (pauseError != null) throw new InvalidOperationException("OHAudio pause failed during disposal; sink cleaned up", pauseError);\n', '')
    publication = replace_once(source, '                // Publish samples only after their accounting record is visible.\n                _samples.Enqueue(buffer);\n', '')
    publication = replace_once(publication, '        public override void QueueBuffer(AudioBuffer buffer)\n        {\n', '        public override void QueueBuffer(AudioBuffer buffer)\n        {\n            _samples.Enqueue(buffer);\n')
    variants = [('actual', SESSION, 'all', 0)]
    for name, content, case in [('old-pause', pause, 'pause'), ('old-publication', publication, 'publication')]:
        path = build / (name + '.cs')
        path.write_text(content, encoding='utf-8')
        variants.append((name, path, case, 1))
    passed = True
    sdk = run('sdk', [args.dotnet, '--version'])
    results = []
    for name, path, case, expected in variants:
        output = build / name / 'out'
        command = [args.dotnet, 'build', str(HERE / 'AudioSession.Tests.csproj'), '--configuration', 'Release',
                   '--configfile', str(HERE / 'NuGet.Config'), '--output', str(output),
                   '-p:BaseIntermediateOutputPath=' + str(build / name / 'obj') + os.sep,
                   '-p:SessionSource=' + str(path), '-p:UseSharedCompilation=false', '--nologo']
        compiled = run(name + '-build', command)
        if compiled.returncode != 0:
            passed = False
            results.append({'variant': name, 'build_exit_code': compiled.returncode, 'accepted': False})
            continue
        executed = run(name + '-run', [args.dotnet, str(output / 'AudioSession.Tests.dll'), case])
        expected_marker = 'PASS publication' if expected == 0 else 'FAIL ' + case + ':'
        accepted = executed.returncode == expected and expected_marker in executed.stdout
        if expected == 0:
            accepted = accepted and 'PASS pause' in executed.stdout
        passed &= accepted
        results.append({'variant': name, 'session_source': str(path), 'session_sha256': sha(path),
                        'build_exit_code': compiled.returncode, 'run_exit_code': executed.returncode,
                        'expected_run_exit_code': expected, 'accepted': accepted, 'output': executed.stdout.strip()})
    sources = [SESSION, HERE / 'AudioSession.Tests.csproj', HERE / 'Program.cs', HERE / 'TestBoundary.cs', HERE / 'run.py', HERE / 'NuGet.Config']
    for relative in ['Ryujinx.Audio/Backends/Common/AudioSampleQueue.cs', 'Ryujinx.Audio/Backends/Common/DynamicRingBuffer.cs',
                     'Ryujinx.Audio/Backends/Common/HardwareDeviceSessionOutputBase.cs', 'Ryujinx.Audio/Backends/Common/BackendHelper.cs',
                     'Ryujinx.Audio/Common/AudioBuffer.cs', 'Ryujinx.Audio/Common/SampleFormat.cs', 'Ryujinx.Audio/Integration/IHardwareDeviceSession.cs',
                     'Ryujinx.Common/Utilities/BitUtils.cs', 'Ryujinx.Common/Memory/MemoryOwner.cs']:
        sources.append(REPO / 'compat/tree/src' / relative)
    manifest = {'passed': passed, 'sdk': sdk.stdout.strip(), 'scope': 'Actual managed session and queue, test-only device boundary; no native/device validation',
                'results': results, 'commands': commands, 'inputs': [{'path': str(p), 'sha256': sha(p)} for p in sources]}
    (evidence / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'passed': passed, 'results': results, 'manifest': str(evidence / 'manifest.json')}, ensure_ascii=False, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
