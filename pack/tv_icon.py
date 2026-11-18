#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""tvOS 预编壳的主屏图标（#1457）：tvOS 不认 iPhone 那种散装 PNG（CFBundleIconFiles），主屏图标必须是 actool 编出的 Assets.car，
里面放「App Icon & Top Shelf Image」分层品牌图标（App Icon 400x240 @1x/@2x 与 App Store 1280x768 两个图层栈 + 顶部架图 1920x720 / 2320x720）。
图标是通用品牌图、不随游戏变，所以只在出 tvOS 壳时编一次放进壳（pack/shell_build.sh）；玩家机上组装直接沿用（不需要 actool / Apple TV 模拟器运行时，
Windows 导出 Apple TV 包也一样）。actool 编 tvOS 资源要装 Apple TV 模拟器运行时（xcodebuild -downloadPlatform tvOS），没装时它只出 partial plist、
不出 Assets.car——这时照出壳、打一行黄字说清缺图标的原因（不拦出壳）。

  tv_icon.py <品牌图标 PNG> <S2Arm.app>   → app 里写 Assets.car，Info.plist 并进 actool 给的 CFBundleIcons / TVTopShelfImage"""
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BRAND = "App Icon & Top Shelf Image"
INFO = {"author": "xcode", "version": 1}


def contents(d, data):
    d.mkdir(parents=True, exist_ok=True)
    (d / "Contents.json").write_text(json.dumps(data, indent=1), encoding="utf-8")


def catalog(icon_png, root):
    """品牌图标 → <root>/Assets.xcassets（背景层 = 图标主色铺满，前景层 = 图标居中占高 80%，顶部架图同前景）"""
    from PIL import Image
    icon = Image.open(icon_png).convert("RGBA")
    bg = icon.resize((1, 1), Image.Resampling.LANCZOS).getpixel((0, 0))[:3] + (255,)

    def back(w, h):
        return Image.new("RGBA", (w, h), bg)

    def front(w, h):
        im = Image.new("RGBA", (w, h), (0, 0, 0, 0)); s = int(h * 0.8)
        ic = icon.resize((s, s), Image.Resampling.LANCZOS); im.paste(ic, ((w - s) // 2, (h - s) // 2), ic)
        return im
    xc = root / "Assets.xcassets"; contents(xc, {"info": INFO})
    ba = xc / f"{BRAND}.brandassets"
    contents(ba, {"info": INFO, "assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"}]})
    for name, w, h, scales in (("App Icon.imagestack", 400, 240, (1, 2)), ("App Icon - App Store.imagestack", 1280, 768, (1,))):
        st = ba / name
        contents(st, {"info": INFO, "layers": [{"filename": "Front.imagestacklayer"}, {"filename": "Back.imagestacklayer"}]})
        for layer, draw in (("Front", front), ("Back", back)):
            ld = st / f"{layer}.imagestacklayer"; contents(ld, {"info": INFO}); cs = ld / "Content.imageset"; cs.mkdir(parents=True)
            imgs = []
            for sc in scales:
                f = f"{layer.lower()}@{sc}x.png"; draw(w * sc, h * sc).save(cs / f); imgs.append({"idiom": "tv", "scale": f"{sc}x", "filename": f})
            contents(cs, {"info": INFO, "images": imgs})
    for name, w, h in (("Top Shelf Image.imageset", 1920, 720), ("Top Shelf Image Wide.imageset", 2320, 720)):
        d = ba / name; d.mkdir(parents=True); imgs = []
        for sc in (1, 2):
            f = f"shelf@{sc}x.png"; front(w * sc, h * sc).convert("RGB").save(d / f); imgs.append({"idiom": "tv", "scale": f"{sc}x", "filename": f})
        contents(d, {"info": INFO, "images": imgs})
    return xc


def build(icon_png, app):
    app = Path(app); info_path = app / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    floor = str(info.get("MinimumOSVersion") or "17.0")
    with tempfile.TemporaryDirectory(prefix="tv-icon-") as t:
        t = Path(t); xc = catalog(icon_png, t); out = t / "out"; out.mkdir(); partial = t / "partial.plist"
        r = subprocess.run(["xcrun", "actool", "--compile", str(out), "--platform", "appletvos", "--minimum-deployment-target", floor,
                            "--app-icon", BRAND, "--target-device", "tv", "--output-partial-info-plist", str(partial),
                            "--output-format", "human-readable-text", str(xc)], capture_output=True, text=True)
        car = out / "Assets.car"
        if not car.is_file() or not partial.is_file():   # 照出壳（只是主屏没图标），不拦：原因写清楚
            why = " ".join(l.strip() for l in (r.stdout + r.stderr).splitlines() if "error" in l.lower())[:400]
            print(f"【黄】actool 没有产出 tvOS 图标 Assets.car（{why or 'rc=' + str(r.returncode)}），这个壳主屏没有 S2Arm 图标：装 Apple TV 模拟器运行时"
                  "（xcodebuild -downloadPlatform tvOS）后重新出壳就有")
            return False
        shutil.copy2(car, app / "Assets.car")
        info.update(plistlib.loads(partial.read_bytes()))   # CFBundleIcons（CFBundlePrimaryIcon = 品牌名）、TVTopShelfImage
        info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True))
    print(f"🟢 tvOS 主屏图标：Assets.car {(app / 'Assets.car').stat().st_size} 字节")
    return True


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("用法：tv_icon.py <品牌图标 PNG> <S2Arm.app>")
    build(sys.argv[1], sys.argv[2])
