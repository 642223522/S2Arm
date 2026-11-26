#!/usr/bin/env python3
"""构建预编引擎 APK（每个引擎提交编一次，在构建机 / 发版时跑；玩家电脑不跑）。

  engine_template.py --out <引擎目录>

与 pack/targets/android/package.py 的游戏构建同一套：从已提交源码导出构建树、同一后端
（macOS 宿主原生 / Linux docker）、nativeMode=game 正式构建，同样核游戏运行时链接报告、
verify-apk.py、优化参数和签名。区别只在游戏目录换成占位身份（程序号 0000000000000000、
占位显示名、占位图标、没有 assets/game），产物交给 apk_assemble.py 每款组装。

输出 <引擎目录>/：engine.apk、identity.json（直连编译器构建身份）、engine.json（见 apk_assemble.py）。
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))
from pack.targets.android import package as pkg   # noqa: E402
import apk_assemble   # noqa: E402
import axml   # noqa: E402

DENSITIES = (('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192))   # 同 game_apk.render_game_icon
PLACEHOLDER_ICON = ROOT / 'launchers/macos/Branding/AppIcon-1024.png'
VERSION_PLACEHOLDER = '0'


def placeholder_icons():
    """{密度: PNG}：没有游戏图标的款沿用这一套（S2Arm 图标）；组装时按这些字节在 APK 里找条目。"""
    from PIL import Image
    with Image.open(PLACEHOLDER_ICON) as image:
        image = image.convert('RGB')
        out = {}
        for density, size in DENSITIES:
            data = io.BytesIO()
            image.resize((size, size), Image.Resampling.LANCZOS).save(data, format='PNG')
            out[density] = data.getvalue()
    return out


def write_game_dir(game, icons):
    (game / 'res/values').mkdir(parents=True)
    (game / 'game.properties').write_text(
        f'titleId={apk_assemble.TEMPLATE_TITLE}\nname=S2Arm\nversion={VERSION_PLACEHOLDER}\nversionCode=1\n'
        'launcherIcon=game\nmodules=\n', encoding='ascii')
    (game / 'res/values/game_name.xml').write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
        '    <string name="game_name" translatable="false">S2Arm</string>\n</resources>\n', encoding='utf-8')
    for density, data in icons.items():
        d = game / 'res' / f'mipmap-{density}'
        d.mkdir(parents=True)
        (d / 'game_icon.png').write_bytes(data)


def icon_entries(apk, icons):
    """占位图标在 APK 里的条目 → 密度：按 resources.arsc 查 mipmap/game_icon（正式构建缩短路径、重压 PNG，字节与路径都靠不住）。"""
    with zipfile.ZipFile(apk) as z:
        files = axml.resource_files(z.read('resources.arsc'), 'mipmap', 'game_icon')
        names = set(z.namelist())
    if sorted(files) != sorted(icons) or not set(files.values()) <= names:
        raise ValueError(f'引擎 APK 里没找全占位图标：{files}')
    return {entry: density for density, entry in files.items()}


def build(out):
    out = Path(out).resolve()
    if out.exists():
        raise ValueError(f'{out} 已存在；换一个目录')
    env = pkg.build_environment(os.environ)
    icons = placeholder_icons()
    with tempfile.TemporaryDirectory(prefix='.android-engine-', dir=pkg.build_parent(out.parent)) as tmp:
        src = Path(tmp) / 'src'
        pkg.export_sources(src, env)
        write_game_dir(src / 'build/android-game/input', icons)
        backend = pkg.build_backend(env)
        builder = src / ('android/docker/build.sh' if backend == 'docker' else 'android/host/build.sh')
        subprocess.run(['bash', str(builder), '--direct-identity'], env=env, check=True)
        subprocess.run(['bash', str(builder)], env=env, check=True)
        start_ns = time.time_ns()
        variant = pkg.build_variant()
        task = variant.capitalize()
        subprocess.run(['bash', str(builder), '-Ps2arm.nativeMode=game', ':app:clean',
                        f':app:assemble{task}', f':app:lint{task}'], env=env, check=True)
        built = src / pkg.apk_output(variant)
        stage = Path(tmp) / 'engine'
        stage.mkdir()
        apk = stage / 'engine.apk'
        shutil.copyfile(built, apk)
        pkg.verify_game_provider(src, start_ns, apk, containerized=backend == 'docker')
        subprocess.run([sys.executable, str(src / 'android/verify-apk.py'), str(apk)], env=env, check=True)
        pkg.verify_native_optimized(src, variant, start_ns)
        pkg.verify_signature(src, apk, env, backend, variant)
        shutil.copyfile(src / 'build/android-direct/identity.json', stage / 'identity.json')
        with zipfile.ZipFile(apk) as z:
            package, _, version_name, debuggable = axml.identity(z.read('AndroidManifest.xml'))
        if package != apk_assemble.TEMPLATE_PACKAGE or not version_name.startswith(VERSION_PLACEHOLDER + ' '):
            raise ValueError(f'引擎 APK 身份不是占位身份：{package} / {version_name}')
        commit = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
        doc = dict(schema=apk_assemble.ENGINE_SCHEMA, package=package,
                   versionNameSuffix=version_name[len(VERSION_PLACEHOLDER):], variant=variant, debuggable=debuggable,
                   icons=icon_entries(apk, icons), providerBuildId=pkg.apk_provider_build_id(apk),
                   apkSha256=apk_assemble.sha256(apk), sourceCommit=commit or None,
                   identitySha256=hashlib.sha256((stage / 'identity.json').read_bytes()).hexdigest())
        (stage / 'engine.json').write_text(json.dumps(doc, ensure_ascii=False, indent=1) + '\n')
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(stage), str(out))
    return doc


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument('--out', required=True)
    a = p.parse_args()
    try:
        doc = build(a.out)
    except subprocess.CalledProcessError as error:
        print(f'【红】引擎 APK 构建步骤失败，退出码 {error.returncode}', file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError) as error:
        print('【红】引擎 APK 构建失败：' + str(error), file=sys.stderr)
        return 1
    print(json.dumps(doc, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    sys.exit(main())
