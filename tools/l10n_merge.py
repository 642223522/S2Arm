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
  JSON 写不回本侧原样（手排格式）→ 不碰，退出 1 交普通冲突；例外：SEMANTIC 里的表（launchers/shared/experience.v1.json）按 JSON 语义合并、写成标准格式（main_semantic）。
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


SEMANTIC = ('launchers/shared/experience.v1.json',)   # 按 JSON 语义合并、写成标准格式的表（手排格式写不回原样，不按文本保险）


IDKEYS = ('id', 'code', 'key', 'name')


def idkey(*lists):
    """几份对象数组共同的身份字段：每一项都有、各份内唯一，依次试 IDKEYS；没有 → None"""
    for k in IDKEYS:
        ok = True
        for l in lists:
            if not (isinstance(l, list) and all(isinstance(e, dict) and k in e for e in l)) or len({json.dumps(e[k], sort_keys=True) for e in l}) != len(l):
                ok = False; break
        if ok:
            return k
    return None


def m3s(vo, va, vb):
    """语义三方合并（experience 表用）：字典按键递归；对象数组有身份字段（IDKEYS）→ 按身份逐项递归，顺序按本侧、对侧新增的插在它在对侧的前一项之后；
    其余同 m3（两边一样 / 只一边改了取那边 / 否则 None = 冲突）"""
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
            v = m3s(vo.get(k, GONE), va.get(k, GONE), vb.get(k, GONE))
            if v is None:
                return None
            if v is not GONE:
                out[k] = v
        return out
    lo = [] if vo is GONE else vo
    k = isinstance(va, list) and isinstance(vb, list) and idkey(lo, va, vb)
    if k:
        ident = lambda e: json.dumps(e[k], sort_keys=True)
        mo, ma, mb = ({ident(e): e for e in l} for l in (lo, va, vb))
        val = {}
        for i in list(ma) + [i for i in mb if i not in ma] + [i for i in mo if i not in ma and i not in mb]:
            v = m3s(mo.get(i, GONE), ma.get(i, GONE), mb.get(i, GONE))
            if v is None:
                return None
            val[i] = v
        order = [i for i in ma if val[i] is not GONE]
        prev = None
        for i in mb:   # 对侧新增的：插在它在对侧的前一项之后（那项不在结果里 → 接在最后）
            if i not in order and val.get(i, GONE) is not GONE:
                order.insert(order.index(prev) + 1 if prev in order else len(order), i)
            prev = i
        return [val[i] for i in order]
    return None


def main_semantic(o, a, b):
    """按 JSON 语义三方合并（11-11 合入运维线，维护者批：experience.v1.json 手排格式写不回原样，15:01 一分钟三支冲突退回）：
    三份都解析成对象，按键递归三方合并（m3s：对象数组按身份字段 id / code / key / name 逐项合并，没有身份字段的数组两边都改 = 冲突）；顶层 revision（口径号，每改一次 +1，见 launchers/shared/README.md）两边都改了 →
    基 + 两边各自的增量（两支各从 N 加到 N+1 → N+2），只一边改了取那边。写出固定标准格式：2 格缩进、键序按本侧、新键在后、文件尾换行；
    不管哪边还是旧的手排格式都能合，第一次合并时顺带变成标准格式。保险：写出的文本再解析，须与合并结果语义相等，否则退出 1 交人"""
    try:
        do, da, db = (json.loads(open(x, encoding='utf-8').read()) for x in (o, a, b))
    except (OSError, ValueError):
        return 1
    if not (isinstance(do, dict) and isinstance(da, dict) and isinstance(db, dict)):
        return 1
    ro, ra, rb = do.get('revision'), da.get('revision'), db.get('revision')
    both_rev = all(isinstance(x, int) and not isinstance(x, bool) for x in (ro, ra, rb)) and ra != ro and rb != ro
    if both_rev:   # 先把两边的 revision 对齐成同一个值，让 m3 不把它当冲突；合完再写回增量和
        db = dict(db); db['revision'] = ra
    out = m3s(do, da, db)
    if out is None or not isinstance(out, dict):
        return 1
    if both_rev:
        out['revision'] = ra + rb - ro
    text = json.dumps(out, ensure_ascii=False, indent=2) + '\n'
    if json.loads(text) != out:
        return 1
    open(a, 'w', encoding='utf-8').write(text)
    return 0


def main(o, a, b, path=''):
    if path.endswith('.strings'):
        return main_strings(o, a, b)
    if any(path.endswith(x) for x in SEMANTIC):
        return main_semantic(o, a, b)
    return main_json(o, a, b)


if __name__ == '__main__':
    if len(sys.argv) < 4:
        sys.exit('用法：l10n_merge.py <基> <本侧（写回）> <对侧> [路径]')
    sys.exit(main(*sys.argv[1:5]))
