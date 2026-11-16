# 鸿蒙音频输出层（待提交）

复用 android/native/pcm_ring.c，鸿蒙仅提供 OHAudio 输出、回调与控制线程边界。它独立于旧/新图形后端，不携带游戏数据或签名材料。

## 构建

使用官方 OHOS native SDK 的 CMake toolchain：

```sh
cmake -S ohos/audio -B <build> -G Ninja -DCMAKE_TOOLCHAIN_FILE=<native-sdk>/build/cmake/ohos.toolchain.cmake -DOHOS_ARCH=arm64-v8a -DCMAKE_BUILD_TYPE=Release
cmake --build <build>
```

产物 libs2arm_ohaudio.a；最终引擎须链接 ohaudio。一个串行控制线程负责 open/start/pause/service/stats/close；单生产者写PCM、系统实时回调消费。不得在回调中进入托管服务、分配或重开音频流。

## 本次验证范围

- OHOS Clang15/API26交叉编译通过；whole-archive链接到临时共享库，--no-undefined通过。
- 主机可执行合成PCM测试：`cc -std=c11 -Wall -Wextra -Werror ohos/audio/test_pcm_output.c ohos/audio/pcm_output.c android/native/pcm_ring.c -o <test>`，运行通过。
- 覆盖逻辑容量、20次环绕、短尾包最多等待40ms回调时间、静音填充、reset后恢复。
- 负对照只把40ms上限改成1秒，同用例在第五次回调的样本断言失败。
- 未连接设备；没有验证声音、焦点/路由、蓝牙、实时并发、断流重建与托管会话。编译/合成样本测试不等于音频完整可用。
- 本批仅本地准备，不含运行时服务接入；提交前仍需补完整贡献检查和回调生命周期用例。
