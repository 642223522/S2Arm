#!/usr/bin/env python3
"""S2Arm 抽取（graphics/tools/shbake/nxsh_extract.py）读不了的文件不静默跳过：python3 tests/nxsh_read_red_test.py，约 2 秒。
原先 work() 读不了就计一个「读失败」进统计行、continue：不报红、不进降级表，完成页与诊断都看不到这份文件整份漏抽
（RomFS 只有镜像 romfs.std 时直连抽取 19012 个文件这样跳过，另一路抽取补齐才没露馅）。
夹具：两个普通小文件 a.bin / locked.bin，locked.bin 读时抛 PermissionError。期望（手写，不跑被测实现推）：
  ① work() 直接调（romfs_list 读法换成对 locked.bin 抛错的替身）：读不了计 1、顶层文件 1（a.bin 照读），
     标准错误一行「【红】文件读不了：locked.bin（PermissionError：…）」；
  ② 整个抽取进程（locked.bin 设成不可读 chmod 000）：退出 0，降级表恰一行 extract / s2x:文件读不了 / 1 / 空提示，
     标准错误有收尾红行「【红】抽取：1 个文件读不了」；Windows 或 root 下 chmod 000 读得到，② 判不了、明说跳过"""
import contextlib, io, os, stat, subprocess, sys, tempfile
from pathlib import Path
R = Path(__file__).resolve().parents[1]
bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok; print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')
os.environ['S2A_ROMFS_WALK'] = 'off'
sys.path.insert(0, str(R / 'graphics/tools/shbake')); sys.path.insert(0, str(R / 'graphics/nvn/tools'))
import nxsh_extract as X, romfs_list
with tempfile.TemporaryDirectory() as t:
    root = Path(t, 'romfs'); root.mkdir(); out = Path(t, 'out'); (out / 'src').mkdir(parents=True)
    for n in ('a.bin', 'locked.bin'): (root / n).write_bytes(b'plain data, no shader' * 4)
    # ①
    real = romfs_list.open_file
    def deny(p, *a, **k):
        if os.path.basename(p) == 'locked.bin': raise PermissionError(13, 'Permission denied', p)
        return real(p, *a, **k)
    romfs_list.open_file = deny
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err): rows, st = X.work((str(root), [str(root / 'a.bin'), str(root / 'locked.bin')], str(out)))
    finally:
        romfs_list.open_file = real
    red = [l for l in err.getvalue().splitlines() if l.startswith('【红】')]
    chk('① 读不了计数', 1, st.get('【红】文件读不了', 0))
    chk('① 照读的顶层文件', 1, st.get('顶层文件', 0))
    chk('① 红行一行、带路径与原因', (1, True), (len(red), bool(red) and red[0].startswith('【红】文件读不了：locked.bin（PermissionError：')))
    # ②
    if os.name == 'nt' or (hasattr(os, 'geteuid') and os.geteuid() == 0):
        print('跳过 ②：本机 chmod 000 挡不住读（Windows / root），整进程这条判不了')
    else:
        os.chmod(root / 'locked.bin', 0)
        try:
            p = subprocess.run([sys.executable, '-B', str(R / 'graphics/tools/shbake/nxsh_extract.py'), str(Path(t, 'out2')), str(root)],
                               capture_output=True, text=True, timeout=120, env=dict(os.environ, J='1'))
        finally:
            os.chmod(root / 'locked.bin', stat.S_IRUSR | stat.S_IWUSR)
        chk('② 退出码', 0, p.returncode)
        if p.returncode: print(p.stderr[-2000:])
        deg = Path(t, 'out2/degrade.tsv')
        rows2 = [l.split('\t') for l in deg.read_text(encoding='utf-8').splitlines()] if deg.is_file() else []
        chk('② 降级表', [['extract', 's2x:文件读不了', '1', '', 'S2Arm 抽取跳过读不了的部分，里面的着色器运行时首遇现编']], rows2)
        chk('② 收尾红行', True, any(l.startswith('【红】抽取：1 个文件读不了') for l in p.stderr.splitlines()))
        chk('② 逐条红行带路径', True, any(l.startswith('【红】文件读不了：locked.bin') for l in p.stderr.splitlines()))
print('✓ nxsh_read_red：读不了的文件计红、进降级表 → 通过' if not bad else f'✗ nxsh_read_red：{bad} 项不符')
sys.exit(1 if bad else 0)
