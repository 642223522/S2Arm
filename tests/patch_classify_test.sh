#!/bin/bash
# 门禁覆盖：tools/patch_index.py tools/patch_pack.py
# 社区补丁分类单测（tools/patch_index.py classify / own_name，约 1 秒）：bash tests/patch_classify_test.sh
# 11-15 奥德赛开场动画闪退：聚合仓库 generated-narrow-aspect/ 目录下的「关动态分辨率」「关 FXAA」被上层目录名里的 aspect 判成画幅类，
#   绕过 iOS 不打画面类的规则跟着满屏默认打开；Switch-Emulator-Ultrawide-FPS-Mods 仓库名里的 Ultrawide 把同仓库的帧率 / 1080P / LOD 全判成画幅。
# 期望（按规则手写）：类别只看补丁自己的名字（exefs 往上两级 + 文件名）与文件头，不看更上层的仓库 / 聚合目录名；画面类正向认定，认不出 = other
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$H" <<'PY'
import sys; sys.path.insert(0, sys.argv[1] + '/tools'); import patch_index as P
bad = 0
def ck(name, got, want):
    global bad
    ok = got == want; bad |= not ok; print(('通 ' if ok else '不通 ') + f'{name}：期望 {want}，实得 {got}')
C = [
 ('① 聚合目录名带 aspect、补丁本身是关动态分辨率 → 画面', 'pacoa-kdbg/Switch-Emulator-Ultrawide-FPS-Mods/generated-narrow-aspect/Game [0100000000010000][mods]/[Disable Dynamic Resolution v1.3.0] Nova supplied/exefs/1.3.0.pchtxt',
  '# Game [0100000000010000] v1.3.0 - Disable Dynamic Resolution', 'gfx'),
 ('② 仓库名带 Ultrawide、补丁是 60 帧 → 帧率', 'Fl4sh9174/Switch-Emulator-Ultrawide-FPS-Mods/Game [0100000000010000][mods].zip/[60FPS Snapshot Mode v1.3.0]/exefs/1.3.0 v2.pchtxt',
  '# GAME [0100000000010000] v1.3.0 - 60FPS', 'fps'),
 ('③ mod 名写 21:9 → 画幅', 'Fl4sh9174/Switch-Emulator-Ultrawide-FPS-Mods/Game [0100000000010000][mods].zip/[21.9 Ultrawide Adjusted HUD v1.4.1]/exefs/1.3.0.pchtxt',
  '# GAME [0100000000010000] v1.3.0 - 21:9 Ultrawide', 'widescreen'),
 ('④ 变体只用数字命名、类别在上一级 Aspect Ratio → 画幅', "Kenji-NX/switch-pchtxt-mods/Game/010015100B514000/Aspect Ratio/16'10/exefs/1.0.0.pchtxt", '# Game [010015100B514000] v1.0.0', 'widescreen'),
 ('⑤ 没有 exefs 结构：只看最后两段与文件头', 'repo/some aspect dir/Game/1080p.pchtxt', '# Game v1.0 - 1080p', 'gfx'),
]
for name, path, text, want in C: ck(name, P.classify(path, text)[0], want)
# ⑦–⑪ 画面类正向认定（11-15：认不出的归 other——不默认开、iPhone 不打；6 份 Mac 诊断里「No Music」「Remove Audio」默认开着，玩家一开游戏就没声音）
for name, path, text, want in [
 ('⑦ 去背景音乐 → other', 'Game/[mods]/[No Music v1.0]/exefs/1.0.0.pchtxt', '# Game v1.0 - No Music', 'other'),
 ('⑧ 改金币 → other', 'Game/[mods]/[Subtract Coins subtracts 0]/exefs/1.0.0.pchtxt', '# Game', 'other'),
 ('⑨ 关 FXAA → gfx', 'Game/[mods]/[Disable FXAA v1.3.0]/exefs/1.3.0.pchtxt', '# Game v1.3.0 - Disable FXAA', 'gfx'),
 ('⑩ 16.10 画幅 → widescreen；版本号 1.16.10 不算', 'Game/1.0.1/[16.10]/exefs/1.0.1.pchtxt', '# Game', 'widescreen'),
 ('⑩b 版本号 1.16.10 不当画幅', 'Game/Skip Intro/exefs/1.16.10.pchtxt', '# Game 1.16.10', 'other'),
]: ck(name, P.classify(path, text)[0], want)
ck('⑪ 画面合集仓库里只写版本号的 → gfx（按仓库）', P.classify('Yoshi/1.0.1.pchtxt', '# Yoshi [01006000040C2800]', 'cucholix/NX-IPS-romfs-compilation')[0], 'gfx')
ck('⑪b 同样的文件在别的仓库 → other', P.classify('Yoshi/1.0.1.pchtxt', '# Yoshi [01006000040C2800]', 'someone/other-repo')[0], 'other')
ck('⑥ own_name 取 exefs 往上两级', P.own_name('a/b/c/[mod]/exefs/x.pchtxt'), 'c/[mod]/exefs/x.pchtxt')
# ⑫ 画面类方向（gfx_dir，11-16 维护者：iOS 只收降负载；判据 cmdr 判据表：比底座档默认少干活 = load、多干活 = quality、判不出 / 中性 = ''）
D = lambda name, text='': P.gfx_dir(f'Repo/Game [0100000000010000][mods].zip/[{name} v1.3.0]/exefs/1.3.0.pchtxt', text)
for name, got, want in [
 ('⑫a 关 FXAA → load', D('Disable FXAA'), 'load'),
 ('⑫b 去景深（段注释 Removed depth of field）→ load', D('No DOF', '# Game [0100000000010000] v1.3.0 - No DOF\n\n// Removed depth of field\n@enabled\n00000010 1F2003D5\n'), 'load'),
 ('⑫c 低阴影 → load', D('Low Quality Shadows'), 'load'),
 ('⑫d 1280x720 底座 → load', D('1280x720 Docked'), 'load'),
 ('⑫e 4K → quality', D('4K'), 'quality'),
 ('⑫f 2560x1440 → quality', D('2560x1440'), 'quality'),
 ('⑫g 关动态分辨率（锁最高档）→ quality', D('Disable Dynamic Resolution'), 'quality'),
 ('⑫h 1080p（900p–1080p 判不出升降）→ 认不出', D('1080p'), ''),
 ('⑫i 1080p-720p 一对 → 认不出', D('1080p-720p'), ''),
 ('⑫j 名字关 FXAA、文件头写 Improved Quality（两类都中）→ 认不出', D('Disable FXAA', '# Game [0100000000010000] 1.3.0 - Improved Quality\n// Disable FXAA and improve mipmap lodbias\n'), ''),
 ('⑫k 关 FXAA 和动态分辨率（关动态分辨率 = 提画质）→ 认不出', D('Disable FXAA & Dynamic Resolution'), ''),
 ('⑫l 关景深 + 加视野（中性改动，整份开关）→ 认不出', D('Disable DOF + Increase FOV'), ''),
 ('⑫m 720p 掌机档目标（我们跑底座档）→ 认不出', D('720p Handheld Target'), ''),
 ('⑫n 汇编备注里的 handheld resx 不算信号；只剩 LOD → 认不出', D('LOD', '// mov w9, #0x500 (handheld resx)\n'), ''),
 ('⑫o 游戏名里的词不算（文件头游戏名带 4K、变体是关泛光）→ load', D('Disable Bloom', '# 4K Racing [0100000000010000] v1.3.0 - Disable Bloom\n'), 'load'),
 ('⑫p 版本号 1.0.720 不当 720p；只写 LOD → 认不出', P.gfx_dir('Game/LOD/exefs/1.0.720.pchtxt'), ''),
 ('⑫q 4:3 画幅 + 960x720 掌机 → 认不出', D('1440x1080', '// 4:3 Standard\n// 1440x1080 Docked 960x720 Handheld\n'), ''),
]: ck(name, got, want)
sys.exit(1 if bad else 0)
PY
r=$?; [ $r = 0 ] && echo "✅ patch_classify_test 全过" || { echo "🔴 patch_classify_test 有不通项"; exit 1; }
