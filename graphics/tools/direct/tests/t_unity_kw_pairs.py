#!/usr/bin/env python3
# Unity 着色器按 Pass + 关键字配对（translator/shader_split.py unity_kw_pairs / unity_pass_index / var_pairs）。Unity 2019.3 之前（Ori and the Will of the Wisps，2018.4）
#   每个子程序只存一个阶段，同一 Pass 的顶点 / 片元子程序分开编号，原先只配同条目 vs + ps → 0 对（该款配对表 34 对，序章用到的 51 对一对不在）。期望按规则手写，不跑被测实现推：
#   ① 同一（平台, SubShader, Pass, 档位）内关键字集合相等的顶点 / 片元成对：{A}↔{A}、{A,B}↔{A,B}，不交叉配 {A}↔{A,B}
#   ② 顶点 {A,C} 没有相等的片元：取差最少的 {A}（差 1），不取 {A,B}（差 2）；差一样多的全取
#   ③ 不同 Pass / 不同档位 / 不同平台不交叉；只有顶点没有片元的组不配
#   ④ unity_pass_index：m_ParsedForm 的 SubShader / Pass / 阶段 / 档位按条目号登记
#   ⑤ var_pairs：同条目 vs + ps 照旧成对，并入 UNITY_PAIRS 后清空（下一个文件不带上一个文件的对）
#   反证：去掉 unity_shaders 里 UNITY_PAIRS.update 那行 → Ori 2 抽取配对表回到 34 对（11-19 实测：改后 26418 对、序章 51/51、众包种子 2155 对里覆盖 2152，改前 0）
import os, sys, tempfile, unittest
from pathlib import Path
TOOLS = Path(__file__).resolve().parents[4] / 'translator'
SS = None
A, B, C = 'A', 'B', 'C'

class UnityKwPairs(unittest.TestCase):
    def test_equal(self):
        g = ('19', 0, 0, 0)
        got = SS.unity_kw_pairs([(g, 'vs', frozenset({A}), 'v1'), (g, 'vs', frozenset({A, B}), 'v2'), (g, 'ps', frozenset({A}), 'p1'), (g, 'ps', frozenset({A, B}), 'p2')])
        self.assertEqual(got, {('v1', 'p1'), ('v2', 'p2')})
    def test_nearest(self):
        g = ('19', 0, 0, 0)
        got = SS.unity_kw_pairs([(g, 'vs', frozenset({A, C}), 'v'), (g, 'ps', frozenset({A}), 'p1'), (g, 'ps', frozenset({A, B}), 'p2')])
        self.assertEqual(got, {('v', 'p1')})
        got = SS.unity_kw_pairs([(g, 'vs', frozenset({C}), 'v'), (g, 'ps', frozenset({A}), 'p1'), (g, 'ps', frozenset({B}), 'p2')])
        self.assertEqual(got, {('v', 'p1'), ('v', 'p2')})
    def test_no_cross(self):
        got = SS.unity_kw_pairs([(('19', 0, 0, 0), 'vs', frozenset(), 'v0'), (('19', 0, 1, 0), 'ps', frozenset(), 'p1'), (('19', 0, 0, 1), 'ps', frozenset(), 'pt'),
                                 (('20', 0, 0, 0), 'ps', frozenset(), 'pp'), (('19', 1, 0, 0), 'vs', frozenset(), 'lonely')])
        self.assertEqual(got, set())
    def test_pass_index(self):
        o = {'m_ParsedForm': {'m_SubShaders': [{'m_Passes': [{'progVertex': {'m_SubPrograms': [{'m_BlobIndex': 3, 'm_ShaderHardwareTier': 1}]}, 'progFragment': {'m_SubPrograms': [{'m_BlobIndex': 7}]}}]},
                                                {'m_Passes': [{}, {'progVertex': {'m_SubPrograms': [{'m_BlobIndex': 3}]}}]}]}}
        m = SS.unity_pass_index(o)
        self.assertEqual(sorted(m[3]), [(0, 0, 'vs', 1), (1, 1, 'vs', 0)]); self.assertEqual(m[7], [(0, 0, 'ps', 0)])
    def test_var_pairs_merge(self):
        SS.UNITY_PAIRS.clear(); SS.UNITY_PAIRS.add(('uv', 'up'))
        c1, c2 = bytes(0x880), bytes([1]) * 0x880   # Switch 1 控制段长度（+0x20 为 0：取 0x880）
        found = [('x#var19.1', 'vs', c1, b'd1'), ('x#var19.1', 'ps', c2, b'd2')]
        got = SS.var_pairs(found)
        self.assertEqual(got, {(SS.skey(c1, b'd1'), SS.skey(c2, b'd2')), ('uv', 'up')})
        self.assertEqual(SS.var_pairs([]), set())   # 用完清空

def main():
    global SS
    with tempfile.TemporaryDirectory(prefix='unity-kw-') as tmp:
        (Path(tmp) / 'game.tsv').write_text('shader_groups\tsynthetic=synthetic\nshader_note\tsynthetic\n')
        previous = os.environ.get('DM_GAME'); os.environ['DM_GAME'] = tmp
        try:
            sys.path.insert(0, str(TOOLS)); import shader_split
            SS = shader_split; SS.COMMON = {}
            result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(UnityKwPairs))
        finally:
            if previous is None: os.environ.pop('DM_GAME', None)
            else: os.environ['DM_GAME'] = previous
    print(f'Unity 按 Pass + 关键字配对：{result.testsRun} 项，失败 {len(result.failures)}，错误 {len(result.errors)}')
    return 0 if result.wasSuccessful() else 1

if __name__ == '__main__':
    sys.exit(main())
