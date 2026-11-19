#!/usr/bin/env python3
"""繁体中文文案生成（11-14 i18n 加新语言）：简中原文经 OpenCC s2twp（台湾正体 + 台湾用语）转出，再按
launchers/shared/glossary.json 的 zhHantFixes 纠正固定术语。只在维护者机器上跑（要装 opencc：brew install opencc），
产物是普通文案文件、随仓库提交；门禁与玩家机器不需要 opencc。

写两处：
  launchers/shared/l10n/zh-Hant.json   {"launcher": {id: 文字}, "text": {简中原句: 文字}}
      launcher = 共享体验表 launcher.items（两端界面文案，按 id）
      text     = 共享体验表其余双语句子 + 作业层对照表 Localizable.json 的原句（两端翻作业层文字时按原句查）
  launchers/macos/frontend/l10n/zh-Hant.json   Mac 前端自带文案（同 zh.json 的键）
  shell/Sources/ShellUI/Resources/Localizable.xcstrings   iOS 游戏库界面：缺 zh-Hant 的条目
已有的译文不覆盖（人工改过的保留），只补缺的键；--all 全部重转。

用法：python3 tools/l10n_hant.py [--all]
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHARED = ROOT / "launchers/shared"
GLOSSARY = json.loads((SHARED / "glossary.json").read_text(encoding="utf-8"))
SEP = "⁣⸻⁣"   # 批量转换时的分隔行（不会出现在文案里）


def convert(texts):
    """一次调 opencc 转一批：每条之间夹分隔行，转完按分隔行切回"""
    if not texts:
        return []
    joined = f"\n{SEP}\n".join(t.replace("\r", "") for t in texts)
    out = subprocess.run(["opencc", "-c", "s2twp.json"], input=joined, capture_output=True, text=True, check=True).stdout
    parts = out.rstrip("\n").split(f"\n{SEP}\n")
    if len(parts) != len(texts):
        raise SystemExit(f"opencc 切回条数不对：{len(parts)} ≠ {len(texts)}")
    fixed = []
    for p in parts:
        for wrong, right in GLOSSARY["zhHantFixes"].items():
            p = p.replace(wrong, right)
        fixed.append(p)
    return fixed


def shared_sources(spec):
    """共享体验表里 launcher.items 以外的双语句子（简中原句）"""
    out = []

    def walk(o, top):
        if isinstance(o, dict):
            if isinstance(o.get("zh-Hans"), str) and isinstance(o.get("en"), str):
                out.append(o["zh-Hans"])
            for k, v in o.items():
                if not (top and k == "launcher"):
                    walk(v, False)
        elif isinstance(o, list):
            for v in o:
                walk(v, False)
    walk(spec, True)
    return out


def fill(have, wanted, overwrite):
    """wanted: {键: 简中}；只转缺的（或 --all 全转），返回合并后的 {键: 繁中}"""
    todo = [k for k in wanted if overwrite or k not in have]
    result = dict(have)
    for k, v in zip(todo, convert([wanted[k] for k in todo])):
        result[k] = v
    return {k: result[k] for k in wanted if k in result}   # 原表删掉的键跟着删



def write_xcstrings(path, doc):
    """同 Xcode 的写法：每条的各语言按字母排、两格缩进、结尾不换行（11-14：不然整份 diff 被打乱）"""
    for e in doc["strings"].values():
        if "localizations" in e:
            e["localizations"] = dict(sorted(e["localizations"].items()))
    path.write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")

def main(argv):
    overwrite = "--all" in argv
    spec = json.loads((SHARED / "experience.v1.json").read_text(encoding="utf-8"))
    table = json.loads((ROOT / "launchers/macos/adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json").read_text(encoding="utf-8"))
    out_path = SHARED / "l10n" / "zh-Hant.json"
    old = json.loads(out_path.read_text(encoding="utf-8")) if out_path.exists() else {}
    launcher = {i["id"]: i["zh-Hans"] for i in spec["launcher"]["items"]}
    text = {s: s for s in shared_sources(spec)}
    text.update({e["source"]: e["source"] for e in table})
    doc = {"_note": "繁体中文（台湾用语）：tools/l10n_hant.py 由简中经 OpenCC s2twp 转出、按 glossary.json 纠正；人工改过的条目重跑不覆盖。",
           "language": "zh-Hant",
           "launcher": fill(old.get("launcher", {}), launcher, overwrite),
           "text": fill(old.get("text", {}), text, overwrite)}
    out_path.parent.mkdir(exist_ok=True)
    out_path.write_text(json.dumps(doc, ensure_ascii=False, indent=1, sort_keys=False) + "\n", encoding="utf-8")

    front = ROOT / "launchers/macos/frontend/l10n"
    zh = json.loads((front / "zh.json").read_text(encoding="utf-8"))
    fpath = front / "zh-Hant.json"
    fold = json.loads(fpath.read_text(encoding="utf-8")) if fpath.exists() else {}
    keys = {k: v for k, v in zh.items() if k != "_language" and isinstance(v, str)}
    fdoc = {"_language": {"name": "繁體中文", "order": 2, "locales": ["zh-hant", "zh-tw", "zh-hk", "zh-mo"]}}
    fdoc.update(fill({k: v for k, v in fold.items() if k != "_language"}, keys, overwrite))
    fpath.write_text(json.dumps(fdoc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    # iOS 游戏库界面（shell/Sources/ShellUI/Resources/Localizable.xcstrings）：缺 zh-Hant 的条目由 zh-Hans 转出（11-14）
    xc_path = ROOT / "shell/Sources/ShellUI/Resources/Localizable.xcstrings"
    xc = json.loads(xc_path.read_text(encoding="utf-8"))
    todo = [(k, e["localizations"]["zh-Hans"]["stringUnit"]["value"]) for k, e in xc["strings"].items()
            if "zh-Hans" in e.get("localizations", {}) and (overwrite or "zh-Hant" not in e["localizations"])]
    for (k, _), v in zip(todo, convert([t for _, t in todo])):
        xc["strings"][k]["localizations"]["zh-Hant"] = {"stringUnit": {"state": "translated", "value": v}}
    write_xcstrings(xc_path, xc)
    print(f"zh-Hant：共享界面 {len(doc['launcher'])} 条、作业层与共享句 {len(doc['text'])} 条、Mac 前端 {len(fdoc) - 1} 条、iOS 游戏库界面补 {len(todo)} 条")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
