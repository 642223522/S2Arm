#!/bin/bash
# 单一 IMG v1（pack/img.py + services/romfs_index --std）单测外壳：头 / 目录表 / 标准 RomFS 段（独立解析）/ write / convert，期望来自夹具本身（见 tests/img_test.py 文件头）
# 门禁覆盖：pack/img.py pack/romfs_img.py services/romfs_index/ services/romfs_index.sh services/S2A.Services/RomFsIndex.cs tests/img_test.py tests/img_test.sh tests/img_spec_load_test.py pack/jobs/sgrade_bf.py
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
export DOTNET_ROOT=${DOTNET_ROOT:-$HOME/.dotnet}; export PATH=$DOTNET_ROOT:$PATH
python3 "$H/tests/img_spec_load_test.py" || exit 1   # 作业层按文件路径加载 img.py 时找得到同目录的 romfs_img（11-16）
python3 "$H/tests/img_test.py"
