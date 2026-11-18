# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""S 级优化升级（v0.4.0 维护者：已经导出在 Mac 游戏库 / iPhone 上的游戏不用重出包就能用上 S 级优化）。

原始程序（exefs：main / sdk / subsdk* / main.npdm，几十 MB）是给老游戏补 S 级优化的唯一原料：
  出 iPhone 包时存一份到这款游戏文件夹 original-exefs/（save_program，pack/jobs/ipa.py 调）；老游戏没存过的，「升级前查找」从原件只解 exefs 补存。
  pack/jobs/rewrite_refresh.py original_exefs 优先读它。

作业：
  sgradeScan  「S 级优化升级」页打开时：逐款找原始程序（存下的 → 解包缓存 → Mac 运行版本 → 原件只解 exefs 并存下），
              按补丁库（本地：随启动器的快照与增量缓存，不联网）看这个版本有哪几类补丁 → 每款 {program, patches, iphone, mac, off}
  sgradeMac   启动器打开时后台跑：游戏库里有 Mac 运行版本的款逐款补上 S 级优化（rewrite_refresh.refresh_mac，按补丁记号，补过的不重做）"""
from __future__ import annotations

import shutil
import tempfile
from pathlib import Path

import layout
from core import Failure

PROGRAM_DIR = layout.PROGRAM_EXEFS
MODULES = ("main", "main.npdm", "sdk") + tuple(f"subsdk{i}" for i in range(10))


def saved_program(c, gid):
    d = layout.program_exefs(c, gid)
    return d if (d / "main").is_file() and (d / "main.npdm").is_file() else None


def save_program(c, gid, exefs):
    """原始程序存进游戏程序常驻（.programs/<号>/exefs.tar.zst，pack/jobs/programs.py；已存且主程序相同就不动）→ 解开的那份（缓存）；源目录不完整 → None"""
    exefs = Path(exefs)
    if not ((exefs / "main").is_file() and (exefs / "main.npdm").is_file()):
        return None
    dest = layout.program_exefs(c, gid)
    if (dest / "main").is_file() and (dest / "main").read_bytes()[0x40:0x60] == (exefs / "main").read_bytes()[0x40:0x60]:
        return dest
    tmp = Path(tempfile.mkdtemp(prefix=".exefs-"))
    try:
        for m in MODULES:
            if (exefs / m).is_file():
                shutil.copyfile(exefs / m, tmp / m)
        import programs
        return programs.save_exefs(c, gid, tmp)   # 常驻 exefs.tar.zst + 缓存解开的一份
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def find_program(c, game, extract=True):
    """→ (来处, exefs 目录 | None)。来处：saved / cache / mac / source（从原件只解 exefs、已存下）/ none"""
    from build import extract_valid, shared_dir
    gid = game["id"].upper()
    d = saved_program(c, gid)
    if d:
        return "saved", d
    try:
        if extract_valid(c, game):
            return "cache", shared_dir(c, game) / "extract/exefs"
    except (OSError, Failure, ValueError):
        pass
    mac = layout.image_mac(c, gid, create=False) / "exefs"
    if (mac / "main").is_file() and (mac / "main.npdm").is_file():
        return "mac", mac
    if extract:
        from rewrite_refresh import original_exefs
        with tempfile.TemporaryDirectory(dir=c.private) as tmp:
            try:
                x = original_exefs(c, game, Path(tmp))
            except (OSError, Failure, ValueError) as e:
                c.emit("message", f"【黄】{game.get('name') or gid} 从原件取原始程序没成：{str(e)[:160]}")
                x = None
            if x is not None and (saved := save_program(c, gid, x)):
                return "source", saved
    return "none", None


def local_patches(c, gid, bid, others=None):
    """这个版本在本地补丁库（快照 + 增量缓存，不联网）里各类条数（同 patches.match 的口径：按构建号精确对）。
    others 给一个 dict：顺带收「只有别的版本」的各类版本号 {类: [版本号…]}（升级页拆「没有 / 是别的版本的」，同 patches.match 的 others）"""
    import patches
    snap, snap_get = patches._snapshot(c)
    keys = [f"g/{gid}"] + ([f"b/{bid[:16]}"] if len(bid) >= 16 else [])
    out = {k: 0 for k in patches.CATS}
    for k in keys:
        for it in patches.bundle(c, k, None, snap, snap_get):
            if it.get("kind") == "pso":
                continue
            cat = it.get("cat") if it.get("cat") in patches.CATS else "gfx"
            if bid and any(patches.bid_hit(bid, b) for b in it.get("bids") or []):
                out[cat] += 1
            elif others is not None:
                v = patches._version_label(it)
                if v and v not in others.setdefault(cat, []):
                    others[cat].append(v)
    return out


def scan(c):
    c.begin("查找原始程序与补丁", 1, 1)
    games = []
    for g in c.catalog()["games"]:
        gid = g["id"].upper()
        info = layout.game_info(c, gid)
        iphone = layout.has_ios_kit(c, gid)
        mac = (layout.image_mac(c, gid, create=False) / "exefs/main").is_file()
        if not (iphone or mac):
            continue   # 没出过包：没有可升级的东西（出包时就会带上 S 级优化）
        where, exefs = find_program(c, g)
        bid = (exefs / "main").read_bytes()[0x40:0x48].hex().upper() if exefs else ""
        oth = {}
        pats = local_patches(c, gid, bid, oth) if bid else {}
        import patches as _p   # 维护者 11-15「两者合成一套」：没社区满屏补丁、这一版在宽屏已验证名单 → 满屏算我方通用满屏
        own = not pats.get("widescreen") and _p.own_widen(c, gid, bid)
        import sgrade_bf   # 直连库缺可读瓦片版着色器（_bf）：iPhone 看 game.json ios.bfGen，Mac 看运行版本清单 bfGen
        from core import read
        bf = dict(iphone=iphone and sgrade_bf.due(c, gid),
                  mac=mac and sgrade_bf.stale(read(layout.image_mac(c, gid, create=False) / "manifest.json", {}).get("bfGen"))
                      and (layout.image_mac(c, gid, create=False) / "shaders/direct/keys.tsv").is_file())
        games.append(dict(id=gid, name=g.get("name") or gid, bfPending=bf, program=where, build=bid, patches=pats, total=sum(pats.values()) + (1 if own else 0),
                          ownWiden=bool(own), iphone=iphone, mac=mac, off=info.get("sgradeOff") is True,
                          versions={"mine": _p.display_version(c, g) or "",
                                    "available": {k: sorted(v) for k, v in oth.items() if not pats.get(k)}}))
    found = [x for x in games if x["program"] != "none"]
    return dict(games=games, found=len(found), upgradable=sum(1 for x in found if (x["total"] and not x["off"]) or any(x["bfPending"].values())),
                noPatch=sum(1 for x in found if not x["total"]), missing=len(games) - len(found))


def mac_all(c):
    """启动器打开时后台跑（v0.4.0）：有 Mac 运行版本的款逐款补上 S 级优化；补丁记号没变的 refresh_mac 自己跳过。一款出错不挡别的
    后台活给玩家让路（诊断 D-R8NG：原先整款改写都拿着与开始游戏同一把 execution 锁，一款要两分多钟，玩家点开始等 30 秒报「另一个任务正在使用游戏库」）：
      库里有任务在用这把锁（正在玩 / 正在出包）就这款不做，不抢 CPU；改写在锁外的临时目录里做，只有换进运行版本那一下「没人用才拿锁」，
      拿不到就放弃这款——开始游戏起局前自己会补它（build.launch → refresh_mac）"""
    from rewrite_refresh import refresh_mac
    import sgrade_bf
    games = [g for g in c.catalog()["games"] if (layout.image_mac(c, g["id"], create=False) / "exefs/main").is_file()]
    c.begin("给 Mac 游戏补上 S 级优化", 1, 1)
    done = []
    for g in games:
        try:
            with c.idle("execution") as free:
                pass
            if not free:
                continue
            # 后台：只补补丁记号变了的；改写器指纹单独变了不重改写（11-17 维护者定），开始游戏起局前 build.launch 前台会做这一款
            if refresh_mac(c, g["id"], layout.image_mac(c, g["id"], create=False), hold=lambda: c.idle("execution"), ignore_rewriter=True):
                done.append(g["id"].upper())
            # 老包直连库缺可读瓦片版着色器（_bf）：整份重出在锁外做（几分钟到几十分钟），换进运行版本前同样进 c.idle，玩家正在开局就这次放弃
            if sgrade_bf.upgrade_mac(c, g["id"], layout.image_mac(c, g["id"], create=False), hold=lambda: c.idle("execution")) and g["id"].upper() not in done:
                done.append(g["id"].upper())
        except (Failure, OSError) as e:
            c.emit("message", f"【黄】{g.get('name') or g['id']} 这次没补上：{str(e)[:160]}")
    if done:
        c.emit("message", f"已给 {len(done)} 款 Mac 游戏补上 S 级优化")
    return dict(updated=done, checked=len(games))


# S 级优化按类状态（11-15 维护者「优化 S 级优化，让满屏更好用」；口径与体验梳理线 cmdr/S级状态与文案_三端对照 第二节一致，界面按它显示）：
#   每款四类 widescreen / fps / gfx / cheats，各一段 {state, source（满屏才有）, active, lastRun, autoOff, versions}。state 取值：
#   on 在用 · ineffective 开着但上一局没生效 · off_user 玩家关的 · off_auto 自动关的（崩溃 / 画面停住）· version 补丁库有、版本不同 ·
#   none 补丁库没有这一类 · opted_out 出包时选了不打入 · pending 能用、还没打进这个包 · mac_only 画面类在 iPhone · unknown 还不知道版本
#   满屏 source：patch 社区补丁（含移植成的）· own 我方通用满屏（维护者 11-15「两者合成一套」：没补丁、在宽屏已验证名单）· none
STATES = ("on", "ineffective", "off_user", "off_auto", "version", "none", "opted_out", "pending", "mac_only", "unknown")


def _auto_off(c, gid):
    import cheats
    from core import read
    ao = read(cheats.cheats_dir(c, gid, create=False) / "auto_off.json", None)
    if not isinstance(ao, dict):
        return set(), {}
    return {tuple(x) for x in ao.get("off", [])}, ao.get("meta") or {}


def _match(c, gid):
    """补丁库按版本的对照（patches.match）：要 c.r 里是这款；取不到（没解过包 / 单测没补丁库）给空"""
    import patches
    keep = getattr(c, "r", None)
    try:
        c.r = dict(keep or {}, gameId=gid)
        return patches.match(c)
    except Exception:   # noqa: BLE001 —— 状态只读展示，查不到版本对照不挡别的类
        return {}
    finally:
        c.r = keep


def fi_supported():
    """这台 Mac 能不能补帧：出图补帧只走 Metal 4（macOS 26 起，graphics/nvn/gfx/nvn/nvn_present_fi.inc）"""
    import platform
    v = platform.mac_ver()[0]
    return bool(v) and int(v.split(".")[0]) >= 26


def fps_failed(c, gid, platform):
    """这款这一端出包时没打进去的帧率补丁（patches.record 记的 sgradeResult.<端>.failed 里 cat = fps）→ [{name, why}]（why = 文案键 result.why.*）。
    11-15 #934：补丁库有这一版的帧率补丁、一份都没打进去时，开关不能显示成开着生效，要如实写「没能打入（原因）」"""
    res = ((layout.game_info(c, gid) or {}).get("sgradeResult") or {}).get(platform) or {}
    return [dict(name=f.get("name") or "", why=f.get("why") or "") for f in res.get("failed") or [] if isinstance(f, dict) and f.get("cat") == "fps"][:3]


def state(c, game, match=None):
    """→ {platform: mac, widescreen: {…}, fps: {…}, gfx: {…}, cheats: {…}}（Mac 启动器读；iPhone 读出包写进 kit 的 sgrade_state.json + 本机开关）"""
    import community, cheats
    gid = game["id"].upper()
    img = layout.image_mac(c, gid, create=False)
    exported = (img / "exefs" / "main").is_file()
    rows = community._rows(img / "cpatch.tsv")
    data = community.load_launch(c, gid)
    sset, pset = data["settings"], data["patches"]
    st = community.patch_status(c, gid)
    off, meta = _auto_off(c, gid)
    opted = (layout.game_info(c, gid) or {}).get("sgradeOff") is True
    m = match if match is not None else (_match(c, gid) if exported else {})
    exact, others = m.get("exact") or {}, m.get("others") or []
    mine = m.get("version") or ""

    def versions(cat):
        return {"mine": mine, "available": [o["version"] for o in others if cat in o.get("cats", [])],
                "port": ("failed" if not exact.get("widescreen") else "ok") if cat == "widescreen" and m.get("port") else "none"}

    def auto(keys):
        for k in keys:
            if k in off:
                info = meta.get(f"{k[0]}\t{k[1]}") or {}
                return {"cause": info.get("cause", "crash"), "at": info.get("at")}
        return None

    def bad(s):   # 上一局没生效：数据对不上 / 表不认 / 没铺满
        return bool(s) and (s[0] in ("不配套", "表不认") or s[1] == "unfilled")   # 非玩家句（表列名 / 运行时状态值）

    def missing(cat):   # 包里没有这一类时：补丁库有别的版本 = version，否则 none；没出包 / 不知道版本 = unknown / pending
        if not exported or not m.get("build"):
            return "unknown"
        if exact.get(cat):
            return "pending"   # 这份版本补丁库有、包里没有：老包，升级页能补
        return "version" if any(cat in o.get("cats", []) for o in others) else "none"

    out = {"platform": "mac"}
    # 满屏：社区补丁（自适应一族 wsauto: 跟满屏开关；定画幅变体 widescreen:auto；其余 widescreen: 单列）→ 我方通用满屏 → 没有
    fams, _ = community.adaptive_patches(c, gid)
    ws_ids = sorted({(r.get("编号") or "") for r in rows if (r.get("编号") or "").startswith("widescreen:")})   # 非玩家句（表列名 / 运行时状态值）
    fixed = any(float(r.get("画幅") or 0) > 0 for r in rows if (r.get("编号") or "").startswith("widescreen:") and (r.get("画幅") or "").replace(".", "", 1).isdigit())   # 非玩家句（表列名 / 运行时状态值）
    # 11-15 维护者「没补丁的游戏手动打开满屏就走咱们通用方案」：没有社区满屏补丁的款一律可开我方通用满屏（第三层整套放宽，不看已验证名单），缺省关
    src = "patch" if fams or ws_ids else "own" if exported else "none"
    switch = sset.get("widescreen", True) is not False if src == "patch" else sset.get("widescreen") is True
    keys = [("fs", "fullscreen")] + [("patch", k) for k in ws_ids] + ([("patch", "widescreen:auto")] if fixed else [])
    ws_st = next((st[k] for k in [*(fams or []), "widescreen:auto", *ws_ids] if k in st), None)
    if opted: s = "opted_out"
    elif src == "none": s = missing("widescreen")
    elif auto(keys) and not switch: s = "off_auto"
    elif not switch: s = "off_user"
    elif bad(ws_st): s = "ineffective"
    else: s = "on"
    out["widescreen"] = {"state": s, "source": src, "active": "adaptive" if fams else "fixed" if fixed else "own" if src == "own" else "",
                         "lastRun": community.patch_result(ws_st), "autoOff": auto(keys), "versions": versions("widescreen")}
    # 帧率解锁（11-15 维护者「补帧稳定了就直接用补帧」）：有社区帧率补丁用补丁（按档），没有用补帧（MetalFX 30→60，Metal 4 才有）；二选一。
    #   Mac 今天缺省不补帧：没补丁的款玩家明确开才补（pack/jobs/community.py launch_env 写 DM_PRESENT_FI），不退化
    levels = community.fps_levels(c, gid)
    fi_ok = fi_supported()
    on = sset.get("fps60", True) is not False if levels else sset.get("fps60") is True
    pick = str(sset.get("fpsPick") or "0")
    fst = next((v for k, v in st.items() if k.startswith("fps:") and v[0] == "开"), None)   # 非玩家句（表列名 / 运行时状态值）
    target = int(pick) if pick.isdigit() and int(pick) else (max(levels) if levels else 0)
    weak = bool(fst) and fst[1].startswith("fps=") and fst[1][4:].isdigit() and int(fst[1][4:]) < (min(target, 60) if pick == "0" else target) - 5
    ffail = [] if levels else fps_failed(c, gid, "mac")
    if opted: s = "opted_out"
    elif ffail: s = "failed"   # 补丁库有、一份没打进去（转换器不支持 / 对不上 …）：不说成开着生效，也不说成「不支持补帧」
    elif not levels and not exported: s = "unknown"
    elif not levels and not fi_ok: s = "unsupported"
    elif auto([("fps", "fps60")]) and not on: s = "off_auto"
    elif not on: s = "off_user"
    elif weak: s = "ineffective"
    else: s = "on"
    out["fps"] = {"state": s, "source": "patch" if levels else "fi", "fiSupported": fi_ok, "active": {"levels": levels, "pick": pick}, "lastRun": community.patch_result(fst),
                  **({"failed": ffail} if ffail else {}),
                  "autoOff": auto([("fps", "fps60")]), "versions": versions("fps")}
    # 画面：Mac 才打（iPhone 一律 mac_only）
    gfx = [it for it in community.packed_patches(c, gid) if it["kind"] == "gfx"]
    gon = [it for it in gfx if community.patch_on(pset, it)]   # 没选过：降负载的缺省关（11-16）
    gkeys = [("patch", it["id"]) for it in gfx]
    if opted: s = "opted_out"
    elif not gfx: s = missing("gfx")
    elif gon: s = "ineffective" if all(bad(st.get(it["id"])) for it in gon) else "on"
    else: s = "off_auto" if auto(gkeys) else "off_user"
    out["gfx"] = {"state": s, "active": [it["id"] for it in gon], "lastRun": "", "autoOff": auto(gkeys), "versions": versions("gfx")}
    # 金手指：打进包、缺省关，玩家逐条开
    items = [it for it in cheats.listing(c, game)["items"] if it.get("ok")] if exported else []
    con = [it["key"] for it in items if it["enabled"]]
    ckeys = [("cheat", it["key"]) for it in items]
    if opted: s = "opted_out"
    elif not items: s = missing("cheat")
    elif con: s = "on"
    else: s = "off_auto" if auto(ckeys) else "off_user"
    out["cheats"] = {"state": s, "active": con, "lastRun": "", "autoOff": auto(ckeys), "versions": versions("cheat")}
    return out


def reenable(c):
    """一键重开（sgradeReenable {gameId, key}）：key = fps / fullscreen / 补丁编号 / 金手指「文件名/条目名」。打开它、从自动关记录去掉 → 新状态"""
    import community, cheats
    from core import atomic
    gid = (c.r.get("gameId") or "").upper(); key = c.r.get("key") or ""
    game = community.game_of(c, gid)
    data = community.load_launch(c, gid)
    if key == "fps":
        data["settings"].pop("fps60", None); t = ("fps", "fps60")
    elif key == "fullscreen":
        data["settings"].pop("widescreen", None); t = ("fs", "fullscreen")
    elif ":" in key and "/" not in key:
        data["patches"].pop(key, None); t = ("patch", key)
    elif "/" in key:
        cheats.save(c, game, {key: True}); t = ("cheat", key)
    else:
        raise Failure("重开哪一项没说清楚。", code="job_failed")
    if t[0] != "cheat":
        atomic(community.launch_path(c, gid), data)
    cheats.forget_auto_off(c, gid, [t])
    return state(c, game)


def write_kit_state(c, gid, kit):
    """出 iPhone 包后写 <iOS kit>/sgrade_state.json：手机上没有补丁库，版本对照 / 满屏来源 / 出包时选不打入由这里给，
    开关、上一局是否生效、自动关由手机本机算（ios/game_options.m s2a_ios_sgrade_state 读它，按 state() 同一套状态码）。写不出不挡出包"""
    import json, community
    from core import atomic
    try:
        kit = Path(kit)
        rows = community._rows(kit / "cpatch.tsv")
        ids = [r.get("编号") or "" for r in rows]   # 非玩家句（表列名）
        m = _match(c, gid)
        vers = lambda cat: {"mine": m.get("version") or "", "available": [o["version"] for o in m.get("others") or [] if cat in o.get("cats", [])],
                            "exact": int((m.get("exact") or {}).get(cat) or 0)}
        ws = "patch" if any(i.startswith(("widescreen:", "wsauto:")) for i in ids) else "own"   # 11-15：没补丁一律可开我方通用满屏（不看已验证名单）
        out = {"schema": 1, "build": m.get("build") or "", "optedOut": (layout.game_info(c, gid) or {}).get("sgradeOff") is True,
               "widescreen": dict(source=ws, port="failed" if m.get("port") and not (m.get("exact") or {}).get("widescreen") else "none", versions=vers("widescreen")),
               "fps": dict(versions=vers("fps"), **({} if any(i.startswith("fps:") for i in ids) or not fps_failed(c, gid, "ios") else
                                                    dict(state="failed", failed=fps_failed(c, gid, "ios")))),
               "gfx": dict(state="mac_only"), "cheats": dict(versions=vers("cheat"))}
        atomic(kit / "sgrade_state.json", out)
    except (OSError, ValueError, TypeError) as e:
        c.emit("message", f"【黄】S 级状态底料没写出（不影响出包）：{str(e)[:120]}")   # 非玩家句
