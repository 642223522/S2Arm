#!/bin/bash
# pack/ns2_nup.py 单测（tests/ns2_nup_test.py：按 NUP v1 规格拼合成容器，期望值是写进去的内容本身）+ 核 pack/oneclick/oneclick.sh 接 NUP 的那段：
#   源是 .nup 文件或文件夹里恰有一个 .nup → pack/ns2_nup.py 展开成导出目录 → 交 pack/ns2_dump.py
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PYTHON:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
# ⑪ 镜像形态要真 nx_unpack（--romfs-image）与 services/romfs_index.sh（旧路径建镜像，当参照）；构建产物放 <仓库根>/build/ns2_nup_test
export DOTNET_ROOT=${DOTNET_ROOT:-$HOME/.dotnet}; export PATH=$DOTNET_ROOT:$PATH
OUT=$H/build/ns2_nup_test; mkdir -p "$OUT"; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
timeout 500 dotnet build "$H/pack/nx_unpack/nx_unpack.csproj" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; echo "✗ nx_unpack 编译（期望编过）"; exit 1; }
NXD=$(find "$OUT/art/bin" -name nx_unpack.dll | head -1); [ -n "$NXD" ] || { echo "✗ 没找到 nx_unpack.dll"; exit 1; }
printf '#!/bin/bash\nexec dotnet "%s" "$@"\n' "$NXD" > "$T/nxu"; chmod +x "$T/nxu"
# ⑪ 的参照只用 romfs_index 的产物；构建一次到本测试自己的 artifacts，避免每个用例经 services/romfs_index.sh 重复 build、并行时互等锁。
RIOUT=$OUT/ri
RIB=(dotnet build "$H/services/romfs_index" -c Release -o "$RIOUT" -v quiet -nologo)
[ -f "$H/services/romfs_index/obj/project.assets.json" ] && RIB+=(--no-restore)   # 有本地 assets 就不走 restore（门禁/本机离线时 restore 会等源）
timeout 500 "${RIB[@]}" >> "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; echo "✗ romfs_index 编译（期望编过）"; exit 1; }
RID=$RIOUT/romfs_index.dll; [ -s "$RID" ] || { echo "✗ 没找到 romfs_index.dll"; exit 1; }
printf '#!/bin/bash\nexec dotnet "%s" "$@"\n' "$RID" > "$T/ri"; chmod +x "$T/ri"
# ①–⑩ 按目录形态（romfs/ 散文件）写期望：显式 S2A_ROMFS_IMAGE=0；缺省（镜像形态）见 ⑪
S2A_ROMFS_IMAGE=0 S2A_TEST_NXU=$T/nxu S2A_TEST_ROMFS_INDEX=$T/ri "$PY" "$H/tests/ns2_nup_test.py"; r=$?
grep -q '"$PY" "$P/ns2_nup.py" "$NUPF" "$B/ns2_dump/$ND"' "$H/pack/oneclick/oneclick.sh" \
  && grep -q 'NS2D=$B/ns2_dump/$ND' "$H/pack/oneclick/oneclick.sh" || { echo "✗ oneclick.sh 没接 ns2_nup.py"; r=1; }
[ $r = 0 ] && echo "✓ t_ns2_nup"
exit $r
