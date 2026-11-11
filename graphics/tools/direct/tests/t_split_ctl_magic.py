#!/usr/bin/env python3
# 代码区碰巧含控制段魔数 34 12 76 98（#477：一支着色器含这四字节，shader_split 整批退出，离线直连库 0 支，进游戏现场编译卡 26 秒）。
#   期望手写：① 代码区含魔数：pkg_record 不退出；按记录头长度切（同 PkgRead.cs Split）切回的代码 / 控制段与输入逐字节相同
#   ② 正常记录照旧：切回相同
#   ③ 代码区含分隔符 BTCDBTCD：仍退出（按分隔符分记录的读法会真的切错）
import os, struct, sys, tempfile
from pathlib import Path

H = Path(__file__).resolve().parents[4]
bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')

def split(rec):   # PkgRead.cs Split：+0x28 控制段长、+0x2c 代码长，代码从 +0x38 起
    nctl, ncode = struct.unpack_from('<2I', rec, 0x28)
    return bytes(rec[0x38:0x38 + ncode]), bytes(rec[0x38 + ncode:0x38 + ncode + nctl])

def build(code, ctl):
    try: return shader_split.pkg_record('k', ctl, code), None
    except SystemExit as e: return None, str(e)

with tempfile.TemporaryDirectory(prefix='ctlmagic-') as t:
    (Path(t) / 'game.tsv').write_text('shader_groups\tsynthetic=synthetic\nshader_note\tsynthetic\n')
    os.environ['DM_GAME'] = t
    sys.path.insert(0, str(H / 'translator'))
    import shader_split
    magic = bytes.fromhex('34127698')
    ctl = magic + bytes(range(0x40))
    code = b'\x00' * 16 + magic + b'\x11' * 12
    rec, err = build(code, ctl)
    chk('① 代码区含魔数：不退出', None, err)
    chk('① 按头长度切回代码 / 控制段逐字节相同', (code, ctl), split(rec) if rec else None)
    code2 = b'\x22' * 32
    rec, err = build(code2, ctl)
    chk('② 正常记录：不退出、切回相同', (None, (code2, ctl)), (err, split(rec) if rec else None))
    rec, err = build(b'\x00' * 8 + b'BTCDBTCD' + b'\x00' * 8, ctl)
    chk('③ 代码区含分隔符：仍退出', True, bool(err and 'record separator' in err))
print(f'代码区含控制段魔数：失败 {bad}')
sys.exit(1 if bad else 0)
