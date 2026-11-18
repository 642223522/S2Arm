# 直连图形层的剖析数据（`nvn.prof.txt`）

`graphics/nvn/Makefile` 编 `libnvn.a`（Mac `-O2`、iOS `-Os`）时带 `-fprofile-instr-use`：clang 按录下的回放里每个分支 / 调用跑了多少次来排代码布局、定内联。
源码一行不改；没有这个文件时就是原来的编法。

- **只有计数**：文件里是函数名、源码指纹（哈希）和计数，没有游戏数据（录像本身不进仓库）。
- **文本格式入仓**（后缀 `.txt`：公开仓扫描按后缀读正文，`.proftext` 不认、只告警不扫）：二进制 `.profdata` 的格式版本跟 clang 走，旧 Xcode 读新版本会编译报错；构建时用本机的 `xcrun llvm-profdata merge` 转成二进制（`build/nvn/pgo/`）。
- **过期不出错**：源码改过、指纹对不上的函数 clang 按无剖析编（告警已用 `-Wno-profile-instr-out-of-date` 等关掉），只少拿这部分收益。
- **Mac 录、iOS 也用**：同为 arm64，iOS 的 `-Os` 编译照样按函数指纹对上；11-16 核对 26 个源文件，Mac 0 个函数对不上，iOS 11 个（iOS 专有分支，`nvn_mtl.m` 6、`nvn2_codec.c` 3、`host_adapt.m` 2），其余照用。
- **门禁不跑录制**：日常构建只读这个文件；回放层热路径（每笔绘制走的函数）改动较大后手动重录一次、和改动一起提交。

重录（录像与产物根同 `tools/frame_replay.sh`，可以给多份录像）：

    bash tools/pgo_record.sh <款> <录像目录> [<款> <录像目录> …]

看过期了多少：在 `graphics/nvn` 下 `make -B mac` 前临时去掉 `-Wno-profile-instr-out-of-date`，clang 打印「of N functions, M have mismatched data」。
