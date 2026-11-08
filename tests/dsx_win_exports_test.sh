#!/bin/bash
# 门禁覆盖：graphics/dsx/dsx_win.py graphics/dsx/win_posix.h graphics/dsx/dsx_xc.c graphics/dsx/gal_tessxc.c graphics/dsx/gal_vpullc.c graphics/dsx/gal_tess.h graphics/dsx/Makefile graphics/tools/direct/dsh/SpvCross.cs graphics/tools/direct/dsh/batch/Build.cs tests/dsx_win_exports_test.sh
# Windows 出包机的直连翻译库 dsx.dll 的导出要盖住 S2A.Dsh 的全部 DllImport("dsx")（11-05 Windows 出包机巫师3：旧小库没有 nxgal_dmsh_xc_tess，
#   外壳 / 域着色器 22 支每支翻译失败，只记成缺键、整单照绿；11-08 起 dsx.dll 与 libdsx 同一源码集合，nxgal_dmsh_xc 也在，不再豁免）。
#   bash tests/dsx_win_exports_test.sh（纯静态，约 1 秒；Windows 真编不在本测）
# 期望（手写，不跑被测实现推）：
#   ① dsx_win.py 导出表 ⊇ graphics/tools/ 下全部 C#（含 tests/）的 DllImport("dsx") 名，含 nxgal_dmsh_xc
#   ② 点名：nxgal_dmsh_xc、nxgal_dmsh_xc_free、nxgal_dmsh_xc_tess、nxgal_dmsh_spill、nxgal_dmsh_color_round、nxgal_spv_harden、nxgal_spv_free 都在
#   ③ 曲面段源码是纯 C：gal_tessxc.c / gal_vpullc.c / gal_tess.h 里没有 #import、没有 Metal / Foundation 头
#   ④ 出库遇到 EntryPointNotFoundException / DllNotFoundException 整份退出（Build.cs 原生库缺件那一行）
#   ⑤ 三端同一源码集合：dsx_win.py 编的 C 源 = graphics/dsx 全部 *.c（Makefile SRCS 的口径），导出表 = 这些源码里 NXGAL_API 定义的全部函数（9 个）
#   ⑥ 通用渲染器不再定义直连入口：graphics/metal 下 *.m / *.c 没有 NXGAL_API 的 nxgal_dmsh_* / nxgal_spv_* 定义；C# 里没有 DllImport("nxgal") 调直连入口
# 负对照（手做，见坑记录）：dsx_win.py 的 SRCS 去掉 dsx_xc.c → ① ② ⑤ 红
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$H" <<'PY'
import glob, os, re, sys
H = sys.argv[1]; bad = 0
def chk(name, ok, got):
    global bad; bad += not ok; print(f'{"通" if ok else "不通"} {name}：{got}')
sys.path.insert(0, os.path.join(H, 'graphics/dsx')); import dsx_win
have = set(dsx_win.exports())
used, stale = set(), set()
for f in glob.glob(os.path.join(H, 'graphics/tools/**/*.cs'), recursive=True) + glob.glob(os.path.join(H, 'services/**/*.cs'), recursive=True):
    t = open(f, encoding='utf-8').read()
    used |= set(re.findall(r'DllImport\("dsx"\)\][^;]*?\b(nxgal_\w+)\s*\(', t))
    stale |= set(re.findall(r'DllImport\("nxgal"\)\][^;]*?\b(nxgal_(?:dmsh|spv)_\w+)\s*\(', t))
chk('① 导出表盖住全部 DllImport("dsx")', bool(used) and used <= have, f'要 {len(used)} 个，缺 {sorted(used - have) or "无"}')
named = {'nxgal_dmsh_xc', 'nxgal_dmsh_xc_free', 'nxgal_dmsh_xc_tess', 'nxgal_dmsh_spill', 'nxgal_dmsh_color_round', 'nxgal_spv_harden', 'nxgal_spv_free'}
chk('② 点名的 7 个导出都在', named <= have, f'缺 {sorted(named - have) or "无"}')
M = os.path.join(H, 'graphics/dsx'); objc = []
for n in ('gal_tessxc.c', 'gal_vpullc.c', 'gal_tess.h'):
    t = open(os.path.join(M, n), encoding='utf-8').read()
    if re.search(r'^\s*#\s*import\b|<Metal/|<Foundation/|\bNSString\b|\bid<', t, re.M): objc.append(n)
chk('③ 曲面段纯 C', not objc, f'带 Objective-C / Metal 的 {objc or "无"}')
b = open(os.path.join(H, 'graphics/tools/direct/dsh/batch/Build.cs'), encoding='utf-8').read()
chk('④ 原生库缺件整份退出', bool(re.search(r'EntryPointNotFoundException.*DllNotFoundException.*Environment\.Exit\(1\)', b)), '')
srcs = sorted(os.path.basename(g) for g in glob.glob(os.path.join(M, '*.c')))
defs = set()
for g in srcs: defs |= set(re.findall(r'^NXGAL_API\b[^(]*?\b(nxgal_\w+)\s*\(', open(os.path.join(M, g), encoding='utf-8').read(), re.M))
chk('⑤ 与 libdsx 同一源码集合、同一导出', list(dsx_win.SRCS) == srcs and have == defs and len(have) == 9, f'源 {len(dsx_win.SRCS)}/{len(srcs)}，导出 {len(have)}/{len(defs)}')
mdefs = set()
for g in glob.glob(os.path.join(H, 'graphics/metal/*.m')) + glob.glob(os.path.join(H, 'graphics/metal/*.c')):
    mdefs |= set(re.findall(r'^NXGAL_API\b[^(]*?\b(nxgal_(?:dmsh|spv)_\w+)\s*\(', open(g, encoding='utf-8').read(), re.M))
chk('⑥ 渲染器不再定义 / 不再经 nxgal 调直连入口', not mdefs and not stale, f'graphics/metal 定义 {sorted(mdefs) or "无"}；DllImport("nxgal") 调 {sorted(stale) or "无"}')
print(f'{"✓" if not bad else "✗"} dsx_win_exports：{bad} 不通')
sys.exit(1 if bad else 0)
PY
