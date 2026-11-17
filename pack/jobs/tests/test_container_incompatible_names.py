#!/usr/bin/env python3
"""多款容器地址空间类型不一致时点名是哪几款（#1132：原先只说「先从 iPhone 删掉不兼容的那款」，玩家不知道是哪款）。
   输入是 pack/ship_ext.py container 的红行原文；期望句子按名字手写。"""
import unittest

import jobcase  # noqa: F401  同目录用例的导入路径（pack/jobs）由它设好
import ipa

A, B, C = "0100AAAA00000000", "0100BBBB00000000", "0100CCCC00000000"
NAMES = {A: "甲游戏", B: "乙游戏", C: "丙游戏"}
RED = "【红】各款 NPDM 地址空间类型不一致，装不进同一个窗口：{}\n"


class ContainerIncompatibleNames(unittest.TestCase):

    def test_names_the_phone_games_of_the_other_kind(self):
        text = RED.format(f"{A} 类型 3、{B} 类型 1、{C} 类型 1")
        self.assertEqual(ipa.incompatible_message(text, A.lower(), NAMES),
                         "「甲游戏」和手机上的「乙游戏」「丙游戏」地址空间类型不同，放不进同一个 App。要装这款，先从 iPhone 删掉「乙游戏」「丙游戏」再装。")

    def test_same_kind_phone_games_are_not_named(self):
        text = RED.format(f"{A} 类型 1、{B} 类型 3、{C} 类型 1")
        self.assertEqual(ipa.incompatible_message(text, A, NAMES),
                         "「甲游戏」和手机上的「乙游戏」地址空间类型不同，放不进同一个 App。要装这款，先从 iPhone 删掉「乙游戏」再装。")

    def test_unknown_name_falls_back_to_title_id(self):
        text = RED.format(f"{A} 类型 3、{B} 类型 1")
        self.assertIn(f"「{B}」", ipa.incompatible_message(text, A, {A: "甲游戏"}))

    def test_without_new_game_lists_groups(self):
        text = RED.format(f"{A} 类型 3、{B} 类型 1")
        self.assertEqual(ipa.incompatible_message(text, None, NAMES),
                         "这几款游戏地址空间类型不同，放不进同一个 App：「甲游戏」 / 「乙游戏」；只能留其中一组。")

    def test_unparsable_log_keeps_old_sentence(self):
        self.assertEqual(ipa.incompatible_message("地址空间类型不一致", A, NAMES),
                         "这款和手机上已有的游戏地址空间类型不同，放不进同一个 App。")


if __name__ == "__main__":
    unittest.main()
