"""Mac 公共宿主与只换宿主（11-09 维护者定「升级后只换宿主」；游戏库结构双端统一后宿主多款共用，见 layout.py）。

宿主放 <库>/hosts/mac/<可执行文件摘要前 12 位>/S2ArmGame.app，每款镜像 games/<英文名>/image/mac 不含宿主；game.json 的 hostMac 记这款在用的宿主。
升级 S2Arm 后，新宿主认得旧镜像就直接换用，不用重新准备。判据两项，都对上才换：
  hostAbi    —— 宿主读每款产物的约定号，就是下面的 HOST_ABI。改了宿主读产物的方式（改写器与运行时的约定：跳板 / 虚拟寄存器槽 / 门控表，
                *.fixups / *.sites / *.gates / addr_need.tsv 等表的格式，镜像目录布局）就把它加 1；只修宿主自身的 bug 不动它。
  dmshChain  —— 直连着色器库版本 V（graphics/nvn/gfx/nvn/dmsh_chain.h 的 DMSH_CHAIN，宿主只读 shaders/direct/b-<V>/），从引擎源码机械读出。
镜像的 manifest.json 记准备时的这两项；本字段之前（v0.1.0 起的公开版）出的镜像 hostAbi 按 1，dmshChain 按目录里实有的 b-<V> 认。
试玩：换上新宿主后第一局 TRIAL_OK_SECONDS 秒内异常退出 = 新宿主不认这款，记进 game.json hostFailed、退回原来的宿主（不动任何文件）；
正常退出或玩满这么久 = 通过，hostMac 改成新宿主。60 秒同直连安全网「首帧后前台满 60 秒算成功玩过」（runtime/include/s2a_dguard.h）。
不兼容时照用原来的宿主，catalog 报 hostUpdate = "incompatible"，游戏库提示重新准备。
"""
from __future__ import annotations
import re
import shutil
from pathlib import Path

import layout
from core import Failure, contained, digest, read

HOST_ABI = 1
TRIAL_OK_SECONDS = 60
APP = "S2ArmGame.app"
EXE = APP + "/Contents/MacOS/s2arm-host"
# iPhone 容器（pack/ship_ext.py container）：s2a_catalogue.json 每款记 host_abi / chain，装机时壳变了但兼容的款原样带进新壳（ipa.assemble）。
#   本字段之前的容器条目按 1 / LEGACY_CHAIN：v0.1.0 起 graphics/nvn/gfx/nvn/dmsh_chain.h 的 DMSH_CHAIN 一直是它（git log v0.1.0.. 该文件无改动）
LEGACY_CHAIN = "0be3f28548fd"


def engine_compat(c):
    """本版引擎（新宿主）的两项判据；读不到直连库版本 → None（不换）"""
    try:
        text = (c.engine / "graphics/nvn/gfx/nvn/dmsh_chain.h").read_text()
    except OSError:
        return None
    m = re.search(r'^#define DMSH_CHAIN "([0-9a-f]+)"', text, re.M)
    return dict(hostAbi=HOST_ABI, dmshChain=m.group(1)) if m else None


def compatible(c, entry):
    """iPhone 容器里的一款能不能原样放进本版宿主"""
    want = engine_compat(c)
    return bool(want) and dict(hostAbi=entry.get("host_abi", 1), dmshChain=entry.get("chain", LEGACY_CHAIN)) == want


def image_compat(image, manifest):
    chain = manifest.get("dmshChain")
    if not chain:
        libs = [p.name[2:] for p in (Path(image) / "shaders/direct").glob("b-*") if p.is_dir()]
        chain = libs[0] if len(libs) == 1 else None
    return dict(hostAbi=manifest.get("hostAbi", 1), dmshChain=chain)


def host_exe(c, sha):
    return contained(c.library, layout.hosts_mac(c) / sha / EXE)


def install_host(c, app):
    """把一份 S2ArmGame.app 放进 hosts/mac/<摘要>（已有就不动）→ 摘要"""
    from build import clone_tree
    sha = digest(Path(app) / "Contents/MacOS/s2arm-host")[:12]
    dest = layout.hosts_mac(c) / sha
    if not (dest / EXE).is_file():
        temporary = dest.with_name(sha + ".partial")
        shutil.rmtree(temporary, ignore_errors=True)
        temporary.mkdir(parents=True)
        try:
            clone_tree(c, Path(app), temporary / APP)
            if dest.exists():
                shutil.rmtree(dest)
            temporary.rename(dest)
        finally:
            shutil.rmtree(temporary, ignore_errors=True)
    return sha


def bundled_sha(c):
    """应用内置宿主的摘要前 12 位：engine.json 的文件清单里就有，不用现算（catalog 每款都要问）；开发模式没有 → None"""
    entry = read(c.engine / "engine.json", {}).get("files", {}).get("Binaries/" + EXE)
    return entry[1][:12] if isinstance(entry, list) and len(entry) == 2 else None


def status(c, gid, image, manifest):
    """catalog 用：none（开发模式 / 没准备好）| current（在用的就是本版宿主）| swap（下次起局自动换）| incompatible | failed（换过没起来、已退回）"""
    new, info = bundled_sha(c), layout.game_info(c, gid)
    if not new or not manifest:
        return "none"
    if info.get("hostMac") == new:
        return "current"
    if new in info.get("hostFailed", []):
        return "failed"
    return "swap" if image_compat(image, manifest) == engine_compat(c) else "incompatible"


def choose(c, gid, image, manifest):
    """起局用哪个宿主 → (摘要, 是不是新宿主的试玩)。兼容就换上本版内置宿主（放进 hosts/mac）；否则用这款原来的"""
    info = layout.game_info(c, gid)
    current = info.get("hostMac")
    if status(c, gid, image, manifest) == "swap":
        from embedded import artifact
        sha = install_host(c, artifact(c, APP))
        return sha, sha != current
    if not current or not host_exe(c, current).is_file():
        raise Failure("这款游戏的 Mac 宿主不在了，请重新准备这款游戏。", code="runtime_invalid")
    return current, False


def settle(c, gid, sha, ok):
    """试玩结论：ok → 这款改用新宿主；否则记进 hostFailed，下次照用原来的宿主"""
    info = layout.game_info(c, gid)
    if ok:
        layout.update_info(c, gid, hostMac=sha)
        prune(c)
    else:
        layout.update_info(c, gid, hostFailed=sorted(set(info.get("hostFailed", [])) | {sha}))
        c.emit("message", "新版运行层这款没能正常启动，下次会用原来的版本启动；再点一次开始即可。")


def prune(c):
    """hosts/mac 里没有任何一款在用、也不是本版内置的宿主删掉（.partial 残留一并清）"""
    root = layout.hosts_mac(c)
    if not root.is_dir():
        return
    keep = {bundled_sha(c)}
    for d in layout.games_root(c).iterdir() if layout.games_root(c).is_dir() else []:
        keep.add(read(d / layout.GAME_JSON, {}).get("hostMac"))
    for d in root.iterdir():
        if d.is_dir() and not d.is_symlink() and d.name not in keep:
            shutil.rmtree(d, ignore_errors=True)
