#!/usr/bin/env python3
"""本地化 / 体验表内重复键检查（11-11 合入运维线，维护者批）：l10n_dupkeys.py [仓库根]
起因：launcher/ios-error-codes 的 Localizable.json 里同一个 source 写了两条，按键合并器判不了、每次合 main 都冲突退回，来回查了两轮。
查哪些表：.gitattributes 里 merge=s2a-l10n 登记的路径（含通配）+ EXTRA（体验规格表），逐张查表内重复：
  JSON 任一对象里同名键出现两次；条目表（[{"source": …}]）source 重复；对象数组里每项都有 id / code / key / name 时该字段重复；
  .strings 同一个 "键" 两行。
  安卓资源（ANDROID：android/**/res/values*/strings.xml，不论是否登记）：同一文件里同类资源（string / plurals / string-array）同名两次——
  两支各补同一条、各自合得进来，合在一起 Gradle 合并资源报「Found item String/… more than one time」、整包出不了（11-11 #661）。
输出每处一行「表:第 N 项（或第 N 行）重复键「…」，与第 M 项同」，有就退出 1；没有登记的表不查。"""
import fnmatch, json, os, re, subprocess, sys

IDKEYS = ('id', 'code', 'key', 'name')
EXTRA = ('launchers/shared/experience.v1.json',)   # 维护者点名要查、不论是否登记 merge=s2a-l10n
ANDROID = 'android/*/res/values*/strings.xml'   # fnmatch 的 * 跨目录，= android/**/res/values*/strings.xml
ARES = re.compile(r'<(string|plurals|string-array)\b[^>]*?\bname\s*=\s*"([^"]+)"')
ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"(?:[^"\\]|\\.)*";\s*$')


def registered(repo):
    pats = []
    try:
        for l in open(os.path.join(repo, '.gitattributes'), encoding='utf-8'):
            l = l.strip()
            if l and not l.startswith('#') and 'merge=s2a-l10n' in l.split()[1:]:
                pats.append(l.split()[0])
    except OSError:
        pass   # 没有 .gitattributes 只是没有登记的表；体验表、安卓资源照查
    files = subprocess.run(['git', '-C', repo, 'ls-files'], capture_output=True, text=True).stdout.split('\n')
    return sorted({f for f in files if f and (any(fnmatch.fnmatch(f, p) for p in pats) or f in EXTRA or fnmatch.fnmatch(f, ANDROID))})


def dup_json(path, text):
    out = []
    def hook(pairs):
        seen = {}
        for i, (k, _) in enumerate(pairs):
            if k in seen:
                out.append(f'{path}：对象里键「{k[:60]}」出现两次（第 {seen[k] + 1} 个与第 {i + 1} 个）')
            else:
                seen[k] = i
        return dict(pairs)
    try:
        doc = json.loads(text, object_pairs_hook=hook)
    except ValueError as e:
        return [f'{path}：不是合法 JSON（{e}）']
    def walk(x, where):
        if isinstance(x, dict):
            for k, v in x.items():
                walk(v, f'{where}/{k}')
        elif isinstance(x, list):
            if x and all(isinstance(e, dict) for e in x):
                for k in ('source',) + IDKEYS:
                    if all(k in e for e in x):
                        seen = {}
                        for i, e in enumerate(x):
                            v = json.dumps(e[k], ensure_ascii=False, sort_keys=True)
                            if v in seen:
                                out.append(f'{path}{where or "/"}：第 {i + 1} 项 {k} 重复「{str(e[k])[:60]}」（与第 {seen[v] + 1} 项同）')
                            else:
                                seen[v] = i
                        break
            for i, e in enumerate(x):
                walk(e, f'{where}[{i}]')
    walk(doc, '')
    return out


def dup_strings(path, text):
    out, seen = [], {}
    for n, l in enumerate(text.split('\n'), 1):
        m = ENTRY.match(l)
        if m:
            if m.group(1) in seen:
                out.append(f'{path}：第 {n} 行键「{m.group(1)[:60]}」重复（与第 {seen[m.group(1)]} 行同）')
            else:
                seen[m.group(1)] = n
    return out


def dup_android(path, text):
    # 注释里的条目不算：把 <!-- … --> 换成同样多的换行，行号不变
    text = re.sub(r'<!--.*?-->', lambda m: '\n' * m.group(0).count('\n'), text, flags=re.S)
    out, seen = [], {}
    for n, l in enumerate(text.split('\n'), 1):
        for m in ARES.finditer(l):
            k = (m.group(1), m.group(2))
            if k in seen:
                out.append(f'{path}：第 {n} 行 {k[0]}「{k[1][:60]}」重复（与第 {seen[k]} 行同；Gradle 合并资源会失败）')
            else:
                seen[k] = n
    return out


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else '.'
    hits, files = [], registered(repo)
    for f in files:
        try:
            text = open(os.path.join(repo, f), encoding='utf-8').read()
        except OSError:
            continue
        hits += dup_strings(f, text) if f.endswith('.strings') else dup_android(f, text) if f.endswith('.xml') else dup_json(f, text)
    for h in hits:
        print('【红】' + h)
    print(f'本地化 / 体验表重复键：查了 {len(files)} 张表，重复 {len(hits)} 处')
    return 1 if hits else 0


if __name__ == '__main__':
    sys.exit(main())
