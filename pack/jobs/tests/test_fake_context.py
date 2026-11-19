# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""作业上下文替身工厂（jobcase.fake_context）与真上下文（core.Context）对齐：产品代码里用到的 c.<名>，凡是 Context 有的（类里的公开方法 / 属性，
加 Context 各方法里 self.<名> = 赋过的字段），替身都得有。产品代码新用一个上下文字段、工厂没跟上 → 这里先红，
而不是等哪个用例的替身缺字段、在 discover 顺序全量跑时才冒出 AttributeError（11-16 test_win_jobs 缺 env 三红）"""
import ast
import re
import tempfile
import unittest
from pathlib import Path

import jobcase

JOBS = Path(__file__).resolve().parents[1]


def context_attrs():
    tree = ast.parse((JOBS / "core.py").read_text(encoding="utf-8"))
    cls = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "Context")
    names = {n.name for n in cls.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
    for node in ast.walk(cls):
        if isinstance(node, ast.Attribute) and isinstance(node.ctx, ast.Store) and isinstance(node.value, ast.Name) and node.value.id == "self":
            names.add(node.attr)
    return {n for n in names if not n.startswith("_")}


def used_by_product():
    used = set()
    for p in JOBS.glob("*.py"):
        used |= set(re.findall(r"\bc\.([a-z_][a-z0-9_]*)\b", p.read_text(encoding="utf-8")))
    return used


class FakeContextTests(unittest.TestCase):
    def test_fake_context_covers_context(self):
        required = used_by_product() & context_attrs()
        self.assertGreater(len(required), 30, "判据射程：产品代码用到的上下文字段应有三十多个，太少说明解析坏了")
        with tempfile.TemporaryDirectory() as t:
            c = jobcase.fake_context(t)
            missing = sorted(n for n in required if not hasattr(c, n))
        self.assertEqual(missing, [], "jobcase.fake_context 要补上这些字段（产品代码在用、真上下文有）")

    def test_side_effects_are_loud_and_overridable(self):
        with tempfile.TemporaryDirectory() as t:
            c = jobcase.fake_context(t, r={"gameId": "G"})
            with self.assertRaisesRegex(AssertionError, "c.run 没配"):
                c.run(["x"])
            self.assertEqual(c.r, {"gameId": "G"}); self.assertIn("PATH", c.env())
            with c.lock("catalog"):
                pass
            c.diagnostic("x", code="k", severity="warning"); c.emit("message", "m")
            self.assertEqual((c.diagnostics[0]["code"], c.events), ("k", [("message", "m")]))


if __name__ == "__main__":
    unittest.main()
