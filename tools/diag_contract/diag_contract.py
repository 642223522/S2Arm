"""诊断收件契约的 Python 解释器（规则数据在同目录 diag_contract.json，收件 Worker 用它的逐字节拷贝 + 自己的 JS 解释器，两边都跑 cases.json）。

一份诊断包收不收，按收件 Worker 的顺序判（第一条错 = Worker 回的错误码）：
  ① 压缩后 > limits.zip_bytes → too_large；不到 22 字节 / 读不出 → bad_zip；成员（含目录条目）> limits.members → too_many_files
  ② 逐个条目（含目录）：路径安全（空、反斜杠、绝对路径、盘符、NUL、. / .. / 空段 → unsafe_path）、符号链接、重名 → unsafe_path；
     解开 > limits.member_bytes → file_too_large；合计 > limits.total_bytes → too_large
  ③ 唯一一层包装目录（根上没有 manifest.json、而 <唯一根>/manifest.json 在）：剥掉再按根判
  ④ 逐个文件（不含目录条目）：首段在 forbidden_dirs（不分大小写）或文件名以 forbidden_suffixes 结尾 → forbidden_file；
     再按 rules 顺序找第一条匹配的：dir = "*" 任意位置，否则必须正好是「dir/文件名」两段（dir 区分大小写）；
     ext = 小写文件名最后一个点之后（点在开头不算扩展名），name = 对小写文件名的正则（只用 Python re 与 JS RegExp 都一样的写法）；
     匹配到的规则有 max_bytes 且超了 → file_too_large；有 count 且该组超过 counts[组] → too_many_files；一条都不匹配 → forbidden_file
  ⑤ 根上要有 manifest.json（≤ limits.manifest_bytes），JSON 对象且 schema = 1，否则 not_diag
用法：python3 tools/diag_contract/diag_contract.py <诊断包.zip> …   → 逐个成员打印命中的规则，有拒收项退出 1
"""
import json
import re
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONTRACT = HERE / "diag_contract.json"
CASES = HERE / "cases.json"


def load(path=CONTRACT):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _unsafe(name):
    if not name or "\\" in name or name.startswith("/") or re.match(r"^[A-Za-z]:", name) or "\0" in name:
        return True
    parts = name[:-1].split("/") if name.endswith("/") else name.split("/")
    return any(p in ("..", ".", "") for p in parts)


def judge(contract, rel, size, counts):
    """一个文件成员（已剥包装目录的相对路径、解开大小）→ (规则 id 或 None, 错误码或 None, 说明)。counts 是本包各计数组已用份数，命中时就地加一"""
    parts = rel.split("/")
    base = parts[-1].lower()
    if parts[0].lower() in contract["forbidden_dirs"] or any(base.endswith(s) for s in contract["forbidden_suffixes"]):
        return None, "forbidden_file", f"诊断包里不能有密钥、存档或游戏文件：{rel[:80]}"
    dot = base.rfind(".")
    ext = base[dot + 1:] if dot > 0 else ""
    for rule in contract["rules"]:
        if rule["dir"] != "*" and not (len(parts) == 2 and parts[0] == rule["dir"]):
            continue
        if "ext" in rule and ext not in rule["ext"]:
            continue
        if "name" in rule and not re.search(rule["name"], base):
            continue
        cap = rule.get("max_bytes")
        if cap is not None and size > cap:
            return rule["id"], "file_too_large", f"{rule['label']}超过 {cap >> 20} MB：{rel[:80]}"
        group = rule.get("count")
        if group:
            counts[group] = counts.get(group, 0) + 1
            if counts[group] > contract["counts"][group]:
                return rule["id"], "too_many_files", f"{rule['label']}超过 {contract['counts'][group]} 个。"
        return rule["id"], None, ""
    return None, "forbidden_file", f"诊断包里有不收的文件类型：{rel[:80]}"


def check_zip(data, contract=None):
    """整包判定 → (问题列表 [(错误码, 成员, 说明)]，按 Worker 的判定顺序排、第一条就是 Worker 会回的那个；收下的成员 [(成员, 规则 id)])"""
    c = contract or load()
    lim = c["limits"]
    if len(data) > lim["zip_bytes"]:
        return [("too_large", "", f"诊断包超过 {lim['zip_bytes'] >> 20} MB。")], []
    if len(data) < 22:
        return [("bad_zip", "", "不是 ZIP 文件。")], []
    import io
    try:
        z = zipfile.ZipFile(io.BytesIO(data))
    except (zipfile.BadZipFile, ValueError, OSError):
        return [("bad_zip", "", "不是 ZIP 文件。")], []
    infos = z.infolist()
    if len(infos) > lim["members"]:
        return [("too_many_files", "", f"文件数超过 {lim['members']} 个。")], []
    bad, seen, total, entries = [], set(), 0, []
    for i in infos:
        # Worker 一律按 UTF-8 解名字（不看通用标志第 11 位）；zipfile 没标记时按 cp437 解，换回原字节再按 UTF-8 解
        name = i.filename if i.flag_bits & 0x800 else i.orig_filename.encode("cp437").decode("utf-8", "replace")
        if _unsafe(name):
            bad.append(("unsafe_path", name, f"不安全的文件路径：{name[:80]}"))
        elif (i.external_attr >> 16) & 0o170000 == 0o120000:
            bad.append(("unsafe_path", name, f"不收符号链接：{name[:80]}"))
        elif name in seen:
            bad.append(("unsafe_path", name, f"文件重名：{name[:80]}"))
        elif i.file_size > lim["member_bytes"]:
            bad.append(("file_too_large", name, f"单个文件超过 {lim['member_bytes'] >> 20} MB：{name[:80]}"))
        seen.add(name)
        total += i.file_size
        entries.append((name, i))
    if total > lim["total_bytes"]:
        bad.append(("too_large", "", f"解开后合计超过 {lim['total_bytes'] >> 20} MB。"))
    files = [(n, i) for n, i in entries if not n.endswith("/")]
    roots = {n.split("/")[0] for n, _ in files}
    wrap = ""
    if len(roots) == 1:
        r = next(iter(roots))
        names = {n for n, _ in files}
        if "manifest.json" not in names and r + "/manifest.json" in names:
            wrap = r + "/"
    counts, manifest, kept = {}, None, []
    for n, i in files:
        rel = n[len(wrap):] if wrap and n.startswith(wrap) else n
        rule, code, why = judge(c, rel, i.file_size, counts)
        if code:
            bad.append((code, n, why))
            continue
        kept.append((n, rule))
        if rel == "manifest.json" and rule == "general":
            manifest = i
    if manifest is None:
        bad.append(("not_diag", "", "不是 S2Arm 诊断包（缺 manifest.json）。"))
    elif manifest.file_size > lim["manifest_bytes"]:
        bad.append(("not_diag", "manifest.json", "manifest.json 太大。"))
    elif manifest.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):   # Worker 只会解存储 / deflate
        bad.append(("bad_zip", "manifest.json", "manifest.json 的压缩方式不认识。"))
    else:
        try:
            m = json.loads(z.read(manifest).decode("utf-8"))
        except (ValueError, zipfile.BadZipFile, OSError, NotImplementedError):
            m = None
        if not isinstance(m, dict) or m.get("schema") != 1 or isinstance(m.get("schema"), bool):
            bad.append(("not_diag", "manifest.json", "不是 S2Arm 诊断包（manifest.json 读不出或 schema 不是 1）。"))
    return bad, kept


def main(argv):
    rc = 0
    for p in argv:
        bad, kept = check_zip(Path(p).read_bytes())
        for n, rule in kept:
            print(f"收 {n}（{rule}）")
        for code, n, why in bad:
            print(f"拒 {code} {n}：{why}")
        rc |= bool(bad)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
