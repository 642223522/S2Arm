#!/usr/bin/env python3
"""预编引擎 APK + 一款游戏的数据 → 这款游戏的 APK（不跑 Gradle / NDK / JDK，只用 Python 标准库）。

  apk_assemble.py <引擎目录> <game_apk.py 输出目录> <输出 apk> [--key <签名钥文件>]

引擎目录（android/tools/engine_template.py 产出，随启动器发版提供）：
  engine.apk    nativeMode=game 的正式构建，占位身份 org.s2arm.game.t0000000000000000、占位图标
  engine.json   模板身份：占位包名、versionName 后缀、占位图标在 APK 里的条目（正式构建会缩短资源路径，
                所以构建模板时按占位图字节找出条目名记下，这里不按路径猜）、APK SHA-256
  identity.json 引擎里直连编译器的构建身份（direct_library.py describe 用，与 APK 同源）

每款不同的只有：清单里的包名（及由它派生的 taskAffinity / authorities）、versionCode、versionName、
显示名（改成字面串）、图标 PNG，以及 assets/game/。其余条目（dex、原生库、resources.arsc、许可）原样
按原压缩数据搬过去；签名用 apk_sign.py 的本机钥（v2）。
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
import zlib

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import apk_sign   # noqa: E402
import axml       # noqa: E402

ENGINE_SCHEMA = 's2a.android.engine.v1'
TEMPLATE_TITLE = '0000000000000000'
TEMPLATE_PACKAGE = 'org.s2arm.game.t' + TEMPLATE_TITLE
STORED_EXT = ('.bin', '.zip', '.png', '.so', '.arsc')   # 与 AGP 一致：这些不压缩（.bin 由 AAsset_getBuffer 原地读）
SIGNATURE_FILE = re.compile(r'META-INF/([^/]+\.(SF|RSA|DSA|EC)|MANIFEST\.MF)$')


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(4 << 20), b''):
            h.update(block)
    return h.hexdigest()


def load_engine(engine):
    engine = Path(engine)
    doc = json.loads((engine / 'engine.json').read_text())
    if doc.get('schema') != ENGINE_SCHEMA:
        raise ValueError(f'{engine}/engine.json 不是 {ENGINE_SCHEMA}')
    apk = engine / 'engine.apk'
    if sha256(apk) != doc['apkSha256']:
        raise ValueError('引擎 APK 与 engine.json 记录的 SHA-256 不符（引擎目录被改过或不完整）')
    return doc, apk


def read_properties(path):
    """java.util.Properties 的子集：game_apk.py 写的 key=value，值里 \\uXXXX 与反斜杠转义。"""
    props = {}
    for line in Path(path).read_text(encoding='ascii').splitlines():
        if not line or line.startswith(('#', '!')) or '=' not in line:
            continue
        key, value = line.split('=', 1)
        value = re.sub(r'\\u([0-9a-fA-F]{4})', lambda m: chr(int(m[1], 16)), value)
        value = re.sub(r'\\(.)', r'\1', value)
        props[key] = value.encode('utf-16', 'surrogatepass').decode('utf-16')   # 代理对拼回
    return props


def read_label(game):
    """res/values/game_name.xml 的显示名（game_apk.resource_string 的反向：XML 解析后去 aapt 反斜杠转义）。"""
    root = ET.parse(Path(game) / 'res/values/game_name.xml').getroot()
    node = root.find("string[@name='game_name']")
    if node is None or not (node.text or '').strip():
        raise ValueError('游戏目录缺显示名（res/values/game_name.xml）')
    return re.sub(r'\\(.)', r'\1', node.text)


class ZipOut:
    """只写本地条目 + 中央目录 + 无注释 EOCD；搬运条目时直接复制原压缩数据。"""

    def __init__(self, stream):
        self.f = stream
        self.cd = bytearray()
        self.count = 0

    def _header(self, name, method, crc, csize, usize, dostime, align):
        nb = name.encode('utf-8')
        extra = b''
        if align > 1:
            pad = -(self.f.tell() + 30 + len(nb)) % align
            if 0 < pad < 4:
                pad += align   # 放不下对齐扩展字段头：跳到下一个对齐点
            if pad:
                extra = struct.pack('<HH', 0xd935, pad - 4) + b'\0' * (pad - 4)   # zipalign 的对齐扩展字段
        offset = self.f.tell()
        flags = 0x0800 if any(c > 0x7f for c in nb) else 0
        t, d = dostime
        self.f.write(struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, flags, method, t, d, crc, csize, usize, len(nb), len(extra)) + nb + extra)
        self.cd += struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 20, 20, flags, method, t, d, crc, csize, usize,
                               len(nb), 0, 0, 0, 0, 0, offset) + nb
        self.count += 1

    @staticmethod
    def align_for(name, method):
        if method != zipfile.ZIP_STORED:
            return 1
        return 16384 if name.endswith('.so') else 4

    def copy_raw(self, src, info):
        """src 里的 info 条目原样搬：读本地头算出数据起点，复制 compress_size 字节。"""
        src.seek(info.header_offset)
        head = src.read(30)
        if head[:4] != b'PK\x03\x04':
            raise ValueError(f'{info.filename}: 本地头无效')
        name_len, extra_len = struct.unpack_from('<HH', head, 26)
        src.seek(info.header_offset + 30 + name_len + extra_len)
        dostime = _dos(info.date_time)
        self._header(info.filename, info.compress_type, info.CRC, info.compress_size, info.file_size, dostime,
                     self.align_for(info.filename, info.compress_type))
        left = info.compress_size
        while left:
            block = src.read(min(left, 4 << 20))
            if not block:
                raise ValueError(f'{info.filename}: 数据不完整')
            self.f.write(block)
            left -= len(block)

    def add_bytes(self, name, data, method=None):
        method = (zipfile.ZIP_STORED if name.endswith(STORED_EXT) else zipfile.ZIP_DEFLATED) if method is None else method
        crc = zlib.crc32(data)
        if method == zipfile.ZIP_DEFLATED:
            c = zlib.compressobj(9, zlib.DEFLATED, -15)
            payload = c.compress(data) + c.flush()
        else:
            payload = data
        self._header(name, method, crc, len(payload), len(data), _dos((1981, 1, 1, 1, 1, 2)), self.align_for(name, method))
        self.f.write(payload)

    def add_file(self, name, path):
        path = Path(path)
        if not name.endswith(STORED_EXT):
            return self.add_bytes(name, path.read_bytes())
        crc, size = 0, 0
        with path.open('rb') as f:
            for block in iter(lambda: f.read(4 << 20), b''):
                crc = zlib.crc32(block, crc)
                size += len(block)
        self._header(name, zipfile.ZIP_STORED, crc, size, size, _dos((1981, 1, 1, 1, 1, 2)), self.align_for(name, zipfile.ZIP_STORED))
        with path.open('rb') as f:
            shutil.copyfileobj(f, self.f, 4 << 20)

    def finish(self):
        cd_off = self.f.tell()
        self.f.write(self.cd)
        self.f.write(struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, self.count, self.count, len(self.cd), cd_off, 0))


def _dos(dt):
    y, mo, d, h, mi, s = dt
    return (h << 11) | (mi << 5) | (s // 2), ((max(y, 1980) - 1980) << 9) | (mo << 5) | d


def game_icons(game):
    """{密度: PNG 字节}：game_apk.py 渲染出的 res/mipmap-<密度>/game_icon.png；没有就空（沿用模板图标）。"""
    out = {}
    for path in sorted(Path(game).glob('res/mipmap-*/game_icon.png')):
        out[path.parent.name[len('mipmap-'):]] = path.read_bytes()
    return out


def rewrite_manifest(data, doc, title, version_code, version, label):
    m = axml.Manifest(data)
    package = 'org.s2arm.game.t' + title.lower()
    if m.get('manifest', 'package', android=False) != doc['package']:
        raise ValueError('引擎 APK 清单的包名不是 engine.json 记录的占位包名')
    if m.replace_prefix(doc['package'], package) < 1:
        raise ValueError('引擎 APK 清单里找不到占位包名')
    m.set_int('manifest', 'versionCode', version_code)
    m.set_string('manifest', 'versionName', version + doc['versionNameSuffix'])
    m.set_string('application', 'label', label)
    return m.to_bytes(), package


def assemble(engine, game, out, key_path=None):
    doc, engine_apk = load_engine(engine)
    game, out = Path(game), Path(out)
    props = read_properties(game / 'game.properties')
    title = props.get('titleId', '')
    if not re.fullmatch(r'[0-9A-F]{16}', title) or title == TEMPLATE_TITLE:
        raise ValueError('游戏目录的程序号无效')
    version_code = int(props.get('versionCode', '1'))
    label = read_label(game)
    icons = game_icons(game) if props.get('launcherIcon') == 'game' else {}
    icon_entries = doc.get('icons') or {}
    if icons and set(icons) != set(icon_entries.values()):
        raise ValueError(f'游戏图标密度 {sorted(icons)} 与引擎模板 {sorted(set(icon_entries.values()))} 不一致')
    assets = sorted(p for p in (game / 'assets').rglob('*') if p.is_file())
    if not any(p.relative_to(game / 'assets').as_posix().startswith('game/modules/') for p in assets):
        raise ValueError('游戏目录没有改写后的模块（assets/game/modules）')
    key, cert = apk_sign.load_or_create_key(key_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.' + out.name + '.', dir=out.parent)
    try:
        with os.fdopen(fd, 'w+b') as stream, zipfile.ZipFile(engine_apk) as z, open(engine_apk, 'rb') as src:
            w = ZipOut(stream)
            package = None
            for info in z.infolist():
                name = info.filename
                if SIGNATURE_FILE.match(name) or name.startswith('assets/game/'):
                    continue
                if name == 'AndroidManifest.xml':
                    data, package = rewrite_manifest(z.read(info), doc, title, version_code, props.get('version', 'unknown'), label)
                    w.add_bytes(name, data, zipfile.ZIP_DEFLATED)
                elif name in icon_entries and icons:
                    w.add_bytes(name, icons[icon_entries[name]], info.compress_type)
                else:
                    w.copy_raw(src, info)
            if package is None:
                raise ValueError('引擎 APK 没有 AndroidManifest.xml')
            for path in assets:
                w.add_file('assets/' + path.relative_to(game / 'assets').as_posix(), path)
            w.finish()
        apk_sign.sign_file(tmp, key, cert)
        os.chmod(tmp, 0o644)
        os.replace(tmp, out)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    return dict(apk=str(out), packageName=package, versionCode=version_code,
                signingCertSha256=hashlib.sha256(cert).hexdigest())


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument('engine')
    p.add_argument('game')
    p.add_argument('out')
    p.add_argument('--key', help='签名钥文件（缺省 ~/.s2arm/android/signing-key.json，没有就生成）')
    a = p.parse_args()
    try:
        print(json.dumps(assemble(a.engine, a.game, a.out, a.key), ensure_ascii=False))
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print('【红】组装 APK 失败：' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
