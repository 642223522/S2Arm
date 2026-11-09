"""出包期横版封面抓取（照 GC 落地版 LCFetchedCover.swift 的已验链搬运；Tiao 定出包期抓、不走设备端懒抓）。

按程序号直达 ec.nintendo.com/apps/<程序号>/US → 跳转后的商品页 __NEXT_DATA__ 里
schema.org linkedData 的 image（图床 assets.nintendo.com）为首选、整页正则兜底 →
下载 → 门槛校验：host = assets.nintendo.com、宽 ≥ 1280、宽 > 高（三款实测均为 1920×1080 JPEG）。

纪律（红线）：抓图是锦上添花——任何失败只回 (False, 原因)，绝不抛、绝不让出包失败；
调用方（pack/ship_ext.py container 组装）记一行黄字、该款退回只有 icon 的现状。
只用标准库；图不是 JPEG 时仅当 Pillow 在场才转码（出包 Python 按 applenv 清单带 Pillow），不在场就放弃。
按程序号通用，不写死任何游戏名单 / 图 URL。
"""
from __future__ import annotations

import json
import re
import struct
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1")
MIN_WIDTH = 1280
_PAGE_TIMEOUT = 30
_IMG_TIMEOUT = 30

_NEXT_DATA = re.compile(r'id="__NEXT_DATA__"[^>]*>(.*?)</script>', re.S)
_FALLBACK = re.compile(r'"image"\s*:\s*"(https://assets\.nintendo\.com/image/upload/[^"]*/store/software/switch/[0-9]+/[^"]+)"')


def _get(url: str, timeout: int) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        if r.status != 200:
            raise OSError(f"HTTP {r.status}")
        return r.read()


def _extract_image_url(html: str):
    """商品页主图 URL：linkedData 首选（与 GC 同判：条目 image 且 host 为 assets.nintendo.com），整页正则兜底。"""
    m = _NEXT_DATA.search(html)
    if m:
        try:
            root = json.loads(m.group(1))
            linked = root["props"]["pageProps"]["linkedData"]
            if isinstance(linked, dict):
                linked = [linked]
            for entry in linked:
                if isinstance(entry, dict):
                    img = entry.get("image")
                    if isinstance(img, str) and urlparse(img).hostname == "assets.nintendo.com":
                        return img
        except (ValueError, KeyError, TypeError):
            pass
    m = _FALLBACK.search(html)
    return m.group(1) if m else None


def _jpeg_size(data: bytes):
    if len(data) < 4 or data[:2] != b"\xff\xd8":
        return None
    sof = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
    i = 2
    while i + 9 <= len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xD8, 0xD9, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        seglen = struct.unpack(">H", data[i + 2:i + 4])[0]
        if marker in sof:
            h, w = struct.unpack(">HH", data[i + 5:i + 9])
            return w, h
        i += 2 + seglen
    return None


def _webp_size(data: bytes):
    if len(data) < 30 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        return None
    chunk = data[12:16]
    if chunk == b"VP8X":
        w = int.from_bytes(data[24:27], "little") + 1
        h = int.from_bytes(data[27:30], "little") + 1
        return w, h
    if chunk == b"VP8 " and len(data) >= 30 and data[23:26] == b"\x9d\x01\x2a":
        w = struct.unpack("<H", data[26:28])[0] & 0x3FFF
        h = struct.unpack("<H", data[28:30])[0] & 0x3FFF
        return w, h
    if chunk == b"VP8L" and len(data) >= 25 and data[20] == 0x2F:
        bits = int.from_bytes(data[21:25], "little")
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    return None


def _png_size(data: bytes):
    if len(data) >= 24 and data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR":
        return struct.unpack(">II", data[16:24])
    return None


def _image_size(data: bytes):
    return _jpeg_size(data) or _webp_size(data) or _png_size(data)


def fetch_banner(title_id: str, dest: Path):
    """按程序号抓一张横版封面写到 dest（JPEG）。→ (True, "1920x1080 jpeg") / (False, 原因)；失败不留半成品。"""
    tid = title_id.strip().upper()
    if not re.fullmatch(r"[0-9A-F]{16}", tid):
        return False, f"程序号格式不对：{title_id!r}"
    try:
        html = _get(f"https://ec.nintendo.com/apps/{tid}/US", _PAGE_TIMEOUT).decode("utf-8", "replace")
    except Exception as e:
        return False, f"商品页拉取失败：{e}"
    url = _extract_image_url(html)
    if not url:
        return False, "商品页没找到 assets.nintendo.com 主图"
    try:
        data = _get(url, _IMG_TIMEOUT)
    except Exception as e:
        return False, f"封面图下载失败：{e}"
    size = _image_size(data)
    if not size:
        return False, "封面图格式不认（非 JPEG/WebP/PNG）或已损坏"
    w, h = size
    if w < MIN_WIDTH or w <= h:
        return False, f"封面图不达门槛：{w}x{h}（要宽 ≥ {MIN_WIDTH} 且横版）"
    if _jpeg_size(data) is None:
        try:
            import io
            from PIL import Image
            im = Image.open(io.BytesIO(data))
            buf = io.BytesIO()
            im.convert("RGB").save(buf, "JPEG", quality=90)
            data = buf.getvalue()
        except Exception as e:
            return False, f"封面图不是 JPEG 且转码不可用：{e}"
    dest = Path(dest)
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_bytes(data)
        tmp.replace(dest)
    except OSError as e:
        return False, f"封面图落盘失败：{e}"
    return True, f"{w}x{h} jpeg {len(data)}B ← {url}"
