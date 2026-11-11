#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""安装程序界面素材（24 位 BMP，Inno 的 TBitmapImage 直接读；视觉同 DMG 新窗口：深色底、S2ARM 字标、奶油色强调、圆角卡片）。
底色 #111113（同 DMG 新窗口与已通过的示意图；安装脚本用 WizardBackColor 把窗口底色设成它），素材都铺在这个底色上，不露方框。
用法：python3 make_header.py；改了字标、配色或卡片尺寸就重跑、把产物一起提交。产物：
  header.bmp   顶栏 S2ARM 字标
  card.bmp     卡片底（圆角、比底色亮一档、细描边），安装中的轮播与第一步的安装位置用
  bar.bmp      进度条（奶油色）；track.bmp 进度条底槽
  btn_install.bmp / btn_finish.bmp / btn_cancel.bmp   主按钮（奶油色圆角、深色字）/ 次按钮（描边圆角、浅色字）：文字画进图里——
                 深色样式会把叠在上面的文字强制画成浅色，奶油色底上就看不见了（天眼实机截图）
  check_on.bmp / check_off.bmp          复选框（奶油色勾 / 描边空框）"""
from pathlib import Path
from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
SRC = HERE.parents[2] / "docs/images/s2arm-wordmark-transparent.png"
BG, CARD, LINE, CREAM, TRACK = "#111113", "#1c1c1f", "#34343a", "#f5ead6", "#26262a"
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


def check(on, size=18):
    big = Image.new("RGB", (size * SS, size * SS), BG)
    d = ImageDraw.Draw(big)
    if on:
        d.rounded_rectangle([0, 0, size * SS - 1, size * SS - 1], radius=4 * SS, fill=CREAM)
        d.line([(4 * SS, 9.5 * SS), (7.5 * SS, 13 * SS), (14 * SS, 5.5 * SS)], fill=BG, width=2 * SS, joint="curve")
    else:
        d.rounded_rectangle([0, 0, size * SS - 1, size * SS - 1], radius=4 * SS, outline="#5a5a62", width=int(1.5 * SS))
    return big.resize((size, size), Image.LANCZOS)


wordmark().convert("RGB").save(HERE / "header.bmp")
def button(text, size, fill, ink, outline=None):
    from PIL import ImageFont
    w, h = size
    big = Image.new("RGB", (w * SS, h * SS), BG)
    d = ImageDraw.Draw(big)
    d.rounded_rectangle([0, 0, w * SS - 1, h * SS - 1], radius=h * SS // 2, fill=fill, outline=outline, width=SS if outline else 0)
    font = ImageFont.truetype(FONT, 15 * SS)
    box = d.textbbox((0, 0), text, font=font)
    d.text(((w * SS - (box[2] - box[0])) / 2 - box[0], (h * SS - (box[3] - box[1])) / 2 - box[1]), text, font=font, fill=ink)
    return big.resize(size, Image.LANCZOS)


FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"   # 生成机（Mac）上的中文字体；Windows 上不需要它，产物是位图
button("安装", (160, 40), CREAM, BG).save(HERE / "btn_install.bmp")
button("完成", (160, 40), CREAM, BG).save(HERE / "btn_finish.bmp")
button("取消", (144, 40), None, "#f2f0eb", "#5a5a62").save(HERE / "btn_cancel.bmp")
check(True).save(HERE / "check_on.bmp")
check(False).save(HERE / "check_off.bmp")
rounded((560, 120), CARD, LINE).save(HERE / "card.bmp")
rounded((560, 8), CREAM, radius=4).save(HERE / "bar.bmp")
rounded((560, 8), TRACK, radius=4).save(HERE / "track.bmp")
Image.new("RGB", (8, 8), BG).save(HERE / "bg.bmp")   # 按钮面板的底：深色样式下面板自己的 Color 不生效（会画成灰），铺这张纯底色
print("界面素材已生成，底色", BG)
