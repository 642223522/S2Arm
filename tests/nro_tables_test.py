#!/usr/bin/env python3
"""装到手机的程序包里 NRO 随行表合成一份（pack/ship_ext.py place_game / write_nro_tables，宿主 runtime/src/loader.c nrot_get 读）。

期望按约定手写（不跑被测实现推期望）：
  ① 产物根有 main + nro0..2（nro_modules.tsv 列 nro0..2）：目标目录 main 的 fixups / gates 照旧逐个拷；nro0..2 的 fixups / gates 不拷，
     合成 nro_tables.tsv：段序 nro0 fixups → nro0 gates → nro1 fixups → nro2 fixups → nro2 gates（nro1 门表空：不出段），段内容逐字节 = 原表；
     NRO 的 widen 表照旧逐个拷。
  ② 没有 nro_modules.tsv（不用 nn::ro 的款）：不出合并表，全部照旧逐个拷——与改前布局逐文件相同。
  ③ 原表里有行首是 @ 的行：报红（退出 1），不静默改写。
宿主读合并表（布局 / 门 / 模块跨度）由原生单测 runtime/tests/t_nro_many.c 的合并表档覆盖。"""
import os
import sys
import tempfile
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "pack"))
import ship_ext   # noqa: E402

fails = 0


def check(what, ok, got=""):
    global fails
    print(f"{'通' if ok else '不通'} {what}{'' if ok else f'：真结果 {got}'}")
    fails += not ok


FIX = {m: f"# BUILD_ID\t{m}\n# PATCH_OFF\t0x10000\n".encode() for m in ("main", "nro0", "nro1", "nro2")}
GATES = {"main": b"0x10\tsvc\t1\t0x4\n", "nro0": b"0x20\tsvc\t2\t0x8\n", "nro1": b"", "nro2": b"0x30\tcntpct\t0\t0xc"}   # nro2 末行不带换行


def make_root(d, with_nro=True):
    r = Path(d) / "root"; r.mkdir()
    for m in FIX:
        (r / f"{m}.fixups.tsv").write_bytes(FIX[m]); (r / f"{m}.gates.tsv").write_bytes(GATES[m]); (r / f"{m}.patched.bin").write_bytes(b"\0" * 16)
    (r / "nro2.widen.tsv").write_bytes(b"w\n")
    (r / "main.npdm").write_bytes(b"npdm")
    if with_nro:
        (r / "nro_modules.tsv").write_text("# 表头\n" + "".join(f"nro{k}\t{'ab' * 32}\t0x1000\t0x0\tnro/{k}.nro\n" for k in range(3)))
    return r


def place(r, d):
    dest = Path(d) / "out"
    with mock.patch.object(ship_ext.subprocess, "run", return_value=mock.Mock(returncode=0, stdout="", stderr="")):   # 镜像包（embed.py）不在本测范围
        ship_ext.place_game(r, dest, Path(d) / "img" / "S2AImages.dylib", [])
    return dest


with tempfile.TemporaryDirectory() as d:
    out = place(make_root(d), d)
    names = sorted(p.name for p in out.iterdir())
    check("① 目标目录 = main 两表 + nro2.widen + main.npdm + 合并表", names == ["main.fixups.tsv", "main.gates.tsv", "main.npdm", "nro2.widen.tsv", "nro_tables.tsv"], names)
    body = (out / "nro_tables.tsv").read_bytes().split(b"\n", 1)[1]
    want = (b"@fixups\tnro0\n" + FIX["nro0"] + b"@gates\tnro0\n" + GATES["nro0"] + b"@fixups\tnro1\n" + FIX["nro1"]
            + b"@fixups\tnro2\n" + FIX["nro2"] + b"@gates\tnro2\n" + GATES["nro2"] + b"\n")
    check("① 合并表段序与段内容（空门表不出段、末行补换行）", body == want, body)
    check("① main 两表逐字节照拷", (out / "main.fixups.tsv").read_bytes() == FIX["main"] and (out / "main.gates.tsv").read_bytes() == GATES["main"])

with tempfile.TemporaryDirectory() as d:
    out = place(make_root(d, with_nro=False), d)
    names = sorted(p.name for p in out.iterdir())
    want = sorted([f"{m}.{k}.tsv" for m in FIX for k in ("fixups", "gates")] + ["main.npdm", "nro2.widen.tsv"])
    check("② 没有 nro_modules.tsv：不出合并表、全部逐个拷", names == want, names)

with tempfile.TemporaryDirectory() as d:
    r = make_root(d); (r / "nro1.gates.tsv").write_bytes(b"0x40\tsvc\t0\t0x10\n@x\n")
    try:
        place(r, d); got = "没报红"
    except SystemExit as e:
        got = f"退出 {e.code}"
    check("③ 原表有行首 @ 的行：报红", got == "退出 1", got)

print("NRO 合并随行表单测全过" if not fails else f"NRO 合并随行表单测 {fails} 项不通")
sys.exit(1 if fails else 0)
