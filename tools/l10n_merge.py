#!/usr/bin/env python3
"""翻译表的 git 合并器（11-09 启动器线：每支新文案都追加在 Localizable.json 文件尾，同批几支依次合入时后合的一律文本冲突、整支退回，
#201 #221 #238 一天被顶掉四次）。.gitattributes 把翻译表交给它（merge=s2a-l10n）；列车启动时在仓库配置里登记：
  git config merge.s2a-l10n.driver 'python3 tools/l10n_merge.py %O %A %B'
不能用 merge=union：两边都在尾部追加时 git 把相同的「},  {」行收掉，并出的 JSON 缺逗号（实测），坏文件还不报冲突。
两种表：
  条目表 [{"source": 中文, "en": 英文}, …]（launchers/macos/adapter/.../Localizable.json）：按 source 认条目；
  键值表 {"键": 文案, …}（launchers/macos/frontend/l10n/*.json）：按键认。
  Xcode 字符串目录 .xcstrings（{"strings": {键: …}}，「" : "」分隔）：按键逐层递归（11-11 合入运维线）；
  .strings（一行一条 "键" = "值";，ios/l10n/*.lproj/*.strings）：按键逐行合并，对侧新增的插在它在对侧的前一个键之后；注释等非条目行两边都改了 → 冲突（11-11）。
  JSON 写不回本侧原样（手排格式，如 launchers/shared/experience.v1.json）→ 不碰，退出 1 交普通冲突。
三方合并，逐条：两边一样 → 留；只一边相对基改了（含新增、删除）→ 取改的那边；两边都改且不同 → 退出 1（留给人，同普通冲突）。
输出顺序：本侧（%A）原有条目按原序，对侧（%B）新增的接在后面；缩进与文件尾换行照本侧原样。写回 %A，退出 0。"""
import json, re, sys

GONE = object()


def load(path):
    text = open(path, encoding='utf-8').read()
    return text, json.loads(text)


def entries(doc):
    """→ (形状, 有序 {键: 值})；认不出的形状 → None"""
    if isinstance(doc, dict):
        return 'dict', dict(doc)
    if isinstance(doc, list) and all(isinstance(e, dict) and isinstance(e.get('source'), str) for e in doc):
        keys = [e['source'] for e in doc]
        if len(set(keys)) == len(keys):
            return 'list', {e['source']: e for e in doc}
    return None


def m3(vo, va, vb):
    """三方合并一个值：两边一样 / 只一边相对基改了 → 取那边；两边都是字典 → 逐键递归（本侧原序，对侧新增接后）；否则 → None（冲突）"""
    if va == vb:
        return va
    if va == vo:
        return vb
    if vb == vo:
        return va
    if isinstance(va, dict) and isinstance(vb, dict) and (vo is GONE or isinstance(vo, dict)):
        vo = {} if vo is GONE else vo
        out = {}
        for k in list(va) + [k for k in vb if k not in va]:
            v = m3(vo.get(k, GONE), va.get(k, GONE), vb.get(k, GONE))
            if v is None:
                return None
            if v is not GONE:
                out[k] = v
        return out
    return None


def dump(doc, like):
    """按本侧原文的缩进 / 分隔符写出（Xcode 的 .xcstrings 用「" : "」）"""
    m = re.match(r'[\[{]\n( +)', like)
    sep = (',', ' : ') if '" : ' in like else (',', ': ')
    return json.dumps(doc, ensure_ascii=False, indent=len(m.group(1)) if m else 1, separators=sep) + ('\n' if like.endswith('\n') else '')


def main_json(o, a, b):
    try:
        (_, do), (ta, da), (_, db) = load(o), load(a), load(b)
    except (OSError, ValueError):
        return 1
    if dump(da, ta) != ta:   # 写不回原样（手排格式）→ 不碰，交普通冲突
        return 1
    eo, ea, eb = entries(do), entries(da), entries(db)
    if not eo or not ea or not eb or not eo[0] == ea[0] == eb[0]:
        return 1
    shape, mo, ma, mb = ea[0], eo[1], ea[1], eb[1]
    out = m3(mo, ma, mb) if shape == 'dict' else None
    if shape == 'list':
        out = {}
        for k in list(ma) + [k for k in mb if k not in ma]:
            vo, va, vb = mo.get(k, GONE), ma.get(k, GONE), mb.get(k, GONE)
            v = va if va == vb else vb if va == vo else va if vb == vo else None
            if v is None:
                return 1
            if v is not GONE:
                out[k] = v
    if out is None:
        return 1
    open(a, 'w', encoding='utf-8').write(dump(out if shape == 'dict' else list(out.values()), ta))
    return 0


ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"(?:[^"\\]|\\.)*";\s*$')


def strings_parse(path):
    """→ (各行, {键: 行})；一行一条 "键" = "值";（11-11 合入运维线：ios/l10n/*.lproj/*.strings 多支同时加条目、每次冲突退回）。重复键 → None"""
    lines = open(path, encoding='utf-8').read().split('\n')
    ent = {}
    for l in lines:
        m = ENTRY.match(l)
        if m:
            if m.group(1) in ent:
                return None
            ent[m.group(1)] = l
    return lines, ent


def main_strings(o, a, b):
    try:
        po, pa, pb = strings_parse(o), strings_parse(a), strings_parse(b)
    except (OSError, UnicodeDecodeError):
        return 1
    if not po or not pa or not pb:
        return 1
    (lo, eo), (la, ea), (lb, eb) = po, pa, pb
    rest = lambda ls: [l for l in ls if not ENTRY.match(l)]
    if rest(lb) != rest(lo) and rest(lb) != rest(la):   # 注释等非条目行两边都改了 → 留给人
        return 1
    val = {}
    for k in list(ea) + [k for k in eb if k not in ea] + [k for k in eo if k not in ea and k not in eb]:
        v = m3(eo.get(k, GONE), ea.get(k, GONE), eb.get(k, GONE))
        if v is None:
            return 1
        val[k] = v
    out = []
    for l in la:
        m = ENTRY.match(l)
        if not m:
            out.append(l)
        elif val[m.group(1)] is not GONE:
            out.append(val[m.group(1)])
    # 对侧新增的键：插在它在对侧的前一个键之后（那个键不在结果里就接在最后一条之后）
    have = {ENTRY.match(l).group(1) for l in out if ENTRY.match(l)}
    prev = None
    for k in eb:
        if k not in have and val.get(k, GONE) is not GONE:
            idx = None
            if prev is not None:
                idx = next((i for i, l in enumerate(out) if ENTRY.match(l) and ENTRY.match(l).group(1) == prev), None)
            if idx is None:
                idx = max([i for i, l in enumerate(out) if ENTRY.match(l)], default=len(out) - 1)
            out.insert(idx + 1, val[k]); have.add(k)
        prev = k
    open(a, 'w', encoding='utf-8').write('\n'.join(out))
    return 0


def main(o, a, b, path=''):
    if path.endswith('.strings'):
        return main_strings(o, a, b)
    return main_json(o, a, b)


if __name__ == '__main__':
    if len(sys.argv) < 4:
        sys.exit('用法：l10n_merge.py <基> <本侧（写回）> <对侧> [路径]')
    sys.exit(main(*sys.argv[1:5]))
