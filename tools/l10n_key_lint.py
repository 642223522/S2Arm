#!/usr/bin/env python3
"""界面文案键对表检查（快检查，只用标准库）：三端界面里每处取文案调用，按它实际经过的取文案函数（含前缀）拼出完整键，对照键表。
  python3 tools/l10n_key_lint.py [仓库根]   → 每处问题一行「种类<TAB>文件:行<TAB>表<TAB>经由<TAB>拼出的键」，有问题退出 1
种类：DOUBLE = 拼出的键不在表、去掉前缀在表（前缀重复，界面显示成 [export.export.boost.title]，11-15 v0.4.0 候选出包完成页）；
      MISSING = 拼出的键和原样都不在表（键名打错 / 表里漏加）。
表：shared = launchers/shared/experience.v1.json 的 id（Mac BackendText.launcherText、Windows T / text.Get）；
    mac = launchers/macos/frontend/l10n/en.json（Mac loc.t）；ios = ios/l10n/en.lproj/S2ArmHost.strings（iOS S2AL）。
认得的取法：
  Swift  func NAME(_ id: String…) -> String { …launcherText("前缀." + id… / loc.t(… / 转调本文件别的这类函数 }，调用 NAME("键")；
         组件传闭包 Comp(…, text: NAME) / text: { BackendText.launcherText("前缀." + $0 … }，组件里 let text: (String) -> String，
         组件内 text("键") 与组件里写成字面量再传进 text 的键（如横幅的分类表）都按传进来的前缀核；
  C#     string NAME(string id) => T("前缀." + id)，调用 NAME("键") / T("键") / .Get("键")；
  iOS    S2AL(@"键")。
拼接出来的动态键（"前缀." + 变量）不核。"""
import collections, json, pathlib, re, sys

LIT = r'"([A-Za-z][\w-]*(?:\.[\w-]+)+)"'   # 像键的字面量：至少一个点


def ids(o, out):
    if isinstance(o, dict):
        if isinstance(o.get("id"), str): out.add(o["id"])
        for v in o.values(): ids(v, out)
    elif isinstance(o, list):
        for v in o: ids(v, out)
    return out


def read(p):
    try: return p.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError): return ""


def tables(R):
    shared = R / "launchers/shared/experience.v1.json"
    mac = R / "launchers/macos/frontend/l10n/en.json"
    return {"shared": ids(json.loads(read(shared) or "{}"), set()),
            "mac": set(json.loads(read(mac) or "{}")),
            "ios": set(re.findall(r'^\s*"([^"]+)"\s*=', read(R / "ios/l10n/en.lproj/S2ArmHost.strings"), re.M))}


def lint(R):
    T = tables(R); out = []

    def check(f, line, table, prefix, lit, via):
        keys, full = T[table], prefix + lit
        if full in keys or any(k.startswith(full + ".") for k in keys): return   # 组键下再挂选项（拿来再拼）不算缺
        out.append(("DOUBLE" if prefix and lit in keys else "MISSING", f"{f.relative_to(R)}:{line}", table, via, full))

    # ---------- Swift（Mac） ----------
    swift = [p for p in sorted((R / "launchers/macos").rglob("*.swift")) if "/Tests/" not in str(p) and "/.build/" not in str(p)]
    helper_def = re.compile(r'func (\w+)\(_ (\w+): String[^)]*\)\s*->\s*String\s*\{(.*)')
    passed = collections.defaultdict(lambda: collections.defaultdict(list))   # 组件 → 闭包参数名 → [(表, 前缀, 出处)]
    per_file = {}
    for p in swift:
        lines = read(p).splitlines(); hs = []   # (行号, 名, 表, 前缀)
        for i, l in enumerate(lines):
            m = helper_def.search(l)
            if not m: continue
            name, arg, body = m.group(1), m.group(2), " ".join([m.group(3)] + lines[i + 1:i + 3])
            pm = re.search(r'"([\w.]*\.)"\s*\+\s*' + arg + r'\b', body)
            prefix = pm.group(1) if pm else ""
            if "launcherText" in body: table = "shared"
            elif "loc.t(" in body or "L10n.string" in body: table = "mac"
            else:   # 一层转调本文件别的取文案函数
                cm = re.search(r'\b(\w+)\(("[\w.]*\."\s*\+\s*)?' + arg + r'\b', body)
                base = next((h for h in reversed(hs) if cm and h[1] == cm.group(1)), None)
                if not base: continue
                table, prefix = base[2], base[3] + (re.search(r'"([\w.]*\.)"', cm.group(2)).group(1) if cm.group(2) else "")
            hs.append((i + 1, name, table, prefix))
        per_file[p] = (lines, hs)
        for i, l in enumerate(lines):
            for cm in re.finditer(r'\b([A-Z]\w+)\(([^()]*(?:\([^()]*\))?[^()]*)\)', l):
                for am in re.finditer(r'(\w+):\s*(\w+)\s*(?=[,)]|$)', cm.group(2)):
                    hit = [h for h in hs if h[1] == am.group(2) and h[0] <= i + 1]
                    if hit: passed[cm.group(1)][am.group(1)].append((hit[-1][2], hit[-1][3], f"{p.name}:{i + 1}"))
            for am in re.finditer(r'\b([A-Z]\w+)\(.*?(\w+):\s*\{\s*BackendText\.launcherText\((?:"([\w.]*\.)"\s*\+\s*)?\$0', l):
                passed[am.group(1)][am.group(2)].append(("shared", am.group(3) or "", f"{p.name}:{i + 1}"))

    for p, (lines, hs) in per_file.items():
        # 本文件定义的组件：行范围（到下一个顶层 struct / 文件尾）与其闭包参数
        starts = [(i, m.group(1)) for i, l in enumerate(lines) for m in [re.match(r'(?:\w+\s+)*struct (\w+)', l)] if m]
        spans = [(n, s, starts[k + 1][0] if k + 1 < len(starts) else len(lines)) for k, (s, n) in enumerate(starts)]
        def comp_at(i):
            return next((n for n, s, e in spans if s <= i < e), None)
        labels = {comp_at(i): set() for i in range(len(lines))}
        for i, l in enumerate(lines):
            m = re.search(r'let (\w+): \(String\) -> String', l)
            if m and comp_at(i): labels.setdefault(comp_at(i), set()).add(m.group(1))
        for i, l in enumerate(lines):
            ln, comp = i + 1, comp_at(i)
            for m in re.finditer(r'BackendText\.launcherText\(' + LIT, l):
                check(p, ln, "shared", "", m.group(1), "launcherText")
            for m in re.finditer(r'\bloc\.t\(' + LIT, l):
                check(p, ln, "mac", "", m.group(1), "loc.t")
            called = set()
            for m in re.finditer(r'(?<![\w.])(\w+)\(' + LIT + r'\s*\)', l):
                name, lit = m.group(1), m.group(2)
                prev = [h for h in hs if h[1] == name and h[0] <= ln]
                if prev:
                    h = prev[-1]; check(p, ln, h[2], h[3], lit, f'{name}() = "{h[3]}" +'); called.add(lit)
                elif comp and name in labels.get(comp, ()):
                    for table, prefix, src in passed.get(comp, {}).get(name, []):
                        check(p, ln, table, prefix, lit, f"{comp}.{name} ← {src}")
                    called.add(lit)
            # 组件里写成字面量、再经闭包取文案的键（横幅分类表 [("cheats", "export.boost.cheats"), …]）：表里有原样的才算键
            if comp and labels.get(comp):
                for m in re.finditer(LIT, l):
                    lit = m.group(1)
                    if lit in called or lit not in T["shared"]: continue
                    for name in labels[comp]:
                        for table, prefix, src in passed.get(comp, {}).get(name, []):
                            if prefix: check(p, ln, table, prefix, lit, f"{comp}.{name} ← {src}")

    # ---------- C#（Windows） ----------
    for p in sorted((R / "launchers/windows/launcher").rglob("*.cs")):
        if any(s in str(p) for s in ("/obj/", "/bin/", "Tests", "Snapshots")): continue
        lines = read(p).splitlines(); hs = {"T": ""}
        for l in lines:
            m = re.search(r'string (\w+)\(string (\w+)\)\s*=>\s*T\("([\w.]*\.)"\s*\+\s*\2\)', l)
            if m: hs[m.group(1)] = m.group(3)
        for i, l in enumerate(lines):
            for m in re.finditer(r'(?<![\w.])(\w+)\(' + LIT + r'\s*\)', l):
                if m.group(1) in hs: check(p, i + 1, "shared", hs[m.group(1)], m.group(2), f"{m.group(1)}()")
            for m in re.finditer(r'\.Get\(' + LIT, l):
                check(p, i + 1, "shared", "", m.group(1), "Get")

    # ---------- iOS ----------
    for p in sorted((R / "ios").glob("*.m")):
        for i, l in enumerate(read(p).splitlines()):
            for m in re.finditer(r'S2AL\(@' + LIT + r'\)', l):
                check(p, i + 1, "ios", "", m.group(1), "S2AL")
    return out


if __name__ == "__main__":
    R = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    found = lint(R)
    for f in found: print("\t".join(f))
    sys.exit(1 if found else 0)
