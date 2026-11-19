#!/bin/bash
# v0.4.1 补丁包候选一键验收（11-15）：候选一出来一条命令跑完，读日志判，出「期望 → 真结果」表（stdout + <工作目录>/result.md）。任一项红 → 退出码 1。
#   ① Mac：带 60 / 120 两档帧率补丁、开场画面游戏自锁 30 帧的一款，停在标题 120 秒，帧率梯子不降档（日志无「档位梯子：换到 30 帧」、ladder.txt 不写 tier=1）
#      （runtime/src/qladder.c：目标帧时长不低于游戏自设交换间隔）
#   ③ Mac：屏幕最高 120 Hz 时帧率补丁自动档选 120（日志有「帧率档 120 帧（默认」；屏幕不是 120 Hz → 跳过）（cpatch.c s2a_cpatch_screen_changed）
#   ④ Mac：只开着自适应满屏（帧率 / 其余补丁关）时崩溃 → 满屏开关被关、通知记「满屏」（crashed.json fullscreen=true、launch.json widescreen=false）
#      （pack/jobs/cheats.py note_crash）；包里没有自适应满屏补丁 → 跳过
#   ② iPhone：一款带 120 帧补丁的单款壳换成候选壳，补帧按缺省开着、选 120 档进到能操控的场景，帧率约 120（末 3 个读数都 ≥ 110）
#      （nvn_mtl.m mtl_init：补丁要了 120 Hz 显示链就不清）。不给 --ios-ref 就跳过
#
# 用法：
#   bash tools/v041_patch_accept.sh --app <候选 S2Arm.app> --mac-gid <程序号> --mac-src <这款原件所在目录> --work <内置盘上的工作目录>
#        [--keys ~/.switch/prod.keys]
#        [--ios-ref <这款已签好的单款壳 S2Arm.app：取游戏镜像与随包表> --device <s2a_device 选机：1 / 2 / UDID> --team <签名团队>
#         --padrec <容器 Documents 下的开机按键回放文件名，配合事先放好的存档进到能操控的场景>]
#   工作目录要在内置盘：候选 App 从外置卷起时系统会弹「访问可移除宗卷」授权框（只能人点），所以先把 App 拷到工作目录里再起。
#   iPhone 项要求设备上已装着这款单款壳（资源包在机上，只换程序不推资源）、存档与回放文件已放进容器；真机走设备锁（S2A_PRIVATE_TOOLS 里的 devlock.sh）。
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
APP= GID= SRC= WORK= KEYS=$HOME/.switch/prod.keys IREF= DEV= TEAM= PADREC=
while [ $# -gt 0 ]; do case $1 in
  --app) APP=$2; shift 2;; --mac-gid) GID=$(echo "$2" | tr a-f A-F); shift 2;; --mac-src) SRC=$2; shift 2;; --work) WORK=$2; shift 2;; --keys) KEYS=$2; shift 2;;
  --ios-ref) IREF=$2; shift 2;; --device) DEV=$2; shift 2;; --team) TEAM=$2; shift 2;; --padrec) PADREC=$2; shift 2;;
  *) echo "🔴 认不出参数 $1"; exit 2;; esac; done
[ -d "$APP" ] && [ -n "$GID" ] && [ -d "$SRC" ] && [ -n "$WORK" ] || { sed -n 2,22p "$0"; exit 2; }
W=$WORK/run_$(date +%m%d_%H%M%S); mkdir -p "$W" || exit 2
ROWS=(); BAD=0
row() { ROWS+=("| $1 | $2 | $3 | $4 |"); [ "$4" = 红 ] && BAD=1; echo "[$4] $1：$3"; }
finish() {
  { echo "# v0.4.1 补丁包候选验收（$(date '+%F %T')，App $(defaults read "$APP/Contents/Info.plist" S2ABuildID 2>/dev/null)）"; echo
    echo "| 项 | 期望 | 真结果 | 判 |"; echo "|---|---|---|---|"; printf '%s\n' "${ROWS[@]}"; echo; echo "工作目录：$W"; } > "$W/result.md"
  echo; cat "$W/result.md"; exit $BAD
}

# ---- Mac：拷 App 到内置盘工作目录、新数据目录导入出包 ----
ditto "$APP" "$W/S2Arm.app" || { echo "🔴 拷 App 失败"; exit 2; }
D=$W/data; ctl() { "$W/S2Arm.app/Contents/Resources/s2armctl" --data-root "$D" "$@"; }
pkill -f "$W/S2Arm.app/Contents/MacOS/" 2> /dev/null
ctl start "$W/S2Arm.app" > "$W/start.log" && ctl keys "$KEYS" > "$W/keys.log" && ctl games "$SRC" > "$W/games.log" && ctl build "$GID" mac > /dev/null \
  && ctl wait "$GID" --op build --timeout 3600 > "$W/build.log" 2>&1 || { tail -3 "$W/build.log" 2> /dev/null; row "Mac 出包" "出包成功" "失败（${W}）" 红; finish; }
LIB=$D/游戏库; TMPG=$LIB/temp/$GID
GDIR=$(grep -l "\"$GID\"" "$LIB"/games/*/game.json 2> /dev/null | head -1); GDIR=${GDIR%/game.json}
[ -d "$GDIR" ] || { row "Mac 出包" "游戏文件夹在" "找不到 $GID 的文件夹" 红; finish; }
host_pid() { pgrep -f "$LIB/hosts/mac/" | head -1; }
newest_log() { ls -t "$D"/logs/*-game.log 2> /dev/null | head -1; }
stop_game() { local p; p=$(host_pid); [ -n "$p" ] && kill -TERM "$p"; for _ in $(seq 20); do [ -z "$(host_pid)" ] && return; sleep 1; done; p=$(host_pid); [ -n "$p" ] && kill -KILL "$p"; }

# ---- ① + ③：停在标题 125 秒 ----
rm -f "$TMPG/ladder.txt"
ctl launch "$GID" > /dev/null; sleep 125; L=$(newest_log); stop_game; sleep 3
if grep -aq "档位梯子：三档" "$L"; then
  down=$(grep -a "档位梯子：换到 30 帧" "$L" | head -1 | cut -c1-90); lt=$(cat "$TMPG/ladder.txt" 2> /dev/null)
  if [ -z "$down" ] && ! grep -q "tier=1" <<< "$lt"; then row "① 标题自锁 30 帧不降档" "无「换到 30 帧」、ladder.txt 不是 tier=1" "没降档；ladder.txt：${lt:-（没写）}" 绿
  else row "① 标题自锁 30 帧不降档" "无「换到 30 帧」、ladder.txt 不是 tier=1" "${down:-没降档}；ladder.txt：${lt:-（没写）}" 红; fi
else row "① 标题自锁 30 帧不降档" "梯子跑三档（这款靠帧率补丁）" "日志里没有「档位梯子：三档」，这款不适合本项（${L}）" 跳过; fi
hz=$(grep -aoE "窗口所在屏最高刷新 [0-9]+ Hz" "$L" | tail -1 | grep -oE "[0-9]+")
if [ "${hz:-0}" -ge 120 ]; then
  pick=$(grep -a "帧率档 [0-9]* 帧（默认" "$L" | tail -1 | grep -oE "帧率档 [0-9]+ 帧")
  if grep -aq "帧率档 120 帧（默认" "$L"; then row "③ 120 Hz 屏自动档" "自动档选 120" "屏幕 ${hz} Hz，自动档 120" 绿
  else row "③ 120 Hz 屏自动档" "自动档选 120" "屏幕 ${hz} Hz，自动档：${pick:-没有自动档行}" 红; fi
else row "③ 120 Hz 屏自动档" "屏幕 120 Hz 时自动档选 120" "本机屏幕 ${hz:-?} Hz，判不了" 跳过; fi

# ---- ④：只开着自适应满屏时崩溃 ----
TSV=$LIB/games/$(basename "$GDIR")/image/mac/cpatch.tsv
if grep -q "^wsauto:" "$TSV" 2> /dev/null; then
  rm -f "$GDIR/cheats/crashed.json" "$GDIR/cheats/good.json" "$GDIR/cheats/enabled.txt"
  python3 - "$TSV" "$GDIR/launch.json" << 'PY' || { row "④ 崩溃关满屏" "准备只开满屏" "写 launch.json 失败" 红; finish; }
import csv, json, sys
ids = {r["编号"] for r in csv.DictReader(open(sys.argv[1], encoding="utf-8"), delimiter="\t") if r.get("编号") and not r["编号"].startswith(("fps:", "cheat:", "wsauto:"))}
ids |= {"widescreen:auto"} if any(i.startswith("widescreen:") for i in ids) else set()
json.dump({"schema": 1, "settings": {"fps60": False}, "patches": {i: False for i in sorted(ids)}}, open(sys.argv[2], "w"), ensure_ascii=False)
PY
  ctl launch "$GID" > /dev/null; sleep 45; p=$(host_pid)
  if [ -z "$p" ]; then row "④ 崩溃关满屏" "起局后发崩溃信号" "45 秒时游戏进程不在" 红; else
    kill -SEGV "$p"; for _ in $(seq 30); do [ -f "$GDIR/cheats/crashed.json" ] && break; sleep 1; done; sleep 2
    got=$(python3 -c "import json,sys
c=json.load(open(sys.argv[1])) if __import__('os').path.exists(sys.argv[1]) else {}
l=json.load(open(sys.argv[2]))
print(f\"crashed.json fullscreen={c.get('fullscreen')}，launch.json widescreen={l.get('settings',{}).get('widescreen')}\")" "$GDIR/cheats/crashed.json" "$GDIR/launch.json")
    if grep -q "fullscreen=True，launch.json widescreen=False" <<< "$got"; then row "④ 崩溃关满屏" "crashed.json fullscreen=True、满屏开关写关" "$got" 绿
    else row "④ 崩溃关满屏" "crashed.json fullscreen=True、满屏开关写关" "$got" 红; fi
  fi
else row "④ 崩溃关满屏" "包里有自适应满屏补丁" "cpatch.tsv 里没有 wsauto: 行，这款不适合本项" 跳过; fi
pkill -f "$W/S2Arm.app/Contents/MacOS/" 2> /dev/null

# ---- ②：iPhone 120 档开补帧 ----
if [ -n "$IREF" ]; then
  [ -n "$DEV" ] && [ -n "$TEAM" ] && [ -n "$PADREC" ] || { row "② iPhone 120 档开补帧" "参数齐" "--ios-ref 要配 --device / --team / --padrec" 红; finish; }
  SH=$W/S2Arm.app/Contents/Resources/Shell; E=$W/S2Arm.app/Contents/Resources/Engine; A=$W/ios/Payload/S2Arm.app
  mkdir -p "$W/ios/Payload" && ditto "$SH/root" "$A" && cp "$IREF"/AppIcon*.png "$IREF"/*.tsv "$IREF/main.npdm" "$A/" && cp "$IREF/Frameworks/S2AImages.dylib" "$A/Frameworks/" \
    && cp "$IREF/Info.plist" "$A/Info.plist" || { row "② iPhone 120 档开补帧" "候选壳 + 游戏镜像组成包" "组包失败" 红; finish; }
  plutil -replace S2ACommit -string "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['details']['sourceCommit'])" "$SH/manifest.json")" "$A/Info.plist"
  BID=$(plutil -extract CFBundleIdentifier raw "$A/Info.plist")
  (cd "$W/ios" && python3 "$E/pack/dev_sign.py" Payload/S2Arm.app "$BID" "$TEAM" "$E/pack/app.entitlements" > sign.log 2>&1) || { row "② iPhone 120 档开补帧" "签名" "签名失败（$W/ios/sign.log）" 红; finish; }
  source "$H/tools/devices.sh" && s2a_device "$DEV" || { row "② iPhone 120 档开补帧" "选到设备" "s2a_device $DEV 失败" 红; finish; }
  if [ -n "${S2A_PRIVATE_TOOLS:-}" ] && [ -f "$S2A_PRIVATE_TOOLS/devlock.sh" ]; then source "$S2A_PRIVATE_TOOLS/devlock.sh"; devlock_acquire "v0.4.1 补丁包验收" 900 || { row "② iPhone 120 档开补帧" "取设备锁" "取锁失败" 红; finish; }; trap devlock_release EXIT; fi
  U=$SW_DEVICE; DC="xcrun devicectl"
  $DC device install app --device "$U" "$A" > "$W/ios/install.log" 2>&1 || { row "② iPhone 120 档开补帧" "装上" "装机失败（$W/ios/install.log）" 红; finish; }
  $DC device process launch --device "$U" --terminate-existing --json-output "$W/ios/launch.json" \
    --environment-variables "{\"S2A_FPS60\":\"1\",\"S2A_FPS_PICK\":\"120\",\"S2A_AUTOPLAY\":\"1\",\"S2A_AP_PADREC_BOOT\":\"$PADREC\",\"S2A_DEV_FACILITIES\":\"1\",\"S2A_GUEST_FILE\":\"0\"}" "$BID" > "$W/ios/launch.log" 2>&1 \
    || { row "② iPhone 120 档开补帧" "起局" "起局失败" 红; finish; }
  sleep 170
  $DC device copy from --device "$U" --domain-type appDataContainer --domain-identifier "$BID" --source Documents/host.log --destination "$W/ios/host.log" > /dev/null 2>&1
  pid=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['result']['process']['processIdentifier'])" "$W/ios/launch.json" 2> /dev/null)
  [ -n "$pid" ] && $DC device process signal --device "$U" --pid "$pid" --signal SIGTERM > /dev/null 2>&1
  fi_on=$(grep -ac "present frame interpolation: on" "$W/ios/host.log" 2> /dev/null)
  fps=$(grep -a "power up to frame" "$W/ios/host.log" 2> /dev/null | tail -3 | grep -oE "\([0-9.]+ fps\)" | grep -oE "[0-9.]+" | tr '\n' ' ')
  if [ "${fi_on:-0}" -lt 1 ]; then row "② iPhone 120 档开补帧" "补帧开着时约 120 帧" "这局补帧没开（日志没有「present frame interpolation: on」），判不了" 跳过
  elif [ -n "$fps" ] && python3 -c "import sys;v=[float(x) for x in sys.argv[1].split()];sys.exit(0 if len(v)==3 and min(v)>=110 else 1)" "$fps"; then row "② iPhone 120 档开补帧" "补帧开、末 3 个读数 ≥ 110 帧" "${fps}帧" 绿
  else row "② iPhone 120 档开补帧" "补帧开、末 3 个读数 ≥ 110 帧" "${fps:-没有读数}帧" 红; fi
else row "② iPhone 120 档开补帧" "约 120 帧" "没给 --ios-ref，没跑" 跳过; fi
finish
