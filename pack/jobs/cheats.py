"""金手指（11-12 维护者：出包时自动对接公开库，「咱们只是提供了便利的对接服务」）：一款游戏文件夹的 cheats/ 是唯一的家。
  · 来源只是一个字段：玩家导入的（from = player）与出包时从公开库取来的（from = library）同放 cheats/*.txt（Atmosphere 格式），
    来源记在 cheats/sources.json {文件名: {from, repo, path, author, license, fetched}}；没登记的文件按玩家导入算。
  · 开关 cheats/enabled.txt（每行「文件名/条目名」，缺省全关），运行时服务层 services/S2A.Services/Cheats.cs 每秒重载、局内即时生效；
    改游戏代码的条目在出包时编进包（pack/cpatch.py scan_cheats，作业层 core.env 交 S2A_CHEATS_DIRS），状态 status.txt 由 Cheats.cs 写。
  · 查库：按程序号 + 主程序构建号前 16 位取，每库 10 秒，离线 / 没查到 / 格式不认都静默跳过、不挡出包；只解析文本，大小有上限。
    仓库与安装包不放这些文件（只在玩家本机按需下载，同 EdiZon / Breeze 这类金手指管理器的做法）。"""
from __future__ import annotations

import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

from core import Failure, atomic, read

TIMEOUT = 10
MAX_BYTES = 4 << 20
SKIP = ("enabled.txt", "status.txt")
# Cheats.cs 状态串（与 iOS ios/vpad_cheats.m 同一约定）在电脑上的说法：改代码的条目没编进这次的包 = 重新准备这款就能编进去
STATUS = {"改代码，不支持": "这条要改游戏代码：重新准备这款就能用。"}  # 非玩家句
UA = "S2Arm-cheats"   # 公开接口要求带 User-Agent；不带任何本机 / 用户信息


def cheats_dir(c, gid, create=True):
    import layout
    return layout.path(c, gid, "cheats", create=create)


def main_build(c, game):
    """这款实际运行的主程序构建号前 16 位（大写）：读主程序 NSO 头 0x40。找的顺序：共用解包目录 → Mac 运行版本 exefs/ → 存下的原始程序
    （pack/jobs/sgrade.py）→ iPhone 程序件记的 mainBid（11-14：出完包解包目录会删，原先只读它，出过包的款出包页就当「没解过包」、
    卡片只剩一句通用说明，封面金色 S 也按「库里有这款」乱亮）。都没有 = ''（真没解过包；目录里只记了本体的构建号，
    装了更新的款跑的是更新里的主程序，按目录取会错——11-12 暗黑 3：本体 EAFC2CEF，更新后 2607A74F）"""
    import layout
    gid = game["id"].upper()
    def head(p):
        with open(p, "rb") as f:
            f.seek(0x40)
            return f.read(8).hex().upper()
    try:
        from build import shared_dir
        return head(shared_dir(c, game) / "extract/exefs/main")
    except (OSError, ImportError, Failure):
        pass
    for p in (layout.image_mac(c, gid, create=False) / "exefs/main", layout.program_exefs(c, gid) / "main"):   # 原始程序在游戏程序专用文件夹（layout.program_store）
        try:
            if p.is_file():
                return head(p)
        except (OSError, Failure):
            continue
    return ((layout.game_info(c, gid).get("ios") or {}).get("mainBid") or "")[:16].upper()


# 写死地址：指令按「堆 / 别名 / 随机区起点 + 固定偏移」直接寻址（Atmosphere 0 存值、1 条件、5 取值且不以寄存器为基址，第 3 位区号非 0 = 不是主程序区）。
#   这类地址赌的是游戏堆内的分配排布与作者当年环境一致；11-12 实测：同一存档在 Ryujinx 与我们这边目标数值都比金手指写的偏 0x10000，
#   即作者环境与现行环境不同、不是我们偏离参照。界面标「地址写死，可能不生效」、缺省关（开关缺省本就全关），玩家自己决定。
#   改代码（区号 0）、按主程序里的指针一路找（5 区号 0 起链）不受影响。规则两处一致：这里与 ios/cheats_parse.m fixed_address
def fixed_address(line):
    t = line.strip().split()
    if not t or len(t[0]) != 8 or not re.fullmatch(r"[0-9A-Fa-f]{8}", t[0]):
        return False
    w = t[0]
    if w[0] in "01":
        return w[2] != "0"
    if w[0] == "5":
        return w[4] == "0" and w[2] != "0"
    return False


def parse(text):
    """→ (文件头 BID 或 '', [(条目名, 是主代码, 行数, 写死地址)])，同 Cheats.cs Parse / pack/cpatch.py parse_cheats 的切段口径"""
    m = re.search(r"BID\s*=\s*([0-9A-Fa-f]{16,64})", text.split("\n", 1)[0])
    out, cur = [], None
    for line in text.splitlines():
        s = line.strip()
        if not s:
            continue
        h = re.fullmatch(r"([\[{])(.*)[\]}]", s)
        if h:
            cur = [h.group(2).strip(), h.group(1) == "{", 0, False]
            out.append(cur)
        elif cur is not None and not re.fullmatch(r"20[0-9A-Fa-f]{6}", s):   # 只有「条件块结束」的段是分类标题，不算条目
            cur[2] += 1
            cur[3] = cur[3] or fixed_address(s)
    return (m.group(1)[:16].upper() if m else ""), [(n, mst, k, fx) for n, mst, k, fx in out if k]


SHORT = {"bad1dea/NXCheats": "nxcheats", "HamletDuFromage/switch-cheats-db": "cheatsdb", "ChanseyIsTheBest/NX-60FPS-RES-GFX-Cheats": "gfx",
         "s2arm/player-cheats": "player"}   # 玩家分享：<构建号>.player.txt，iPhone 金手指面板按文件名认「玩家分享、未验证」（ios/vpad_cheats.m）   # 文件名里的库简名（同 11-12 起的文件名，玩家已开的开关键不变）


def _unified(c):
    """金手指来源（11-13 维护者：由我们的下载站分发，统一包 pack/jobs/patches.py；各金手指库与补丁库附带的都在里面，按来源库分文件）"""
    import patches
    def get(gid, bids):
        by = {}
        for bid, text, repo, author, lic, path in patches.cheat_rows(c, gid, bids):
            t = by.setdefault((repo, bid), dict(text="", path=path, author=author, license=lic, repo=repo, short=SHORT.get(repo, "patchlibs")))
            if text.strip() not in t["text"]:
                t["text"] += text.rstrip("\n") + "\n\n"
        return [(bid, t) for (repo, bid), t in sorted(by.items())]
    return [("下载站统一包", "", get)]  # 非玩家句


def fetch(c, game, libraries=None):
    """出包第一步：按程序号（+ 已知的主程序构建号）查各公开库，取到的写进 cheats/<构建号>.<库简名>.txt（文件头补上 BID，运行时与出包都按它核版本）。
    任何一库失败都静默跳过（记 stderr），不挡出包；返回取到的库名"""
    libraries = libraries if libraries is not None else _unified(c)
    gid, bid = game["id"].upper(), main_build(c, game)
    bids = {bid} if bid else set()
    d = cheats_dir(c, gid)
    d.mkdir(parents=True, exist_ok=True)
    src = read(d / "sources.json", {}) or {}
    got = []
    for repo, short, get in libraries:
        try:
            found = get(gid, bids)
        except Exception as e:   # 离线 / 超时 / 库里没有（404）/ 结构变了：静默跳过
            print(f"金手指：{repo} 没取到（{type(e).__name__}）", file=sys.stderr)
            continue
        for fbid, r in found or []:
            rrepo, rshort = r.get("repo", repo), r.get("short", short)   # 统一包一条带自己的来源库
            text = r["text"].replace("\r\n", "\n")
            head = parse(text)[0]
            if not parse(text)[1] or (head and head != fbid) or (bids and fbid not in bids):
                continue
            if not head:
                text = f"[{rrepo} BID={fbid}]\n" + text
            name = f"{fbid}.{rshort}.txt"
            p = d / name
            if not p.is_file() or p.read_text(encoding="utf-8", errors="replace") != text:
                atomic_text(p, text)
            src[name] = {"from": "library", "repo": rrepo, "path": r["path"], "author": r["author"], "license": r["license"], "fetched": int(time.time())}
            if rrepo not in got:
                got.append(rrepo)
    atomic(d / "sources.json", src)
    return got


def atomic_text(p, text):
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(p)


# 玩家分享（11-15 维护者：「支持玩家自己导入金手指，还能收集更多金手指文件」）：导入时勾了「分享给其他玩家」就把原文连同程序号、构建号
#   传到诊断上传 Worker（diag.s2arm.com/v1/cheats，release/diag/worker.js；不碰补丁库发布令牌），取件后收进补丁库「玩家分享」上游
#   s2arm/player-cheats，下一次补丁库发布后别的玩家出包时带上（缺省关、标未验证）。只传金手指原文和游戏版本，不带设备 / 账号信息
SHARE_DEFAULT = False   # 勾选框缺省勾不勾（维护者定，改这一行；11-15「金手指分享缺省不勾」）
SHARE_URL = "https://diag.s2arm.com/v1/cheats"
PLAYER_REPO = "s2arm/player-cheats"   # 玩家分享上游的库名（补丁库按它记来源）：这类条目开之前提示一句可能坏存档，不拦


def share(c, game, name, text):
    """把一份玩家导入的金手指传上去 → "shared" / "duplicate" / "no_build"（这款没解过包、不知道构建号）/ "failed"（网络等，不影响导入本身）"""
    bid = main_build(c, game)
    if not bid:
        return "no_build"
    body = json.dumps({"gid": game["id"].upper(), "bid": bid, "name": name, "text": text}).encode()
    plat = "win" if sys.platform.startswith("win") else "mac"
    req = urllib.request.Request(SHARE_URL, data=body, method="POST", headers={
        "content-type": "application/json", "x-s2arm-client": f"{plat}/{app_version(c) or 'dev'}", "user-agent": "s2arm"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return "duplicate" if json.loads(r.read()).get("duplicate") else "shared"
    except Exception as e:   # 分享失败不挡导入：玩家这台照样能用
        print("金手指分享失败（不影响导入）：%s" % (str(e)[:200]), file=sys.stderr)  # 非玩家句
        return "failed"


def import_files(c, game, paths, share_on=None):
    """玩家导入：Atmosphere txt 拷进 cheats/（同名覆盖），登记 from = player；解析不出条目的不收。
    share_on（缺省 SHARE_DEFAULT）：勾了「分享给其他玩家」就逐份上传（share）。→ [{name, shared}]"""
    d = cheats_dir(c, game["id"].upper())
    d.mkdir(parents=True, exist_ok=True)
    src = read(d / "sources.json", {}) or {}
    done = []
    for raw in paths:
        p = Path(raw)
        if not p.is_file() or p.stat().st_size > MAX_BYTES:
            raise Failure("金手指文件读不了或太大（上限 4 MB）：%s" % p.name, code="job_failed")
        text = p.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")
        if not parse(text)[1]:
            raise Failure("这不是金手指文件（Atmosphere 格式的 txt）：%s" % p.name, code="job_failed")
        name = p.name if p.suffix.lower() == ".txt" else p.stem + ".txt"
        if name in SKIP or name == "sources.json":
            name = "imported-" + name
        atomic_text(d / name, text)
        src[name] = {"from": "player", "repo": "", "path": p.name, "author": "", "license": ""}
        done.append((name, text))
    atomic(d / "sources.json", src)
    on = SHARE_DEFAULT if share_on is None else bool(share_on)
    return [{"name": n, "shared": share(c, game, n, t) if on else "off"} for n, t in done]


def listing(c, game):
    """启动器「游戏设置 → 金手指」：每条 {key, file, name, enabled, status, from, repo, author, ok, reason}（主代码不列：同文件任一条开着就随之执行）"""
    gid, bid = game["id"].upper(), main_build(c, game)
    d = cheats_dir(c, gid, create=False)
    if not d.is_dir():
        return dict(items=[], reason="这个版本没有现成的金手指。")
    src = read(d / "sources.json", {}) or {}
    enabled = set((d / "enabled.txt").read_text(encoding="utf-8").splitlines()) if (d / "enabled.txt").is_file() else set()
    status = {}
    if (d / "status.txt").is_file():
        for line in (d / "status.txt").read_text(encoding="utf-8", errors="replace").splitlines():
            k, _, v = line.partition("\t")
            status[k] = v
    items = []
    import layout
    for f in layout.entries(d, "*.txt"):   # exFAT 上的 ._<名>.txt 不是金手指（#911 同类）
        if f.name in SKIP:
            continue
        fbid, entries = parse(f.read_text(encoding="utf-8", errors="replace"))
        stem_bid = f.name.split(".")[0].upper()
        want = fbid or (stem_bid if re.fullmatch(r"[0-9A-F]{16}", stem_bid) else "")
        ok = not want or not bid or want == bid
        s = src.get(f.name) or {"from": "player"}
        if not ok and s.get("from") == "library":
            continue   # 公开库里别的版本（没解过包时各版本都取了）：不列；玩家导入的版本不对照列、写原因
        for name, master, _, fixed in entries:
            if master:
                continue
            key = f"{f.name}/{name}"
            items.append(dict(key=key, file=f.name, name=name, enabled=key in enabled, status=STATUS.get(status.get(key, ""), status.get(key, "")),
                              **{"from": s.get("from", "player")}, repo=s.get("repo", ""), author=s.get("author", ""), license=s.get("license", ""),
                              shared=s.get("repo", "") == PLAYER_REPO or f.name.endswith(".player.txt"),   # 玩家分享、未验证：开之前提示一句可能坏存档（不拦）
                              ok=ok, fixed=fixed, reason="" if ok else f"版本不对：金手指是 {want}，这份游戏是 {bid}。"))
    return dict(items=items, reason="" if items else "这个版本没有现成的金手指。")


def save(c, game, want):
    """开关 {键「文件名/条目名」: 真 / 假} → cheats/enabled.txt（Cheats.cs 每秒看改动时间重载，游戏运行中也即时生效）"""
    if not isinstance(want, dict) or not all(isinstance(v, bool) for v in want.values()):
        raise Failure("金手指开关格式不对。", code="job_failed")
    d = cheats_dir(c, game["id"].upper())
    known = {it["key"] for it in listing(c, game)["items"]}
    p = d / "enabled.txt"
    on = set(p.read_text(encoding="utf-8").splitlines()) - {""} if p.is_file() else set()
    for k, v in want.items():
        if k not in known:
            raise Failure("没有这条金手指：%s。" % k, code="job_failed")
        (on.add if v else on.discard)(k)
    atomic_text(p, "".join(k + "\n" for k in sorted(on)))


# 崩了能恢复（11-13 维护者改定：金手指 / 补丁是玩家主动开的，开局前不再问；崩了就关掉、下次进来告诉玩家关了什么，想用去设置里再开）：
#   开着金手指 / 画面补丁时游戏异常退出（build.py launch 调）→ 当场关掉、记在 cheats/crashed.json；
#   下次开始这款时启动器读记录弹一条通知（不拦开局），读完清掉（answer_crash ack）
# 只关出事的那份（v0.4.1）：原先把开着的全部关掉，玩家要一条条重开。按嫌疑从小到大，一次只关一层，再崩再扩大（narrow）：
#   ① 比上一次好好收局时（note_good 记的 cheats/good.json）新开的那几条；② 没有新开的 → 我方没验过的（金手指、表里「缺省开」不是 1 的补丁 / 帧率档）；
#   ③ 还没有 → 全部。崩溃地址定位不了具体哪份：补丁数据写在数据段，代码改动出包时编进补丁区按位开关，表里没有代码地址。iOS 同口径（ios/cpatch_model.m S2ACrashNarrow）
def _on_now(c, game):
    """→ (开着的 [(类, 键)], 我方验过的键集合, launch.json 数据)。类 = cheat / patch / fps"""
    gid = game["id"].upper()
    d = cheats_dir(c, gid, create=False)
    keys = sorted(set((d / "enabled.txt").read_text(encoding="utf-8").splitlines()) - {""}) if (d / "enabled.txt").is_file() else []
    import community
    data = community.load_launch(c, gid)
    # 开着的补丁：按包里编进去的、这一局实际开着的算（同 launch_env 的 community.patch_on：玩家选过的照选的，没选过 other 与降负载画面补丁关、其余开）
    patches = sorted(it["id"] for it in community.packed_patches(c, gid) if community.patch_on(data["patches"], it))
    # 帧率补丁（编号 fps:）跟「60 帧」开关走、不在 packed_patches 里：包里有帧率补丁且开关没关 → 算一条（iOS 同口径，ios/game_options.m s2a_ios_crash_suspects_for）
    fps = bool(community.fps_levels(c, gid)) and data["settings"].get("fps60", True) is not False
    # 自适应满屏一族（编号 wsauto:）跟「满屏」开关走、也不在 packed_patches 里（11-15 候选自测：崩了没关它）：有这一族且开关没关 → 算一条，关 = 关满屏开关（iOS 同口径）
    fams, fam_verified = community.adaptive_patches(c, gid)
    # 玩家手动开的我方通用满屏（没有自适应满屏补丁、开关明确开，11-15 维护者「手动打开满屏就走咱们通用方案」）也算一条：崩了下一局关满屏
    fs = (bool(fams) and data["settings"].get("widescreen", True) is not False) or (not fams and data["settings"].get("widescreen") is True)
    on = [("cheat", k) for k in keys] + [("patch", k) for k in patches] + ([("fps", "fps60")] if fps else []) + ([("fs", "fullscreen")] if fs else [])
    return on, community.verified_patches(c, gid) | ({"fullscreen"} if fam_verified else set()), data


def narrow(on, good, verified):
    """嫌疑从小到大取一层（规则见上）。on = [(类, 键)]，good = 上次好好收局时开着的集合（没记过 = None），verified = 我方验过的键"""
    if good is not None:
        new = [x for x in on if x not in good]
        if new:
            return new
    return [x for x in on if x[0] == "cheat" or x[1] not in verified] or on


def note_good(c, game):
    """好好收局（build.py launch 正常退出调）：记下这时开着的，下次崩了按它找「新开的」"""
    on, _, _ = _on_now(c, game)
    d = cheats_dir(c, game["id"].upper())
    atomic(d / "good.json", {"on": [list(x) for x in on], "at": int(time.time())})


def crash_where(docs):
    """运行时崩溃处理写的落点（runtime/src/crash.c crash_where_note）：game / patch / host；没有 = ''。读完删（一次崩溃只认一次）"""
    if not docs:
        return ""
    p = Path(docs) / "crash_where"
    try:
        w = p.read_text(encoding="utf-8").strip()
    except OSError:
        return ""
    p.unlink(missing_ok=True)
    return w if w in ("game", "patch", "host") else ""


def app_version(c):
    """启动器引擎版本（engine.json version；开发树没有 = ''）：自动关时记下，换了版本自动重开一次（restore_after_update）"""
    try:
        return str(json.loads((Path(c.engine) / "engine.json").read_text(encoding="utf-8")).get("version") or "")
    except (OSError, ValueError, AttributeError, TypeError):
        return ""


# 宿主自己崩（11-15 维护者「优化 S 级优化，不是撤」）：落点两头都在宿主代码 = 多半是 S2Arm 的毛病，不是补丁 / 金手指（D-RRES / D-AZFR：宿主贴图上传
#   SIGBUS 把自适应满屏关了）。第一次不关、只记下这组开关（host_crash.json）；同一组开关再崩（落点不论）才照常关。落点是游戏 / 补丁区、或没有落点（被杀 / 老运行时）照常关
def note_crash(c, game, docs=None):
    gid = game["id"].upper()
    on, verified, data = _on_now(c, game)
    if not on:
        return
    d = cheats_dir(c, gid, create=False)
    where = crash_where(docs)
    tags = sorted(list(x) for x in on)
    hc = read(d / "host_crash.json", None)
    if where == "host" and not (isinstance(hc, dict) and hc.get("on") == tags):
        d.mkdir(parents=True, exist_ok=True)
        atomic(d / "host_crash.json", {"on": tags, "at": int(time.time())})
        return
    (d / "host_crash.json").unlink(missing_ok=True)
    g = read(d / "good.json", None)
    off = narrow(on, {tuple(x) for x in g.get("on", [])} if isinstance(g, dict) else None, verified)
    keys = [k for t, k in off if t == "cheat"]
    patches = [k for t, k in off if t == "patch"]
    fps = ("fps", "fps60") in off
    fs = ("fs", "fullscreen") in off
    known = {it["key"] for it in listing(c, game)["items"]}
    if keys:
        save(c, game, {k: False for k in keys if k in known})
    if patches or fps or fs:
        for k in patches:
            data["patches"][k] = False
        if fps:
            data["settings"]["fps60"] = False
        if fs:
            data["settings"]["widescreen"] = False
        import community
        atomic(community.launch_path(c, gid), data)
    d.mkdir(parents=True, exist_ok=True)
    atomic(d / "crashed.json", {"cheats": keys, "patches": patches, "fps": fps, "fullscreen": fs, "at": int(time.time()), "off": True})
    # 记下这次自动关掉的、当时的版本：换了版本（多半修了引起崩溃的毛病）自动重开一次（restore_after_update）
    remember_auto_off(c, d, off, "crash", where)


def remember_auto_off(c, d, off, cause, where=""):
    """记下自动关掉的（常驻，玩家看过通知也不删）：cheats/auto_off.json {ver, off: [[类, 键]…], where, meta: {"类\t键": {cause, at}}}。
    版本给 restore_after_update（换版本重开一次）；meta 给 S 级状态（sgrade.state 的 autoOff：原因 crash / stall、时间）。玩家动那个开关、或一键重开时清（forget_auto_off）"""
    ao = read(d / "auto_off.json", None)
    ao = ao if isinstance(ao, dict) else {}
    prev = [x for x in ao.get("off", []) if tuple(x) not in off]
    meta = dict(ao.get("meta") or {})
    now = int(time.time())
    for t, k in off:
        meta[f"{t}\t{k}"] = {"cause": cause, "at": now}
    d.mkdir(parents=True, exist_ok=True)
    atomic(d / "auto_off.json", {"ver": app_version(c), "off": prev + [list(x) for x in off], "where": where or ao.get("where") or "unknown", "meta": meta})


def forget_auto_off(c, gid, items):
    """玩家自己动了这几项（重新打开 / 关掉）：从自动关记录里去掉，状态不再显示「自动关的」。items = [(类, 键)]"""
    d = cheats_dir(c, gid, create=False)
    ao = read(d / "auto_off.json", None)
    if not isinstance(ao, dict):
        return
    drop = {tuple(x) for x in items}
    off = [x for x in ao.get("off", []) if tuple(x) not in drop]
    meta = {k: v for k, v in (ao.get("meta") or {}).items() if tuple(k.split("\t", 1)) not in drop}
    if off:
        atomic(d / "auto_off.json", dict(ao, off=off, meta=meta))
    else:
        (d / "auto_off.json").unlink(missing_ok=True)


def restore_after_update(c, game):
    """起局前（build.py launch）调：上次崩溃自动关掉的，换了启动器版本就重开一次（只开当时关的、现在仍关着的），记录删掉。→ 重开的 [(类, 键)]"""
    gid = game["id"].upper()
    d = cheats_dir(c, gid, create=False)
    ao = read(d / "auto_off.json", None)
    ver = app_version(c)
    if not isinstance(ao, dict) or not ver or not ao.get("ver") or ao.get("ver") == ver:
        return []
    import community
    data = community.load_launch(c, gid)
    back, keys = [], []
    for t, k in (tuple(x) for x in ao.get("off", [])):
        if t == "cheat":
            keys.append(k); back.append((t, k))
        elif t == "patch" and data["patches"].get(k) is False:
            data["patches"].pop(k); back.append((t, k))
        elif t == "fps" and data["settings"].get("fps60") is False:
            data["settings"].pop("fps60"); back.append((t, k))
        elif t == "fs" and data["settings"].get("widescreen") is False:
            data["settings"].pop("widescreen"); back.append((t, k))
    if keys:
        known = {it["key"] for it in listing(c, game)["items"]}
        save(c, game, {k: True for k in keys if k in known})
    atomic(community.launch_path(c, gid), data)
    (d / "auto_off.json").unlink(missing_ok=True)
    return back


# 停帧救场（11-14 维护者）：局内画面停住时社区帧率补丁开着，运行时当场关掉（runtime/src/cpatch.c s2a_cpatch_stall_rescue）并在 S2A_DOCS 下写 cpatch_stall_off。
#   游戏退出后（正常退出 / 崩溃都调）读到它 → 这款「60 帧 / 帧率」写关、记进 crashed.json（下次开始时同一条通知），删标记。→ True 记了
def note_stall(c, game, docs):
    mark = Path(docs) / "cpatch_stall_off"
    if not mark.is_file():
        return False
    mark.unlink(missing_ok=True)
    gid = game["id"].upper()
    import community
    data = community.load_launch(c, gid)
    data["settings"]["fps60"] = False
    atomic(community.launch_path(c, gid), data)
    d = cheats_dir(c, gid)
    r = read(d / "crashed.json", {}) or {}
    atomic(d / "crashed.json", dict(r, fps=True, at=int(time.time()), off=True, cheats=r.get("cheats", []), patches=r.get("patches", [])))
    remember_auto_off(c, d, [("fps", "fps60")], "stall")
    return True


# 我方通用满屏自检退回（runtime/src/qprompt_host.c widen_auto_revert：玩家手动开的通用满屏局内没铺满 / 被拉伸，当场退回 16:9 并在 S2A_DOCS 下写 widen_auto_off）：
#   收局读到 → 这款「满屏」写关、记自动关（原因 widen_fit），下次开始时通知（同停帧救场 note_stall 一套）
def note_widen(c, game, docs):
    mark = Path(docs) / "widen_auto_off"
    if not mark.is_file():
        return False
    mark.unlink(missing_ok=True)
    gid = game["id"].upper()
    import community
    data = community.load_launch(c, gid)
    data["settings"]["widescreen"] = False
    atomic(community.launch_path(c, gid), data)
    d = cheats_dir(c, gid)
    r = read(d / "crashed.json", {}) or {}
    atomic(d / "crashed.json", dict(r, fullscreen=True, at=int(time.time()), off=True, cheats=r.get("cheats", []), patches=r.get("patches", [])))
    remember_auto_off(c, d, [("fs", "fullscreen")], "widen_fit")
    return True


def crashed(c, game):
    """→ [{kind: cheat | patch | fps | fs, key, name}]：上次异常退出时开着、已经关掉的几条；没记录 = []"""
    r = read(cheats_dir(c, game["id"].upper(), create=False) / "crashed.json", {}) or {}
    labels = {it["id"]: it["label"] for it in __import__("community").packed_patches(c, game["id"].upper())} if r.get("patches") else {}
    return [dict(kind="cheat", key=k, name=k.split("/", 1)[-1]) for k in r.get("cheats", [])] + \
           [dict(kind="patch", key=k, name=labels.get(k, k)) for k in r.get("patches", [])] + \
           ([dict(kind="fps", key="fps60", name="")] if r.get("fps") else []) + \
           ([dict(kind="fs", key="fullscreen", name="")] if r.get("fullscreen") else [])


def answer_crash(c, game, choice):
    """玩家看过通知（ack）：清掉记录。开关已在 note_crash 当场关了，这里不再动"""
    if choice != "ack":
        raise Failure("回答不对。", code="job_failed")
    (cheats_dir(c, game["id"].upper(), create=False) / "crashed.json").unlink(missing_ok=True)
