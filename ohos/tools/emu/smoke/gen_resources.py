# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Write the smoke HAP's resource files into a build copy of smoke/hap.

They are generated instead of committed: the public-repository scan treats resources/
directories and pictures as payload, and a placeholder icon is all the HAP needs.
Usage: python3 gen_resources.py <hap-dir>
"""
import json
import struct
import sys
import zlib
from pathlib import Path


def png(size, rgb):
    raw = b''.join(b'\0' + bytes(rgb) * size for _ in range(size))
    def chunk(tag, data):
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else json.dumps(data, indent=1).encode())


def main(hap):
    icon = png(64, (0x20, 0x60, 0xa0))
    app = hap / 'AppScope/resources/base'
    write(app / 'element/string.json', {'string': [{'name': 'app_name', 'value': 'S2ArmEmuSmoke'}]})
    write(app / 'media/app_icon.png', icon)
    entry = hap / 'entry/src/main/resources/base'
    write(entry / 'element/string.json', {'string': [{'name': 'module_desc', 'value': 'S2Arm emulator smoke'}]})
    write(entry / 'element/color.json', {'color': [{'name': 'bg', 'value': '#000000'}]})
    write(entry / 'profile/main_pages.json', {'src': ['pages/Index']})
    write(entry / 'media/app_icon.png', icon)


if __name__ == '__main__':
    main(Path(sys.argv[1]))
