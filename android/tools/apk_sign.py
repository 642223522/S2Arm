#!/usr/bin/env python3
"""APK Signature Scheme v2 签名与本机签名钥，只用 Python 标准库（玩家电脑不需要 JDK / Android SDK）。

RSA / DER / 自签证书 / v2 签名块的写法改编自 nx2android（nxnative/dm/android/apk/apksign.py，
MIT License，Copyright (c) 2026 seedds；许可全文见 THIRD_PARTY_LICENSES.md）。本文件的改动：
签名钥按机器一份存进 ~/.s2arm/android/signing-key.json（换钥后机上已装的同款覆盖不了），
签名对象改成磁盘上的 ZIP 文件（大包不整份读进内存）。

  apk_sign.py key [<钥文件>]         打印证书 SHA-256（没有就先生成）
  apk_sign.py sign <apk> [<钥文件>]  原地给只含 ZIP 数据、还没签名的 APK 加 v2 签名块
"""
import hashlib
import json
import os
from pathlib import Path
import secrets
import struct
import sys

CHUNK = 1 << 20
ALG_RSA_PKCS1_SHA256 = 0x0103
V2_BLOCK_ID = 0x7109871a


# ---------------- RSA, DER, self-signed certificate（改编自 nx2android apksign.py） ----------------
def _is_prime(n):
    if n < 2:
        return False
    for p in (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37):
        if n % p == 0:
            return n == p
    d, r = n - 1, 0
    while d % 2 == 0:
        d //= 2
        r += 1
    for _ in range(40):
        x = pow(secrets.randbelow(n - 3) + 2, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(r - 1):
            x = pow(x, 2, n)
            if x == n - 1:
                break
        else:
            return False
    return True


def _gen_prime(bits):
    while True:
        p = secrets.randbits(bits) | (3 << (bits - 2)) | 1
        if p % 65537 != 1 and _is_prime(p):
            return p


def gen_key(bits=3072):
    p, q = _gen_prime(bits // 2), _gen_prime(bits // 2)
    n, e = p * q, 65537
    return {'n': n, 'e': e, 'd': pow(e, -1, (p - 1) * (q - 1))}


def _der(tag, body):
    n = len(body)
    ln = bytes([n]) if n < 0x80 else (lambda b: bytes([0x80 | len(b)]) + b)(n.to_bytes((n.bit_length() + 7) // 8, 'big'))
    return bytes([tag]) + ln + body


def _der_int(v):
    return _der(0x02, v.to_bytes(v.bit_length() // 8 + 1, 'big'))


def _der_seq(*xs):
    return _der(0x30, b''.join(xs))


def _der_oid(s):
    a = [int(x) for x in s.split('.')]
    out = bytes([a[0] * 40 + a[1]])
    for v in a[2:]:
        b = [v & 0x7f]
        v >>= 7
        while v:
            b.append(0x80 | (v & 0x7f))
            v >>= 7
        out += bytes(reversed(b))
    return _der(0x06, out)


_NULL = b'\x05\x00'
_ALG_SHA256_RSA = _der_seq(_der_oid('1.2.840.113549.1.1.11'), _NULL)


def spki(k):
    return _der_seq(_der_seq(_der_oid('1.2.840.113549.1.1.1'), _NULL),
                    _der(0x03, b'\0' + _der_seq(_der_int(k['n']), _der_int(k['e']))))


def rsa_sign(k, msg):
    di = bytes.fromhex('3031300d060960864801650304020105000420') + hashlib.sha256(msg).digest()
    kl = (k['n'].bit_length() + 7) // 8
    em = b'\x00\x01' + b'\xff' * (kl - len(di) - 3) + b'\x00' + di
    return pow(int.from_bytes(em, 'big'), k['d'], k['n']).to_bytes(kl, 'big')


def make_cert(k, common_name='S2Arm player build'):
    name = _der_seq(_der(0x31, _der_seq(_der_oid('2.5.4.3'), _der(0x0c, common_name.encode()))))
    validity = _der_seq(_der(0x17, b'260101000000Z'), _der(0x18, b'21251231000000Z'))
    tbs = _der_seq(_der(0xa0, _der_int(2)), _der_int(secrets.randbits(62) | 1), _ALG_SHA256_RSA, name, validity, name, spki(k))
    return _der_seq(tbs, _ALG_SHA256_RSA, _der(0x03, b'\0' + rsa_sign(k, tbs)))


# ---------------- 本机签名钥 ----------------
def default_key_path():
    return Path.home() / '.s2arm' / 'android' / 'signing-key.json'


def load_or_create_key(path=None):
    """(钥, 证书 DER)。按机器一份、长期复用：同款再出包用同一把钥，装得上已装的旧包、存档保留。"""
    path = Path(path) if path else default_key_path()
    if path.is_file():
        doc = json.loads(path.read_text())
        return {n: int(doc[n]) for n in ('n', 'e', 'd')}, bytes.fromhex(doc['cert'])
    key = gen_key()
    cert = make_cert(key)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump({'n': str(key['n']), 'e': str(key['e']), 'd': str(key['d']), 'cert': cert.hex()}, f)
    os.replace(tmp, path)
    return key, cert


# ---------------- APK Signature Scheme v2（改编自 nx2android apksign.py：签磁盘上的文件） ----------------
def _lp(b):
    return struct.pack('<I', len(b)) + b


def _chunk_digests(stream, length):
    digests = []
    while length > 0:
        c = stream.read(min(CHUNK, length))
        if not c:
            raise ValueError('APK 读取不完整')
        digests.append(hashlib.sha256(b'\xa5' + struct.pack('<I', len(c)) + c).digest())
        length -= len(c)
    return digests


def _bytes_digests(data):
    return [hashlib.sha256(b'\xa5' + struct.pack('<I', len(data[i:i + CHUNK])) + data[i:i + CHUNK]).digest()
            for i in range(0, len(data), CHUNK)]


def sign_file(apk, key, cert):
    """原地签名：apk 是「本地条目 + 中央目录 + EOCD」的未签名 ZIP（无注释），在中央目录前插入 v2 签名块。"""
    apk = Path(apk)
    with apk.open('rb') as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(size - 22)
        eocd = f.read(22)
        if eocd[:4] != b'PK\x05\x06':
            raise ValueError('APK 末尾不是无注释的 ZIP EOCD')
        cd_size, cd_off = struct.unpack_from('<II', eocd, 12)
        if cd_off + cd_size + 22 != size:
            raise ValueError('APK 中央目录位置不符')
        f.seek(cd_off - 16)
        if cd_off >= 16 and f.read(16) == b'APK Sig Block 42':
            raise ValueError('APK 已经签过名')
        f.seek(0)
        digests = _chunk_digests(f, cd_off)
        f.seek(cd_off)
        cd = f.read(cd_size)
    digests += _bytes_digests(cd) + _bytes_digests(eocd)   # EOCD 的中央目录偏移仍指向签名块将插入的位置（规范要求）
    digest = hashlib.sha256(b'\x5a' + struct.pack('<I', len(digests)) + b''.join(digests)).digest()
    signed = _lp(_lp(struct.pack('<I', ALG_RSA_PKCS1_SHA256) + _lp(digest))) + _lp(_lp(cert)) + _lp(b'')
    signer = _lp(signed) + _lp(_lp(struct.pack('<I', ALG_RSA_PKCS1_SHA256) + _lp(rsa_sign(key, signed)))) + _lp(spki(key))
    value = _lp(_lp(signer))
    pair = struct.pack('<QI', 4 + len(value), V2_BLOCK_ID) + value
    block_size = len(pair) + 8 + 16
    block = struct.pack('<Q', block_size) + pair + struct.pack('<Q', block_size) + b'APK Sig Block 42'
    new_eocd = eocd[:16] + struct.pack('<I', cd_off + len(block)) + eocd[20:]
    with apk.open('r+b') as f:
        f.seek(cd_off)
        f.write(block + cd + new_eocd)
        f.truncate()


def main(argv):
    if argv[:1] == ['key'] and len(argv) <= 2:
        _, cert = load_or_create_key(argv[1] if len(argv) == 2 else None)
        print(hashlib.sha256(cert).hexdigest())
        return 0
    if argv[:1] == ['sign'] and len(argv) in (2, 3):
        key, cert = load_or_create_key(argv[2] if len(argv) == 3 else None)
        sign_file(argv[1], key, cert)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
