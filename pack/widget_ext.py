# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""主屏小组件扩展（PlugIns/S2ArmWidget.appex，11-16 维护者：4×2 小组件进 0.5.0）在出包 / 装机各处跟着主程序走。

- 包名：苹果要求扩展包名 = 主包名 + 后缀。壳里编的是 <壳包名>.widget（runtime/build.mk ios-widget）；凡是改主包名的地方
  （出壳占位、组装 App、装机换包名）都调 retarget，扩展一并改成 <新主包名>.widget。
- 去掉：签名方式带不了扩展（玩家自己的证书只有一份描述文件）、申请不到扩展的描述文件、免费账号 App ID 额度满（9120）时调 strip，
  App 照常装、只是没有小组件——绝不能因为小组件让玩家装不上。
"""
import plistlib
import shutil
from pathlib import Path

PLUGINS = "PlugIns"
SUFFIX = "widget"


def appexes(app):
    d = Path(app) / PLUGINS
    return sorted(p for p in d.glob("*.appex") if p.is_dir()) if d.is_dir() else []


def bundle_id(main_bid):
    return f"{main_bid}.{SUFFIX}"


def retarget(app, main_bid):
    """扩展包名跟着主包名改；返回改了几个。没有扩展（单款包 / 已去掉）返回 0"""
    n = 0
    for x in appexes(app):
        info = x / "Info.plist"
        pl = plistlib.loads(info.read_bytes())
        want = bundle_id(main_bid)
        if pl.get("CFBundleIdentifier") != want:
            pl["CFBundleIdentifier"] = want
            info.write_bytes(plistlib.dumps(pl, fmt=plistlib.FMT_XML, sort_keys=True))
            n += 1
    return n


def strip(app):
    """整个去掉小组件扩展；返回去掉前有没有"""
    d = Path(app) / PLUGINS
    had = bool(appexes(app))
    if d.exists():
        shutil.rmtree(d)
    return had


def executables(app):
    """扩展里的可执行文件（相对 App 根），组装 / 打 IPA 时要保留可执行位"""
    out = []
    for x in appexes(app):
        exe = plistlib.loads((x / "Info.plist").read_bytes()).get("CFBundleExecutable")
        if exe and (x / exe).is_file():
            out.append((x / exe).relative_to(Path(app)).as_posix())
    return out
