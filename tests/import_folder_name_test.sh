#!/bin/bash
# 门禁覆盖：ios/l10n/ runtime/src/pack_apply.c pack/jobs/install.py
# 手机上导入文件夹名三处一致（诊断#4eb185：0.4.1 加西 / 法 / 日界面时把 img.importFolder 译成别的名字，
#   app.m 只建 s2a_img_import_dirs 里的名字 → 这几种语言下导入文件夹不建、玩家无处放 .img）：
#   ① 每份 ios/l10n/*.lproj/S2ArmHost.strings 的 img.importFolder 都是 pack_apply.c s2a_img_import_dirs 之一
#   ② pack/jobs/install.py IMPORT_DIRS 与 s2a_img_import_dirs 同值同序（电脑端推送往这两个名字推）
set -u; cd "$(dirname "$0")/.." || exit 1
python3 -B - <<'PY'
import re, sys, glob
c = open('runtime/src/pack_apply.c', encoding='utf-8').read()
m = re.search(r's2a_img_import_dirs\[\d+\]\s*=\s*\{([^}]*)\}', c)
known = re.findall(r'"([^"]*)"', m.group(1)) if m else []
bad = 0
if len(known) < 2: print('不通：pack_apply.c 里读不出 s2a_img_import_dirs'); sys.exit(1)
files = sorted(glob.glob('ios/l10n/*.lproj/S2ArmHost.strings'))
if not files: print('不通：没找到 ios/l10n/*.lproj/S2ArmHost.strings'); sys.exit(1)
for f in files:
    v = re.findall(r'^"img\.importFolder"\s*=\s*"([^"]*)";', open(f, encoding='utf-8').read(), re.M)
    if len(v) != 1 or v[0] not in known:
        print(f'不通 ① {f}：img.importFolder = {v}，不在 {known} 里'); bad += 1
    else: print(f'通 ① {f}：{v[0]}')
inst = open('pack/jobs/install.py', encoding='utf-8').read()
m2 = re.search(r'^IMPORT_DIRS\s*=\s*\(([^)]*)\)', inst, re.M)
dirs = re.findall(r'"([^"]*)"', m2.group(1)) if m2 else []
if dirs != known: print(f'不通 ② install.py IMPORT_DIRS {dirs} ≠ pack_apply.c {known}'); bad += 1
else: print(f'通 ② install.py IMPORT_DIRS 与 pack_apply.c 一致：{dirs}')
sys.exit(1 if bad else 0)
PY
rc=$?
[ "$rc" = 0 ] && echo "import_folder_name 单测全过" || { echo "import_folder_name 单测有不通"; exit 1; }
