#!/usr/bin/env python3
"""iPhone App 随包的新功能介绍（0.6.0 起，11-19 维护者定：iPhone 只放两页，和电脑共用 docs/site/feature.json 与图）。
用法：python3 pack/feature_bundle.py <docs/site 目录> <App 包里的输出目录>
只取标了 ios 的页（页上的 platforms，没写就看文件顶层的 platforms），文字中英两份都要有、图要在；
输出目录写 feature.json（{id, badge, pages:[{image:{zh-Hans,en}, kicker, title, what, how, where, labels?}]}，图路径相对输出目录）和用到的图。
一页都没有就不写（App 里不弹）。只读 docs/site，不碰别处；电脑端弹不弹、版本门槛仍在 pack/jobs/updater.py。"""
import json
import shutil
import sys
from pathlib import Path

TEXTS = ("kicker", "title", "what", "how", "where")


def bilingual(value):
    if not isinstance(value, dict):
        return None
    zh, en = value.get("zh-Hans"), value.get("en")
    return {"zh-Hans": zh.strip(), "en": en.strip()} if isinstance(zh, str) and zh.strip() and isinstance(en, str) and en.strip() else None


def bundle(site, out):
    site, out = Path(site), Path(out)
    try:
        data = json.loads((site / "feature.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return 0
    if not isinstance(data, dict) or data.get("schema") != 1 or not isinstance(data.get("id"), str):
        return 0
    top = data.get("platforms") if isinstance(data.get("platforms"), list) else []
    pages, copies = [], {}
    for row in data.get("pages") or []:
        if not isinstance(row, dict) or "ios" not in (row.get("platforms") if isinstance(row.get("platforms"), list) else top):
            continue
        texts = {k: bilingual(row.get(k)) for k in TEXTS}
        raw = row.get("image") if isinstance(row.get("image"), dict) else {"zh-Hans": row.get("image")}
        image, mine = {}, {}
        for lang in ("zh-Hans", "en"):
            rel = raw.get(lang) or raw.get("zh-Hans")
            src = (site / rel).resolve() if isinstance(rel, str) else None
            if src and site.resolve() in src.parents and src.is_file():
                image[lang] = src.name; mine[src.name] = src
        if None in texts.values() or "zh-Hans" not in image:
            continue
        copies.update(mine)   # 只拷留下的页用到的图
        page = dict(texts, image={"zh-Hans": image["zh-Hans"], "en": image.get("en", image["zh-Hans"])})
        labels = {k: v for k, v in ((k, bilingual(v)) for k, v in (row.get("labels") or {}).items() if k in ("what", "how", "where")) if v} \
            if isinstance(row.get("labels"), dict) else {}
        if labels:
            page["labels"] = labels
        pages.append(page)
    if not pages:
        return 0
    out.mkdir(parents=True, exist_ok=True)
    for name, src in copies.items():
        shutil.copyfile(src, out / name)
    badge = bilingual(data.get("badge")) or {"zh-Hans": "新功能", "en": "New"}  # 非玩家句
    (out / "feature.json").write_text(json.dumps({"id": data["id"], "badge": badge, "pages": pages}, ensure_ascii=False, indent=1), encoding="utf-8")
    return len(pages)


if __name__ == "__main__":
    n = bundle(sys.argv[1], sys.argv[2])
    print(f"新功能介绍（iPhone）：{n} 页" if n else "新功能介绍（iPhone）：这一期没有给 iPhone 的页，不带")  # 非玩家句
