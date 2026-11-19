"""Android target adapter on the existing local job and oneclick pipeline."""
from __future__ import annotations

import json
import os
from pathlib import Path
import platform
import shutil
import sys
import tempfile

from pack.contracts.validate import ContractError, validate


def check_request(request):
    validate('request', request)
    if request.get('targetId') != 'android' or request.get('operation') != 'android':
        raise ContractError('Android 宿主目标只接受 targetId=android / operation=android。')
    if not all(request.get(k) for k in ('gameId', 'library', 'libraryId')):
        raise ContractError('Android 任务缺少游戏或游戏库身份。')
    system, arch = platform.system(), platform.machine()
    if (system, arch) not in {('Darwin', 'arm64'), ('Linux', 'x86_64'), ('Linux', 'aarch64')}:
        raise ContractError('Android 宿主目标需要 Apple Silicon Mac 或 Linux x64/arm64。')


def selected_sources(c, packages, stage):
    """出包输入：游戏库里这款选中的原件（library.source_path：导入时记的绝对路径，原地只读）。不复制、不重算整份哈希——
    库里的包身份按 NCA content ID 算（library.source_identity，11-09 起），不是整文件 SHA-256；原件在不在由 require_game 核。
    同 iPhone 出包：macOS / Linux 在 stage 里按身份软链（library.stage_sources），返回 [stage]；Windows 建软链要权限，直接返回原件路径（oneclick_win 收多个原件）。"""
    from library import source_path, stage_sources
    if os.name == 'nt':
        return list(dict.fromkeys(str(source_path(c, p)) for p in packages))
    stage_sources(c, packages, stage)
    return [str(stage)]


def build(c, extra_env=None):
    """extra_env：作业层给的少数 S2A_* 设置（c.env() 会清掉它们）：S2A_ANDROID_ENGINE 预编引擎目录、S2A_ADB 装机用的 adb。"""
    from core import Failure, contained
    from library import require_game, selected_packages
    from ipa import dotnet_sdk, oneclick_result
    from pack.targets.android.package import verify_manifest

    with c.lock('execution'):
        c.begin('检查游戏输入')
        gid = c.r.get('gameId') or ''
        game = next((g for g in c.catalog()['games'] if g['id'] == gid), None)
        if not game:
            raise Failure('游戏库里没有这款游戏。')
        require_game(c, game)
        home, exe = dotnet_sdk()
        if not exe and os.name != 'nt':   # Windows 走随发版预编的工具（S2A_PREBUILT_TOOLS），不要 .NET SDK（同 iPhone 的 oneclick_win）
            raise Failure('安卓出包需要 .NET 10 SDK，请先在设置中准备环境。', code='dotnet_sdk_missing')
        fonts = c.fonts_dir()
        if fonts is None:
            raise Failure('没有共享字体：指定含 .bfttf 文件的字体目录，或先安装 pack/fonts/requirements.txt 并运行 python3 pack/fonts/make_open_fonts.py <目录> 生成开源替代字体。')
        out = contained(c.library, c.library / 'Android' / gid)
        out.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix='android-src-', dir=c.private))
        events = c.private / 'logs' / (c.task + '-android.events.jsonl')
        events.parent.mkdir(parents=True, exist_ok=True)
        events.write_text('')
        try:
            sources = selected_sources(c, selected_packages(game), stage)
            c.begin('安卓出包')
            env = c.env()
            if exe:
                for name in tuple(env):
                    if name.startswith('DOTNET_ROOT_'):
                        env.pop(name)
                env.update(DOTNET=str(exe), DOTNET_ROOT=str(home), DOTNET_MULTILEVEL_LOOKUP='0',
                           PATH=os.pathsep.join(dict.fromkeys([str(exe.parent), str(home), env['PATH']])))
            env.update({k: v for k, v in (extra_env or {}).items() if k in ('S2A_ANDROID_ENGINE', 'S2A_ADB')})
            serial = ['--install-serial', c.r['installSerial']] if c.r.get('installSerial') else []
            log = c.private / 'logs' / (c.task + '-android.log')
            if os.name == 'nt':   # Windows：同 iPhone 的 win_oneclick，原生 Python 编排（pack/orch/oneclick_win.py --target android），从引擎根按包起
                env.update(S2A_FONTS=str(fonts), S2A_KEYS=str(c.keys))
                c.run([sys.executable, '-X', 'utf8', '-m', 'pack.orch.oneclick_win', *sources, '--target', 'android', '--out', out,
                       '--title-id', gid, '--events', events, *serial], log, env=env, cwd=c.engine)
            else:
                c.run(['bash', c.engine / 'pack/oneclick/oneclick.sh', *sources, '--target', 'android', '--keys', c.keys, '--fonts', fonts,
                       '--out', out, '--title-id', gid, '--events', events, *serial], log, env=env)
            result = oneclick_result(events) or {}
            if not result.get('ok'):
                raise Failure('安卓出包没有报告本轮交付物。')
            apk = contained(out, Path(result['apk']))
            resources = contained(out, Path(result['pack']))
            ledger = contained(out, Path(result['artifact']))
            if apk.parent != resources.parent or ledger.parent != apk.parent:
                raise Failure('安卓交付物不在同一版本目录。')
            computed = verify_manifest(apk.parent, apk, resources, json.loads(ledger.read_text()))
            return dict(target='android', outputPath=str(apk.parent), apk=str(apk),
                        resources=str(resources), artifactManifest=computed,
                        installedSerial=c.r.get('installSerial') or None,
                        outputBytes=apk.stat().st_size + sum(p.stat().st_size for p in resources.rglob('*') if p.is_file()))
        except (OSError, KeyError, ValueError, ContractError) as error:
            raise Failure('安卓交付物校验失败，请查看任务日志。', code='artifact_invalid') from error
        finally:
            shutil.rmtree(stage, ignore_errors=True)
