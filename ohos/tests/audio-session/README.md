# OHAudio Session 主机回归

运行 `python ohos/tests/audio-session/run.py`。

依赖只有两样：

- Python 3（只用标准库）；
- .NET 10 SDK（`dotnet` 在 PATH 上，或用 `--dotnet` 指定）。

不需要鸿蒙 SDK / DevEco / NDK / hdc，不需要设备或模拟器，不构建 native/AOT/HAP。没有 NuGet 包引用，`NuGet.Config` 清空了源，不联网。可直接挂进安卓、鸿蒙的宿主用例。

测试原样链接产品 `OHAudioHardwareDeviceSession.cs`，以及实际 `AudioSampleQueue`、`DynamicRingBuffer`、音频基类、PCM 计数和内存池源码。只有 OHAudio 设备 API、driver 回调和虚拟内存边界使用明确的测试替身。本测试不能证明设备声音、原生 OHAudio 返回值或实时性能。

- `pause`：设备替身返回 Pause -5；断言第一次 Dispose 仍停止 feeder、调用 close、清空 sink、注销 session，同时向调用者报告原错误，二次 Dispose 不重复释放。
- `publication`：测试持有真实 writer/queue 锁，把 QueueBuffer 生产线程停在记账边界；断言样本不可早于记录可见。解锁后由实际 feeder 计数并归还全部 480 帧，重复 16 次。
- 两个负例只在构建输出目录生成 Session 的临时副本，分别恢复修复前的 Pause 异常顺序和样本提前发布顺序；必须编译通过、测试退出 1 并出现对应失败标记，才算检出旧缺陷。产品源码不改。

`--build-root` 可指定构建目录，`--evidence` 可指定日志与 manifest 目录。清单记录全部编译/执行命令、退出码、源文件和日志 SHA256。默认所有生成文件在仓库忽略的 `build/ohos/audio-session-tests/`。

已验证：2026-11-19，Windows 11 + .NET SDK 10.0.401 + Python 3.14，PATH 只留 dotnet、Python、System32（无 DevEco/hdc/鸿蒙 SDK 环境变量），全新 `--build-root`：退出 0，约 8 s；actual 2/2 通过，两个负例各自失败检出。Linux/macOS 未跑。

与安卓托管 Session 的逐函数差异和共用抽取方案见 [SESSION_DIFF.md](SESSION_DIFF.md)。
