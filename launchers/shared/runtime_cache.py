#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""随包运行时的下载件本地缓存：命中不联网，未命中才下载，每个文件都核钉死的 SHA-256，不符报红拒打。

缓存目录 S2A_RT_CACHE，缺省 <运行区>/s2arm/cache/runtime：<缓存>/<文件名> 放下载件，<缓存>/wheels/<平台>/ 放 pip 轮子。
升级版本时改下面的表；轮子的版本表要和 launchers/macos/requirements-runtime.txt 一致（pins_of 核）。
"""
import hashlib
import os
from pathlib import Path
import shutil
import urllib.request

FILES = {
    "python-3.12.10-embed-amd64.zip": ("https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip",
                                       "4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3"),
    "MinGit-2.54.0-64-bit.zip": ("https://github.com/git-for-windows/git/releases/download/v2.54.0.windows.1/MinGit-2.54.0-64-bit.zip",
                                 "04f937e1f0918b17b9be6f2294cb2bb66e96e1d9832d1c298e2de088a1d0e668"),
    "zstd-v1.5.7-LICENSE": ("https://raw.githubusercontent.com/facebook/zstd/v1.5.7/LICENSE",
                            "7055266497633c9025b777c78eb7235af13922117480ed5c674677adc381c9d8"),
}
WHEELS = {
    "win_amd64": {
        "capstone==5.0.7": ("capstone-5.0.7-py3-none-win_amd64.whl", "4ab8bcb7da8f221ff45926ca168ca33e76f7237d06fbf3c10780002faa2670e1"),
        "lz4==4.4.5": ("lz4-4.4.5-cp312-cp312-win_amd64.whl", "713a777de88a73425cf08eb11f742cd2c98628e79a8673d6a52e3c5f0c116f33"),
        "numpy==2.4.2": ("numpy-2.4.2-cp312-cp312-win_amd64.whl", "209fae046e62d0ce6435fcfe3b1a10537e858249b3d9b05829e2a05218296a85"),
        "Pillow==12.3.0": ("pillow-12.3.0-cp312-cp312-win_amd64.whl", "a2b55dd6b2a4c4b7d87ffa56bdb33fdc5fdb9a462173861a7bc097f17d91cb09"),
        "zstandard==0.25.0": ("zstandard-0.25.0-cp312-cp312-win_amd64.whl", "ffef5a74088f1e09947aecf91011136665152e0b4b359c42be3373897fb39b01"),
    },
    "macos_arm64": {
        "capstone==5.0.7": ("capstone-5.0.7-py3-none-macosx_11_0_arm64.whl", "acb89f5bf6f625745a104a3a44819d3acea173228055c1eadc60d2282ae490bb"),
        "lz4==4.4.5": ("lz4-4.4.5-cp312-cp312-macosx_11_0_arm64.whl", "6d0bf51e7745484d2092b3a51ae6eb58c3bd3ce0300cf2b2c14f76c536d5697a"),
        "numpy==2.4.2": ("numpy-2.4.2-cp312-cp312-macosx_14_0_arm64.whl", "b3a24467af63c67829bfaa61eecf18d5432d4f11992688537be59ecd6ad32f5e"),
        "Pillow==12.3.0": ("pillow-12.3.0-cp312-cp312-macosx_11_0_arm64.whl", "ffd0c5368496f41b0944be820fcb7a838aa6e623d250b01acf2643939c3f99d7"),
        "zstandard==0.25.0": ("zstandard-0.25.0-cp312-cp312-macosx_11_0_arm64.whl", "913cbd31a400febff93b564a23e17c3ed2d56c064006f54efec210d586171c00"),
    },
}


def cache_root():
    return Path(os.environ.get("S2A_RT_CACHE") or Path(os.environ.get("S2A_RUN_ROOT") or Path.home() / ".s2arm/run") / "s2arm/cache/runtime")


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch_file(name, cache=None, fetch=urllib.request.urlretrieve):
    """返回缓存里核过 SHA-256 的文件路径；表里没有这个文件、下载失败、哈希不符都报红退出"""
    if name not in FILES:
        raise SystemExit(f"【红】{name} 没有钉版哈希：在 launchers/shared/runtime_cache.py 的 FILES 里登记后再打包")
    url, want = FILES[name]
    cache = Path(cache or cache_root()); cache.mkdir(parents=True, exist_ok=True)
    path = cache / name
    if not path.is_file():
        print(f"[运行时] 下载 {name}", flush=True)
        part = path.with_name(name + ".part")
        try:
            fetch(url, part)
        except OSError as error:
            raise SystemExit(f"【红】取不到 {url}（{error}）：在能联网的机器上下好放进 {cache}（或用 S2A_RT_CACHE 指过去）") from error
        part.replace(path)
    got = sha256(path)
    if got != want:
        path.unlink()
        raise SystemExit(f"【红】{name} 的 SHA-256 是 {got}，钉的是 {want}：拒打（已从缓存移除）")
    return path


def wheelhouse(pins, platform, download, cache=None):
    """返回只含钉版轮子的目录，供 pip --no-index --find-links 用。download(目录, 缺的版本号列表) 负责补齐，之后逐个核哈希"""
    table = WHEELS.get(platform)
    if table is None or set(pins) != set(table):
        raise SystemExit(f"【红】{platform} 的轮子哈希表与 requirements-runtime.txt 不一致：表 {sorted(table or [])}，清单 {sorted(pins)}")
    folder = Path(cache or cache_root()) / "wheels" / platform; folder.mkdir(parents=True, exist_ok=True)
    missing = [pin for pin in pins if not (folder / table[pin][0]).is_file()]
    if missing:
        print(f"[运行时] 下载轮子 {' '.join(missing)}", flush=True)
        download(folder, missing)
    for pin in pins:
        name, want = table[pin]
        path = folder / name
        if not path.is_file():
            raise SystemExit(f"【红】{pin} 没有得到 {name}（在能联网的机器上下好放进 {folder}）")
        got = sha256(path)
        if got != want:
            path.unlink()
            raise SystemExit(f"【红】{name} 的 SHA-256 是 {got}，钉的是 {want}：拒打（已从缓存移除）")
    return folder


def copy_file(name, target, cache=None):
    shutil.copyfile(fetch_file(name, cache), target)
