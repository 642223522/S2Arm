#!/usr/bin/env python3
# 辅助脚本：android/tests/caps_shape/run.sh 用它把设备档案出成假驱动的 C 头、核对真机设备档、核对生成的档案；随 run.sh 在 android/test.sh 里跑
"""整台设备能力形态档（#1749：不读厂商号，只看能力）。

形态 = 一份设备档案（s2a-device-profile-v1，#1749 §4.1）：默认读 android/tests/devprofiles/*.json（环境变量 S2A_DEVPROFILES 可换目录），
档名 = 文件名去掉 .json。现有三档：
  adreno-8xx-qcom = 骁龙 8 至尊版 / Adreno 830
  mali-g710-r32p1 = 天玑 9000 / Mali-G710 MC10
  minimal-1.1     = Vulkan 1.1 保守档（只留建设备必需的特性、不列任何设备扩展；限值 / 格式 / 内存取两台真机逐项更紧）
三份怎么来的见 android/tests/devprofiles/make_profiles.py。假驱动只读档案的 api / identity / vulkan 三段；
档案里写 null（来源没有读数）的项，假驱动按「无」回答（与原形态档同一口径）。

子命令：
  header <out.h>                    出各档的 C 头（假驱动 fake_vk.c 按 S2A_CAPS_SHAPE 选档）
  names                             列档名
  oracle <档名> <设备打出的 caps JSON>  真机档：本构建在该形态下打出的 caps 和 android/tests/vk/profiles/devices/*.json 逐项比
  compare <档名> <生成的档案>          本构建在该形态下现查生成的设备档案和该档的档案文件逐字段比（期望 = 档案文件本身）
"""
import glob, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
sys.path.insert(0, os.path.join(REPO, 'tools'))
import devprofile_lint as lint   # noqa: E402

PROFILES = os.environ.get('S2A_DEVPROFILES') or os.path.join(REPO, 'android', 'tests', 'devprofiles')
DEVICES = os.path.join(REPO, 'android', 'tests', 'vk', 'profiles', 'devices')
VK_CORE = os.path.join(REPO, 'graphics', 'nvn', 'third_party', 'vulkan-headers', 'include', 'vulkan', 'vulkan_core.h')
REAL = {'adreno-8xx-qcom': '8e', 'mali-g710-r32p1': '9000'}   # 有应用直连层真机 caps 读数的档
# 实例扩展不是设备能力：各档一样（假驱动给全）
INSTANCE_EXTS = ('VK_KHR_get_physical_device_properties2', 'VK_KHR_surface', 'VK_KHR_android_surface',
                 'VK_KHR_get_surface_capabilities2', 'VK_EXT_surface_maintenance1')
# 假驱动答的扩展特性位（caps_shape.h 的同名字段，di* = 描述符索引支持位）：档案 vulkan.features 的键 → C 字段
EXT_FEATURES = (('shaderDrawParameters', 'shaderDrawParameters'), ('timelineSemaphore', 'timelineSemaphore'),
                ('indexTypeUint8', 'indexTypeUint8'), ('customBorderColors', 'customBorderColors'),
                ('customBorderColorWithoutFormat', 'customBorderColorWithoutFormat'),
                ('vertexAttributeInstanceRateDivisor', 'vertexAttributeInstanceRateDivisor'), ('formatA4B4G4R4', 'formatA4B4G4R4'),
                ('depthClipControl', 'depthClipControl'), ('swapchainMaintenance1', 'swapchainMaintenance1'),
                ('runtimeDescriptorArray', 'diRuntimeArray'), ('descriptorBindingPartiallyBound', 'diPartiallyBound'),
                ('shaderSampledImageArrayNonUniformIndexing', 'diSampledNonUniform'),
                ('shaderStorageImageArrayNonUniformIndexing', 'diStorageNonUniform'),
                ('descriptorBindingVariableDescriptorCount', 'diVariableCount'),
                ('descriptorBindingSampledImageUpdateAfterBind', 'diSampledUpdateAfterBind'))


def names():
    return sorted(os.path.basename(p)[:-5] for p in glob.glob(os.path.join(PROFILES, '*.json')))


def load(name):
    p = json.load(open(os.path.join(PROFILES, name + '.json'), encoding='utf-8'))
    bad = lint.check(p)
    if bad: sys.exit('【红】形态档 %s 的档案不合格（tools/devprofile_lint.py）：\n  %s' % (name, '\n  '.join(bad)))
    return p


def c_ident(name): return re.sub(r'[^A-Za-z0-9]', '_', name)
def c_str(s): return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
def c_val(v):
    if isinstance(v, list): return '{' + ', '.join(c_val(x) for x in v) + '}'
    if isinstance(v, float): return repr(v) + 'f'
    return str(v) + ('ull' if isinstance(v, int) and v > 0x7fffffff else '')
def z(v, d=0): return d if v is None else v   # null（没有读数）= 按「无」/ 原假驱动的固定值回答


def api_num(s):
    a, b, c = (int(x) for x in s.split('.'))
    return (a << 22) | (b << 12) | c


def header(out):
    fmt_num = {n: int(v) for n, v in re.findall(r'\n\s+(VK_FORMAT_[A-Za-z0-9_]+) = (\d+),', open(VK_CORE, encoding='utf-8').read())}
    lines = ['// 生成文件（android/tests/caps_shape/shapes.py header，读 %s），不进仓库' % os.path.relpath(PROFILES, REPO), '#pragma once']
    shapes = names()
    if not shapes: sys.exit('【红】%s 下没有设备档案' % PROFILES)
    core = None
    for name in shapes:
        p = load(name); v = p['vulkan']; i = p['identity']; pr = v['properties']; f = v['features']; cid = c_ident(name)
        core = core or sorted(lint.names()[1])
        ext = sorted(v['extensions'])
        fmts = sorted((fmt_num[k], x) for k, x in v['formats'].items() if x is not None)
        uuid = bytes.fromhex(i['pipelineCacheUUID']) if i['pipelineCacheUUID'] else bytes(16)
        lines.append('static const char *const cs_ext_%s[] = { %s };' % (cid, ', '.join(c_str(e) for e in ext) or 'NULL'))
        lines.append('static const struct cs_fmt cs_fmt_%s[] = { %s };' % (cid, ', '.join('{%d, %du, %du, %du}' % (n, *x) for n, x in fmts)))
        lines.append('static const struct cs_shape cs_%s = {' % cid)
        lines.append('  .name = %s, .n_ext = %d, .ext = %s, .n_fmt = %d, .fmt = cs_fmt_%s,' % (
            c_str(name), len(ext), 'cs_ext_' + cid if ext else 'NULL', len(fmts), cid))
        lines.append('  .props = { .apiVersion = %du, .driverVersion = %du, .vendorID = %du, .deviceID = %du, .deviceType = %d, .deviceName = %s,' % (
            api_num(p['api']['version']), i['driverVersion'], int(i['vendorId'], 16), int(i['deviceId'], 16), pr['deviceType'], c_str(i['deviceName'])))
        lines.append('    .pipelineCacheUUID = {%s},' % ', '.join(str(b) for b in uuid))
        lines.append('    .limits = { ' + ', '.join('.%s = %s' % (k, c_val(x)) for k, x in sorted(pr['limits'].items())) + ' } },')
        lines.append('  .features = { ' + ', '.join('.%s = %d' % (k, z(f.get(k))) for k in core) + ' },')
        lines.append('  ' + ', '.join('.%s = %d' % (c, z(f.get(k))) for k, c in EXT_FEATURES) + ',')
        lines.append('  .driver_id = %d, .driver_name = %s, .max_alloc = %dull, .max_per_set = %d, .subgroup_size = %d,' % (
            z(i['driverId']), c_str(z(i['driverName'], '')), z(pr.get('maxMemoryAllocationSize')), z(pr.get('maxPerSetDescriptors'), 1024),
            z(pr.get('subgroupSize'))))
        lines.append('  .subgroup_stages = %du, .subgroup_ops = %du,' % (z(pr.get('subgroupSupportedStages')), z(pr.get('subgroupSupportedOperations'))))
        mem = v['memory']
        lines.append('  .n_heap = %d, .heaps = { %s }, .n_type = %d, .types = { %s },' % (
            len(mem['heaps']), ', '.join('{%dull, %d}' % (h['size'], h['flags']) for h in mem['heaps']),
            len(mem['types']), ', '.join('{%d, %d}' % (t['flags'], t['heap']) for t in mem['types'])))
        lines.append('  .n_queue = %d, .queues = { %s },' % (len(v['queues']), ', '.join(
            '{%d, %d, %d}' % (q['flags'], q['count'], z(q['timestampValidBits'], 64)) for q in v['queues'])))
        lines.append('};')
    lines.append('static const struct cs_shape *const cs_all[] = { %s };' % ', '.join('&cs_' + c_ident(n) for n in shapes))
    lines.append('static const char *cs_feature_name(size_t i) {')
    lines.append('    static const struct { size_t i; const char *n; } t[] = { %s };' % ', '.join(
        '{offsetof(VkPhysicalDeviceFeatures, %s) / sizeof(VkBool32), "%s"}' % (k, k) for k in core))
    lines.append('    for (size_t k = 0; k < sizeof t / sizeof *t; k++) if (t[k].i == i) return t[k].n;')
    lines.append('    return "?";')
    lines.append('}')
    lines.append('static const char *const cs_instance_ext[] = { %s };' % ', '.join(c_str(e) for e in INSTANCE_EXTS))
    open(out, 'w').write('\n'.join(lines) + '\n')


def oracle(name, got_path):
    stem = REAL[name]
    want = json.load(open(os.path.join(DEVICES, stem + '.json')))
    got = json.load(open(got_path))
    bad = []
    for sect in ('limits', 'features', 'formats', 'memory'):
        for k, v in want[sect].items():
            if sect == 'features' and k in ('geometryShader', 'geometryShaderOcclusionQuery'): continue   # capprobe 判定，不是能力形态
            g = got.get(sect, {}).get(k)
            if (abs(g - v) > 1e-6 if isinstance(v, float) else g != v): bad.append('%s.%s：真机 %r / 本构建 %r' % (sect, k, v, g))
    for k in ('vendorId', 'deviceId', 'deviceName', 'driverName', 'subgroupSize'):
        if got.get(k) != want.get(k): bad.append('%s：真机 %r / 本构建 %r' % (k, want.get(k), got.get(k)))
    if bad:
        print('FAIL: %s 档打出的设备 caps 和真机档 devices/%s.json 不一致（%d 处）：\n  %s' % (name, stem, len(bad), '\n  '.join(bad)))
        return 1
    n = sum(len(want[s]) for s in ('limits', 'features', 'formats', 'memory')) - 2 + 5
    print('PASS: %s 档打出的设备 caps 与真机档 devices/%s.json 一致（比了 %d 项）' % (name, stem, n))
    return 0


def leaves(v, path=''):
    if isinstance(v, dict):
        for k in v: yield from leaves(v[k], path + '.' + k)
    elif isinstance(v, list) and any(isinstance(x, (dict, list)) for x in v):
        for i, x in enumerate(v): yield from leaves(x, '%s[%d]' % (path, i))
    else:
        yield path, v


def compare(name, got_path):
    """生成的档案 vs 档案文件：api / identity / vulkan 三段逐叶子比；文件里写 null 的跳过（来源没读数，假驱动按「无」答）。
    model / system 是宿主自己的读数（假驱动管不到），不比；两份都要过 lint（各自的 factsDigest 自洽）。"""
    want = load(name)
    got = json.load(open(got_path, encoding='utf-8'))
    bad = ['生成的档案不合格：' + b for b in lint.check(got)]
    if (got.get('provenance'), got.get('completeness')) != ('probed', 'complete'):
        bad.append('生成的档案元数据应为 probed + complete，实为 %r + %r' % (got.get('provenance'), got.get('completeness')))
    w = dict(leaves({k: want[k] for k in ('api', 'identity', 'vulkan')}))
    g = dict(leaves({k: got.get(k) for k in ('api', 'identity', 'vulkan')}))
    skipped = 0
    for k, v in w.items():
        if v is None: skipped += 1; continue
        if k not in g: bad.append('%s：档案 %r / 生成的没有这项' % (k, v)); continue
        if g[k] != v: bad.append('%s：档案 %r / 生成 %r' % (k, v, g[k]))
    extra = sorted(k for k in g if k not in w)
    bad += ['%s：生成的多出这项（%r），档案里没有' % (k, g[k]) for k in extra]
    if bad:
        print('FAIL: [%s] 生成的设备档案和 devprofiles/%s.json 不一致（%d 处）：\n  %s' % (name, name, len(bad), '\n  '.join(bad[:40])))
        return 1
    print('PASS: [%s] 生成的设备档案与 devprofiles/%s.json 逐字段一致（比 %d 项，档案标未知跳过 %d 项；生成档 %s 过 lint）'
          % (name, name, len(w) - skipped, skipped, got['factsDigest'][:23]))
    return 0


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'header' and len(sys.argv) == 3: header(sys.argv[2])
    elif cmd == 'names': print(' '.join(names()))
    elif cmd == 'oracle' and len(sys.argv) == 4: sys.exit(oracle(sys.argv[2], sys.argv[3]))
    elif cmd == 'compare' and len(sys.argv) == 4: sys.exit(compare(sys.argv[2], sys.argv[3]))
    else: sys.exit(__doc__)
