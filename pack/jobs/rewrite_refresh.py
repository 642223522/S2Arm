# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""只重跑改写阶段（维护者 11-11：改写器修了，受影响的款不重出资源包，只换改写产物，随「更新 iPhone 上的 S2Arm」组进新壳）。

为什么不靠缓存键：改写阶段的键含改写器源码指纹（pack/stage_rewrite.sh），改写器一改所有款的键都变；也不能比产物（游戏库里早些时候出的款，
产物本来就跟今天的改写器对不上，比出差别不等于受这次修复影响）。判据由改写器自己报：统计行里 x18_spdyn > 0 的模块，产物会因这次修复而变
（开发丙 11-11 实测：九款金样全 0、产物逐字节同旧；路易吉洋馆 3 两个版本各 38）。

做法（每款）：
  1. 这款记下的改写器指纹（game.json ios.rewriterId）= 本引擎的 → 跳过（改写器没变，平时更新手机不多花时间）
  2. 取原始 exefs：共用解包目录还有效就用它，否则用读取器 --exefs-only 从原件只解 exefs（几秒）；原件不在（外接盘没插）→ 这次跳过、下次再核
  3. 对 main / sdk / subsdk0–9 跑改写器，输入与出包时相同：这款 kit 里的 widen_sites.tsv、fps.tsv，同一份随包代码补丁，S2A_TARGET / 自旋闸同出包
     （11-11 核过：旧改写器按这组输入重跑，产物与完整出包逐字节相同）
  4. 任一模块 x18_spdyn > 0 → 这款受影响：该模块的改写产物（<模块>.patched.bin / .fixups.tsv / .gates.tsv / .sites.tsv / .gaps.tsv / .widen.tsv / .code_patch.tsv）
     换进 kit；资源包（game.img）、直连库不动不推
  5. 记下本引擎的改写器指纹
romfs 里藏的 NRO 模块没有原件可取（资源在 game.img 里），不在这里重跑：保持 kit 原样。"""
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import layout
from core import Failure

MODULE = re.compile(r"(main|sdk|subsdk[0-9])")
OUTPUTS = ("patched.bin", "fixups.tsv", "gates.tsv", "sites.tsv", "gaps.tsv", "widen.tsv", "code_patch.tsv")
AFFECTED = re.compile(r"'x18_spdyn':\s*(\d+)")


def rewriter_id(c):
    """本引擎改写器的身份：编译输入的内容指纹（同 stage_rewrite.sh 的 KR 口径，pack/rewriter.py source）"""
    r = subprocess.run([os.sys.executable, "-X", "utf8", c.engine / "pack/rewriter.py", "source"], cwd=c.engine, env=c.env(),
                       capture_output=True, text=True)
    if r.returncode or not r.stdout.strip():
        raise Failure("取不到改写器指纹：" + (r.stderr.strip()[-200:] or "无输出"))
    return hashlib.sha256(r.stdout.encode()).hexdigest()[:16]


def rewriter_bin(c):
    r = subprocess.run([os.sys.executable, "-X", "utf8", c.engine / "pack/rewriter.py", "c-path"], cwd=c.engine, env=c.env(),
                       capture_output=True, text=True)
    path = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
    if r.returncode or not Path(path).is_file():
        raise Failure("找不到改写器：" + (r.stderr.strip()[-200:] or "无输出"))
    return path


def original_exefs(c, game, work):
    """这款的原始 exefs 目录；取不到（原件不在 / 不是 NSP、XCI）→ None"""
    from build import extract_valid, shared_dir
    from library import selected_packages, source_path
    if extract_valid(c, game):
        return shared_dir(c, game) / "extract/exefs"
    packages = selected_packages(game)
    if any(p.get("format") for p in packages if p.get("format") not in (None, "nsp", "xci", "nsz", "xcz")):
        return None   # 解包好的文件夹 / Switch 2 NUP：没有现成的只解 exefs 路子，留给重新出包
    paths = [source_path(c, p) for p in packages if p["type"] in ("base", "update")]
    if not paths or not all(Path(p).is_file() for p in paths):
        return None
    import toolchain
    out = work / "x"
    c.run(["dotnet", toolchain.reader(c), c.keys, out, "--exefs-only", "--title-id=" + game["id"], *map(str, paths)], work / "exefs.log", c.env())
    return out / "exefs" if (out / "exefs/main").is_file() else None


def rewrite_env(c, kit, exefs, target):
    env = dict(c.env(), S2A_TARGET=target, S2A_REWRITE_SPIN=os.environ.get("S2A_REWRITE_SPIN", "1"))
    for k in ("S2A_FPS_TSV", "S2A_CPATCH_TSV", "S2A_CODE_PATCH", "S2A_CODE_BUILD"):
        env.pop(k, None)
    if (kit / "fps.tsv").is_file():
        env["S2A_FPS_TSV"] = str(kit / "fps.tsv")
    # 随包代码补丁：同 stage_rewrite.sh（S2A_PATCH_DIR/<程序号>/patch.tsv，构建号 = main 头 0x40 起 16 字节）
    pdir = env.get("S2A_PATCH_DIR")
    if pdir:
        d = (exefs / "main").read_bytes()
        bid = d[0x40:0x50].hex()
        npdm = (exefs / "main.npdm").read_bytes()
        aci = int.from_bytes(npdm[0x70:0x74], "little")
        pid = "%016X" % int.from_bytes(npdm[aci + 0x10:aci + 0x18], "little") if npdm[aci:aci + 4] == b"ACI0" else ""
        patch = Path(pdir) / pid / "patch.tsv"
        if pid and patch.is_file():
            env.update(S2A_CODE_PATCH=str(patch), S2A_CODE_BUILD=bid)
    return env


def rewrite_modules(binary, env, exefs, out, widen):
    """exefs 里宿主会装载的模块（同 stage_rewrite.sh 的名单）逐个改写到 out → 这次修复会改到的模块（统计行 x18_spdyn > 0）"""
    hit = []
    for m in sorted(p.name for p in Path(exefs).iterdir() if MODULE.fullmatch(p.name)):
        args = [binary, str(Path(exefs) / m), str(out), m] + ([str(widen)] if Path(widen).is_file() else [])
        r = subprocess.run(args, env=env, capture_output=True, text=True, timeout=600)
        if r.returncode:
            raise Failure(f"重跑改写 {m} 失败（退出码 {r.returncode}）：" + ((r.stderr.strip().splitlines() or [""])[-1])[:200])
        if max((int(x) for x in AFFECTED.findall(r.stdout)), default=0) > 0:
            hit.append(m)
    return hit


def apply_outputs(out, kit, modules):
    """命中模块的改写产物换进 kit（逐个原子替换）；新改写器不再出的那份删掉（旧的留着会被装载器当成本次的）。没命中的模块一个字节都不动"""
    for m in modules:
        for ext in OUTPUTS:
            src, dst = Path(out) / f"{m}.{ext}", Path(kit) / f"{m}.{ext}"
            if src.is_file():
                tmp = dst.with_name(dst.name + ".rw")
                shutil.copyfile(src, tmp); os.replace(tmp, dst)
            elif dst.is_file():
                dst.unlink()


def check_and_update(c, gid, kit, target, rid):
    """一款：→ 'skip'（改写器没变）| 'unavailable'（原件取不到）| 'unaffected' | 'updated'"""
    info = layout.game_info(c, gid)
    side = info.get("ios") or {}
    if side.get("rewriterId") == rid:
        return "skip"
    game = next((g for g in c.catalog()["games"] if g["id"].upper() == gid.upper()), None)
    if game is None or not (kit / "main.patched.bin").is_file():
        return "unavailable"
    with tempfile.TemporaryDirectory(dir=c.private) as tmp:
        work = Path(tmp)
        exefs = original_exefs(c, game, work)
        if exefs is None:
            return "unavailable"
        out = work / "out"; out.mkdir()
        hit = rewrite_modules(rewriter_bin(c), rewrite_env(c, kit, exefs, target), exefs, out, kit / "widen_sites.tsv")
        apply_outputs(out, kit, hit)
    layout.update_info(c, gid, ios=dict(side, rewriterId=rid))
    return "updated" if hit else "unaffected"


def refresh_ios(c, games):
    """组容器前：这几款的 iPhone 容器件按本引擎改写器核一遍（见文件头）。→ 换了改写产物的款"""
    if not games:
        return []
    try:
        rid = rewriter_id(c)
    except (Failure, OSError, subprocess.SubprocessError) as e:
        # 同 refresh_mac：取不到改写器指纹就整轮不核，不挡这次装机；各款保留原来的产物、不记指纹，下次再核
        c.emit("message", f"【黄】没取到改写器指纹，这次先不核要不要按新版更新程序：{str(e)[:200]}")
        return []
    todo = [g for g in games if (layout.game_info(c, g).get("ios") or {}).get("rewriterId") != rid]
    if not todo:
        return []
    c.emit("message", f"正在核对 {len(todo)} 款游戏的程序是否要按新版更新")
    updated = []
    for g in todo:
        try:
            if check_and_update(c, g, layout.ios_kit(c, g), "ios", rid) == "updated":
                updated.append(g)
        except (Failure, OSError, subprocess.SubprocessError) as e:
            # 核对是附带的一步：某款核不了（改写器在它上面出错、原件读不了）不挡这次装机；这款保留原来的产物、不记指纹，下次再核
            c.emit("message", f"【黄】{g} 没核成要不要按新版更新程序，先保留原来的：{str(e)[:200]}")
    if updated:
        c.emit("message", f"已更新 {len(updated)} 款游戏的程序（资源不用重推）")
    return updated


def refresh_mac(c, gid, runtime):
    """起局前：这款的 Mac 运行版本按本引擎改写器核一遍（运行版本自带 exefs/，不用回原件）；记号记在运行版本的 manifest.json（rewriterId）。
    换了的文件同步改清单里的大小与摘要（起局前按清单核文件）。核不了不挡起局 → True = 换了改写产物"""
    import json
    from core import atomic, read
    runtime = Path(runtime)
    manifest = read(runtime / "manifest.json", {})
    if not isinstance(manifest.get("files"), dict) or not (runtime / "exefs/main").is_file():
        return False
    try:
        rid = rewriter_id(c)
        if manifest.get("rewriterId") == rid:
            return False
        with tempfile.TemporaryDirectory(dir=c.private) as tmp:
            out = Path(tmp)
            hit = rewrite_modules(rewriter_bin(c), rewrite_env(c, runtime, runtime / "exefs", "apple"), runtime / "exefs", out, runtime / "widen_sites.tsv")
            if hit:
                c.emit("message", "正在按新版更新这款游戏的程序（资源不动）")
            apply_outputs(out, runtime, hit)
        files = dict(manifest["files"])
        for m in hit:
            for ext in OUTPUTS:
                name, p = f"{m}.{ext}", runtime / f"{m}.{ext}"
                if p.is_file():
                    files[name] = [p.stat().st_size, ""]   # 同 build.snapshot：只记大小（v0.2.3 起校验只核大小）
                else:
                    files.pop(name, None)
        atomic(runtime / "manifest.json", dict(manifest, files=files, rewriterId=rid))
        return bool(hit)
    except (Failure, OSError, subprocess.SubprocessError, ValueError) as e:
        c.emit("message", f"【黄】没核成要不要按新版更新这款的程序，先用原来的：{str(e)[:200]}")
        return False
