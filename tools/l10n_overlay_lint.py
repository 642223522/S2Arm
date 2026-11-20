#!/usr/bin/env python3
"""各语言叠加文案的门禁（11-14 i18n 加新语言）：译文里的占位符必须和原文一模一样，少一个、多一个运行时就拼错句子。

查两类文件：
  launchers/shared/l10n/<语言>.json     launcher 块（按 id，对照共享体验表的 en 列）、text 块（按简中原句，对照这句的英文；没有英文对照原句）
  launchers/macos/frontend/l10n/<语言>.json（除 zh / en 两张底表）   按键对照 en.json
占位符：{0} {1} …、%@ %d %s %ld %1$@ 这类 printf 写法，按出现的多重集合比。
原表里已经没有的键只提示（别的支删文案不该打红你），占位符不一致退出 1、点名文件 / 键。

用法：l10n_overlay_lint.py [仓库根]
"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

SLOT = re.compile(r"\{\d+\}|%(?:\d+\$)?(?:l{0,2}[dus]|@|\.?\d*f)")


def slots(text):
    """占位符多重集合；printf 的位置写法 %1$@ 归一成 %@（语序不同的语言常要调换参数位置，类型和个数一样就对）"""
    return Counter(re.sub(r"%\d+\$", "%", s) for s in SLOT.findall(text or ""))


def main(argv):
    root = Path(argv[0] if argv else Path(__file__).resolve().parents[1]).resolve()
    shared = root / "launchers/shared"
    spec = json.loads((shared / "experience.v1.json").read_text(encoding="utf-8"))
    items = {i["id"]: i for i in spec["launcher"]["items"]}
    table = root / "launchers/macos/adapter/Sources/S2ArmAppleAdapter/Resources/Localizable.json"
    # 作业层句子：日 / 西 / 法等从英文翻出，占位符对照这句的英文（英文本身省掉某个占位、译文跟着省是对的）；繁中从简中原句转出，对照原句
    english = {e["source"]: e.get("en", "") for e in json.loads(table.read_text(encoding="utf-8"))} if table.exists() else {}
    sources = set(english)

    def walk(o):
        if isinstance(o, dict):
            if isinstance(o.get("zh-Hans"), str) and isinstance(o.get("en"), str):
                sources.add(o["zh-Hans"])
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(spec)

    bad, stale, checked = [], 0, 0
    for path in sorted((shared / "l10n").glob("*.json")) if (shared / "l10n").is_dir() else []:
        doc = json.loads(path.read_text(encoding="utf-8"))
        rel = path.relative_to(root)
        for key, text in (doc.get("launcher") or {}).items():
            checked += 1
            if key not in items:
                stale += 1
                continue
            if slots(text) != slots(items[key].get("en", "")):
                bad.append(f"{rel} launcher「{key}」占位符和原文不一致：{dict(slots(text))} ≠ {dict(slots(items[key].get('en', '')))}")
        for source, text in (doc.get("text") or {}).items():
            checked += 1
            if source not in sources:
                stale += 1
                continue
            ref = source if doc.get("language") == "zh-Hant" else (english.get(source) or source)   # 繁中从简中原句转出，其余从英文翻出
            if slots(text) != slots(ref):
                bad.append(f"{rel} text「{source[:40]}」占位符和原文不一致：{dict(slots(text))} ≠ {dict(slots(ref))}")
    front = root / "launchers/macos/frontend/l10n"
    if (front / "en.json").exists():
        en = json.loads((front / "en.json").read_text(encoding="utf-8"))
        for path in sorted(front.glob("*.json")):
            if path.name in ("en.json", "zh.json"):
                continue
            rel = path.relative_to(root)
            for key, text in json.loads(path.read_text(encoding="utf-8")).items():
                if key == "_language" or not isinstance(text, str):
                    continue
                checked += 1
                if key not in en:
                    stale += 1
                    continue
                if slots(text) != slots(en[key]):
                    bad.append(f"{rel}「{key}」占位符和原文不一致：{dict(slots(text))} ≠ {dict(slots(en[key]))}")
    for line in bad:
        print("🔴 " + line)
    print(f"叠加文案：查了 {checked} 条，占位符不一致 {len(bad)} 处" + (f"；{stale} 条原表已删（可重跑生成工具清掉）" if stale else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
