#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""安装程序界面素材（24 位 BMP，Inno 的 TBitmapImage 直接读；视觉同 DMG 新窗口：深色底、S2ARM 字标、奶油色强调、圆角卡片）。
底色取 Inno 内置深色样式的窗口底色 #2b2b2b（天眼实机截图取色），素材都铺在这个底色上，不露方框。
用法：python3 make_header.py；改了字标、配色或卡片尺寸就重跑、把产物一起提交。产物：
  header.bmp   顶栏 S2ARM 字标
  card.bmp     卡片底（圆角、比底色亮一档、细描边），安装中的轮播与第一步的安装位置用
  bar.bmp      进度条（奶油色）；track.bmp 进度条底槽"""
from pathlib import Path
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
SRC = HERE.parents[2] / "docs/images/s2arm-wordmark-transparent.png"
BG, CARD, LINE, CREAM, TRACK = "#2b2b2b", "#343437", "#46464c", "#f5ead6", "#3a3a3e"
SS = 4   # 先按 4 倍画再缩，圆角边缘平滑


def wordmark(height=34):
    mark = Image.open(SRC).convert("RGBA")
    mark = mark.crop(mark.getbbox())
    mark = mark.resize((round(mark.width * height / mark.height), height), Image.LANCZOS)
    out = Image.new("RGBA", mark.size, BG)
    out.alpha_composite(mark)
    return out


def rounded(size, fill, outline=None, radius=14):
    w, h = size
    big = Image.new("RGB", (w * SS, h * SS), BG)
    ImageDraw.Draw(big).rounded_rectangle([0, 0, w * SS - 1, h * SS - 1], radius=radius * SS, fill=fill, outline=outline, width=SS if outline else 0)
    return big.resize(size, Image.LANCZOS)


wordmark().convert("RGB").save(HERE / "header.bmp")
rounded((560, 120), CARD, LINE).save(HERE / "card.bmp")
rounded((560, 8), CREAM, radius=4).save(HERE / "bar.bmp")
rounded((560, 8), TRACK, radius=4).save(HERE / "track.bmp")
print("header.bmp card.bmp bar.bmp track.bmp 已生成，底色", BG)
