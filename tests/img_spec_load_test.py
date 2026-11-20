#!/usr/bin/env python3
"""pack/img.py 被作业层按文件路径加载（pack/jobs/sgrade_bf.py _img：spec_from_file_location，pack/ 不在模块搜索路径里）时，
std_files 要能找到同目录的 romfs_img（11-16：裸 import 报 ModuleNotFoundError，资源包是 game.img、要补片上读取着色器的款装机「放进手机」一步失败）。
期望手写：隔离模式（-I，不带脚本目录 / 当前目录）的子进程里照作业层的写法加载 img.py，对一个不是 RomFS 的文件调 std_files → 抛的是 romfs_img 的
RomfsError（说明模块加载到了、开始解析了），不是 ModuleNotFoundError。约 0.2 秒，不需要 dotnet"""
import os, subprocess, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
CODE = r'''
import importlib.util, sys
spec = importlib.util.spec_from_file_location("s2a_pack_img", sys.argv[1])   # 同 pack/jobs/sgrade_bf.py _img
img = importlib.util.module_from_spec(spec); spec.loader.exec_module(img)
try:
    img.std_files(sys.argv[2], 0)
    print("没报错")
except Exception as e:
    print(type(e).__name__)
'''
with tempfile.TemporaryDirectory(prefix="img spec ") as t:
    junk = Path(t) / "junk.img"; junk.write_bytes(b"\0" * 200)
    r = subprocess.run([sys.executable, "-I", "-c", CODE, str(R / "pack/img.py"), str(junk)], capture_output=True, text=True, cwd=t)
    got = r.stdout.strip() or r.stderr.strip()[-300:]
ok = got == "RomfsError"
print(("通 " if ok else "不通 ") + f"按文件路径加载 img.py 后 std_files 用得到 romfs_img（期望 RomfsError，真结果 {got}）")
sys.exit(0 if ok else 1)
