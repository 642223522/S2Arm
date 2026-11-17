#!/usr/bin/env python3
"""测试包本机开发签名（底本旧库 tools/dev_sign.py；10-19 出包线，维护者定：测试装包不走 xcodebuild 导出 Ad Hoc，那一步 64 秒）：
dev_sign.py <NxIOS.app> <包名> <团队号> <基础权限 Gen/NxIOS.entitlements> [--extension]
  --extension：签的是 App 扩展（主屏小组件 PlugIns/*.appex，11-16）：只带它自己的权限（共享组），不核「提高内存上限」（那是主程序的）；主程序随后另签。
① 挑描述文件：~/Library/MobileDevice/Provisioning Profiles 与 Xcode UserData 里 application-identifier = <团队号>.<包名>、带 ProvisionedDevices、get-task-allow 真（开发描述文件），取到期最晚的；
② 挑签名身份：本机 codesigning 身份里，证书（DER 的 SHA-1）在该描述文件 DeveloperCertificates 中的；
③ 权限 = 基础权限 + application-identifier / team-identifier / get-task-allow，且每项必须被描述文件允许（否则装不上）；
④ 嵌入 embedded.mobileprovision → 先签内嵌 *.dylib / *.framework → 再带权限签 App → 核「提高内存上限」在签名里。
找不到合适的描述文件或身份、描述文件缺 S2A_PROFILE_NEED_UDIDS 里的测试设备，退出码 3（调用方退回 Xcode 导出）；本机描述文件解不出（安全服务不可用）退出码 4（调用方不申请、照报）；其余失败退出码 1。"""
import glob, hashlib, os, plistlib, shutil, subprocess, sys, tempfile
app, bid, team, base = sys.argv[1:5]
EXTENSION = '--extension' in sys.argv[5:]
NEED = ['com.apple.developer.kernel.increased-memory-limit']   # 10-19 维护者定案（docs/研究/免费账号.md）：只带这一项就有整块 64 GB 窗口 + 6144 MB 内存上限；扩展寻址多余且免费账号签不了
# 平台（11-15 tvOS 版）：S2A_SIGN_PLATFORM=tvos（pack/jobs/tvos.py 传）或 App 的 CFBundleSupportedPlatforms 写着 AppleTVOS → 只挑 tvOS 的开发描述文件
#   （同一包名可能还有 iOS 的那份）。权限按款（pack/jobs/tvos.py entitlements_for）：「提高内存上限」照带，描述文件不允许就不带
#   （免费账号在 tvOS 上本来就会被系统丢掉，TVPort tvport/README.md「Memory」；游戏靠客体内存文件后备压在上限下），不挡签名；
#   「扩展虚拟寻址」只有 Switch 2 款带，带了就必须被描述文件允许、签进去（只有付费账号的描述文件有），缺了照实报
IML, EVA = 'com.apple.developer.kernel.increased-memory-limit', 'com.apple.developer.kernel.extended-virtual-addressing'
try: _plats = plistlib.load(open(os.path.join(app, 'Info.plist'), 'rb')).get('CFBundleSupportedPlatforms') or []
except Exception: _plats = []
TVOS = os.environ.get('S2A_SIGN_PLATFORM') == 'tvos' or 'AppleTVOS' in _plats
def cms(f):
    r = subprocess.run(['security', 'cms', '-D', '-i', f], capture_output=True)
    try: return plistlib.loads(r.stdout)
    except Exception: return None
best, unread = None, []
for f in glob.glob(os.path.join(glob.escape(os.path.expanduser('~/Library/MobileDevice/Provisioning Profiles')), '*.mobileprovision')) + glob.glob(os.path.join(glob.escape(os.path.expanduser('~/Library/Developer/Xcode/UserData/Provisioning Profiles')), '*.mobileprovision')):
    p = cms(f)
    if not p: unread.append(os.path.basename(f)); continue
    e = p.get('Entitlements', {})
    if e.get('application-identifier') != f'{team}.{bid}' or not p.get('ProvisionedDevices') or e.get('get-task-allow') is not True: continue
    if TVOS and 'tvOS' not in (p.get('Platform') or []): continue
    if best is None or p['ExpirationDate'] > best[1]['ExpirationDate']: best = (f, p)
# 解不出的描述文件不等于没有（10-30 出包线：凌晨内存耗尽、trustd 等安全服务被 Jetsam 杀，security cms 全解不出，这里报「没有」，
#   调用方去申请新描述文件、原因空白，真因被盖住）：一个都没挑中且有解不出的 → 退出码 4、点名，调用方不申请、照原样报红
if not best and unread:
    print(f'【红】读不出本机描述文件 {len(unread)} 个（security cms -D 失败，系统安全服务 trustd / securityd 不可用或内存耗尽被杀？如 {unread[0]}）：不当作「没有描述文件」'); sys.exit(4)
if not best: print(f'没有 {team}.{bid} 的开发描述文件'); sys.exit(3)
pf, prof = best
# 描述文件要含我方全部测试设备（S2A_PROFILE_NEED_UDIDS，pack/ipa_tail.py 从 tools/devices.sh 名单给；没给不核）：设备登记晚于申请的旧描述文件缺它，
#   装上去报「This provisioning profile cannot be installed on this device」（11-07 惊奇装 Duo）→ 退 3，调用方 ensure_profile.sh 移走旧的、按账号现有设备重申
miss = sorted(set(os.environ.get('S2A_PROFILE_NEED_UDIDS', '').split()) - set(prof['ProvisionedDevices']))
if miss: print(f'描述文件 {os.path.basename(pf)} 不含测试设备 {" ".join(miss)}（设备登记晚于申请），要换新'); sys.exit(3)
certs = {hashlib.sha1(c).hexdigest().upper() for c in prof.get('DeveloperCertificates', [])}
ids = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True).stdout.split('\n')
ident = next((l.split()[1] for l in ids if len(l.split()) > 1 and l.split()[1] in certs), None)
if not ident: print(f'本机钥匙串没有描述文件 {os.path.basename(pf)} 里的开发证书'); sys.exit(3)
ents = plistlib.load(open(base, 'rb'))
ents.update({'application-identifier': f'{team}.{bid}', 'com.apple.developer.team-identifier': team, 'get-task-allow': True})
allow = prof['Entitlements']
if TVOS:
    NEED = [EVA] if EVA in ents else []
    if IML in ents and IML not in allow:
        ents.pop(IML); print('描述文件没有「提高内存上限」（免费账号常见）：tvOS 上照签不带这项，游戏靠客体内存文件后备压在单进程上限下')
bad = [k for k in ents if k not in allow]
if bad: print(f'描述文件不允许这些权限：{bad}'); sys.exit(3)
shutil.copyfile(pf, os.path.join(app, 'embedded.mobileprovision'))
tf = tempfile.NamedTemporaryFile(suffix='.plist', delete=False); plistlib.dump(ents, tf); tf.close()
def sign(path, extra=()):
    r = subprocess.run(['codesign', '--force', '--sign', ident, '--timestamp=none', *extra, path], capture_output=True, text=True)
    if r.returncode: print(f'签名失败 {path}：{r.stderr.strip()[:300]}'); sys.exit(1)
# 已先签好的扩展（PlugIns/ 下）里的库不再动：重签会破坏扩展的封印，主程序签名随之报 nested code 无效
plugins = os.path.join(app, 'PlugIns') + os.sep
nested = sorted({p for p in glob.glob(os.path.join(glob.escape(app), '**', '*.dylib'), recursive=True)} | {p for p in glob.glob(os.path.join(glob.escape(app), '**', '*.framework'), recursive=True)}, key=len, reverse=True)
nested = [p for p in nested if EXTENSION or not p.startswith(plugins)]
for p in nested: sign(p)
sign(app, ('--entitlements', tf.name)); os.unlink(tf.name)
got = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', app], capture_output=True).stdout
miss = [] if EXTENSION else [k for k in NEED if k.encode() not in got]
if miss and TVOS: print(f'签名里没有 tvOS 版要的权限（{", ".join(miss)}）：Switch 2 款要「扩展虚拟寻址」，只有付费开发者账号的描述文件允许'); sys.exit(1)
if miss: print(f'签名里没有「提高内存上限」权限（{", ".join(miss)}）'); sys.exit(1)   # 与 adhoc_sign.sh、iml_check.py 同一句
print(f'开发签名：{os.path.basename(pf)}（{prof.get("Name")}，{len(prof["ProvisionedDevices"])} 台设备，到期 {prof["ExpirationDate"]:%Y-%m-%d}），身份 {ident[:8]}…，内嵌 {len(nested)} 个库')
