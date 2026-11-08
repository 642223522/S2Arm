"""Mac 启动器出哪个前端（环境变量 S2A_APP_FRONTEND）：可执行文件、App 身份与前端自带资源的布局。

build_app.py 照这里出 App；单测（Tests/test_frontend_layout.py）只测这里，不出壳。
- 缺省 / apple：S2Arm × NX2Apple 前端 S2ArmApple：NX2Apple 派生界面（launchers/macos/frontend）+ S2Arm 适配层。11-07 起是发版缺省
  （维护者上线冲刺方案 v2）。App 文件名仍是 S2Arm.app：玩家 /Applications/S2Arm.app 原地覆盖升级，签名公证（sign_release.sh）、
  发版文档、s2armctl 都认这个名字；App 名（访达 / 程序坞）仍叫 S2Arm（维护者 11-07「咱们的 app 还是叫 S2Arm」），窗口顶栏品牌字「S2Arm × NX2Apple」；包标识 org.s2arm.macos.nx2apple 不变。
- launcher：旧 SwiftUI 启动器 S2ArmLauncher（同为 S2Arm.app），留作回退：S2A_APP_FRONTEND=launcher 照样出。
  自带资源：界面文案 l10n/<语言>.json → Resources/l10n（NXCore LocalizationFiles 先找这里）；
  NX2Apple 的 LICENSE / NOTICE 与内嵌 Manrope 字体的 OFL 许可 → Resources/Licenses/NX2Apple/。
  字体本体已内嵌在可执行文件（EmbeddedFonts.swift），不另拷；Resources/Fonts 是 S2Arm 给游戏用的共享字体，不动（大小写不敏感的盘上
  「fonts」与「Fonts」是同一个目录，前端字体许可因此放 Licenses 下）。
两者共用的 Engine / Runtime / Shell / Fonts / Jobs 与 SwiftPM 资源包（适配层的作业层文字对照表 + 共享体验规格）由 build_app.py 原样放，与前端无关。
"""
from __future__ import annotations
import os
from pathlib import Path
import shutil

FRONTENDS = {
    "launcher": dict(product="S2ArmLauncher", app="S2Arm.app", bundle_id="org.s2arm.macos.launcher",
                     name="S2Arm", display="S2Arm", nx2apple_resources=False),
    "apple": dict(product="S2ArmApple", app="S2Arm.app", bundle_id="org.s2arm.macos.nx2apple",
                  name="S2Arm", display="S2Arm", nx2apple_resources=True),
}

APPLE_FRONTEND = Path("launchers/macos/frontend")
APPLE_LICENSES = ("LICENSE", "NOTICE", "fonts/Manrope-OFL.txt")


def pick(environ=None):
    """S2A_APP_FRONTEND 选的前端（空 = apple，11-07 起发版缺省）；不认识的值直接退出，不悄悄出缺省。"""
    value = (os.environ if environ is None else environ).get("S2A_APP_FRONTEND", "") or "apple"
    if value not in FRONTENDS:
        raise SystemExit(f"🔴 S2A_APP_FRONTEND={value!r} 不认识：只收 {' / '.join(FRONTENDS)}")
    return dict(FRONTENDS[value], key=value, executable=FRONTENDS[value]["product"])


def info_identity(spec):
    """Info.plist 里随前端变的几项（其余两者相同，由 build_app.py 填）。"""
    return dict(CFBundleIdentifier=spec["bundle_id"], CFBundleExecutable=spec["executable"],
                CFBundleName=spec["name"], CFBundleDisplayName=spec["display"])


def stage_apple_resources(root, resources):
    """把 NX2Apple 前端自带的文案与许可放进 Resources；源文件缺一个就退出（不出缺许可的包）。返回放进去的相对路径（排序）。"""
    root, resources = Path(root), Path(resources)
    frontend = root / APPLE_FRONTEND
    languages = sorted((frontend / "l10n").glob("*.json"))
    if not any(p.name == "en.json" for p in languages):
        raise SystemExit(f"🔴 前端文案缺 en.json：{frontend / 'l10n'}")
    missing = [name for name in APPLE_LICENSES if not (frontend / name).is_file()]
    if missing:
        raise SystemExit(f"🔴 NX2Apple 许可文件缺：{', '.join(missing)}（{frontend}）")
    placed = []
    (resources / "l10n").mkdir(parents=True, exist_ok=True)
    for p in languages:
        shutil.copy2(p, resources / "l10n" / p.name)
        placed.append(f"l10n/{p.name}")
    licenses = resources / "Licenses/NX2Apple"
    licenses.mkdir(parents=True, exist_ok=True)
    for name in APPLE_LICENSES:
        shutil.copy2(frontend / name, licenses / Path(name).name)
        placed.append(f"Licenses/NX2Apple/{Path(name).name}")
    return sorted(placed)
