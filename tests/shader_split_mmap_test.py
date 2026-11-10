"""translator/shader_split.py 大文件走 mmap（P5R 玩家：12.7 GB 的 CPK 整读进一个进程 13 GB）：合成字节，不用游戏数据。期望手写：
① Mapped 的「多字节包含」按内容判（裸 mmap 判 False——这次抓到的坑，作对照），逐字节遍历是整数（同 bytes）
② 超过 BIG 的普通文件交给 scan_plain 的是 Mapped、不超过的是 bytes；同一份内容两种读法 scan_file 结果相同"""
import mmap, os, shutil, struct, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "translator"))
bad = 0
def ck(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f"{'✓' if ok else '✗'} {name}：期望 {want}，实 {got}")
with tempfile.TemporaryDirectory(prefix="s2a-ssmm-") as d:
    prof = Path(d) / "profile"; prof.mkdir()
    shutil.copyfile(ROOT / "tests/fixtures/shader_split_reuse/shader_split_reuse_profile.tsv", prof / "game.tsv")
    os.environ["DM_GAME"] = str(prof)
    import shader_split as ss
    f = Path(d) / "blob.bin"; data = b"\x01\x02junk" + b"BNSH\0\0\0\0" + b"MGFX" + bytes(64); f.write_bytes(data)
    with open(f, "rb") as h:
        bare = mmap.mmap(h.fileno(), 0, access=mmap.ACCESS_READ); m = ss.Mapped(h.fileno(), 0, access=mmap.ACCESS_READ)
    ck("① 裸 mmap 的 b'BNSH…' in：False（坑）", False, b"BNSH\0\0\0\0" in bare)
    ck("① Mapped 的 b'BNSH…' in：True", True, b"BNSH\0\0\0\0" in m)
    ck("① Mapped 没有的内容 in：False", False, b"NOPE" in m)
    ck("① Mapped 遍历同 bytes（整数）", list(data[:6]), list(m)[:6])
    ck("① 切片 / 下标 / find 同 bytes", (data[4:8], data[3], data.find(b"MGFX")), (m[4:8], m[3], m.find(b"MGFX")))
    bare.close(); m.close()
    seen = []; real = ss.scan_plain
    def spy(path, rel, dd, found, trees):
        seen.append(type(dd).__name__); return real(path, rel, dd, found, trees)
    ss.scan_plain = spy
    ss.BIG = 1 << 62; a = ss.scan_file((str(f), "blob.bin"))
    ss.BIG = 0; b = ss.scan_file((str(f), "blob.bin"))
    ss.scan_plain = real
    ck("② 不超 BIG 给 bytes、超过给 Mapped", ["bytes", "Mapped"], seen)
    ck("② 两种读法结果相同", repr(a), repr(b))
print(f"shader_split_mmap：{'全过' if not bad else f'{bad} 红'}"); sys.exit(1 if bad else 0)
