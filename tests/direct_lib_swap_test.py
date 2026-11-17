#!/usr/bin/env python3
"""审计 P1-173：直连库换进位的三步改名（Windows / 不支持原子互换的外接盘）不丢上一份直连库。
从 graphics/tools/direct/direct_lib.sh 抽出换进位那段 Python 原样跑（把 Windows 分支的条件改成恒真，走三步改名），合成目录夹具，期望手写：
① 成功：正式目录是新库、临时目录是旧库、没有 .swapold 残留；
② 第二步失败（临时目录不在）：正式目录仍是旧库、没有 .swapold 残留，命令退非 0；
③ 停在第一步之后（正式目录在 .swapold、正式名不在）：脚本起跑那两行把它改回正式位置，清扫临时目录时不删它"""
import os, re, subprocess, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
SH = (R / "graphics/tools/direct/direct_lib.sh").read_text(encoding="utf-8")
code = re.search(r"\"\$PY\" -c '(import os, sys, ctypes.*?)' \"\$OS\" \"\$OUT\"", SH, re.S).group(1)
bad = 0
def ck(ok, msg):
    global bad
    print(("通 " if ok else "不通 ") + msg); bad += not ok

def run(a, b):
    three = code.replace('if sys.platform == "win32":', 'if True:', 1)   # 走三步改名那条路（本机 APFS 支持原子互换，平台改不了：ctypes 会去找 Windows 模块）
    assert three != code
    return subprocess.run([sys.executable, "-c", three, a, b], capture_output=True, text=True).returncode

with tempfile.TemporaryDirectory() as t:
    T = Path(t); out, stage = T / "lib", T / "lib.stage.123"
    out.mkdir(); (out / "lib.idx").write_text("old"); stage.mkdir(); (stage / "lib.idx").write_text("new")
    rc = run(str(stage), str(out))
    ck(rc == 0 and (out / "lib.idx").read_text() == "new" and (stage / "lib.idx").read_text() == "old" and not (T / "lib.swapold").exists(), "① 三步改名成功：正式是新库、临时目录是旧库、无残留")
    for p in (out, stage):
        for f in p.iterdir(): f.unlink()
        p.rmdir()
    out.mkdir(); (out / "lib.idx").write_text("old")
    rc = run(str(stage), str(out))   # 临时目录不在：第二步失败
    ck(rc != 0 and (out / "lib.idx").read_text() == "old" and not (T / "lib.swapold").exists(), "② 第二步失败：正式目录还是旧库、改回了正式名")
    # ③ 起跑恢复 + 清扫（direct_lib.sh 里那两行原样跑）
    os.rename(out, T / "lib.swapold"); (T / "lib.stage.999999").mkdir()
    lines = [l for l in SH.splitlines() if l.startswith('[ ! -e "$OUT" ] && [ -d "$OUT.swapold" ]') or l.startswith('for d in "$C"/work.stage.*')]
    script = "say() { :; }; C=" + str(T / "c") + "; OUT=" + str(out) + "\n" + "\n".join(lines)
    subprocess.run(["bash", "-c", script], check=False)
    ck(len(lines) == 2 and (out / "lib.idx").read_text() == "old" and not (T / "lib.swapold").exists() and not (T / "lib.stage.999999").exists(),
       "③ 停在第一步后：起跑改回正式位置、死进程的临时目录照清")

print(f"直连库换进位单测：{'全通' if not bad else f'{bad} 项不通'}"); sys.exit(1 if bad else 0)
