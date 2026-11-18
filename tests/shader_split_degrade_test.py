"""直连抽取降级表（translator/shader_split.py write_degrade）单测；shell 入口 shader_split_degrade_test.sh。
#1122：被丢的 Unity 程序块原先不进降级表、诊断里看不到；每类只写「首个」。期望按五列约定手写，再用出包收尾的同一份解析（pack/jobs/build.py degrade_rows）读回。"""
import os
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILE = tempfile.mkdtemp(prefix="s2a-split-degrade-")   # shader_split 导入时要一份游戏档（目录里放 game.tsv）：借 reuse 夹具的那份
shutil.copyfile(ROOT / "tests/fixtures/shader_split_reuse/shader_split_reuse_profile.tsv", os.path.join(PROFILE, "game.tsv"))
os.environ["DM_GAME"] = PROFILE
sys.path.insert(0, str(ROOT / "translator"))
sys.path.insert(0, str(ROOT / "pack/jobs"))
import shader_split  # noqa: E402
import build  # noqa: E402

bad = 0


def check(ok, what):
    global bad
    if not ok:
        bad += 1
        print("✗ " + what)


with tempfile.TemporaryDirectory() as d:
    p = os.path.join(d, "degrade.tsv")
    # ① 三类各几条、上限 2：文件 2 条（逐条）、程序块 3 条（2 条逐条 + 1 条「另有」）、同键 0 条；说明里的制表符 / 换行压成空格
    shader_split.write_degrade(p, ["Data/a.unity3d: ValueError: x", "Data/b.unity3d: [RED] y"],
                               ["Data/c.unity3d:sharedassets3.assets@1f#nvn.0: empty\tblock", "w2: why2\nmore", "w3: why3"], [], cap=2)
    text = open(p, encoding="utf-8").read()
    want = ("extract\tsplit:file_skipped\t1\t\t直连抽取跳过读不了的文件（里面的着色器运行时首遇现编）：Data/a.unity3d: ValueError: x\n"
            "extract\tsplit:file_skipped\t1\t\t直连抽取跳过读不了的文件（里面的着色器运行时首遇现编）：Data/b.unity3d: [RED] y\n"
            "extract\tsplit:block_skipped\t1\t\t直连抽取丢了 Unity 程序块（这支着色器不进映射表、运行时首遇现编）：Data/c.unity3d:sharedassets3.assets@1f#nvn.0: empty block\n"
            "extract\tsplit:block_skipped\t1\t\t直连抽取丢了 Unity 程序块（这支着色器不进映射表、运行时首遇现编）：w2: why2 more\n"
            "extract\tsplit:block_skipped\t1\t\t直连抽取丢了 Unity 程序块（这支着色器不进映射表、运行时首遇现编）：另有 1 条未逐列（见 split.log）\n")
    check(text == want, "① 降级表逐字不符：\n" + text)
    rows, badl = build.degrade_rows(text)
    check(badl == [], f"① 出包收尾解析有格式不对的行 {badl}")
    got = {}
    for r in rows:
        got[r["kind"]] = got.get(r["kind"], 0) + r["count"]
    check(got == {"split:file_skipped": 2, "split:block_skipped": 3}, f"① 各类处数合计 {got}（应 文件 2、程序块 3 = 实际条数）")
    check(all(r["hint"] == "" for r in rows), "① 玩家提示应留空（不上完成卡）")
    # ② 没有降级：空文件（调用方按有无行判，stage_extract.sh 无行就删旧表）
    shader_split.write_degrade(p, [], [], [])
    check(open(p, encoding="utf-8").read() == "", "② 没有降级应写空文件")
# ③ 收尾行（skip_summary）：读不了、整份没抽的文件计红——个数 + 前 3 个；丢程序块 / 同键照旧黄。原先这三类并成一行黄，
#    RomFS 只有镜像时 19012 个文件这样跳过、没有一行红。期望手写
red = shader_split.skip_summary(["a: OSError: x", "b: OSError: y", "c: OSError: z", "d: OSError: w"], [], [])
check(red == ["【红】直连抽取：4 个文件读不了、整份没抽（前 3 个：a: OSError: x；b: OSError: y；c: OSError: z），其余照抽；这些文件里的着色器运行时首遇现编，逐条见上方 [WARN]"],
      f"③ 4 个读不了的文件应一行红（4 个、举前 3 个）：{red}")
both = shader_split.skip_summary(["a: [RED] bad\nnext"], [("w", "why")], ["k"])
check(len(both) == 2 and both[0].startswith("【红】直连抽取：1 个文件读不了") and "a: [RED] bad next" in both[0]
      and both[1] == "【黄】直连抽取：丢了程序块 1 个、同键不同内容 1 处（留先到的），其余照抽；逐条见上方 [WARN] / [RED]",
      f"③ 读不了 1 个 + 程序块 1 + 同键 1：一行红（说明压成一行）+ 一行黄：{both}")
check(shader_split.skip_summary([], [], []) == [], "③ 没有降级不打收尾行")
check(shader_split.skip_summary([], [("w", "why")], []) == ["【黄】直连抽取：丢了程序块 1 个、同键不同内容 0 处（留先到的），其余照抽；逐条见上方 [WARN] / [RED]"],
      "③ 只丢程序块：只一行黄、没有红")
shutil.rmtree(PROFILE, ignore_errors=True)
print(("✗ shader_split_degrade：有不符合项" if bad else "✓ shader_split_degrade：程序块丢弃进降级表 / 逐条带名 / 上限并行 / 处数合计 / 收尾解析 / 读不了的文件计红 → 通过"))
sys.exit(1 if bad else 0)
