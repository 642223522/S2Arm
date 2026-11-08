#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""扫描 App/*.cs 中所有 T("...") 调用，检查 id 是否存在于 experience.v1.json launcher.items。缺键 → 非零退出。"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]  # 仓库根
APP_DIR = Path(__file__).resolve().parents[1] / "App"
EXPERIENCE = ROOT / "launchers" / "shared" / "experience.v1.json"


def main() -> int:
    with open(EXPERIENCE, encoding="utf-8") as f:
        data = json.load(f)
    items = data.get("launcher", {}).get("items", [])
    known = {it["id"] for it in items if it.get("id")}

    # 扫描所有 T("...") 调用（单双引号均考虑，C# 只用双引号）
    pattern = re.compile(r'\bT\("([^"]+)"\)')
    missing: dict[str, list[str]] = {}  # id → 出现的文件列表

    for cs_file in sorted(APP_DIR.glob("*.cs")):
        text = cs_file.read_text(encoding="utf-8")
        for m in pattern.finditer(text):
            key = m.group(1)
            # 跳过动态拼接键（包含 +、{ 等的不做静态分析）
            if any(c in key for c in ("+", "{", "}")):
                continue
            # 跳过在代码里已知是动态前缀的模式（如 "errors." + code）
            if key not in known:
                missing.setdefault(key, []).append(cs_file.name)

    if missing:
        print(f"MISSING TEXT KEYS ({len(missing)}):", file=sys.stderr)
        for key, files in sorted(missing.items()):
            print(f"  [{key}] in {', '.join(sorted(set(files)))}", file=sys.stderr)
        return 1

    print(f"text key check: {len(known)} keys known, all T() calls resolved")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
