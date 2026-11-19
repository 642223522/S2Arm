# 安卓 / 鸿蒙托管音频 Session 差异清单

对照对象（当前 main + 本 PR）：

| 鸿蒙 | 安卓 |
|---|---|
| `ohos/cs/audio/OHAudioHardwareDeviceSession.cs`（366 行） | `android/cs/audio/AAudioHardwareDeviceSession.cs`（343 行） |
| `ohos/cs/audio/OHAudioHardwareDeviceDriver.cs`（64 行） | `android/cs/audio/AAudioHardwareDeviceDriver.cs`（66 行） |
| `ohos/cs/audio/OHAudioSink.cs`（39 行） | `android/cs/audio/AAudioSink.cs`（36 行） |
| `ohos/audio/ohaudio_sink.c` + `pcm_output.c` | `android/native/aaudio_sink.c` |
| 共用：`android/native/pcm_ring.c`（直接引用，不复制） | 同左 |

结论：鸿蒙 Session 是安卓 Session 的分叉。把 `AAudio`/`OHAudio` 统一改名后逐行比较，安卓 343 行里有 337 行原样出现在鸿蒙版；鸿蒙删了 6 行、加了 29 行，全部属于下文「行为差异」。苹果 Session（`compat/tree/src/Ryujinx.Audio.Backends.Apple/AppleHardwareDeviceSession.cs`）里还有第三份同样的队列记账。

## 1. 托管 Session：逐函数

| 函数 / 区段 | 关系 | 差在哪 |
|---|---|---|
| 常量 `RingMilliseconds`/`ArmedTimeout`/`IdleTimeout`、全部字段 | 相同 | — |
| 构造函数 | 相同 | 只有 P/Invoke 名、线程名、异常文字不同 |
| `Wakeups`、`GetStats` | 相同 | `Stats` 结构布局相同，字段含义见第 3 节 |
| `Arm` | 代码相同 | `ringFrames = RingMilliseconds * rate / 1000`。鸿蒙 `space` 经 `pcm_output` 限在逻辑容量内，与此式一致；安卓 `space` 是 2 的幂物理容量（48 kHz 立体声 i16：65536 帧 ≈ 1.37 s），两者不一致；该分支只在托管侧还有样本等环空间（环刚写满）时进入，实际影响小 |
| `ProcessPlayedSamples` | 相同 | — |
| `GetPlayedSampleCount`、`Get/SetVolume`、`WasBufferFullyConsumed`、`PrepareToClose`、`UnregisterBuffer` | 相同 | — |
| `FeedLoop` | 鸿蒙多一层 | 鸿蒙包 `try/catch`，异常经 `driver.Fail` 上报；service 后读 `last_error`，非 0 即抛 |
| `FeedLocked` | 鸿蒙更严 | 鸿蒙环写入短于请求即抛；安卓忽略返回值 |
| `QueueBuffer` | **顺序不同** | 鸿蒙在 `_queueLock` 内先登记 `(id, 样本数)` 再 `_samples.Enqueue`（苹果 11-02 起也是先登记后 Enqueue）；安卓先 `Enqueue` 再登记。安卓的窗口：feeder 在登记前把样本送进环、回调播完、`ProcessPlayedSamples` 时 `_queuedCount == 0`，这些已播样本被丢弃，该缓冲永远凑不满、不归还。窗口很窄，需要 GC 等停顿配合；本 PR 的 `publication` 负例对鸿蒙旧顺序能稳定检出 |
| `Start` / `Stop` | 鸿蒙检查返回值 | 鸿蒙原生 start/pause 返回非 0 即抛；安卓忽略（安卓原生在后台时 start 返回 OK 并延后） |
| `Check` | 仅鸿蒙 | 统一抛 `InvalidOperationException` |
| `Dispose` | 鸿蒙更严 | 鸿蒙 `Stop` 抛错时仍唤醒并 join feeder、close sink、注销，最后再抛原错误；安卓 `Stop` 抛错会跳过 close（目前安卓 `Stop` 不抛，所以只是潜在问题） |

## 2. Driver / P/Invoke

| 项 | 关系 | 差在哪 |
|---|---|---|
| `OpenDeviceSession`、`Supports*`、事件、会话表 | 相同 | — |
| 构造 | 平台差异 | 鸿蒙必须传 `Action<Exception> fatal`，feeder 失败经它交给宿主；安卓无参 |
| `Dispose` 幂等 | 安卓有、鸿蒙缺 | 安卓用 `_disposed` 防 `Host.DisposeAudioForShutdown` 后 `Switch.Dispose` 的二次调用。鸿蒙二次调用时 session 自身有 `_closing` 防护、`ManualResetEvent` 重复 Dispose 无害；但某个 session `Dispose` 抛错会中断循环，后面的 session 和 `_pauseEvent` 不再释放 |
| `*Sink.cs` | 几乎相同 | 库名 `s2arm_android` / `s2a_native`；鸿蒙多 `s2a_ohaudio_last_error` |

## 3. 原生层：只能平台各自实现的部分

| 能力 | 安卓（AAudio） | 鸿蒙（OHAudio） |
|---|---|---|
| 打开流 | LOW_LATENCY + EXCLUSIVE（退回 shared），USAGE_GAME；格式/采样率/声道不符即失败；设备缓冲设为 2 个 burst；经 `s2a_capacity_call_wide`（线程亲和辅助）打开 | FAST 延迟模式，USAGE_GAME；格式/采样率/声道/回调帧数不符即失败；FAST 能建但 Start 报 `ILLEGAL_STATE` 时同格式重建一次 NORMAL |
| 焦点来源 | 全进程开关：Java `AudioFocusPolicy` → `s2a_aaudio_set_output_allowed`，前后台 → `s2a_aaudio_set_foreground` | 每条流的 interrupt 回调：PAUSE/RESUME/STOP/DUCK/UNDUCK/MUTE/UNMUTE |
| **失焦时环是否继续消耗** | 前台失焦：照常读环、输出置零，`frames_out` 前进，缓冲按时归还（`android/tests/audio-focus-managed` 守这条）；后台：不读环 | PAUSE/STOP：回调只填静音不读环，控制线程随后 Pause/Stop 渲染器；`frames_out` 停住，缓冲在恢复前不归还 |
| 闪避 / 静音 | 无（系统处理） | 共享型 DUCK ×0.2、MUTE 置 0；强制型由系统完成，不重复 |
| 路由变化 | 不单独处理；断开走 `DISCONNECTED` | `OutputDeviceChange` 回调：重置预缓冲 + 在控制线程刷新状态与 burst |
| 断流重建 | error 回调仅认 `DISCONNECTED` → service 里 close + 重开，后台时延后 | 任何 error 回调 → `reopen_pending` → service 里 Release + 重建，失败留待下次 |
| 错误回报 | 打 logcat，托管侧看不到 | `last_error` 原子量，托管 feeder 读到即失败上报 |
| 预缓冲 / 尾包 | 无，环空即补静音 | `pcm_output`：断流后攒 20 ms，最多压 40 ms 回调时间放行尾包 |
| 统计 | `buffer_frames`、`sharing` 有效 | `buffer_frames = 0`、`sharing = -1`（无对应概念） |
| close | 摘链表、Stop + Close，释放 | Release 失败时保留内存和 fd 到进程退出，避免回调访问已释放内存 |

## 4. 能共用的面与建议

本轮**不抽取**。原因：

1. 抽取后两端只能有一种 `QueueBuffer` 顺序。用鸿蒙/苹果的顺序会改变安卓行为，做不到安卓字节不变；保留安卓顺序则把上面的竞态带进共用代码。
2. 安卓的回归（`tests/android_audio_focus_test.sh`：`cc -shared` + eventfd/poll 的假 AAudio + 托管 Session）只能在 Linux/macOS 跑，本机 Windows 跑不了，改安卓代码没有可执行的验证。
3. 合适的落点 `compat/tree/src/Ryujinx.Audio/Backends/Common/`（`AudioSampleQueue` 所在）同时被苹果后端用，影响三端。

建议的抽取方案（单独一片，安卓/苹果维护方各自确认）：

- **第一步：队列记账**。新增 `Ryujinx.Audio/Backends/Common/QueuedBufferLedger.cs`，只含纯记账、无平台调用：
  - `bool Register(ulong id, ulong sampleCount, Action publish)`：在锁内登记，登记后调用 `publish`（即 `_samples.Enqueue`），返回登记前是否为空；容量满时翻倍。
  - `bool Consume(ulong samples)`：按队首扣减，返回是否有缓冲播完（调用方据此 `Set` 更新事件）；内部累计已播样本。
  - `ulong HeadRemaining(out bool any)`：给 `Arm` 计算唤醒点。
  - `bool IsConsumed(ulong id)`、`ulong PlayedSampleCount`。
  三端 Session 改为持有它。安卓顺序随之改为先登记，属行为修正，需在 Linux 上跑 `tests/android_audio_focus_test.sh` 和安卓自测入口 `s2a_android_audio_selftest` 后再合。
- **第二步（可选）：feeder 骨架**。`FeedLoop`/`Arm`/`FeedLocked`/`Start`/`Stop`/`Dispose` 两端只差错误处理，可做成 `RingFedOutputSession<TSink> where TSink : struct, IRingSink`（`Wait/Service/Space/Write/NotifyAt/Wake/FramesOut/SetVolume/Start/Pause/Close/LastError`），用 struct 泛型避免接口派发；苹果不走环，不参与。此步之前先定第 3 节「失焦时是否继续消耗」的统一口径。
- 留在平台侧：第 3 节全部（打开参数、焦点、路由、重建、预缓冲、统计、close 语义）。

## 5. 需要维护方定的差异

- 失焦时鸿蒙不消耗环、缓冲不归还，与安卓「前台失焦照常消耗、静音输出」不同。是否对齐安卓，需要在设备上确认 OHAudio 在 PAUSE 提示下是否仍回调后再改，本 PR 未改。
- 安卓 `QueueBuffer` 的发布顺序竞态：建议随第一步一起修，不放在本 PR。
