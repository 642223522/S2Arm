# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""启动器出安卓包 + 装到已连接的手机（缺省关，S2A_ANDROID_EXPORT=1 打开；参照 0.6.0 通用壳 program_pack.enabled 的做法）。

开关只在这里读一处：前端不自己读，靠 androidDevices 作业回报的 enabled 决定安卓卡开不开（关着时两端照旧「即将推出」）。

作业：
  androidDevices  → {enabled, adb, devices: [{serial, state, model}]}：adb devices -l；开关关着不碰 adb
  android         出这款的安卓包（pack/targets/android/adapter.build → oneclick.sh --target android），请求带 installSerial 就接着装到那台手机
出包用随引擎发的预编引擎 APK（<引擎>/Binaries/Android/engine，android/tools/engine_template.py 产出）：玩家电脑不需要
Gradle / NDK / JDK，只把这款的数据组装进引擎 APK、本机钥重签（android/tools/apk_assemble.py）。引擎里没带就交给
package.py 本机全量构建（开发树），缺工具链时它报真原因。

adb：Android SDK 里有就用它，没有就从 Google 官方地址下载 platform-tools 放进 ~/.s2arm/android/platform-tools（只下一次；同目录还有出包签名钥，tools/shared_paths.tsv 登记）。
"""
from __future__ import annotations
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

from errors import Failure
import filelock

ON_BY_DEFAULT = False
PLATFORM_TOOLS_URL = "https://dl.google.com/android/repository/platform-tools-latest-{os}.zip"
ADB_EXE = "adb.exe" if os.name == "nt" else "adb"


def enabled():
    """安卓出包开没开。读作业进程自己的环境（c.env() 会清掉 S2A_*，从那里读永远是缺省，同 program_pack.enabled）。"""
    v = os.environ.get("S2A_ANDROID_EXPORT", "")
    return v == "1" if v in ("0", "1") else ON_BY_DEFAULT


def toolchain_dir():
    """玩家机上安卓出包自己的目录（签名钥 android/tools/apk_sign.py 也在这）。不放开发机人手预装的只读工具链目录（tools/shared_paths.tsv 里登记为脚本不写）"""
    return Path.home() / ".s2arm" / "android"


def engine_dir(c):
    """预编引擎目录：发版随引擎带的 <引擎>/Binaries/Android/engine；开发树没有它，可用作业进程环境 S2A_ANDROID_ENGINE 指一份
    （android/tools/engine_template.py 出的目录）。都没有 → None，package.py 本机全量构建。"""
    d = Path(c.engine) / "Binaries" / "Android" / "engine"
    if (d / "engine.json").is_file():
        return d
    dev = os.environ.get("S2A_ANDROID_ENGINE")
    return Path(dev) if dev and (Path(dev) / "engine.json").is_file() else None


def _sdk_adb():
    homes = [os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT")]
    if sys.platform == "darwin":
        homes.append(str(Path.home() / "Library/Android/sdk"))
    elif os.name == "nt":
        homes.append(os.path.join(os.environ.get("LOCALAPPDATA", ""), "Android", "Sdk"))
    else:
        homes.append(str(Path.home() / "Android/Sdk"))
    for home in filter(None, homes):
        adb = Path(home) / "platform-tools" / ADB_EXE
        if adb.is_file():
            return adb
    return None


def find_adb():
    own = toolchain_dir() / "platform-tools" / ADB_EXE
    if own.is_file():
        return own
    return _sdk_adb() or (Path(shutil.which("adb")) if shutil.which("adb") else None)


def fetch_adb(c=None):
    """下载 Google 官方 platform-tools（约 10 MB）解进 ~/.s2arm/android/platform-tools；已有就直接用。"""
    adb = find_adb()
    if adb:
        return adb
    system = {"darwin": "darwin", "win32": "windows"}.get(sys.platform, "linux")
    root = toolchain_dir()
    root.mkdir(parents=True, exist_ok=True)
    with filelock.held(root / "platform-tools.lock", wait_s=300):
        own = root / "platform-tools" / ADB_EXE
        if own.is_file():
            return own
        if c is not None:
            c.begin("下载安卓调试工具（adb）")
        url = PLATFORM_TOOLS_URL.format(os=system)
        with tempfile.TemporaryDirectory(dir=root) as tmp:
            archive = Path(tmp) / "platform-tools.zip"
            try:
                with urllib.request.urlopen(url, timeout=120) as response, archive.open("wb") as out:
                    shutil.copyfileobj(response, out)
                with zipfile.ZipFile(archive) as z:
                    z.extractall(tmp)
            except (OSError, zipfile.BadZipFile) as error:
                raise Failure(f"下载安卓调试工具（adb）失败：{error}。检查网络后重试；也可以自己装 Android SDK Platform-Tools。",
                              code="adb_download_failed") from None
            extracted = Path(tmp) / "platform-tools"
            if not (extracted / ADB_EXE).is_file():
                raise Failure("下载的 platform-tools 里没有 adb。", code="adb_download_failed")
            if os.name != "nt":
                for name in ("adb", "fastboot"):
                    p = extracted / name
                    if p.is_file():
                        p.chmod(0o755)
            os.replace(extracted, root / "platform-tools")
    return own


def list_devices(adb):
    """adb devices -l → [{serial, state, model}]；state 原样（device / unauthorized / offline），未授权的也列出来让玩家看到。"""
    kw = dict(capture_output=True, text=True, timeout=30)
    if os.name == "nt":
        kw["creationflags"] = 0x08000000   # CREATE_NO_WINDOW
    out = subprocess.run([str(adb), "devices", "-l"], **kw)
    if out.returncode:
        raise Failure("adb devices 失败：" + (out.stderr or out.stdout).strip()[:300], code="adb_failed")
    devices = []
    for line in out.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 2:
            continue
        info = dict(p.split(":", 1) for p in parts[2:] if ":" in p)
        devices.append(dict(serial=parts[0], state=parts[1], model=info.get("model", "").replace("_", " ")))
    return devices


def devices_job(c):
    if not enabled():
        return dict(enabled=False, adb=None, devices=[])
    adb = fetch_adb(c)
    return dict(enabled=True, adb=str(adb), devices=list_devices(adb))


def build_job(c):
    if not enabled():
        raise Failure("安卓出包还没开放。", code="android_disabled")
    sys.path.insert(0, str(c.engine))
    from pack.targets.android import adapter
    extra = {}
    engine = engine_dir(c)
    if engine:
        extra["S2A_ANDROID_ENGINE"] = str(engine)
    if c.r.get("installSerial"):
        extra["S2A_ADB"] = str(fetch_adb(c))
    return adapter.build(c, extra_env=extra)
