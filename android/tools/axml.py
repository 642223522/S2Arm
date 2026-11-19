#!/usr/bin/env python3
"""编译后 AndroidManifest.xml（二进制 XML，AXML）的读取与改写，只用标准库。

  axml.py dump <apk | AndroidManifest.xml>    打印包名 / versionCode / versionName / label / debuggable

改写只动字符串池与属性值，不增删元素、不改属性个数：元素块大小不变，只有字符串池块变长。
资源 ID 映射（0x0180）只对应字符串池前 N 项，新串一律追加在池尾，不影响映射。
"""
import struct
import sys
import zipfile

RES_STRING_POOL = 0x0001
RES_XML = 0x0003
RES_XML_START_ELEMENT = 0x0102
UTF8_FLAG = 1 << 8
T_REFERENCE, T_STRING, T_INT_DEC, T_INT_HEX, T_BOOL = 0x01, 0x03, 0x10, 0x11, 0x12
ANDROID_NS = 'http://schemas.android.com/apk/res/android'
NO_INDEX = 0xffffffff


class AxmlError(ValueError):
    pass


def _decode_len8(data, at):
    n = data[at]
    if n & 0x80:
        return ((n & 0x7f) << 8) | data[at + 1], at + 2
    return n, at + 1


def _decode_len16(data, at):
    n = struct.unpack_from('<H', data, at)[0]
    if n & 0x8000:
        return ((n & 0x7fff) << 16) | struct.unpack_from('<H', data, at + 2)[0], at + 4
    return n, at + 2


def _encode_len8(n):
    if n > 0x7fff:
        raise AxmlError('字符串过长')
    return bytes([n]) if n < 0x80 else bytes([0x80 | (n >> 8), n & 0xff])


def _encode_len16(n):
    if n > 0x7fffffff:
        raise AxmlError('字符串过长')
    return struct.pack('<H', n) if n < 0x8000 else struct.pack('<HH', 0x8000 | (n >> 16), n & 0xffff)


def parse_pool(chunk, allow_styles=False):
    """(字符串列表, 是否 UTF-8)。带样式的池只读不改（allow_styles：resources.arsc 的全局池；清单里没有样式）。"""
    _, header_size, _, count, styles, flags, strings_start, _ = struct.unpack_from('<HHIIIIII', chunk, 0)
    if styles and not allow_styles:
        raise AxmlError('清单字符串池带样式，不支持改写')
    utf8 = bool(flags & UTF8_FLAG)
    offsets = struct.unpack_from(f'<{count}I', chunk, header_size)
    out = []
    for off in offsets:
        at = strings_start + off
        if utf8:
            _, at = _decode_len8(chunk, at)          # UTF-16 长度
            n, at = _decode_len8(chunk, at)          # 字节数
            out.append(chunk[at:at + n].decode('utf-8'))
        else:
            n, at = _decode_len16(chunk, at)
            out.append(chunk[at:at + 2 * n].decode('utf-16-le'))
    return out, utf8


def build_pool(strings, utf8):
    data, offsets = bytearray(), []
    for s in strings:
        offsets.append(len(data))
        if utf8:
            b = s.encode('utf-8')
            data += _encode_len8(len(s.encode('utf-16-le')) // 2) + _encode_len8(len(b)) + b + b'\0'
        else:
            u = s.encode('utf-16-le')
            data += _encode_len16(len(u) // 2) + u + b'\0\0'
    data += b'\0' * (-len(data) % 4)
    header_size = 28
    strings_start = header_size + 4 * len(strings)
    size = strings_start + len(data)
    head = struct.pack('<HHIIIIII', RES_STRING_POOL, header_size, size, len(strings), 0,
                       UTF8_FLAG if utf8 else 0, strings_start, 0)
    return head + struct.pack(f'<{len(strings)}I', *offsets) + bytes(data)


class Manifest:
    """可改写的清单：strings 是字符串池；attrs(tag) 列出某元素的属性位置。"""

    def __init__(self, data):
        if len(data) < 8:
            raise AxmlError('清单太短')
        kind, header_size, size = struct.unpack_from('<HHI', data, 0)
        if kind != RES_XML or size != len(data):
            raise AxmlError('不是二进制清单')
        at = header_size
        kind, _, pool_size = struct.unpack_from('<HHI', data, at)
        if kind != RES_STRING_POOL:
            raise AxmlError('清单缺字符串池')
        self.strings, self.utf8 = parse_pool(data[at:at + pool_size])
        self.head = data[:header_size]
        self.rest = bytearray(data[at + pool_size:])   # 资源映射 + 节点，原样保留（属性值就地改）

    def _elements(self):
        at = 0
        while at < len(self.rest):
            kind, header_size, size = struct.unpack_from('<HHI', self.rest, at)
            if size < 8 or at + size > len(self.rest):
                raise AxmlError('清单节点越界')
            if kind == RES_XML_START_ELEMENT:
                ext = at + header_size
                _, name, attr_start, attr_size, attr_count = struct.unpack_from('<IIHHH', self.rest, ext)
                yield self.strings[name], [ext + attr_start + i * attr_size for i in range(attr_count)]
            at += size

    def _attr(self, pos):
        ns, name, raw, _, _, dtype, value = struct.unpack_from('<IIIHBBI', self.rest, pos)
        return (self.strings[ns] if ns != NO_INDEX else None), self.strings[name], raw, dtype, value

    def find(self, tag, name, android=True):
        """第一个 <tag> 元素上的 name 属性位置；没有返回 None。"""
        for t, attrs in self._elements():
            if t != tag:
                continue
            for pos in attrs:
                ns, n, *_ = self._attr(pos)
                if n == name and (ns == ANDROID_NS) == android:
                    return pos
            return None
        return None

    def get(self, tag, name, android=True):
        pos = self.find(tag, name, android)
        if pos is None:
            return None
        _, _, raw, dtype, value = self._attr(pos)
        if dtype == T_STRING:
            return self.strings[value]
        if raw != NO_INDEX:
            return self.strings[raw]
        if dtype == T_BOOL:
            return value != 0
        if dtype in (T_INT_DEC, T_INT_HEX):
            return value
        if dtype == T_REFERENCE:
            return ('ref', value)
        return (dtype, value)

    def _string_index(self, text):
        self.strings.append(text)
        return len(self.strings) - 1

    def set_string(self, tag, name, text, android=True):
        """把属性改成字面字符串（原来是资源引用也改成字面串，例如 label）。新串追加在池尾。"""
        pos = self.find(tag, name, android)
        if pos is None:
            raise AxmlError(f'清单没有 <{tag}> 的 {name} 属性')
        idx = self._string_index(text)
        ns, nm = struct.unpack_from('<II', self.rest, pos)
        struct.pack_into('<IIIHBBI', self.rest, pos, ns, nm, idx, 8, 0, T_STRING, idx)

    def set_int(self, tag, name, value, android=True):
        pos = self.find(tag, name, android)
        if pos is None:
            raise AxmlError(f'清单没有 <{tag}> 的 {name} 属性')
        _, _, _, dtype, _ = self._attr(pos)
        if dtype not in (T_INT_DEC, T_INT_HEX):
            raise AxmlError(f'<{tag}> 的 {name} 不是整数')
        ns, nm = struct.unpack_from('<II', self.rest, pos)
        struct.pack_into('<IIIHBBI', self.rest, pos, ns, nm, NO_INDEX, 8, 0, dtype, value)

    def replace_prefix(self, old, new):
        """池里所有以 old 开头的串换前缀（包名、由包名派生的 taskAffinity / authorities）；返回换了几个。"""
        n = 0
        for i, s in enumerate(self.strings):
            if s == old or s.startswith(old + '.') or s.startswith(old + ':'):
                self.strings[i] = new + s[len(old):]
                n += 1
        return n

    def to_bytes(self):
        pool = build_pool(self.strings, self.utf8)
        body = pool + bytes(self.rest)
        head = bytearray(self.head)
        struct.pack_into('<I', head, 4, len(head) + len(body))
        return bytes(head) + body


DENSITY_NAMES = {120: 'ldpi', 160: 'mdpi', 213: 'tvdpi', 240: 'hdpi', 320: 'xhdpi', 480: 'xxhdpi', 640: 'xxxhdpi'}


def resource_files(arsc, type_name, key):
    """resources.arsc 里 <type_name>/<key> 各配置对应的文件路径 → {密度名: APK 条目名}（正式构建会缩短资源路径，按表查，不按路径猜）。"""
    kind, header_size, size = struct.unpack_from('<HHI', arsc, 0)
    if kind != 0x0002 or size != len(arsc):
        raise AxmlError('不是 resources.arsc')
    at, values, found = header_size, None, {}
    while at < len(arsc):
        kind, hsize, csize = struct.unpack_from('<HHI', arsc, at)
        if kind == RES_STRING_POOL and values is None:
            values, _ = parse_pool(arsc[at:at + csize], allow_styles=True)
        elif kind == 0x0200:   # 包
            pkg = arsc[at:at + csize]
            type_off, _, key_off = struct.unpack_from('<III', pkg, 268)
            types, _ = parse_pool(pkg[type_off:type_off + struct.unpack_from('<I', pkg, type_off + 4)[0]], allow_styles=True)
            keys, _ = parse_pool(pkg[key_off:key_off + struct.unpack_from('<I', pkg, key_off + 4)[0]], allow_styles=True)
            sub = hsize
            while sub < len(pkg):
                k2, h2, c2 = struct.unpack_from('<HHI', pkg, sub)
                if k2 == 0x0201:   # 类型块
                    type_id, flags, entry_count, entries_start = struct.unpack_from('<BBxxII', pkg, sub + 8)
                    if types[type_id - 1] == type_name:
                        density = struct.unpack_from('<H', pkg, sub + 20 + 14)[0]
                        offs_at = sub + h2
                        for i in range(entry_count):
                            if flags & 0x01:   # 稀疏：u16 下标 + u16 偏移/4
                                _, off = struct.unpack_from('<HH', pkg, offs_at + 4 * i)
                                off *= 4
                            elif flags & 0x02:   # 16 位偏移/4
                                off = struct.unpack_from('<H', pkg, offs_at + 2 * i)[0]
                                off = NO_INDEX if off == 0xffff else off * 4
                            else:
                                off = struct.unpack_from('<I', pkg, offs_at + 4 * i)[0]
                            if off == NO_INDEX:
                                continue
                            e = sub + entries_start + off
                            _, eflags, key_index = struct.unpack_from('<HHI', pkg, e)
                            if keys[key_index] != key or eflags & 0x0001:   # 复合值不是文件
                                continue
                            _, _, dtype, data = struct.unpack_from('<HBBI', pkg, e + 8)
                            if dtype == T_STRING:
                                found[DENSITY_NAMES.get(density, str(density))] = values[data]
                sub += c2
        at += csize
    return found


def identity(data):
    """(包名, versionCode, versionName, 可调试)：直接读清单，不依赖 aapt2。"""
    m = Manifest(data)
    package = m.get('manifest', 'package', android=False)
    code = m.get('manifest', 'versionCode')
    if not isinstance(package, str) or not isinstance(code, int):
        raise AxmlError('清单缺包名或 versionCode')
    return package, code, m.get('manifest', 'versionName'), m.get('application', 'debuggable') is True


def read_manifest(path):
    if str(path).endswith('.xml'):
        with open(path, 'rb') as f:
            return f.read()
    with zipfile.ZipFile(path) as z:
        return z.read('AndroidManifest.xml')


def main(argv):
    if len(argv) != 2 or argv[0] != 'dump':
        print(__doc__, file=sys.stderr)
        return 2
    m = Manifest(read_manifest(argv[1]))
    for tag, name, android in (('manifest', 'package', False), ('manifest', 'versionCode', True),
                               ('manifest', 'versionName', True), ('application', 'label', True),
                               ('application', 'icon', True), ('application', 'debuggable', True)):
        print(f'{tag}.{name}={m.get(tag, name, android)!r}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
