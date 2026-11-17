# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""补丁打入结果（pack/jobs/patches.py outcome / record，11-14）：读编译器自己的记录（cpatch.tsv / cpatch_plan.log / cpatch_excluded.tsv）
整理出「打上 / 没打上 + 原因」。期望按下面手写的记录行逐条推出，不跑编译器"""
import json
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import jobcase  # noqa: F401
import layout
import patches

HEAD = "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅\t模式\n"


class OutcomeTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())

    def write(self, rows, log, excluded=""):
        (self.root / "cpatch.tsv").write_text(HEAD + "".join("\t".join(r) + "\n" for r in rows))
        (self.root / "cpatch_plan.log").write_text(log)
        (self.root / "cpatch_excluded.tsv").write_text(excluded)

    def test_applied_and_failed_with_reasons(self):
        self.write(
            [("wsauto:aa:w", "main", "1", "widescreen", "满屏 宽", "", "", "", "1"), ("wsauto:aa:n", "main", "2", "widescreen", "满屏 窄", "", "", "", "1"),
             ("fps:bb", "main", "3", "60fps", "60 FPS", "", "", "", "1"), ("cheat:cc:1", "main", "-", "cheat", "无限血", "", "", "", "0")],
            "收\tfps:bb\tmain\t60 FPS\t位 3\n"
            "收\tgfx:gap\tmain\t分辨率提升\t位 4\n"                                    # 先收后被改写器剔掉（下面 excluded）：名字从这一行取
            "不收\tgfx:old\tmain\t旧版画质\t版本不对：补丁是 1111，这份是 2222\n"      # 别的版本：不算失败
            "不收\tfps:dup\tmain\t30 FPS\t本款已有我方帧率表（fps.tsv），社区帧率类不收\n"   # 有意不收：不算失败
            "不收\tgfx:bad\tmain\t阴影\t数据写入 main+0x10 原值不符\n"
            "不收\tfps:cf\tmain\t动画修正\t与 fps:bb 改同一处 main+0x20\n"
            "移植不了\twidescreen:x1\tmain\t21:9\t自 AAAA → BBBB：画幅值找不到\n"      # 已有满屏打上：移植不了的不算没打上
            "不收\tcheat:dd:2\tmain\t秒杀\t改到我方改写点 main+0x30（宽屏点）\n",
            "gfx:gap\t改写器缺口：main+0x40 要翻译\n")
        r = patches.outcome(self.root)
        self.assertEqual([(a["id"], a["cat"], a["name"]) for a in r["applied"]],
                         [("wsauto:aa", "widescreen", "满屏 宽"), ("fps:bb", "fps", "60 FPS")], "自适应一族宽 / 窄算一份；金手指不逐条列（下面数条数）")
        self.assertEqual(sorted((f["id"], f["cat"], f["name"], f["why"]) for f in r["failed"]), sorted([
            ("gfx:bad", "gfx", "阴影", "result.why.mismatch"),
            ("fps:cf", "fps", "动画修正", "result.why.conflict"),
            ("cheat:dd:2", "cheat", "秒杀", "result.why.translate"),
            ("gfx:gap", "gfx", "分辨率提升", "result.why.translate")]))

    def test_cheat_count_from_shipped_source(self):
        # 随包原文两份：一份 2 条（{主代码} 不算）、一份 1 条 → 3；只改内存的条目不在补丁表里，也要算进去
        self.write([("cheat:cc:1", "main", "-", "cheat", "无限血", "", "", "", "0")], "")
        (self.root / "cheat-src.A.txt").write_text("[游戏 1.0]\n{主代码}\n04000000 0 0\n[无限血]\n04000000 1 1\n[秒杀]\n04000000 2 2\n")
        (self.root / "cheat-src.B.txt").write_text("[金钱]\n04000000 3 3\n")
        r = patches.outcome(self.root)
        self.assertEqual((r["cheats"], r["applied"]), (3, []), "A：标题行没有代码不算、{主代码} 不算 → 无限血、秒杀 2 条；B：金钱 1 条 → 3")

    def test_port_failure_counts_when_no_widescreen_applied(self):
        self.write([], "移植不了\twidescreen:x1\tmain\t21:9\t自 AAAA → BBBB：画幅值找不到\n")
        self.assertEqual([(f["id"], f["why"]) for f in patches.outcome(self.root)["failed"]], [("widescreen:x1", "result.why.port")])

    def test_mod_applied_and_wrong_version_listed(self):
        # 玩家导入的 mod 代码补丁（11-15）：打上的列在 mod 一类；构建号对不上的（pack/cpatch.py mod_miss）列「没打上：Mod 是别的版本的」——社区补丁版本不对照旧不列
        self.write([("mod:aa", "main", "1", "mod", "60 FPS", "", "Smooth/m.pchtxt", "", "0")],
                   "收\tmod:aa\tmain\t60 FPS\t位 1\n"
                   "不收\tmod:bb\t-\tOld/x.pchtxt\tmod 构建号对不上：mod 是 1111，这份游戏的主程序是 2222\n"
                   "不收\tgfx:old\tmain\t旧版画质\t版本不对：补丁是 1111，这份是 2222\n")
        r = patches.outcome(self.root)
        self.assertEqual([(a["id"], a["cat"]) for a in r["applied"]], [("mod:aa", "mod")])
        self.assertEqual([(f["id"], f["cat"], f["name"], f["why"]) for f in r["failed"]], [("mod:bb", "mod", "Old/x.pchtxt", "result.why.version")])

    def test_cheat_without_build_id_listed_per_file(self):
        # #1321：没写构建号的金手指文件（pack/cpatch.py scan_cheats「不收 cheat:<文件名> … 没写构建号」）→ 完成页逐份列「没打上：金手指文件没写构建号」，
        #   两份就两条；库里别的版本（版本不对）照旧不列。期望手写
        self.write([], "不收\tcheat:a.txt\tmain\ta.txt\t没写构建号：文件名不是 16 位构建号、首行也没有 BID=，核不了版本\n"
                       "不收\tcheat:b.txt\tmain\tb.txt\t没写构建号：文件名不是 16 位构建号、首行也没有 BID=，核不了版本\n"
                       "不收\tcheat\tmain\t1111222233334444.txt\t版本不对：金手指是 1111222233334444，这份游戏的主程序是 AABBCCDD00112233\n")
        self.assertEqual([(f["id"], f["cat"], f["name"], f["why"]) for f in patches.outcome(self.root)["failed"]],
                         [("cheat:a.txt", "cheat", "a.txt", "result.why.nobid"), ("cheat:b.txt", "cheat", "b.txt", "result.why.nobid")])

    def test_fpslocker_unsupported_listed(self):
        # 11-15 #934：FPSLocker 配置里有 S2Arm 不支持的写法（pack/cpatch.py 记「不收 … FPSLocker 配置不支持」）→ 完成页列「没打上：补丁用了 S2Arm 还不支持的写法」
        self.write([], "不收\tfps:ab\tmain\tFPSLocker\tFPSLocker 配置不支持：调用 _fpsLock()：FPSLocker 自带的帮助函数，S2Arm 没有\n")
        self.assertEqual([(f["id"], f["cat"], f["why"]) for f in patches.outcome(self.root)["failed"]], [("fps:ab", "fps", "result.why.unsupported")])

    def test_no_records_is_empty(self):
        self.assertEqual(patches.outcome(self.root), dict(applied=[], failed=[], cheats=0))

    def test_record_writes_game_json_and_error(self):
        info = {}
        with patch.object(layout, "game_info", side_effect=lambda c, g: dict(info)), \
             patch.object(layout, "update_info", side_effect=lambda c, g, **f: info.update(f)):
            c = types.SimpleNamespace()
            patches.remember(c, "0100a", patches.record(c, "0100A", "ios", None, error="改写器在 main+0x10 出错"))
            self.write([("fps:bb", "main", "3", "60fps", "60 FPS", "", "", "", "1")], "")
            patches.remember(c, "0100a", patches.record(c, "0100A", "mac", self.root))
        self.assertEqual(info["sgradeResult"]["ios"]["error"], "改写器在 main+0x10 出错")
        self.assertEqual(info["sgradeResult"]["ios"]["applied"], [])
        self.assertEqual([a["id"] for a in info["sgradeResult"]["mac"]["applied"]], ["fps:bb"], "两端各记各的，后记的不盖掉前一端")
        self.assertEqual(list(patches.results(c)), ["0100A"])


class PendingTests(unittest.TestCase):
    # 「更新 iPhone」壳已是本版时要不要照样重组容器（install.sgrade_pending，11-14）：有款要补 S 级优化 → 要；
    #   这一版记号下已确认缺原件补不上的不算（不然每次更新都白重装一遍）
    def test_pending_ignores_known_missing_original(self):
        import install, rewrite_refresh
        info = {"0100A": {"ios": {"sgradeKey": "old"}}, "0100B": {"ios": {"sgradeKey": "old", "sgradeMissing": "new"}}}
        import sgrade_bf
        c = types.SimpleNamespace(); kept = {}; bf_due = set()
        with patch.object(rewrite_refresh, "rewriter_id", return_value="rid"), \
             patch.object(rewrite_refresh, "pending_ios", side_effect=lambda c, gs, rid, ignore_rewriter=False: [g for g in gs if info[g]["ios"]["sgradeKey"] != "new"]) as pend, \
             patch.object(rewrite_refresh, "ios_key", return_value="new"), patch.object(layout, "game_info", side_effect=lambda c, g: info[g]), \
             patch.object(rewrite_refresh, "kept_todo", side_effect=lambda c, g, base: kept.get(g, [])), patch.object(layout, "ios_kit", return_value=None), \
             patch.object(sgrade_bf, "due", side_effect=lambda c, g: g in bf_due):   # 缺可读瓦片版（_bf）那条判据：这里的假游戏库没有资源包，按 bf_due 给（判据本身另有单测 test_sgrade_bf）
            self.assertTrue(install.sgrade_pending(c, ["0100A", "0100B"]), "甲要补（记号 old → new）")
            self.assertFalse(install.sgrade_pending(c, ["0100B"]), "乙在 new 这一版下已确认缺原件：不因它重组")
            info["0100B"]["ios"]["sgradeMissing"] = "older"
            self.assertTrue(install.sgrade_pending(c, ["0100B"]), "记号又变了（补丁库更新 / 导入了金手指）：再试")
            info["0100B"]["ios"]["sgradeMissing"] = "new"; kept["0100B"] = ["x.nro"]
            self.assertTrue(install.sgrade_pending(c, ["0100B"]), "乙有运行时留下、还没进 iPhone 件的 NRO（#8be819）：要重组补上")
            kept.pop("0100B"); self.assertFalse(install.sgrade_pending(c, ["0100B"]), "乙回到「已确认缺原件、没有留下的 NRO」：不重组")
            bf_due.add("0100B"); self.assertTrue(install.sgrade_pending(c, ["0100B"]), "乙的直连库缺可读瓦片版（_bf）、这一代没因缺原料试过：要重组补上")
            self.assertTrue(all(k.kwargs.get("ignore_rewriter") is True for k in pend.call_args_list), "改写器指纹单独变了不因此重组容器（不让更新 App 顺带批量重改写）")


if __name__ == "__main__":
    unittest.main()
