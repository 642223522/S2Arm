# OHAudio Session 主机回归

运行 `python ohos/tests/audio-session/run.py`，需本机 .NET 10 SDK。没有 NuGet 依赖，源列表为空；不联网、不构建 native/AOT/HAP、不操作设备。

测试原样链接产品 `OHAudioHardwareDeviceSession.cs`，以及实际 `AudioSampleQueue`、`DynamicRingBuffer`、音频基类、PCM 计数和内存池源码。只有 OHAudio 设备 API、driver 回调和虚拟内存边界使用明确的测试替身。本测试不能证明设备声音、原生 OHAudio 返回值或实时性能。

- `pause`：设备替身返回 Pause -5；断言第一次 Dispose 仍停止 feeder、调用 close、清空 sink、注销 session，同时向调用者报告原错误，二次 Dispose 不重复释放。
- `publication`：测试持有真实 writer/queue 锁，把 QueueBuffer 生产线程停在记账边界；断言样本不可早于记录可见。解锁后由实际 feeder 计数并归还全部 480 帧，重复 16 次。
- 两个负例只在构建输出目录生成 Session 的临时副本，分别恢复修复前的 Pause 异常顺序和样本提前发布顺序；必须编译通过、测试退出 1 并出现对应失败标记，才算检出旧缺陷。产品源码不改。

`--build-root` 可指定构建目录，`--evidence` 可指定日志与 manifest 目录。清单记录全部编译/执行命令、退出码、源文件和日志 SHA256。默认所有生成文件在仓库忽略的 `build/ohos/audio-session-tests/`。
