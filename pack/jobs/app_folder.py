"""独立 App（一 App 一游戏，0.6.4 维护者定）在电脑上的文件：全放这款自己的游戏文件夹（layout.game_dir：games/<英文名>/），删这一个文件夹就删干净这款的电脑产物。

  games/<英文名>/
    <游戏名> v<版本>.ipa      独立 App：「推到 iPhone」写装上的那份（证书签的是签好的，Apple ID 的是未签名容器），「导出」写按签名方式签好或未签名的；
                              出新版本删掉这款旧版本那份，只留一份
    <游戏名>.s2arm            只在「导出」时：这款的资源派生件（同通用壳的游戏包格式，手机导入与壳无关；独立 App 起局只认包内程序，launchctx.c）
    <游戏名>.img              只在「导出」且资源包里有本体 game.img 时：硬链接，同盘不占新空间；建不了硬链接就不放，README 写原位置
    请先读我.txt / README.txt  只留一份：中文界面写「请先读我.txt」（末尾附英文摘要），其余界面写 README.txt（英文）

不在这个文件夹里、README 点名的：<默认位置>/.programs/<号>（程序备份，删文件夹后「更新 S2Arm」还要用；启动器「删除游戏」连它一起删）。
文件名、README 正文只在这里定（启动器成功页的「下一步」用同一组句子，见 next_steps）。"""
from __future__ import annotations

import os
import re
import shutil
from pathlib import Path

_BAD = re.compile(r'[\\/:*?"<>|\x00-\x1f]')
README = {"zh": "请先读我.txt", "en": "README.txt"}  # 非玩家句（文件名按界面语言）
S2ARM_SUFFIX, IMG_SUFFIX, IPA_SUFFIX = ".s2arm", ".img", ".ipa"


def stem(name, gid):
    """文件名主干：游戏名（玩家在启动器里看到的那个）去掉文件名里不能有的字符；空了用游戏号"""
    return _BAD.sub(" ", name or "").strip().strip(".") or gid.upper()


def ipa_name(name, gid, version):
    v = _BAD.sub(" ", str(version or "")).strip().strip(".")
    return f"{stem(name, gid)} v{v}{IPA_SUFFIX}" if v else f"{stem(name, gid)}{IPA_SUFFIX}"


def old_ipas(folder, name, gid, keep):
    """这款以前写下的独立 App ipa（同主干、「 v」开头或不带版本），keep 除外：出新版本时删掉，只留一份"""
    base = stem(name, gid)
    out = []
    for p in Path(folder).glob("*" + IPA_SUFFIX):
        n = p.name[:-len(IPA_SUFFIX)]
        if p.name != keep and (n == base or n.startswith(base + " v")):
            out.append(p)
    return out


def place_ipa(src, folder, name, gid, version):
    """把 src（ipa）放成 folder/<游戏名> v<版本>.ipa：同盘改名、跨盘复制（临时名 + 改名，写到一半不留半个文件）；删掉这款旧版本的 ipa。→ 新路径"""
    folder = Path(folder)
    out = folder / ipa_name(name, gid, version)
    tmp = folder / f".{out.name}.{os.getpid()}.partial"
    try:
        shutil.copyfile(src, tmp)
        os.replace(tmp, out)
    finally:
        tmp.unlink(missing_ok=True)
    for p in old_ipas(folder, name, gid, out.name):
        p.unlink(missing_ok=True)
    return out


# 「怎么装」各段（README 与导出成功页的「下一步」同一组句子；{app} = 游戏名，{ipa} / {s2arm} / {img} = 文件名）
_INSTALL = {
    "zh": {
        "appleId": "Apple ID（启动器里登录的）：手机连上电脑，在启动器里点这款的「推到 iPhone」，签名、安装、拷资源一步完成。"  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
                   "免费 Apple ID 有苹果的限制：同时最多 3 个自己签的 App（AltStore / SideStore 也算），每 7 天最多注册 10 个 App ID，每款独立 App 占一个。",
        "devCert": "开发者证书 / 分发证书：同样可以在启动器里点「推到 iPhone」。只导出时，{ipa} 已经用你的证书签好，用你常用的装 ipa 工具装到证书登记过的设备上。"  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
                   "用通配（*）描述文件签的开不了「提高内存上限」，大游戏可能内存不够。",
        "external": "AltStore / SideStore：用它们打开 {ipa} 安装（它们用自己的账号签名）。",  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
        "import": "只导出、没连手机推的，还要做一步：装好后先打开一次「{app}」，再把这个文件夹里的 {files} 放进 iPhone「文件」App →「我的 iPhone」→「{app}」→「放这里导入」，"  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
                  "回到「{app}」点「我已放好，重新检查」，它会自动导入。",
    },
    "en": {
        "appleId": "Apple ID (signed in to the launcher): connect the iPhone and click “Push to iPhone” for this game in the launcher. Signing, installing and copying the game data happen in one go. "
                   "A free Apple ID is limited by Apple to 3 self-signed apps at a time (AltStore / SideStore count too) and 10 new App IDs every 7 days; each standalone app uses one.",
        "devCert": "Developer / distribution certificate: “Push to iPhone” in the launcher works too. When you only export, {ipa} is already signed with your certificate; install it on a device registered "
                   "in the profile with the ipa installer you usually use. A wildcard (*) profile can’t enable “Increased Memory Limit”, so large games may run out of memory.",
        "external": "AltStore / SideStore: open {ipa} with them to install it (they sign it with their own account).",
        "import": "If you only exported (nothing was pushed from the computer), one more step: after installing, open “{app}” once, then put {files} from this folder into the iPhone Files app → "
                  "“On My iPhone” → “{app}” → “Import Here”. Go back to “{app}” and tap “I’ve copied it — check again”; it’s imported automatically.",
    },
}


def _files(lang, s2arm, img):
    names = [n for n in (s2arm, img) if n]
    if not names:
        return ""
    if lang == "zh":
        return "和".join(names)  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
    return " and ".join(names)


def next_steps(lang, mode, *, app, ipa, s2arm="", img="", exported=False):
    """成功页「下一步」：只给这次签名方式那一段（mode = appleId / devCert / external），导出时再加导入那一步。→ [句子]
    导出时 Apple ID 模式的 ipa 是未签名的（install.export_app：不连手机签不出能装的包）：先给 AltStore / SideStore 那段，再给连手机推的那段"""
    t = _INSTALL[lang]
    mode = mode if mode in ("appleId", "devCert", "external") else "external"
    order = ["external", "appleId"] if exported and mode == "appleId" else [mode]
    out = [t[m].format(ipa=ipa, app=app) for m in order]
    if exported:
        out.append(t["import"].format(app=app, files=_files(lang, s2arm, img)))
    return out


def readme_text(lang, *, app, ipa, gid, s2arm="", img="", img_elsewhere=""):
    """README 正文（lang = zh / en）。中文的末尾附英文摘要，方便玩家转给别人"""
    t = _INSTALL[lang]
    files = _files(lang, s2arm or f"{stem(app, gid)}{S2ARM_SUFFIX}", img)
    if lang == "zh":
        body = [
            f"{app} — 独立 App（S2Arm 出的「一个 App 一款游戏」）",  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
            "",
            "【这是什么】",  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
            f"{ipa} 是这款游戏自己的 iPhone App：主屏上叫「{app}」，图标是这款的，打开直接进游戏。它和通用 S2Arm 互不影响，可以同时装。",  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
            "",
            "【怎么装】（按你用的签名方式看一段）",  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
            "· " + t["appleId"],
            "· " + t["devCert"].format(ipa=ipa),
            "· " + t["external"].format(ipa=ipa),
            "· " + t["import"].format(app=app, files=files),
        ]
        if img_elsewhere:
            body.append(f"  这款的资源本体没能放进这个文件夹（盘不支持硬链接），在：{img_elsewhere}")  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
        body += [
            "",
            "【到期与续签】",  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
            "免费 Apple ID 签的 7 天到期，付费开发者账号签的 1 年，证书签的按描述文件的到期日。到期后 App 打不开，手机上的存档还在。",  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
            "续签：手机连上电脑，在启动器总控台「独立 App」一节点这款的「续签」。AltStore / SideStore 装的，用它们自己的刷新。",  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
            "",
            "【存档在哪】",  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
            "存档在手机上这个 App 里。启动器每次装、更新、续签这款时，会把手机存档拉一份到这个文件夹的 save_backup/。",  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
            "",
            "【怎么整体删除】",  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
            f"1. 手机上：长按「{app}」→ 删除 App。手机上这款的存档会一起删掉。",  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
            "2. 电脑上：用启动器删除最干净——游戏库里这款 →「删除游戏」，会连游戏库隐藏文件夹 .programs 里这款的程序备份一起删；"  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
            "这个文件夹里有存档备份时，存档会留下，其余全删。",
            f"   也可以直接删掉这个文件夹：save_backup/ 里的存档备份会一起删掉，想留存档先把它拷走；电脑上还会剩一份程序备份在游戏库的 .programs/{gid.upper()}（隐藏文件夹，"  # 非玩家句（README / 下一步按界面语言直接写，英文在 "en" 那份）
            "几十 MB），在启动器里点「删除游戏」可以删掉。",
            "",
            "—— English summary ——",
            f"{ipa} is this game’s own iPhone app (“{app}” on the Home Screen). Install it by clicking “Push to iPhone” in the S2Arm launcher, or open it with AltStore / SideStore.",
            f"If you only exported it, after installing put {_files('en', s2arm or stem(app, gid) + S2ARM_SUFFIX, img)} into Files → On My iPhone → {app} → Import Here.",
            "Free Apple ID signatures expire after 7 days; renew from the launcher. Saves live in the app on the phone; deleting the app deletes them.",
            "To remove everything: delete the app on the phone, then use “Delete game” in the launcher (or delete this folder).",
        ]
    else:
        body = [
            f"{app} — standalone app (one app, one game, made by S2Arm)",
            "",
            "WHAT THIS IS",
            f"{ipa} is this game’s own iPhone app: it shows up as “{app}” on the Home Screen with the game’s icon and opens straight into the game. It doesn’t affect the S2Arm app; you can have both.",
            "",
            "HOW TO INSTALL (read the part for how you sign)",
            "- " + t["appleId"],
            "- " + t["devCert"].format(ipa=ipa),
            "- " + t["external"].format(ipa=ipa),
            "- " + t["import"].format(app=app, files=files),
        ]
        if img_elsewhere:
            body.append(f"  The game data file couldn’t be placed in this folder (the drive doesn’t support hard links). It is at: {img_elsewhere}")
        body += [
            "",
            "EXPIRY AND RENEWING",
            "Apps signed with a free Apple ID expire after 7 days, with a paid developer account after 1 year, and with a certificate on the profile’s expiry date. "
            "An expired app won’t open; the saves on the phone are kept.",
            "To renew: connect the iPhone and click “Renew” for this game in the “Standalone apps” section of the launcher’s console. If you installed it with AltStore / SideStore, refresh it there.",
            "",
            "WHERE THE SAVES ARE",
            "Saves live in this app on the phone. Each time the launcher installs, updates or renews this game, it copies the phone’s saves to save_backup/ in this folder.",
            "",
            "HOW TO REMOVE EVERYTHING",
            f"1. On the phone: touch and hold “{app}” → Delete App. The game’s saves on the phone are deleted with it.",
            "2. On the computer: “Delete game” in the launcher is the cleanest. It also deletes this game’s program backup in the library’s hidden .programs folder; "
            "if this folder holds save backups, those are kept and everything else is deleted.",
            f"   You can also just delete this folder. The save backups in save_backup/ go with it, so copy them elsewhere first if you want them. A program backup (a few dozen MB) "
            f"stays in the library’s hidden folder .programs/{gid.upper()}; “Delete game” in the launcher removes it.",
        ]
    return "\n".join(body) + "\n"


def write_readme(folder, lang, **kw):
    """写这个文件夹的 README（只留一份：删掉另一种语言那份）。Windows 记事本认 BOM。→ 路径"""
    folder = Path(folder)
    lang = "zh" if lang == "zh" else "en"
    out = folder / README[lang]
    tmp = folder / f".{out.name}.{os.getpid()}.partial"
    tmp.write_text(readme_text(lang, **kw), encoding="utf-8-sig" if os.name == "nt" else "utf-8")
    os.replace(tmp, out)
    for other, name in README.items():
        if other != lang:
            (folder / name).unlink(missing_ok=True)
    return out
