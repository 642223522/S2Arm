"""两端共用的三张表只在共享体验表一处（11-19 结构 9：清单动作表、建议更新原因表、确认码表原先 Mac / Windows 各写一份，已有三处不一致——
Mac 确认码表没有 cert_revoke_confirm，「仍然继续」点不了；Windows 原因表没有 libGen；两端都没有 shaderMiss）。
唯一来源 launchers/shared/experience.v1.json：确认码 = errors 各码的 accept 字段；原因 = update_reasons；清单动作 = install_landing（另见 test_landing_contract）。
期望按后端源码手写核对（静态扫描，不跑被测实现）：
  ① pack/jobs/host_update.py 里每个 why.append("<原因>") 都在 update_reasons 里，且对的文案键在 launcher.items 里；
  ② errors 里每个带 accept 的码：后端源码里有这个码（抛出或推送工具回的 S2A_PUSH_CODE），也读这个 accept 参数；
  ③ 后端读的每个 c.r.get("accept…")（玩家确认后续跑的参数）都有一个码登记了它（新加确认码忘了登记 → 红）。
负对照（手跑核过）：删掉 cert_revoke_confirm 的 accept → ③ 红；update_reasons 删掉 shaderMiss → ① 红。"""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
JOBS = ROOT / "pack/jobs"
EXP = json.loads((ROOT / "launchers/shared/experience.v1.json").read_text(encoding="utf-8"))
SRC = "\n".join(p.read_text(encoding="utf-8") for p in sorted(JOBS.glob("*.py")))
# 后端已退役、前端仍完整处理的确认码（登记照留，前端行为不变）：0.6.0 通用壳起装机不再挤掉别的电脑装的游戏，作业层不再抛 container_would_drop；
#   两端 acceptDropped 管线待单独清掉（清掉时从这里和共享表里一起删）。只豁免「后端源码里有这个码」那一条
RETIRED = {"container_would_drop"}


class SharedTables(unittest.TestCase):
    def test_update_reasons_cover_backend(self):
        sent = set(re.findall(r'why\.append\("([A-Za-z]+)"\)', (JOBS / "host_update.py").read_text(encoding="utf-8")))
        self.assertTrue(sent, "host_update.py 里一个原因都没扫到（写法变了，本测试要跟着改）")
        table = {k: v for k, v in EXP["update_reasons"].items() if k != "note"}
        self.assertEqual(sorted(sent - set(table)), [], "后端会发、共享表 update_reasons 没登记的原因")
        keys = {i["id"] for i in EXP["launcher"]["items"]}
        self.assertEqual(sorted(v for v in table.values() if v not in keys), [], "update_reasons 指向的文案键在 launcher.items 里不存在")

    def test_confirm_codes_are_real(self):
        acc = {i["code"]: i["accept"] for i in EXP["errors"]["items"] if i.get("accept")}
        self.assertTrue(acc)
        for code, flag in acc.items():
            with self.subTest(code):
                if code in RETIRED:
                    continue
                self.assertTrue(re.search(rf'code="{code}"|S2A_PUSH_CODE \(?[^"\n]*{code}', SRC), f"后端源码里没有抛 {code}")
                self.assertIn(f'"{flag}"', SRC, f"后端源码不读 {flag}")

    def test_backend_accept_flags_registered(self):
        read = set(re.findall(r'c\.r\.get\("(accept[A-Z][A-Za-z]+)"\)', SRC))
        self.assertTrue(read)
        registered = {i["accept"] for i in EXP["errors"]["items"] if i.get("accept")}
        self.assertEqual(sorted(read - registered), [], "后端读的确认参数，共享表 errors 里没有码登记它")


if __name__ == "__main__":
    unittest.main()
