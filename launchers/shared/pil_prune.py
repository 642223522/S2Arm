# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""随包 Python 的 Pillow 瘦身（11-16 安装包瘦身，Mac / Windows 共用）。
出包流程只用 Pillow 读写缩放常见位图（pack/app_bundle.py 图标、pack/banner_fetch.py 横幅：PNG / JPEG / WEBP 等），
不用 AVIF（_avif + libavif，Mac 3 MB、Windows 压缩后 4.3 MB）、不用 Tk。
画字（_imagingft + freetype / harfbuzz）要留：下游方案的做包工具用随包 Python 跑，会用 ImageFont 画界面素材
（#1570：d2r-mobile 的 gen_assets.py 报「cannot import name '_imagingft'」，iPhone 包出不来）。
删这两个扩展模块，再删 .dylibs 里没人引用的库（Mac 轮子把依赖放在 PIL/.dylibs；Windows 轮子静态链在 .pyd 里，没有这一步）。
Pillow 对缺的扩展是「这项功能不可用」（features.check 为 False），不影响其余格式。"""
from pathlib import Path
import re

DROP = ("_avif", "_imagingtk")


def prune(site, deps=None):
    """site = site-packages 目录；deps(path) → 这个 Mach-O 依赖的库文件名（Mac 传 otool -L 解析；None = 不清 .dylibs）。
    返回删掉的相对路径，排好序"""
    pil = Path(site) / "PIL"
    if not pil.is_dir():
        return []
    gone = [p for p in pil.iterdir() if p.is_file() and p.name.split(".")[0] in DROP and re.search(r"\.(so|pyd)$", p.name)]
    for p in gone:
        p.unlink()
    libs = pil / ".dylibs"
    if deps is not None and libs.is_dir():
        while True:   # 反复清：删掉一个库后，只被它引用的库也没人要了
            users = [p for p in pil.iterdir() if p.is_file() and p.suffix in (".so", ".pyd")] + [p for p in libs.iterdir() if p.is_file()]
            wanted = {n for u in users for n in deps(u) if n != u.name}
            orphans = [p for p in libs.iterdir() if p.is_file() and p.name not in wanted]
            if not orphans:
                break
            for p in orphans:
                p.unlink(); gone.append(p)
    return sorted(str(p.relative_to(site)) for p in gone)
