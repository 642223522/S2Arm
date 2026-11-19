#!/bin/bash
# 标准 RomFS 镜像读取（pack/romfs_img.py）与 romfs_list.py 镜像盘点单测外壳：列表 / 按路径读 / 区间 / 流式 / IMG 里的段，期望来自夹具本身（见 tests/romfs_img_test.py 文件头）
# 门禁覆盖：pack/romfs_img.py pack/img.py services/romfs_index/ services/romfs_index.sh services/S2A.Services/RomFsIndex.cs tests/romfs_img_test.py tests/romfs_img_test.sh graphics/nvn/tools/romfs_list.py tests/romfs_list_img_test.py tests/romfs_readers_img_test.py translator/shader_split.py translator/gl_shaders.py translator/mvgl.py translator/mbundle.py tests/romfs_split_gl_img_test.py
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
export DOTNET_ROOT=${DOTNET_ROOT:-$HOME/.dotnet}; export PATH=$DOTNET_ROOT:$PATH
# services/romfs_index 只编一次，下面 4 份脚本经 S2A_ROMFS_INDEX_DLL 共用（各脚本原先各编一遍）；没有 dotnet 或编不过就不设，各脚本照旧自己处理
B=$(mktemp -d); trap 'rm -rf "$B"' EXIT
command -v dotnet > /dev/null && dotnet build "$H/services/romfs_index" -c Release -o "$B/ri" > "$B/build.log" 2>&1 && [ -f "$B/ri/romfs_index.dll" ] \
  && export S2A_ROMFS_INDEX_DLL=$B/ri/romfs_index.dll
python3 "$H/tests/romfs_img_test.py" || exit 1
# 目录不在、旁边有 <目录>.std 时 romfs_list.py 从镜像盘点（11-16），与目录盘点对拍
python3 "$H/tests/romfs_list_img_test.py" || exit 1
# 读内容的读取方（按路径读经 romfs_list.open_file 等）目录形态 vs 镜像形态对拍
python3 "$H/tests/romfs_readers_img_test.py" || exit 1
# 直连抽取（shader_split）与 GL 着色器源（gl_shaders / mvgl）读 RomFS：目录形态 vs 镜像形态对拍
python3 "$H/tests/romfs_split_gl_img_test.py" || exit 1
