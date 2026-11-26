#!/bin/bash
# 出包·共享·RomFS 预建索引阶段（J07 #183）：pack/stages/romfsidx.sh <款>
# 与目标无关：产物是产物根顶层的 romfs.s2aidx（与 exefs/ romfs/ ctl/ 并列），路径里不含 ios / android / ohos；
#   索引格式由服务层同一份 C# 读写，各目标插件只是把它放进自己的资源包。
# 实现搬自 pack/stage_romfsidx.sh（对外命令行与行为不变，旧入口只剩一层转发）。
# 用服务接入线的 services/romfs_index.sh 在新版本产物根顶层生成 romfs.s2aidx（起局直接读，不再枚举 romfs/ 现建目录表：iPhone S2A_Init 的大头，10-19 实测 2666 ms）。
# romfs/ 一变就要重出：缓存键 = romfs 文件清单（路径 + 字节数）哈希 + 索引格式的写法，
#   写法只认真正决定索引字节的文件：services/S2A.Services/RomFsIndex.cs（格式与读方同一份）、services/romfs_index/、services/romfs_index.sh、LibHac 版本（compat/tree/Directory.Packages.props）
#   （10-20 回归提速：原来键是整棵 services/ 树，任何服务改动都让分支私有根重出索引）
#   文件内容不进键：索引只记路径 / 字节数 / 偏移，同一份清单生成的索引字节相同，与文件内容无关。
#   目标名 / ABI / 工具链环境变量不进键：索引是纯数据，读方各端同一份。
# 所以排在会改 romfs 的阶段（宽屏界面布局）之后。与现行 .stage_romfsidx 相同就跳过。
set -u
G=${1:?款}; H=$(cd "$(dirname "$0")/.." && pwd); R=$(cd "$H/.." && pwd); source "$H/roots.sh"; source "$H/stage_keyfiles.sh"; stage_deps_on || exit 1; SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")   # 实际读入进键（pack/stage_keyfiles.sh）
CUR=$(root_cur "$G"); [ -n "$CUR" ] && { [ -d "$CUR/romfs" ] || [ -f "$CUR/romfs.std" ]; } || { echo "【红】$G 现行产物根没有 romfs/（或镜像 romfs.std）"; exit 1; }   # RomFS 目录或镜像都行（romfs_list.py image_of）
OI=$(romfs_writer_oids "$R"); KT=$(printf '%s\n' "$OI" | shasum -a 256 | cut -c1-16) \
  && [ "$(printf '%s\n' "$OI" | grep -c .)" = 4 ] \
  || { echo "【红】取不到索引写法文件的对象号（RomFsIndex.cs / romfs_index / romfs_index.sh / Directory.Packages.props，改过名就同笔改这里）"; exit 1; }
# RomFS 遍历经 graphics/nvn/tools/romfs_list.py（仓库里唯一的 RomFS 遍历，walk 同 os.walk）
# 界面布局覆盖层 ui_overlay/romfs/（pack/stage_uilayout.sh，同 Windows pack/orch/stages.py _uilayout）：读方覆盖层优先，键与清单里覆盖文件取覆盖层那份的大小，
#   与原先「就地改 romfs/」读到的清单逐行相同（没有覆盖层的版本键不变）
OVL='import os
def overlay(o):
    """覆盖层 → {RomFS 相对路径（/ 分隔）: 字节数}；没有覆盖层 → 空"""
    if os.path.islink(o) or not os.path.isdir(o): return {}
    return {e.rel: e.lstat.st_size for e in romfs_list.scan(o).files()}'
KR=$(python3 - "$CUR/romfs" "$R" "$CUR/ui_overlay/romfs" "$OVL" <<'PY'
import hashlib, os, sys
sys.path.insert(0, os.path.join(sys.argv[2], 'graphics', 'nvn', 'tools'))
import romfs_list
exec(sys.argv[4]); over = overlay(sys.argv[3])
h = hashlib.sha256(); r = sys.argv[1]
for d, ds, fs in romfs_list.walk(r):
    ds.sort()
    for f in sorted(fs):
        p = os.path.join(d, f); q = os.path.relpath(p, r)
        h.update(f'{q}\t{over.get(q.replace(os.sep, "/"), romfs_list.file_size(p))}\n'.encode())   # file_size：目录形态同 os.path.getsize，镜像形态（romfs.std）从镜像取长度
print(h.hexdigest()[:16])
PY
) && [ -n "$KR" ] || { echo "【红】$G 盘点 RomFS 算索引键失败（${CUR}/romfs 或 romfs.std）"; exit 1; }
K=$(printf '%s %s' "$KR" "$KT" | shasum -a 256 | cut -c1-16)
KB=$K; K=$(stage_deps_key "$CUR" romfsidx "$KB" "$SELF") || exit 1
root_stage_done "$CUR" romfsidx "$K" && { echo "🟢 $G 现行已是 RomFS 索引 ${K}，跳过"; exit 0; }
TAG=$(root_tag "$G" "rx-${K:0:8}"); W=$(root_begin "$G" "$TAG") || exit 1
rm -f "$W/romfs.s2aidx"; t0=$SECONDS
# 文件清单（相对路径 + 字节数）由 graphics/nvn/tools/romfs_list.py 盘点交给索引器（仓库里唯一的 RomFS 遍历；索引器不再自己枚举、逐个打开取长度）；清单放产物根外的临时文件
RL=$(mktemp "${TMPDIR:-/tmp}/romfsidx.XXXXXX") || { root_abort "$G" "$TAG"; exit 1; }
python3 "$R/graphics/nvn/tools/romfs_list.py" sizes "$W/romfs" "$RL" > "$W/romfs_index.log" 2>&1 \
  && python3 -c 'import os, sys
sys.path.insert(0, os.path.join(sys.argv[2], "graphics", "nvn", "tools")); import romfs_list
exec(sys.argv[4]); over = overlay(sys.argv[3])
if over:   # 覆盖层优先：索引只认路径与大小，覆盖文件换成覆盖层那份的大小（同 Windows pack/orch/stages.py _romfsidx）；覆盖层只许替换
    rows = [l.split("\t", 1) for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if "\t" in l]
    extra = sorted(set(over) - {r for _, r in rows})
    if extra: sys.exit(f"界面布局覆盖层有底下 RomFS 没有的文件（{extra[:3]}）：覆盖层只许替换")
    open(sys.argv[1], "w", encoding="utf-8", newline="\n").write("".join(f"{over.get(r, n)}\t{r}\n" for n, r in rows))' "$RL" "$R" "$W/ui_overlay/romfs" "$OVL" >> "$W/romfs_index.log" 2>&1 \
  && bash "$R/services/romfs_index.sh" "$W" --list "$RL" >> "$W/romfs_index.log" 2>&1 && [ -s "$W/romfs.s2aidx" ] || { rm -f "$RL"; echo "【红】$G RomFS 索引生成失败（$(tail -1 "$W/romfs_index.log")）"; root_abort "$G" "$TAG"; exit 1; }
rm -f "$RL"
K=$(stage_deps_save "$W" romfsidx "$KB" "$SELF") || { root_abort "$G" "$TAG"; exit 1; }; echo "$K" > "$W/.stage_romfsidx"
# 与直连链并行（refresh.sh 快路，11-06）：本阶段只写这些，提交时现行被别的阶段改过就重放到新现行
ROOT_REPLAY='romfs.s2aidx romfs_index.log .stage_romfsidx .stage_romfsidx.deps' root_commit "$G" "$TAG" || exit 1
echo "🟢 $G RomFS 索引 $(du -h "$(root_cur "$G")/romfs.s2aidx" | cut -f1)（$((SECONDS - t0)) 秒），现行 → $(basename "$(root_cur "$G")")"
