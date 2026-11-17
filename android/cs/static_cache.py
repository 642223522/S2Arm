#!/usr/bin/env python3
"""cs/build.sh 静态模式（S2ARM_ANDROID_CS_SERVICES=static）的产物缓存：两次 dotnet publish（probe + aot static）
与其后的 libunwind 改名只取决于 C# 编译闭包与固定工具，键相同就把上次的产物放回，不再从零编（门禁里约 164 秒 → 秒级）。

  static_cache.py key --repo R --extra K=V ...      → 打印键（算不出就退 3：调用方照常冷编，绝不猜）
  static_cache.py save --out OUT --cache DIR --key K → 把 OUT 下 static/、assets/licenses/dotnet-runtime-*、jniLibs/ 存进 DIR/<K>/
  static_cache.py restore --out OUT --cache DIR --key K → 命中：放回并把 link.txt 里的路径改到本次 OUT；没命中退 4

键 = sha256（固定参数 + 闭包里每个文件的「仓库相对路径 \\t sha256」按路径排序）。
闭包 = 从 android/cs/aot 与 android/cs/probe 两个入口 csproj 出发，静态解析 ProjectReference / Import / *Include 路径：
  - 每个工程目录整目录收（除 bin/ obj/）——嵌入资源、生成器输入等不用逐类认；
  - Include 指向工程目录外的文件 / 通配按实际展开收；
  - 各工程目录到仓库根一路上的 Directory.Build.* / Directory.Packages.props / global.json / nuget.config / NuGet.Config；
  - 构建脚本自身与它调的校验脚本、钉表。
路径里有认不出的 $(...) → 算不出键（退 3），走冷编：宁可慢，不能拿错产物。"""
import argparse, glob, hashlib, os, re, shutil, sys, tempfile, time

ENTRIES = ("android/cs/aot/S2A.Android.Aot.csproj", "android/cs/probe/S2A.Android.Probe.csproj")
FIXED = ("android/cs/build.sh", "android/cs/static_cache.py", "android/cs/nuget_verify.py", "android/cs/archive_check.py",
         "android/cs/nuget-pins.tsv", "android/cs/nuget.config", "android/tools/ndk_toolchain.sh")
ANCESTOR_FILES = ("Directory.Build.props", "Directory.Build.targets", "Directory.Build.rsp", "Directory.Packages.props",
                  "global.json", "nuget.config", "NuGet.Config", "NuGet.config")
SKIP_DIRS = {"bin", "obj", ".vs"}
OUTDIR_RE = r"\$\((IntermediateOutputPath|BaseIntermediateOutputPath|OutputPath|OutDir|PublishDir)\)"
KEEP = 8   # 缓存里留最近用过的几份


class Unresolvable(Exception):
    pass


def props_of(text, here, repo):
    """工程里的简单属性：<X>…</X> 与 <X Condition="'$(X)' == ''">缺省</X>（环境变量非空时以环境为准，同 MSBuild）。只认能完全代换的"""
    out = {k: v for k, v in os.environ.items() if v and re.fullmatch(r"[A-Za-z_]\w*", k)}
    for name, attrs, val in re.findall(r"<([A-Za-z_][A-Za-z0-9_]*)\b([^>]*)>([^<]*)</\1>", text):
        cond = re.search(r"Condition=\"([^\"]*)\"", attrs)
        if cond:
            if re.fullmatch(r"\s*'\$\(" + name + r"\)'\s*==\s*''\s*", cond.group(1)):
                if out.get(name):
                    continue   # 已有值（环境或前面赋过）：缺省不生效
            else:
                continue       # 别的条件：不猜，用到它的路径会因代换不全而算不出键
        v = subst(val, here, repo, out, strict=False)
        if v is not None:
            out[name] = v
    return out


def subst(s, here, repo, props, strict=True):
    s = s.strip()
    m = re.fullmatch(r"\$\(\[System\.IO\.Path\]::GetFullPath\('(.*)'\)\)", s)
    if m:
        s = m.group(1)
    s = s.replace("$(MSBuildThisFileDirectory)", here + os.sep).replace("$(MSBuildProjectDirectory)", here)
    for k, v in props.items():
        s = s.replace(f"$({k})", v)
    if "$(" in s or "@(" in s or "%(" in s:
        if strict:
            raise Unresolvable(s)
        return None
    return s


def norm(p, here):
    p = p.replace("\\", "/")
    return os.path.normpath(p if os.path.isabs(p) else os.path.join(here, p))


def closure(repo):
    repo = os.path.realpath(repo)
    files, dirs, seen = set(), set(), set()
    todo = [os.path.join(repo, e) for e in ENTRIES]
    while todo:
        proj = os.path.realpath(todo.pop())
        if proj in seen:
            continue
        seen.add(proj)
        if not os.path.isfile(proj):
            raise Unresolvable(f"缺工程文件 {os.path.relpath(proj, repo)}")
        here = os.path.dirname(proj)
        files.add(proj)
        if proj.endswith("proj"):
            dirs.add(here)
        text = open(proj, encoding="utf-8", errors="replace").read()
        text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
        props = props_of(text, here, repo)
        raw = {n: v for n, v in re.findall(r"<([A-Za-z_][A-Za-z0-9_]*)\b[^>]*>([^<]*)</\1>", text)}
        # 属性函数直接读的文件（如 S2A.Dsh 的 ReadAllText(dmsh_chain.h)）：内容进生成的源码
        for inner in re.findall(r"ReadAllText\('([^']*)'\)", text):
            p = norm(subst(inner, here, repo, props), here)
            if os.path.isfile(p):
                files.add(p)
        # 任何条目的 Include / Import 的 Project：指到存在的路径或通配就收（自定义条目如 DshXfpInput 也算），
        #   指不到路径的是名字（包名、程序集名、P/Invoke 库名），跳过；Exclude 不看（多收只会多冷编）
        for tag, attr, val in re.findall(r"<([A-Za-z_][\w.]*)\b[^>]*?\b(Include|Project)=\"([^\"]*)\"", text):
            if tag == "Import" and val.startswith("Sdk"):
                continue
            for one in val.split(";"):
                one = one.strip()
                if not one or one.startswith("@(") or one.startswith("%("):
                    continue   # 引用别的条目 / 元数据，那些条目自己已收
                if re.match(r"\$\((IntermediateOutputPath|BaseIntermediateOutputPath|OutputPath|OutDir|PublishDir)\)", one) \
                        or any(re.search(OUTDIR_RE, raw.get(n, "")) for n in re.findall(r"\$\(([A-Za-z_]\w*)\)", one)):
                    continue   # 编译期生成在输出目录里的文件（直接写或经属性，如 DirectClosureCs）：由闭包内的输入生成
                p = norm(subst(one, here, repo, props), here)
                if not p.startswith(repo + os.sep):
                    if tag == "Import" or not os.path.exists(p):
                        continue   # SDK / 包自带的 targets（由 SDK 版本与 NuGet 钉表管），或不是路径
                    raise Unresolvable(f"闭包指到仓库外：{one}")
                if tag in ("ProjectReference", "Import"):
                    todo.append(p)
                elif any(ch in p for ch in "*?["):
                    files.update(os.path.realpath(h) for h in glob.glob(p, recursive=True) if os.path.isfile(h))
                elif os.path.isfile(p):
                    files.add(p)
                elif os.path.isdir(p):
                    dirs.add(p)
    for d in list(dirs):
        for root, sub, names in os.walk(d):
            sub[:] = [s for s in sub if s not in SKIP_DIRS]
            files.update(os.path.join(root, n) for n in names)
        cur = d
        while cur.startswith(repo):
            for n in ANCESTOR_FILES:
                if os.path.isfile(os.path.join(cur, n)):
                    files.add(os.path.join(cur, n))
            if cur == repo:
                break
            cur = os.path.dirname(cur)
    for f in FIXED:
        p = os.path.join(repo, f)
        if not os.path.isfile(p):
            raise Unresolvable(f"缺 {f}")
        files.add(p)
    closure.projects = sorted(os.path.relpath(q, repo) for q in seen if q.endswith("proj"))
    return sorted(os.path.relpath(f, repo) for f in files if not os.path.islink(f) and os.path.isfile(f))


def key(repo, extra):
    h = hashlib.sha256()
    h.update(b"s2a-cs-static-v1\n")
    for kv in sorted(extra):
        h.update(kv.encode() + b"\n")
    rels = closure(repo)
    for rel in rels:
        d = hashlib.sha256()
        with open(os.path.join(repo, rel), "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                d.update(chunk)
        h.update(f"{rel}\t{d.hexdigest()}\n".encode())
    return h.hexdigest()[:32], len(rels)


MARK = "@S2A_CS_OUT@"


def save(out, cache, k):
    final = os.path.join(cache, k)
    if os.path.isdir(final):
        os.utime(final)
        return
    os.makedirs(cache, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix=f".{k}.", dir=cache)
    try:
        shutil.copytree(os.path.join(out, "static"), os.path.join(tmp, "static"), symlinks=True)
        shutil.copytree(os.path.join(out, "jniLibs"), os.path.join(tmp, "jniLibs"), symlinks=True)
        lic = os.path.join(tmp, "licenses"); os.makedirs(lic)
        for f in glob.glob(os.path.join(out, "assets", "licenses", "dotnet-runtime-*")):
            shutil.copy2(f, lic)
        # link.txt 里本次 $out 的绝对路径换成占位（每次门禁的临时目录都不同）；codec 那三行由 codecs/build.sh 每次现追加，不存
        lt = os.path.join(tmp, "static", "link.txt")
        lines = [l for l in open(lt, encoding="utf-8").read().splitlines() if not re.search(r"libs2a_(opus|vpx|avc)\.a$", l)]
        forms = sorted({out, os.path.realpath(out)}, key=len, reverse=True)   # /var 与 /private/var 两种写法都认
        def mark(l):
            for f in forms:
                l = l.replace(f, MARK)
            return l
        open(lt, "w", encoding="utf-8").write("".join(mark(l) + "\n" for l in lines))
        os.replace(tmp, final)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    olds = sorted((os.path.join(cache, d) for d in os.listdir(cache) if not d.startswith(".")), key=os.path.getmtime, reverse=True)
    for d in olds[KEEP:]:
        shutil.rmtree(d, ignore_errors=True)


def restore(out, cache, k):
    src = os.path.join(cache, k)
    if not os.path.isfile(os.path.join(src, "static", "link.txt")):
        return False
    for sub in ("static", "jniLibs"):
        shutil.rmtree(os.path.join(out, sub), ignore_errors=True)
        shutil.copytree(os.path.join(src, sub), os.path.join(out, sub), symlinks=True)
    lic = os.path.join(out, "assets", "licenses"); os.makedirs(lic, exist_ok=True)
    for f in glob.glob(os.path.join(src, "licenses", "*")):
        shutil.copy2(f, lic)
    lt = os.path.join(out, "static", "link.txt")
    text = open(lt, encoding="utf-8").read().replace(MARK, out)
    open(lt, "w", encoding="utf-8").write(text)
    os.utime(src)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=("key", "save", "restore", "files", "projects"))
    ap.add_argument("--repo"); ap.add_argument("--out"); ap.add_argument("--cache"); ap.add_argument("--key")
    ap.add_argument("--extra", action="append", default=[])
    a = ap.parse_args()
    if a.cmd in ("key", "files", "projects"):
        try:
            if a.cmd in ("files", "projects"):
                rels = closure(a.repo)
                print("\n".join(closure.projects if a.cmd == "projects" else rels))
                return 0
            t = time.time()
            k, n = key(a.repo, a.extra)
        except (Unresolvable, OSError) as e:
            print(f"[s2a] C# 静态库缓存：算不出键（{e}），本次冷编", file=sys.stderr)
            return 3
        print(f"[s2a] C# 静态库缓存键 {k}（闭包 {n} 个文件，{time.time() - t:.1f} 秒）", file=sys.stderr)
        print(k)
        return 0
    if a.cmd == "save":
        save(os.path.abspath(a.out), a.cache, a.key)
        return 0
    return 0 if restore(os.path.abspath(a.out), a.cache, a.key) else 4


if __name__ == "__main__":
    sys.exit(main())
