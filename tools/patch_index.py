#!/usr/bin/env python3
"""社区补丁索引（11-12 维护者：出包时自动对接公开库；「库里的帧率、画幅都是经过验证的，玩家想用就给他打开」）。
我方这边跑：读各上游仓库的本地浅克隆，出一份只含元数据的索引（不含补丁字节）挂到下载站；玩家出包时 pack/jobs/patches.py 取索引，
按「仓库 + 提交号 + 路径」从 raw.githubusercontent 下载对得上这款的文件（不走 GitHub API：未登录每小时 60 次，玩家连出几款就撞上限）。

用法：patch_index.py <上游镜像目录> <输出 .json.gz>
  镜像目录里每个上游一个子目录 <owner>__<repo>：带 .git 的取 HEAD 提交号；删过 .git 的按镜像目录 SOURCES.tsv（来源 / 提交号两列）取。
每行：repo / commit / path / size / sha256 / kind（pchtxt | ips）/ cat（fps | widescreen | gfx）/ target_fps / aspect /
  gids（路径里出现的程序号）/ bids（pchtxt 的 @nsobid、ips 的文件名构建号）/ license（仓库 LICENSE 首行，没有写空）。
romfs 下的文件（游戏数据）、大于 2 MB 的文件不收。
配套里有显存 / 堆 / 内存配置的 mod（同一个 mod 根下既有 exefs 补丁又有 romfs/ 里的 HeapSize 一类，散文件或包内都算）连它的 exefs 补丁也不收（11-16 D-Q3QJ：王国之泪 1800p 只收了改分辨率的
  exefs、漏了 romfs 里调大显存堆的 HeapDef，按 1800p 建缓冲分配失败崩溃）；同一份内容在别的库里单独出现也不收。要整份交付走 mod 通道（0.5.0 之后）。
压缩包（.zip / .rar，11-13：超宽屏 / 老牌补丁库把每款打成一个包）：包里的 exefs 补丁与 cheats/<构建号>.txt 金手指逐个成行，path 是包本身，
  另记 member（包内路径）、archive_sha256 / archive_size（整包，下载时先核它）；sha256 / size 是包内这一份。rar 用系统 bsdtar（libarchive）读。
金手指（kind=cheat，cat=cheat）：cheats/<构建号>.txt（散文件或包内）；出包时由 pack/jobs/cheats.py 收进金手指一栏，不进画面补丁。
  已由金手指专门通道取的库（CHEAT_LIBS，pack/jobs/cheats.py LIBRARIES）不在这里重复收。"""
import gzip
import hashlib
import json
import os
import re
import subprocess
import sys
import zipfile

MAX = 2 << 20
GID = re.compile(r'01[0-9A-Fa-f]{14}')


def own_name(path):
    """补丁自己的名字：Atmosphere 结构 <mod 名>/exefs/<文件> 取 mod 名的上一级起往后（变体只用数字命名时类别写在上一级，
    如 Kenji-NX 的 Aspect Ratio/16'10/exefs/）；不是这种结构取最后两段。
    再往上的仓库名、聚合目录名不算（11-15 奥德赛：pacoa-kdbg 的 generated-narrow-aspect/ 目录下「关动态分辨率」「关 FXAA」被目录名里的
    aspect 判成画幅类，绕过 iOS 不打画面类的规则跟着满屏默认打开，开场动画闪退）"""
    parts = [p for p in path.replace('\\', '/').split('/') if p]
    low = [p.lower() for p in parts]
    if 'exefs' in low:
        i = len(low) - 1 - low[::-1].index('exefs')
        return '/'.join(parts[max(0, i - 2):])
    return '/'.join(parts[-2:])


GFX = re.compile(r'resolution|\bres\b|\d{3,4}\s*[px]\s*\d{3,4}|\b\d{3,4}p\b|\b(1080|720|900|1440|2160|4k)\b|dynamic|\blod|level of detail|detail|'
                 r'anti.?alias|\b(fx|sm|t|ms)aa\b|shadow|bloom|blur|depth of field|\bdof\b|\bfog\b|quality|graphic|sharpen|filter|anisotrop|'
                 r'ambient occlusion|\bssao\b|render|texture|draw distance|lighting|reflection|\bhdr\b|upscal|downscal|scaling|docked|gamma|'
                 r'brightness|colou?r|contrast|vignette|chromatic|film grain|post.?process|outline|mipmap|bias|v-?sync|frame ?buffer|visual|'
                 r'\b\d{1,2}k\b|\b(ss|ms|fx|sm|t)?aa\b|cloud|flare|heat ?wave|lens|shading|shader|tint|\bfov\b|field of view|crop')


# 整个仓库都是画面合集、补丁自身只写版本号的（文件名 1.0.1.pchtxt、文件头只有游戏名）：自身认不出时按仓库判画面（11-15 全库普查）
GFX_REPOS = {'cucholix/NX-IPS-romfs-compilation'}


def classify(path, text='', repo=''):
    """类别按补丁自己的名字（own_name）/ 文件头关键词（同本机补丁库覆盖表口径）：帧率 / 画幅 / 其余画面"""
    # 先去网址（11-13）：作者署名里的仓库网址（github.com/StevensND/ue4-emuswitch-60fps）落在前 400 字内，「60fps」把同一作者的关景深 / 关抗锯齿 / 分辨率补丁全判成帧率 60
    s = re.sub(r'https?://\S+', ' ', (own_name(path) + '\n' + text[:400]).lower())
    fps = re.search(r'(\d{2,3})\s*fps', s)
    if re.search(r'ultra\s*wide|widescreen|21[:x_.]9|32[:x_.]9|aspect|(?<![\d.])16[:x_.\']10(?![\d.])', s):   # 16:10 也写成 16.10 / 16\'10：前后不挨数字和点，免得把版本号 1.16.10 当画幅
        m = re.search(r'(\d{1,2}(?:\.\d)?)\s*[:x_\-](9|10)\b', s)
        return 'widescreen', '', f'{m.group(1)}:{m.group(2)}' if m else ''
    if fps or 'fpslock' in s or 'speedfix' in s or re.search(r'(unlock|uncap|unlimit)\w*[\s_-]*fps|fps[\s_-]*(unlock|uncap|unlimit)', s):
        return 'fps', fps.group(1) if fps else '', ''
    # 画面类按正向认定（11-15：原先认不出的一律算画面，「No Music」「Remove Audio」「Subtract Coins」这类声音 / 玩法补丁跟着画面类默认打开，
    #   Mac 玩家一开游戏就没有背景音乐、没有声音，6 份诊断里都是开着的）；认不出的归 other：不默认开、iPhone 不打，玩家自己在启动设置里开
    if GFX.search(s) or repo in GFX_REPOS:
        return 'gfx', '', ''
    return 'other', '', ''


# 画面类再分「降负载 / 提画质」（11-16 维护者：iOS 只收降负载类；判据 = 比游戏在我们这里的底座档默认少干活还是多干活）。
#   信号只取补丁自己的：own_name 里的变体目录 / 文件名、文件头那行游戏名之后的变体说明、各段的段注释（//、# 行）；游戏名、作者署名、网址不算。
#   同一份里两类都中、出现 900p–1080p（不知道这款底座原生多少，判不出升降）、或带中性改动（视野 / HUD / 颜色…，整份开关、iOS 不收中性）→ 认不出，仍留 gfx。
_OFF = r'(?:disabl\w*|remov\w*|no|off|turn[ _-]*off|without|kill\w*|delet\w*)'
LOAD = re.compile(_OFF + r'[ _-]*(?:the[ _-]*)?(?:fxaa|taa|smaa|aa\b|anti[ _-]*alias\w*|motion[ _-]*blur|camera[ _-]*blur|radial[ _-]*blur|blur|dof\b|depth[ _-]*of[ _-]*field|bloom|'
                  r'shadows?|ambient[ _-]*occlusion|ssao|ao\b|fog|volumetric\w*|particles?|post[ _-]*process\w*|god[ _-]*rays?|light[ _-]*shafts?|reflections?|ssr\b|grass|foliage|lens[ _-]*flare)'
                  r'|\b(?:fxaa|taa|smaa|anti[ _-]*alias\w*|motion[ _-]*blur|camera[ _-]*blur|dof|depth[ _-]*of[ _-]*field|bloom|ssao|ambient[ _-]*occlusion|fog|volumetric\w*|god[ _-]*rays?|lens[ _-]*flare|post[ _-]*process\w*)[ _-]*(?:off|disabled?|removed?)\b'   # 否定词写在后面：「Force FXAA Off」「Bloom Disabled」
                  r'|(?:lower\w*|reduc\w*|decreas\w*|half)[ _-]*(?:the[ _-]*)?(?:render(?:ing)?[ _-]*)?(?:res\b|resolution|lod|shadows?|draw[ _-]*distance|particles?|grass|foliage)'
                  r'|\b(?:360|480|504|540|576|600|648|720)p\b|\b(?:640|854|960|1024|1152|1280)[ _]*x[ _]*(?:360|480|540|576|648|720)\b'
                  r'|performance[ _-]*mode|force[ _-]*handheld|handheld[ _-]*(?:mode|res\w*|profile|settings)|half[ _-]*res\w*|low[ _-]*(?:quality|settings|graphics|preset)'
                  r'|dynamic[ _-]*res\w*[ _-]*(?:lower|min\w*|threshold|floor)')
QUAL = re.compile(r'\b(?:1152|1200|1296|1440|1620|1800|2160|2880|4320)p\b|\b[2-8]k\b|\b(?:1920[ _]*x[ _]*1200|2[0-9]{3}[ _]*x[ _]*1[2-9][0-9]{2}|[3-9][0-9]{3}[ _]*x[ _]*[0-9]{4})\b'
                  r'|(?:increas\w*|improv\w*|enhanc\w*|higher|better|high|boost\w*|max\w*|extend\w*|ultra)[ _-]*(?:the[ _-]*)?(?:render(?:ing)?[ _-]*)?(?:res\b|resolution|lod|shadows?|draw[ _-]*distance|quality|anisotrop\w*|textures?|detail|graphics|settings|preset|mip\w*|filtering)'
                  r'|anisotrop\w*|\baf[ _]*x?16\b|\b16x[ _]*af\b|lod[ _-]*(?:increas\w*|boost\w*)|force[ _-]*max|upscal\w*|sharpen\w*|msaa|supersampl\w*|docked[ _-]*mode|force[ _-]*docked'
                  r'|' + _OFF + r'[ _-]*(?:dynamic[ _-]*res\w*|resolution[ _-]*scaling|drs\b)|(?:lock\w*|fix\w*)[ _-]*(?:to[ _-]*)?(?:max|native)')
QUAL_WH = re.compile(r'\b\d{3,4}[ _]*x[ _]*(?:1[2-9]\d\d|[2-9]\d{3})\b')   # 高 ≥ 1200 的宽×高
# 判不出升降的：721p–1151p（900p–1080p 是底座 / 掌机一对常见写法，不知道这款底座原生多少）、同高度的宽×高
AMBIG = re.compile(r'\b(?:7[3-9]\d|8\d\d|9\d\d|10\d\d|11[0-4]\d)p\b|\b\d{3,4}[ _]*x[ _]*(?:7[3-9]\d|8\d\d|9\d\d|10\d\d|11[0-4]\d)\b')
RES_TOKEN = re.compile(r'\b\d{3,4}p\b|\b\d{3,4}[ _]*x[ _]*\d{3,4}\b|resolution|\bres\b')
DYN = re.compile(r'dynamic[ _-]*res\w*|resolution[ _-]*scaling|\bdrs\b')
DYN_LOWER = re.compile(r'dynamic[ _-]*res\w*[ _-]*(?:lower|min\w*|threshold|floor)')
CODE_NOTE = re.compile(r'[0-9a-f]{20,}|\b(?:movz?|movk|movn|fmov|ldr\w*|str\w*|ldp|stp|add|sub|cmp|fcmp|orr|and|eor|lsl|lsr|nop|ret|bl?|br|blr|b\.\w+|cbn?z|tbn?z|fm(?:ul|add|in|ax)\w*|[su]cvtf|fcvt\w*)\s+(?:[wxsdqv]\d+|wzr|xzr|sp|#|\[)', re.I)   # 汇编备注：助记符后跟寄存器 / 立即数；20 位以上十六进制（构建号 / 数据串；16 位的程序号不算）
NEUTRAL = re.compile(r'(?<![\d.])\d{1,2}\s*:\s*\d{1,2}(?![\d.])|stretch|\bfov\b|field[ _-]*of[ _-]*view|camera|\bhud\b|\bui\b|cursor|intro|skip|outlines?|colou?r|saturation|tint|vignette|letterbox|black[ _-]*bars|'
                     r'\bcrop|zoom|brightness|gamma|contrast|crosshair|\bmenu|subtitle|font|cutscene|aspect|widescreen|ultra[ _-]*wide')


def _dir_signals(path, text=''):
    """补丁自己的变体说明（见上）：own_name 去掉文件名里的版本号、程序号与 [mods] 包名；pchtxt 文件头「# 游戏名 [程序号] 版本 - 变体」只取变体；段注释整行"""
    parts = own_name(path).split('/')
    out = []
    for p in parts:
        p = GID.sub(' ', re.sub(r'\.(?:pchtxt|ips|zip|rar|7z)$', '', p, flags=re.I))
        p = re.sub(r'\bv?\d+(?:\.\d+)+\b', ' ', p)   # 版本号 1.3.0 / v2.7.7.92380（含 720 这类数字时不当分辨率）
        if p.strip().lower() not in ('', 'exefs', 'mods'):
            out.append(p)
    head = True
    for line in text.splitlines():
        t = line.strip()
        if not t or t.startswith('@'):
            continue
        if t.startswith(('#', '//')):
            t = t.lstrip('#/ ').strip()
            if CODE_NOTE.search(t):   # 汇编 / 十六进制备注（「mov w9, #0x500 (handheld resx)」「720 // 0005…」）说的是某条指令，不是这份补丁要做什么
                continue
            if head and GID.search(t):   # 文件头：游戏名 [程序号] 版本 - 变体 / ; 变体
                head = False
                m = re.search(r'01[0-9A-Fa-f]{14}\]?\s*(?:v?\d+(?:\.\d+)*)?\s*(.*)$', t)
                t = re.sub(r'^[-;:,\s]+', '', m.group(1)) if m else ''
            t = re.sub(r'\bv?\d+(?:\.\d+)+\b', ' ', t)
            if t:
                out.append(t)
    return re.sub(r'https?://\S+', ' ', '\n'.join(out).lower())


def gfx_dir(path, text=''):
    """画面类的方向：load（降负载，iOS 收）/ quality（提画质，只进 Mac）/ ''（认不出或中性，iOS 不收）"""
    s = _dir_signals(path, text)
    if AMBIG.search(s):
        return ''
    load, qual = bool(LOAD.search(s)), bool(QUAL.search(s) or QUAL_WH.search(s))
    # 降负载里混着动态分辨率开关（「关 FXAA 和动态分辨率」：关动态分辨率 = 锁最高档，是提画质）→ 认不出
    if load and DYN.search(DYN_LOWER.sub(' ', s)):
        return ''
    # 只改掌机档分辨率（「720p handheld target」）：我们回给游戏的是底座档，掌机档那组数用不上，说不上降负载
    if load and RES_TOKEN.search(s) and 'handheld' in s and not re.search(r'force[ _-]*handheld|handheld[ _-]*(?:mode|profile|settings)', s):
        return ''
    if load and not qual and not NEUTRAL.search(LOAD.sub(' ', s)):
        return 'load'
    if qual and not load:
        return 'quality'
    return ''


# 改内部渲染分辨率的满屏补丁（11-16 #b824d1：阿尔宙斯「3440x1440」变体把渲染分辨率提到 3440×1440，和 1800p（D-Q3QJ）同机制——渲染目标放大、
#   游戏自己的堆放不下 → 空指针崩）。按内容判：补丁写进的 movz 立即数里同时有一个高（> 1080 的常见高度）和一个宽（≥ 1.3 倍高）。
#   只看名字不算：名字里写 3440x1440 的多是目标显示器，正文只改画幅（11-16 普查 116 份名字带分辨率的，正文 0 份写分辨率常数）
UPRES_HEIGHTS = frozenset((1152, 1200, 1440, 1536, 1600, 1620, 1800, 2160, 2880, 4320))


def words_of(kind, data):
    """补丁写进的 4 字节字（小端）：pchtxt 每行「偏移 十六进制」（// 注释掉的不算），IPS 按记录（偏移 3 字节 + 长度 2 字节 + 数据；长度 0 = RLE，不是指令）"""
    out = []
    if kind == 'ips':
        i = 5 if data[:5] in (b'PATCH', b'IPS32') else 0
        wide = data[:5] == b'IPS32'
        while i + (4 if wide else 3) + 2 <= len(data):
            n0 = 4 if wide else 3
            if data[i:i + n0] in (b'EOF', b'EEOF'): break
            size = int.from_bytes(data[i + n0:i + n0 + 2], 'big'); i += n0 + 2
            if size == 0: i += 3; continue
            out += [int.from_bytes(data[i + k:i + k + 4], 'little') for k in range(0, size - 3, 4)]; i += size
        return out
    for line in data.decode('utf-8', 'replace').splitlines():
        m = re.match(r'\s*[0-9A-Fa-f]{8}\s+([0-9A-Fa-f]{8,})\b', line)
        if m:
            hx = m.group(1)
            out += [int.from_bytes(bytes.fromhex(hx[k:k + 8]), 'little') for k in range(0, len(hx) - 7, 8)]
    return out


def upres(words):
    """→ (宽, 高)：这些字里有 movz 写一对渲染分辨率（见 UPRES_HEIGHTS）；没有 → None"""
    imms = {(w >> 5) & 0xFFFF for w in words if (w & 0x7F800000) == 0x52800000 and not (w >> 21) & 3}   # movz w/x，不移位
    return next(((w, h) for h in sorted(imms & UPRES_HEIGHTS) for w in sorted(imms) if 1.3 * h <= w <= 8192), None)


RES_FIX_H = 1080   # 改回的渲染高：发布前没有各款原件、不知道原生高，取 Switch 主机模式最常见的 1080（原生 720 的款高出一些，远低于会崩的 1440 / 2160）


def res_fix(kind, data, wh):
    """把补丁里写渲染分辨率的 movz（upres 认出的 宽 wh[0] / 高 wh[1]）就地改成 高 RES_FIX_H、宽 = 高 × 原宽高比（取偶），其余字节不动
    （11-16 维护者：「提前把这类补丁中参数改对，这样用户用着的就是对的」，老客户端也受益）。补丁里高 > 1080 的常见高度只许 wh[1] 这一个
    （另有一档 / 派生尺寸 → 认不全）→ None。→ (新字节, (新宽, 新高))"""
    W, H = wh
    if {(w >> 5) & 0xFFFF for w in words_of(kind, data) if (w & 0x7F800000) == 0x52800000 and not (w >> 21) & 3} & UPRES_HEIGHTS != {H}: return None
    H2 = RES_FIX_H; W2 = max(2, int(round(H2 * W / H / 2)) * 2)
    def fix(w):
        if (w & 0x7F800000) != 0x52800000 or (w >> 21) & 3: return w
        imm = (w >> 5) & 0xFFFF
        return (w & ~(0xFFFF << 5)) | ((H2 if imm == H else W2 if imm == W else imm) << 5)
    if kind == 'ips':
        out = bytearray(data); i = 5 if data[:5] in (b'PATCH', b'IPS32') else 0; wide = data[:5] == b'IPS32'
        while i + (4 if wide else 3) + 2 <= len(out):
            n0 = 4 if wide else 3
            if bytes(out[i:i + n0]) in (b'EOF', b'EEOF'): break
            size = int.from_bytes(out[i + n0:i + n0 + 2], 'big'); i += n0 + 2
            if size == 0: i += 3; continue
            for k in range(0, size - 3, 4):
                out[i + k:i + k + 4] = fix(int.from_bytes(out[i + k:i + k + 4], 'little')).to_bytes(4, 'little')
            i += size
        new = bytes(out)
    else:
        def line(m):
            hx = m.group(2)
            return m.group(1) + ''.join(fix(int.from_bytes(bytes.fromhex(hx[k:k + 8]), 'little')).to_bytes(4, 'little').hex().upper() for k in range(0, len(hx) - 7, 8)) + hx[len(hx) - len(hx) % 8:]
        new = re.sub(r'(?m)^(\s*[0-9A-Fa-f]{8}\s+)([0-9A-Fa-f]{8,})\b', line, data.decode('utf-8', 'replace')).encode()
    return (new, (W2, H2)) if new != data else None


def bids_of(path, data):
    name = os.path.splitext(os.path.basename(path))[0]
    if path.lower().endswith('.ips'):
        return [name.upper()] if re.fullmatch(r'[0-9A-Fa-f]{16,64}', name) else []
    return sorted({m.upper() for m in re.findall(r'@nsobid-([0-9A-Fa-f]{16,64})', data.decode('utf-8', 'replace'))})


CHEAT_LIBS = {'bad1dea/NXCheats', 'HamletDuFromage/switch-cheats-db', 'ChanseyIsTheBest/NX-60FPS-RES-GFX-Cheats'}
CHEAT = re.compile(r'(?:^|/)cheats/(?:[^/]+/)?([0-9A-Fa-f]{16})\.txt$', re.I)   # 也认多一层目录：cheats/<程序号或游戏名>/<构建号>.txt（tomvita/MyNXCheats 的写法，11-16）


def mod_root(path):
    """Atmosphere 结构 <mod 根>/exefs/… 或 <mod 根>/romfs/… 的 mod 根（小写比较，取最后一个 exefs / romfs 的上一级）；都不在里面 → None"""
    low = [p.lower() for p in path.replace('\\', '/').split('/')]
    for i in range(len(low) - 1, -1, -1):
        if low[i] in ('exefs', 'romfs'):
            return '/'.join(low[:i])
    return None


# 配套数据里会让「只打 exefs 半边」崩的：显存 / 堆 / 内存配置（11-16 D-Q3QJ：1800p 改分辨率要配 HeapSize/…HeapDef 调大显存堆，缺了按 1800p 建缓冲分配失败）。
#   界面布局（LayoutArchive、Bootup pack 等）缺了只是界面没跟着拉宽、不崩，照收（维护者定：超宽屏是满屏重点功能，不一刀切）
CRASH_COMPANION = re.compile(r'heap|memorysystem|memory(?:size|def|config)', re.I)


def romfs_roots(names):
    """配套里有显存 / 堆 / 内存配置（CRASH_COMPANION）的 mod 根（小写）"""
    return {mod_root(n) for n in names if '/romfs/' in '/' + n.replace('\\', '/').lower() and CRASH_COMPANION.search(n.replace('\\', '/').split('/romfs/', 1)[-1])}


def half(path, roots):
    """exefs 补丁且它的 mod 配套里有显存 / 堆 / 内存配置（romfs_roots / companion 记下的根）：只收这半边会崩，整份不收"""
    low = '/' + path.replace('\\', '/').lower()
    return '/exefs/' in low and path.lower().endswith(('.pchtxt', '.ips')) and mod_root(path) in roots


ADJUSTED = []   # 本次扫描改过分辨率的满屏补丁：(路径, 包内路径, (原宽, 原高), (新宽, 新高), 原 sha256)
UPRES = []    # 本次扫描不收的改内部分辨率满屏补丁：(路径, 包内路径, (宽, 高), sha256)；同一份内容在别处（被分成别的类）也不收
# 已定因会崩的单份补丁（按内容 sha256 前 16 位，同 pack/cpatch.py 编号）：不收。新客户端出包时 pack/cpatch.py nop_stale 已能按数据流挡下它们；
#   这张表留给没有这条规则的老客户端（0.4.5 及以前，出包时照收）——老客户端淘汰后清空。cucholix 那份（7a1aa34f90ab0756）残值来自游戏自己的 ldr、真机一致，nop_stale 判安全，已移出
KNOWN_BAD = {
    'e8b51176ead1bcd3': '11-16 帖子 3 台 / 4 次 Mac 崩：nop 掉 main+0x5edb3c 取名字地址的 adrp/add，x8 是前面 bl 留下的值，被当名字指针，进拍照模式读 0x8',
}
HALVES = []   # 本次扫描不收的半边：(文件, 包内路径或空, sha256)；scan 收尾按 sha256 把别的库里同一份内容也去掉


def members(full):
    """压缩包 → [(包内路径, 字节)]，只取补丁（.pchtxt / .ips，不在 romfs 下）与 cheats/<构建号>.txt；读不了 = []"""
    want = lambda n: not n.endswith('/') and '/romfs/' not in '/' + n.lower() and (n.lower().endswith(('.pchtxt', '.ips')) or CHEAT.search(n))
    out = []
    try:
        if full.lower().endswith('.zip'):
            with zipfile.ZipFile(full) as z:
                roots = romfs_roots(i.filename for i in z.infolist())
                for i in z.infolist():
                    if half(i.filename, roots):
                        HALVES.append((full, i.filename, hashlib.sha256(z.read(i)).hexdigest()))
                    elif want(i.filename) and i.file_size <= MAX:
                        out.append((i.filename, z.read(i)))
        else:
            names = subprocess.run(['bsdtar', '-tf', full], capture_output=True, text=True, timeout=60).stdout.splitlines()
            roots = romfs_roots(names)
            for n in names:
                if half(n, roots):
                    HALVES.append((full, n, hashlib.sha256(subprocess.run(['bsdtar', '-xOf', full, n], capture_output=True, timeout=60).stdout).hexdigest()))
                elif want(n):
                    data = subprocess.run(['bsdtar', '-xOf', full, n], capture_output=True, timeout=60).stdout
                    if len(data) <= MAX:
                        out.append((n, data))
    except (OSError, zipfile.BadZipFile, subprocess.SubprocessError) as e:
        print(f'跳过压缩包 {full}：{type(e).__name__}', file=sys.stderr)
    return out


def true_paths(repo, commit):
    """上游这次提交的真实文件树：git 内容号 → [路径]（大小写以上游为准）。镜像放在不分大小写的盘上时，上游只差大小写的两个目录会被合成一个
    （11-13 实测 ShinySick：同一款的全大写与首字母大写两个目录），按本地路径拼下载地址 404。经 gh（我方生成索引的机器已登录）取；取不到回 None、按本地路径"""
    try:
        out = subprocess.run(['gh', 'api', f'repos/{repo}/git/trees/{commit}?recursive=1', '--jq', '.tree[] | select(.type=="blob") | .sha + "\t" + .path'],
                             capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode:
        return None
    m = {}
    for line in out.stdout.splitlines():
        sha, _, path = line.partition('\t')
        m.setdefault(sha, []).append(path)
    return m


def fix_case(rel, data, tree):
    """本地路径 → 上游真实路径：同内容（git 内容号）且只差大小写的那条；对不上照本地"""
    if not tree:
        return rel
    sha = hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest()
    return next((p for p in tree.get(sha, []) if p.lower() == rel.lower()), rel)


def keep_dir(name):
    """上游镜像里不进的子目录：.git、游戏数据目录（补丁库里附带的资源替换，不是补丁）"""
    return name != '.git' and name.lower() != 'romfs'


def companion(base, dirpath, dirs, roots):
    """散文件：这一级带游戏数据目录（mod 的 romfs 配套，keep_dir 不进）且里面有显存 / 堆 / 内存配置（CRASH_COMPANION）→ 记下这个 mod 根，
    它的 exefs 补丁不收（half）。只按文件名判，不读内容"""
    for x in dirs:
        if not keep_dir(x) and x != '.git':
            names = [os.path.relpath(os.path.join(d, f), dirpath).replace(os.sep, '/') for d, _, fs in os.walk(os.path.join(dirpath, x)) for f in fs]
            if romfs_roots(names):
                roots.add(mod_root(os.path.relpath(os.path.join(dirpath, x, 'x'), base).replace(os.sep, '/')))


HAMLET = re.compile(r'^cheats/(01[0-9A-Fa-f]{14})\.json$')   # 金手指汇总库：每款一份 JSON，键 = 构建号前 16 位，值 = {条目名: 整段代码}


def scan(mirror, keep_local=False, cheat_libs=False):
    """keep_local：每行另记 _local（镜像里的本地相对路径，tools/patch_pack.py 取字节用；不进索引）；汇总库 JSON 拆出的金手指另记 _data（内容是拼出来的，按路径取不回）。
    cheat_libs：金手指专门库（CHEAT_LIBS）的金手指也收（统一包用：11-13 起金手指也由我们的下载站分发，不再由出包端逐库去 GitHub 取）"""
    rows, pinned = [], {}
    HALVES.clear(); UPRES.clear(); ADJUSTED.clear()
    src = os.path.join(mirror, 'SOURCES.tsv')
    if os.path.isfile(src):
        for line in open(src, encoding='utf-8'):
            c = line.rstrip('\n').split('\t')
            if len(c) >= 3 and re.fullmatch(r'[0-9a-f]{40}', c[2]):
                pinned[c[0]] = c[2]
    for d in sorted(os.listdir(mirror)):
        root = os.path.join(mirror, d)
        if '__' not in d or not os.path.isdir(root):
            continue
        repo = d.replace('__', '/', 1)
        commit = subprocess.run(['git', '-C', root, 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip() \
            if os.path.isdir(os.path.join(root, '.git')) else pinned.get(d, '')
        if not re.fullmatch(r'[0-9a-f]{40}', commit):
            print(f'跳过 {d}：取不到提交号', file=sys.stderr); continue
        lic = ''
        for n in ('LICENSE', 'LICENSE.md', 'LICENSE.txt'):
            p = os.path.join(root, n)
            if os.path.isfile(p):
                lic = next((l.strip() for l in open(p, encoding='utf-8', errors='replace') if l.strip()), '')[:80]
                break
        def row(rel, name, data, extra=None):
            m = CHEAT.search(name); gdir = ''
            if m:
                if repo in CHEAT_LIBS and not cheat_libs:
                    return
                kind, cat, tfps, aspect, bids = 'cheat', 'cheat', '', '', [m.group(1).upper()]
            else:
                kind = 'ips' if name.lower().endswith('.ips') else 'pchtxt'
                text = data.decode('utf-8', 'replace') if kind == 'pchtxt' else ''
                cat, tfps, aspect = classify(rel + '/' + name if extra else rel, text, repo)
                gdir = gfx_dir(rel + '/' + name if extra else rel, text) if cat == 'gfx' else ''
                bids = bids_of(name, data)
                if cat == 'widescreen' and (wh := upres(words_of(kind, data))):   # 改内部分辨率的满屏补丁（见 upres）：发布前就把分辨率改回原生（res_fix），玩家拿到的就是对的；认不全才不收
                    fixed = res_fix(kind, data, wh) if keep_local else None   # 只有统一包（字节随包分发，tools/patch_pack.py）能发改过的内容；只给元数据、让客户端去上游下的老索引改不了，照旧不收
                    if not fixed:
                        UPRES.append((rel, name, wh, hashlib.sha256(data).hexdigest())); return
                    old_sha, data = hashlib.sha256(data).hexdigest(), fixed[0]
                    ADJUSTED.append((rel, name, wh, fixed[1], old_sha))
                    extra = dict(extra or {}, adjusted=dict(res_from=list(wh), res_to=list(fixed[1]), orig_sha256=old_sha))
            rows.append(dict(repo=repo, commit=commit, path=rel, size=len(data), sha256=hashlib.sha256(data).hexdigest(), kind=kind, cat=cat,
                             target_fps=tfps, aspect=aspect, **({'dir': gdir} if gdir else {}), gids=sorted({g.upper() for g in GID.findall(rel + '/' + name)}), bids=bids, license=lic, **(extra or {})))
            if keep_local:
                rows[-1]['_local'] = local
                if rows[-1].get('adjusted'): rows[-1]['_data'] = data   # 改过分辨率的字节（tools/patch_pack.py content 取它，不再读镜像原件）
        tree = true_paths(repo, commit) if os.environ.get('S2A_PATCH_INDEX_NO_GH') != '1' else None
        if tree is None:
            print(f'{d}：取不到上游文件树，路径按本地（只差大小写的目录会 404）', file=sys.stderr)
        loose_roots = set()
        for dirpath, dirs, files in os.walk(root):
            companion(root, dirpath, dirs, loose_roots)
            dirs[:] = [x for x in dirs if keep_dir(x)]
            for f in files:
                full = os.path.join(dirpath, f); rel = os.path.relpath(full, root).replace(os.sep, '/'); local = rel
                if tree and os.path.getsize(full) <= MAX:
                    rel = fix_case(rel, open(full, 'rb').read(), tree)
                fpsl = f.lower().endswith('.yaml') and '/FPSLocker/patches/' in full.replace(os.sep, '/')
                hm = HAMLET.match(rel) if cheat_libs and repo == 'HamletDuFromage/switch-cheats-db' else None
                if hm:
                    try:
                        dj = json.load(open(full, encoding='utf-8'))
                    except (OSError, ValueError):
                        continue
                    author = '、'.join(sorted({str(v).splitlines()[0] for v in (dj.get('attribution') or {}).values() if str(v).strip()}))[:200]
                    for k, v in sorted(dj.items()):
                        if not (isinstance(v, dict) and re.fullmatch(r'[0-9A-Fa-f]{16}', k)):
                            continue
                        data = ''.join(x for x in v.values() if isinstance(x, str)).encode()
                        if not data.strip():
                            continue
                        rows.append(dict(repo=repo, commit=commit, path=rel, size=len(data), sha256=hashlib.sha256(data).hexdigest(), kind='cheat', cat='cheat',
                                         target_fps='', aspect='', gids=[hm.group(1).upper()], bids=[k.upper()], license=lic, author=author, member=k.upper()))
                        if keep_local:
                            rows[-1]['_data'] = data
                    continue
                if os.path.getsize(full) > MAX:
                    continue
                if f.lower().endswith(('.zip', '.rar')):
                    whole = open(full, 'rb').read()
                    for name, data in members(full):
                        row(rel, name, data, dict(member=name, archive_sha256=hashlib.sha256(whole).hexdigest(), archive_size=len(whole)))
                    continue
                if not f.lower().endswith(('.pchtxt', '.ips')) and not fpsl and not CHEAT.search(rel):
                    continue
                data = open(full, 'rb').read()
                if half(local, loose_roots):
                    HALVES.append((full, '', hashlib.sha256(data).hexdigest()))
                    continue
                if fpsl:
                    rows.append(dict(repo=repo, commit=commit, path=rel, size=len(data), sha256=hashlib.sha256(data).hexdigest(), kind='fpsl', cat='fps',
                                     target_fps='60', aspect='', gids=sorted({g.upper() for g in GID.findall(rel)}), bids=[os.path.splitext(f)[0].upper()], license=lic))
                    if keep_local:
                        rows[-1]['_local'] = local
                else:
                    row(rel, rel, data)
    gone = {h for _, _, h in HALVES} | {h for *_, h in UPRES} | {x[4] for x in ADJUSTED}   # 改过分辨率的：上游原内容在别处（被分成画面类等）原样出现也不收
    kept = [r for r in rows if r['kind'] == 'cheat' or r.get('adjusted') or (r['sha256'] not in gone and r['sha256'][:16] not in KNOWN_BAD)]   # 改过分辨率的行本身留（内容已变），别处同原内容的照去
    print(f'改内部渲染分辨率的满屏补丁：改回原生分辨率 {len(ADJUSTED)} 份，认不全不收 {len(UPRES)} 份', file=sys.stderr)
    print(f'已定因会崩的补丁（KNOWN_BAD）不收：{sum(1 for r in rows if r["sha256"][:16] in KNOWN_BAD)} 行', file=sys.stderr)
    print(f'配套是显存 / 堆配置、只能收到 exefs 半边的补丁不收：{len(HALVES)} 份（去掉 {len(rows) - len(kept)} 行，含别的库里同一份内容）', file=sys.stderr)
    return kept


# 转存合集 / 分叉（收别人的补丁再打包）：同一份内容（sha256 一样）在原作者库里也有时记原作者库，这几个排最后
AGGREGATORS = ('ADEMOLA200/', 'citron-neo/', 'pacoa-kdbg/', 'Copox/', 'Uncloak2/')


def dedupe(rows):
    """同一份内容只留一行：原作者库优先（合集排后），同级按库名；同一提交被镜像成两个名字（仓库改过名）只算一次"""
    rows = sorted(rows, key=lambda r: (r['repo'].startswith(AGGREGATORS), r['repo'], r['path'], r.get('member', '')))
    seen, out = set(), []
    for r in rows:
        k = (r['sha256'], r['kind'], tuple(r['gids']))   # 同内容不同款（通用补丁两款各放一份）各留一行
        if k not in seen:
            seen.add(k); out.append(r)
    return out


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr); return 2
    rows = dedupe(scan(argv[0]))
    with gzip.open(argv[1], 'wt', encoding='utf-8') as f:
        json.dump(dict(schema=1, rows=rows), f, ensure_ascii=False, separators=(',', ':'))
    print(f'补丁索引：{len(rows)} 份文件、{len({r["repo"] for r in rows})} 个上游 → {argv[1]}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
