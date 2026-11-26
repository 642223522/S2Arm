"""nn::ro 多 NRO 夹具（11-03 大乱斗 SPECIAL：nro_modules.tsv 764 行，原定长模块表 256 装不下）。
自有 0BSD 模块 runtime/tests/cpatch_loader/module.nso 交出包缺省 C 改写器改写一次（main），再改写一次作 nro0；
改写产物不含模块名（<名>.fixups.tsv / .patched.bin / .gates.tsv / .sites.tsv 内容与名字无关），nro1… 按名字拷贝 nro0 的产物。
nro_modules.tsv：N 行，第 k 行 = nro<k>、SHA-256 = k 低字节 / k 高字节 + 30 个 0x5a、NRO 大小 0x10000、bss 0（单测按同一规则造哈希去装）。
--merged：再按装到手机的程序包那样（pack/ship_ext.py write_nro_tables）把各 NRO 的 fixups / gates 合成 nro_tables.tsv、删掉逐模块的这两张表——
  宿主只能从合并表读到 NRO 的布局与门（单测同一份期望；读不到时装第一个 NRO 就停在「打不开 nro0.fixups.tsv」）；nro1 另带一行门，单测核它登记上了。
用法：prepare.py <输出目录> <NRO 个数> [--merged]"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
out = Path(sys.argv[1]).resolve(); n = int(sys.argv[2]); merged = sys.argv[3:] == ["--merged"]
shutil.rmtree(out, ignore_errors=True); out.mkdir(parents=True)
fixture = root / "runtime/tests/cpatch_loader/module.nso"
if hashlib.sha256(fixture.read_bytes()).hexdigest() != "2387bf7917e2a680115c802fb10c7023052aa10aef4f8e3cc73f4bfd7799fdaf":
    raise ValueError("自有模块 NSO 的固定 SHA-256 不符")
rewriter = subprocess.check_output([sys.executable, str(root / "pack/rewriter.py"), "c-path"], text=True).strip()
for module in ("main", "nro0"):
    subprocess.run([rewriter, str(fixture), str(out), module], env=dict(os.environ, S2A_TARGET="apple"), check=True, stdout=subprocess.DEVNULL)
kinds = [p.name[len("nro0"):] for p in out.glob("nro0.*")]
for k in range(1, n):
    for kind in kinds: shutil.copyfile(out / f"nro0{kind}", out / f"nro{k}{kind}")
with open(out / "nro_modules.tsv", "w") as f:
    f.write("# 模块名\tSHA-256\tNRO 大小\tbss 大小\tromfs 相对路径\n")
    for k in range(n): f.write(f"nro{k}\t{k & 0xff:02x}{k >> 8:02x}{'5a' * 30}\t0x10000\t0x0\tdata.arc@{k:#x}:zstd\n")
if merged:
    # nro1 带一行门（返回点 +0x10010 在补丁区、原址 +0x100 在代码段），其余 NRO 的门表照旧是空的（合并表里不出 gates 段）：单测按返回点查回原址
    (out / "nro1.gates.tsv").write_text("0x10010\tsvc\t0\t0x100\n")
    sys.path.insert(0, str(root / "pack"))
    import ship_ext
    names = ship_ext.write_nro_tables(out, [f"nro{k}" for k in range(n)], out)
    if len(names) != n:
        raise ValueError(f"合并表收了 {len(names)} 个模块，期望 {n}")
    for k in range(n):
        for kind in ("fixups", "gates"): (out / f"nro{k}.{kind}.tsv").unlink()
