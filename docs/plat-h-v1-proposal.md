# plat.h 人话版：核心换平台时，中间那层“转接头”

> #18 / #37 讨论稿，2026-10-22；2026-10-23 补第一版实现状态。
> 第一版已在 `runtime/plat-h` 落 Apple / Android 平台层、`plat_asm.h`、`entry.S` / `xstack` 的 TSD 偏移改造；Linux 未动。
> 前面是人话，文末是技术附录。只想看结论的话，看到 §7 就可以停。

怎么读：

- 只想知道“这事能不能做、先做什么”：看 §1–§5。
- 想评审第一版接口：看 §5 + 技术附录 C/D。
- 想核对盘点数字或边界：看技术附录 B/E。

## 1. 一句话

`plat.h` 是**核心和操作系统之间的转接头**。

现在的共用核心（`runtime/src`）是照着 Apple 写的：内存映射、线程槽、暂停线程、崩溃现场、代码页权限，全都直接调 Apple 的东西。换到 Android / Linux 就编不过。

`plat.h` 的做法是：核心不再直接说“Apple 方言”，只说一套普通话：

```c
size_t plat_page_size(void);
int    plat_vm_alias(void *dst, const void *src, size_t size, uint32_t prot);
```

Apple 写一份实现，Android / Linux 各写一份实现。核心代码不改，只换下面的实现。

## 2. 现在到底卡在哪

不是“Android 跑不了游戏”，是“共用核心搬不过去”。举几个具体的：

| 现在核心直接用的 | 问题 | 换成 |
|---|---|---|
| `vm_remap` | Apple 有，Linux 没有同名同语义的东西 | `plat_vm_alias` / `plat_code_map` |
| `tpidrro_el0` | Apple 的线程槽基址；Android 是 `tpidr_el0 -> bionic_tls` | `plat_tsd_base` / `plat_tsd_offset` |
| Mach `thread_suspend` | Apple 能单独暂停一个线程；Linux 没有这个按钮 | `plat_thread_suspend` |
| `ucontext` 里的 `__ss` / `__es` | Apple 和 Linux 的崩溃现场字段名、布局都不一样 | `plat_fault_get_regs` / `plat_regs` |
| `getsectiondata` | iOS 把游戏模块编进可执行文件的 `__TEXT`；Android 是从文件 / APK 资产读 | `plat_module_image_get` |
| `mach_absolute_time` | Apple 的单调时钟 | `plat_now_ns` |

所以 `plat.h` 不是“新功能”，是**把已经存在的平台差异收口**。收口之后，Android 才能复用同一份核心。

## 3. 盘点了什么

按“核心到底用了哪些平台能力”分，大概是九类：

| 类别 | 现在直接用的 Apple 东西 | 人话解释 | 现在能不能定 |
|---|---|---|---|
| 内存映射 | `vm_remap`、`vm_allocate`、`vm_protect` | 把一块内存贴到指定地址；改读写执行权限 | Apple 能定；Linux 的固定地址贴法待确认 |
| 线程 | `tpidrro_el0`、Mach suspend、QoS | 线程自己的小抽屉、暂停/恢复、CPU 时间 | Apple 能定；Android 一部分；Linux 暂停待确认 |
| 时间 | `mach_absolute_time` | 单调时钟，只用来算差值 | 能定，Apple / Linux 都有对应 |
| 诊断 | `proc_pid_rusage`、`task_threads` | 读进程内存、线程、能耗 | Apple 能定；Linux 口径不同，要设计 |
| 缺页 / 信号 | `ucontext`、`ESR` | 崩了以后读/改寄存器；判断这次缺页是读还是写 | Apple 能定；Android 已实测能读 ESR（#39）；Linux 同一 arm64 代码可复用，待 biglawine 确认 |
| 地址查询 | `vm_region` | 查某个地址现在映射了什么 | Apple 能定；Linux 在信号处理里查待确认 |
| 内嵌模块 | `getsectiondata` | iOS 把模块编进可执行文件；Android 不需要 | Apple 专属，不影响 Android |
| 代码页 | `vm_remap` + max-protection | 代码页设成 RX，并且以后不许改回可写 | Apple 能定；Linux 没有 max-protection，要接受差异 |
| 内存实占 | `proc_pid_rusage`、`os_proc_available_memory` | 进程实际占了多少、系统还剩多少 | Apple 能定；Linux 只能给近似值 |

调用点大概几十处，逐文件清单在文末技术附录。这里只需要记住：**九类里，Apple 都能定；Android 有一部分已经在 main 上；Linux 有几处真的不知道。**

## 4. 现在能定哪一侧

用红绿灯说：

| 侧 | 状态 | 说明 |
|---|---|---|
| **Apple** | 🟢 能定 | 现在的代码就是 Apple 实现。搬进 `platform/apple`，行为不变，Mac/iOS 现有单测能跑 |
| **Android** | 🟡 能定一部分 | `tsd.c`、`guest_signal.c`、`module.c` 已经在 main，真机跑过。TSD、备用栈、页大小、模块映射可以接；线程暂停、缺页读/写位还要 yyan160 确认 |
| **Linux 公共层** | 🔴 暂时不能定 | 几个问题要 biglawine 回答：固定地址贴内存、信号里查 `/proc`、缺页读/写位、线程暂停用哪个信号、代码页 max-protection |

所以准确说法是：

> **Apple 这一侧现在可以完整定下来；Android 能定大半；Linux 公共层不能定。**
>
> 不是“整个 plat.h 没法开发”，是“不能现在把跨平台契约一次冻死”。

## 5. 最小第一步：先做 10 个，不做 30 个

之前那版列了 30 个候选函数，那只是盘点，不是第一版要全部实现。第一版先做 10 个，都是现有代码已经证明需要、而且 Apple / Android 有现成做法的：

| 先做的函数 | 人话解释 |
|---|---|
| `plat_page_size` | 系统一页多大。Android 有 4 KB 也有 16 KB，不能再写死 16 KB |
| `plat_now_ns` | 单调时钟。算超时、算帧间隔用，不关心墙上时间 |
| `plat_tsd_init` | 启动时测一下线程槽在什么位置。Android 的 Bionic 布局要探测，不能猜 |
| `plat_tsd_base` | 当前线程的槽基址。Apple 是 `tpidrro_el0`，Android 是 `bionic_tls` |
| `plat_tsd_offset` | 某把 key 的槽偏移。改写后的游戏代码按这个偏移直接读写槽 |
| `plat_fault_install` | 安装信号处理函数。崩溃、写跟踪、抢占都要用 |
| `plat_fault_altstack_init` | 给线程装备用栈。正常栈太小或已经坏了时，信号处理函数不能还走正常栈 |
| `plat_fault_altstack_free` | 线程退出时把备用栈还掉 |
| `plat_thread_stack_bounds` | 当前线程的栈从哪到哪。切栈、判断地址要用 |
| `plat_thread_self` | 取当前线程的平台句柄。后面的暂停、取寄存器、算 CPU 时间都要先有它 |

这 10 个能先带来什么：

- Apple 侧可以把线程槽、时钟、信号、备用栈、栈范围、线程句柄先搬进 `platform/apple`，行为不变。
- Android 侧可以把 `tsd.c` 和 `guest_signal.c` 接到同一组接口上，不用再各写一套。
- 不需要先回答 Linux 的那几个难题。

还有一个不是函数的文件：`platform/plat_asm.h`。`entry.S` 里每帧都要取线程槽基址，不能改成普通 C 调用；这个头只放两条汇编宏，Apple 一条 `mrs tpidrro_el0`，Android 是 `mrs tpidr_el0` + `ldur` 两条。没有它，汇编部分没法跨平台。

还留在后面的：

- 共享内存贴到固定地址（`plat_vm_alias`）
- 代码页映射（`plat_code_map`）
- 线程暂停 / 取寄存器 / CPU 时间（`plat_thread_suspend` / `plat_thread_get_regs` / `plat_thread_cpu_ns`；暂停以后用 USR1）
- 地址查询（`plat_vm_query`）
- 缺页读/写位（`plat_fault_write`；Android 已实测支持，Linux 待确认同一段）
- 内存实占（`plat_mem_footprint_get`）

这些不是不重要，是跟第二批 fault / 内存批一起定；Linux 的固定别名和 `/proc` 信号安全还要等 biglawine。

## 6. 边界问题（#39 已答一部分）

### 问 biglawine（Linux 公共层）

1. **共享内存能不能贴到游戏指定的固定地址？**
   - 现在 Android 的 `memory.c` 只验证了“贴到任意新地址”的 `mremap`，没验证“贴到指定地址”。
   - 如果 `mremap(MREMAP_FIXED)` 可以，就用它；如果不行，就用 `memfd` 或改接口。这个答案决定 `plat_vm_alias` 长什么样。

2. **缺页信号处理里，能不能安全读 `/proc/self/maps`？**
   - `graphics/track` 在缺页处理里要查“这页现在是什么权限”。
   - 如果能在信号里安全读，`plat_vm_query` 就按信号安全设计；如果不能，track 要另做缓存，不能假装可以。

3. **Linux 缺页时，能不能知道这次是读还是写？**
   - Android 已经从信号帧 `__reserved` 的 `esr_context` 读出 WnR（#39：写 `0x92000047` WnR=1，读 `0x92000007` WnR=0），这段是纯 arm64 Linux 代码。
   - 请确认 Linux 公共层也能用同一段；拿不到时 `plat_fault_write` 回 `-1`，写跟踪退回保守处理。

4. **Linux 怎么只暂停一个线程？用哪个信号？**
   - Apple 有 `thread_suspend`，Linux 没有。
   - 用信号让目标线程自己停住，就要选一个不会被 .NET、ART、bionic 占用的信号。选不出来，第一版就只能“不支持”，游戏里的 `SetThreadActivity` 退回协作暂停。

5. **Linux 代码页能不能像 Apple 一样“以后不许改回可写”？**
   - Apple 有 max-protection；Linux `mprotect` 只能改当前权限。
   - 如果接受不了这个差异，就要另找机制；如果接受，文档里要写清楚。

### 问 yyan160（Android 覆盖；#39 已答大部分）

1. **Bionic 线程槽偏移**：#39 实测 Redmi（Android 15）和 OnePlus 13（Android 17）的 offset 都是 0；`device_selftest` 的 6 种改写 × 2 个 guest 线程 × 4 把 key 全过。16 KB 页 / Android 16 还没测。结论：保留每次起局实测，测不出就报错，不回退 0；有 16 KB 设备再补。
2. **信号**：#39 普查 10 USR1 / 12 USR2 / 23 URG 都空。但 `det.c` 已经用 USR2，**线程暂停不能用 USR2**；建议用 USR1（或把 det 挪到 USR1）。不需要“动态取号”接口；`plat_fault_install` 装之前查内核视角，被占就报 `EBUSY` / `ENOTSUP`。ART 只接管 SEGV；.NET 用 41。
3. **备用栈**：#39 确认 guest 线程 256 KB + guard，ART / .NET 不装；debuggerd、sigchain、.NET 的 onstack 处理函数会跑在这块上，回溯从 `ucontext` 取 pc/sp/fp，不受影响。36 / 38 在有人抓堆时仍可能踩 guest 红区，第一版文档写明。
4. **共享内存对齐**：#39 确认按宿主页对齐即可，16 KB 只是 Apple 的页大小。原生层检查改成 `plat_page_size()`；C# 分配继续按 16 KB 也没坏处。
5. **暂停 / 读写位**：Android 能拿缺页读/写位（写 ESR `0x92000047` WnR=1，读 `0x92000007` WnR=0），第一版可以支持 `plat_fault_write`；线程暂停第一版可以 `ENOTSUP`，以后用 USR1 做信号 park。`plat_regs` / fpsimd 布局等 `plat_fault_get_regs` 那批再定。

## 7. 下一步

- **现在不建分支。** 等 #18 对上面几个问题有结论，再从 `main` 开 `runtime/plat-h`，不要从 `android/a0-hostapi` 开。
- 第一版 PR 只做：`platform/plat.h` + `platform/plat_asm.h` + `platform/apple/plat_apple.c` + 上面 10 个函数，以及这 10 个函数对应的 Apple 调用点迁移。不动 `launchers/linux`，不动 Android 覆盖。
- 第二版再由 yyan160 接 Android 覆盖；第三版再由 biglawine 补 Linux 公共层。
- 不碰 #32、#28、#27、A4，也不把 WSI lease 放进 `plat.h`。

一句话总结：

> **Apple 现在能完整做；Android 能接一大半；Linux 还有几个问题没答。第一版先做 10 个基础函数，不要把 30 个候选一次写死。**

---

# 技术附录（给实现者；不看不影响人话部分）

## A. 计数口径

- **调用点**按实际调用表达式计；同一行多个调用算多个。`loader.c` 的 `vm_remap` 是 1 个调用点、运行时执行 3 次（text / W / patch）。
- 不含 `#include`、类型声明、注释里的名字。
- `madvise`、`mmap`、`mprotect`、`pthread_*` 是 POSIX，不算 Apple 专有；但它们的语义差异（16 KB 页、max protection、线程栈 API）在对应组里单列。
- fault 组的“数量”按 `ucontext` / `mcontext` 字段访问计，不按函数调用计。
- `graphics/metal` 的 Metal / GCD 调用不在本稿；只把 `graphics/track/track.c` 的 `vm_region_64` 算进来，因为它在缺页信号路径上。
- 16 KB 硬编码单独统计，不和 Apple API 调用数混在一起。

## B. 九组调用点明细

### B.1 memory / alias

| 文件 | 直接调用 | 计数 | 当前返回 / 失败语义 |
|---|---|---:|---|
| `runtime/src/loader.c` | `vm_allocate`、`vm_remap`、`vm_protect`；另有 `mmap` / `mprotect` | 3 + POSIX 5 | `vm_allocate` / `vm_remap` 失败、remap 后权限不足 → `die()`；max protection 失败 → `die()`；没有降级路径 |
| `runtime/src/svc_mem.c` | `vm_remap`、`vm_protect`、`vm_deallocate`；另有 `mmap` / `mprotect` | 3 + POSIX 10 | `MapSharedMemory` 的 remap / protect 失败 → `die()`；`host_processor_info` 的 `vm_deallocate` 失败忽略 |
| `runtime/src/det.c` | `vm_remap`、`vm_protect`；另有 `mmap` / `mprotect` | 2 + POSIX 6 | `vm_remap` 失败 **return 0**（影子副本关闭，确定性降级）；`vm_protect` 失败忽略 |
| `runtime/src/vawin.c` | `mach_vm_map`、`mach_vm_region_recurse`；另有 `mmap` / `munmap` | 1 + POSIX 4 | 仅 macOS 的 iPhone 地址围栏用；失败只计数 / 打红，函数本身 `void` |
| `runtime/src/thread.c` | `mmap` 共享后备 | POSIX 2 | 失败 `die()`；注释和 C# 都依赖 16 KB 对齐 |
| `android/native/module.c`（参照） | `mmap` / `mprotect` / `munmap` | POSIX 5 | 返回 errno；由调用方报错，不 `die()`；这是 Android 已有的正确形状 |

要点：`vm_remap` 同时承担“共享内存别名”（`det.c` / `svc_mem.c`）和“内嵌代码段映射”（`loader.c`）两种语义。前者是**共享同一批物理页**，后者是**按原相对位置映射 / 写时复制**。v1 应拆成 `plat_vm_alias` 和 `plat_code_map`。

### B.2 thread

| 文件 | 直接调用 | 计数 | 当前返回 / 失败语义 |
|---|---|---:|---|
| `runtime/src/thread.c` | `tpidrro_el0`、`pthread_mach_thread_np`、`thread_suspend`、`thread_get_state` ×2、`thread_resume` ×2、`thread_info`、QoS set ×1 / get ×2、`sysctlbyname` ×2、`pthread_setname_np` ×2、`os_workgroup_*` ×6 | 约 21（含可选 workgroup） | `thread_suspend` 失败 **return 0**（`thr_pause` 当作“已停/可退”）；`thread_get_state` 失败重试，2 秒仍停不到 → `die()`；QoS 设不上只报红一次；`thread_info` CPU 时间失败返回 0 但 `*ok` 仍为 1；workgroup 失败报红并关闭功能 |
| `runtime/src/tdump.c` | `task_threads`、`mach_thread_self`、`thread_suspend`、`thread_resume`、`thread_info` ×2、`thread_get_state`、`pthread_from_mach_thread_np`、`pthread_get_qos_class_np`、`vm_read_overwrite`、`vm_deallocate` | 9 + 2 | `task_threads` 失败打“取线程表失败”并返回 0 条；suspend/resume 失败忽略；`thread_get_state` 失败打“取寄存器失败”；`vm_read_overwrite` 失败停止回溯 |
| `runtime/src/energy.c` | `task_threads`、`thread_info`、`pthread_from_mach_thread_np`、`pthread_getname_np`、`sysctlbyname` ×2 | 6 | `task_threads` 失败回 0 行；线程名取不到回退 `#tid`；sysctl 失败用默认值 |
| `runtime/src/loader.c` | `tpidrro_el0` | 1 | 读 TSD 基址后核对键槽；布局不符 `die("TSD 布局不符")` |
| `runtime/src/entry.S` | `mrs tpidrro_el0` ×2 | 2 | 无返回值；门和切栈桩直接读槽 |
| `runtime/src/xstack.c` | `pthread_get_stackaddr_np`、`pthread_get_stacksize_np` | 2 | 栈范围不对 `die()` |
| `runtime/src/svc_mem.c` | `host_processor_info` | 1 | 失败时 `idle = 0`，GetInfo 仍成功（游戏看到 0 空闲计数） |
| `android/native/tsd.c`（参照） | `s2a_android_tsd_probe` / `s2a_bionic_tls` / `s2a_bionic_slot_off` | 已有实现 | 返回 0 / errno；`selftest.c` 在探不到时拒绝起局，无回退 |

### B.3 sync + time

| 文件 | 直接调用 | 计数 | 当前返回 / 失败语义 |
|---|---|---:|---|
| `runtime/src/det.c` | `OS_UNFAIR_LOCK_INIT` ×2、`os_unfair_lock_lock` ×3、`os_unfair_lock_trylock` ×5、`os_unfair_lock_unlock` ×9 | 19 | `void` / 0-1；没有失败路径；`trylock` 失败表示“别人持锁”，不是错误 |
| `runtime/src/os.c` | `mach_absolute_time`、`mach_timebase_info` | 2 | `now_ns()` 不返回错误；timebase 只初始化一次，失败未处理 |
| `runtime/src/energy.c` | `mach_absolute_time`、`mach_timebase_info` | 2 | 同上，wall 时间用于 delta |
| `runtime/src/thread.c` | `mach_absolute_time`、`mach_timebase_info` | 2 | workgroup 周期和 interval 起点；失败未处理 |
| `runtime/src/lifecycle.c` | `dispatch_after`、`dispatch_get_global_queue` ×2、`dispatch_source_create` | 4 | Apple GCD；没有失败检查 |
| `runtime/src/lowva.c` / `thread.c` | `clock_gettime(CLOCK_MONOTONIC)` | POSIX | 已是可移植写法，可直接保留；`plat_now_ns` 只是把它收口 |

### B.4 diagnostics

| 文件 | 直接调用 | 计数 | 当前返回 / 失败语义 |
|---|---|---:|---|
| `runtime/src/energy.c` | `proc_pid_rusage`、`proc_pidinfo` ×2、`coalition_info_resource_usage`、`task_threads` / `thread_info` / `pthread_from_mach_thread_np` / `pthread_getname_np`、`sysctlbyname` ×2、`vm_deallocate` | 11 | `proc_pid_rusage` 失败 → `-1`，`s2a_energy_capture` 打红并返回 0 行；coalition 失败 → GPU 账“取不到”；线程表失败 → 0 行 |
| `runtime/src/tdump.c` | 线程枚举 / 挂起 / 取寄存器 / `vm_read_overwrite` / `vm_deallocate` | 11 | best-effort；失败写“取线程表失败”“取寄存器失败”，仍返回线程数 |
| `runtime/src/vawin.c` | `vm_region_64` ×2、`vm_region_recurse_64` ×4、`mach_vm_region_recurse`、`proc_regionfilename` | 8 | `void`；失败结束当前扫描，低区空洞 / 标签可能少算；只在日志体现 |
| `runtime/src/selfcheck.c` | `os_proc_available_memory` | 1 | 无失败返回；与 4500 MB 阈值比较，不够就报红并阻止起局 |
| `runtime/src/boot.c` | `sysctl(KERN_PROC_PID)` | 1 | 失败回退到 `gettimeofday`，分段计时仍可用 |
| `runtime/src/det.c` | `_dyld_get_image_vmaddr_slide` | 1 | 无失败处理；只用于日志 |
| `runtime/src/svc_mem.c` | `host_processor_info` | 1 | 失败 `idle=0`，GetInfo 成功；游戏可见但语义退化 |
| `services/S2A.Services/MemDiag.cs` | `proc_pid_rusage`、`os_proc_available_memory`（`/usr/lib/libSystem.B.dylib`） | 2 | `proc_pid_rusage` 失败回 -1；`os_proc_available_memory` 缺失时捕获 `EntryPointNotFoundException` |

### B.5 fault

| 文件 | 直接依赖 | 当前语义 |
|---|---|---|
| `runtime/src/crash.c` | `ucontext_t` 的 `uc_mcontext->__ss`（x0–x28 / fp / lr / sp / pc / pstate）、`__es.__esr`、`SIGBUS` / `SIGSEGV` / `SIGILL` / `SIGTRAP` / `SIGFPE` / `SIGABRT`、`sigaltstack`、`sigaction` | 先给 track / touch / det watch 认领；否则打印现场并 `_exit(128+sig)`。没有错误返回 |
| `runtime/src/touch.c` | `_STRUCT_ARM_THREAD_STATE64` / `_STRUCT_ARM_NEON_STATE64`、`uc_mcontext->__ss` / `__ns` | 把缺页线程改道到宿主上下文，保留完整 GPR + NEON；保存区缺失时回退到原路径。返回 1/0 |
| `runtime/src/thread.c` | `_STRUCT_MCONTEXT`、`uc_mcontext->__ss.__pc`、`SIGURG`、`sigaction`、`pthread_kill` | 时钟抢占：第一次信号把 PC 改到 tramp，第二次信号恢复 `porig`；没有 `thr_t` 时直接返回 |
| `runtime/src/det.c` | `ucontext_t` 的 `__ss.__pc`、`SIGUSR2`、`sigaction`、`pthread_kill` | 串行档看门狗抢占；记录/重放档只计数，不发信号 |

要点：这组不是“读崩溃上下文”这么简单。`touch.c` 和 `thread.c` 都要**改 PC / SP / x0 / LR / FP / 整个 NEON 状态**，所以 v1 用可读写的 `plat_regs`，不采用只读的 `plat_crash_context`。

### B.6 vm_query

| 文件 | 直接调用 | 计数 | 当前返回 / 失败语义 |
|---|---|---:|---|
| `runtime/src/vawin.c` | `vm_region_64` ×2、`vm_region_recurse_64` ×4、`mach_vm_region_recurse`、`proc_regionfilename` | 8 | 全部 `void`；扫描失败就停，低区空洞 / 标签合计可能偏小；`proc_regionfilename` 是 `dlsym`，取不到就不打文件账 |
| `graphics/track/track.c` | `vm_region_64` | 1 | `kern_prot()` 返回 -1 表示查不到；**在缺页信号处理里调用**，要求信号安全 |

### B.7 module_image

| 文件 | 直接调用 | 计数 | 当前返回 / 失败语义 |
|---|---|---:|---|
| `runtime/src/loader.c` | `getsectiondata` ×3（`__TEXT,__sw<名>x0` / `__SW<名>W,__img` / `__TEXT,__sw<名>x1`）、`_mh_execute_header` | 3 + 3 引用 | 任一节缺失 → `die()`；节布局 / 对齐不符 → `die()` |
| `runtime/src/xstack.c` | `getsegmentdata(__TEXT)`、`_mh_execute_header` ×2 | 1 + 2 引用 | 取不到时 `lo/hi` 为 0，`sw_is_host_code()` 退化为 0（把宿主入口当客体入口） |
| `runtime/src/host_main.c` | `_NSGetExecutablePath` | 1 | 失败 `die()`；iOS 用可执行文件同目录找随行表 |

### B.8 code_map

| 文件 | 直接调用 | 计数 | 当前返回 / 失败语义 |
|---|---|---:|---|
| `runtime/src/loader.c` | `vm_allocate`、`vm_remap`、`vm_protect`；`mprotect` ×3、`mmap` ×2 | 3 + POSIX 5 | 见 B.1；另外 `vm_protect(..., TRUE, R|X)` 把**最高权限**也压到 R|X，防止之后改回可写，这是 Linux `mprotect` 没有的语义 |
| `runtime/src/svc_mem.c` | `vm_remap`、`vm_protect`；`mprotect` ×9、`mmap` ×1 | 2 + POSIX 10 | 共享内存别名 + 权限；失败 `die()` |
| `runtime/src/det.c` | `vm_remap`、`vm_protect`；`mprotect` ×2、`mmap` ×4 | 2 + POSIX 6 | 影子副本；remap 失败回 0 |
| `android/native/module.c`（参照） | `mmap` / `mprotect` / `munmap` | POSIX 5 | 匿名内存 + 拷贝 + `mprotect(R|X)`；没有 max protection；错误返回 errno |
| `graphics/track/track.c` | `mprotect` ×2、`mmap` ×2 | POSIX 4 | 失败计数 + `sigsafe_hex` 日志，不 abort |

要点：当前**没有** `MAP_JIT` / `pthread_jit_write_protect_np` 调用。不要因为架构文档 §3 提了 `MAP_JIT` 就先加接口；等真的需要运行时生成代码再说。

### B.9 mem_footprint

| 文件 | 直接调用 | 计数 | 当前返回 / 失败语义 |
|---|---|---:|---|
| `runtime/src/energy.c` | `proc_pid_rusage(RUSAGE_INFO_V6)` 的 `ri_phys_footprint` | 1 | `s2a_energy_snap` 失败回 -1；energy 日志打红 |
| `runtime/src/selfcheck.c` | `os_proc_available_memory` | 1 | 无失败；不足 4500 MB 阻止起局 |
| `services/S2A.Services/MemDiag.cs` | `proc_pid_rusage(RUSAGE_INFO_V2)`、`os_proc_available_memory` | 2 | 失败回 -1 / 捕获缺失符号；直接 P/Invoke `libSystem` |

### B.10 16 KB 硬编码

| 文件 | 16 KB 相关位置（约） | 性质 |
|---|---:|---|
| `runtime/src/loader.c` | 8 | 模块布局 / 对齐 / 封页；应改 `plat_page_size`，但模块格式的 16 KB 键页是**格式常量**，不是宿主页 |
| `runtime/src/thread.c` | 8 | 共享内存后备 / wrap 的 16 KB 对齐；应改宿主页 |
| `runtime/src/svc_mem.c` | 35 | 4 KB 子页掩码 + 16 KB 宿主页；不能机械替换，要先定 4 KB guest / 4 KB or 16 KB host 的记账规则 |
| `runtime/src/det.c` | 3 | 写监视页 16 KB；应改宿主页 |
| `runtime/src/layout.c` | 3 | 布局里的 16 KB 保留 / 保护页；与 NPDM 地址空间语义有关，需单独审 |
| `runtime/src/widen.c` | 1 | 可写范围按 16 KB 向上取整；应改宿主页 |
| `graphics/track/track.c` | 5（注释 / 叶子位假设） | 运行时已用 `sysconf` 取 `g_pg`，但叶子容量注释仍按 16 KB 页 = 1 GB；4 KB 页时容量变化，需确认 |
| `android/native/module.c` | 11 | `PAGE16` 同时用于**键页格式**和映射对齐；键页 16 KB 应保留，映射对齐应改宿主页 |
| `android/native/tsd.c` | 2 | `PROBE_LIMIT 0x4000` / 16 KB 注释；探测上限，不是页大小依赖 |

#39 的结论：共享内存对齐按宿主页大小即可，16 KB 只是 Apple / 16 KB Android 的页大小。原生层 `s2a_shmem_wrap` / `MapSharedMemory` 的检查改 `plat_page_size()`；C# 分配继续按 16 KB 没有坏处。

## C. 30 个候选原型

通用约定：

- 返回 `0` 成功；正 `errno` 失败；`ENOTSUP` = 平台没有这个能力，调用方走退路。**不返回负 errno**，不依赖全局 `errno`。
- v1 没有函数返回需要调用方 `free` 的内存。`plat_module_image_get` 返回借用指针；`plat_vm_alias` 是别名，不复制，`src` 必须比 `dst` 活得久。
- 线程标记：`[startup]` 只在 guest 线程启动 / 模块映射前；`[thread]` 任意宿主线程，但不可在信号处理里调用；`[signal]` 必须信号安全（不分配、不拿锁）。
- 编译期接口，不是跨语言函数表；v1 不加 `size/abi_version` 表头。

```c
#ifndef S2A_PLAT_H
#define S2A_PLAT_H

/* POSIX.1-2008 signal types (siginfo_t): build with -std=gnu11 or
   -D_POSIX_C_SOURCE=200809L. Apple / Android toolchains default to this. */
#include <signal.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define S2A_PLAT_API_VERSION 1

enum {
    PLAT_PROT_NONE  = 0,
    PLAT_PROT_READ  = 1u << 0,
    PLAT_PROT_WRITE = 1u << 1,
    PLAT_PROT_EXEC  = 1u << 2,
};

/* ---- memory / alias ---- */

size_t plat_page_size(void);                 /* 0 = unavailable; supported targets must not return 0 */
int plat_vm_alias(void *dst, const void *src, size_t size, uint32_t prot);
int plat_vm_protect(void *addr, size_t size, uint32_t prot);

typedef struct plat_vm_region {
    uint64_t base, size;
    uint32_t prot;       /* PLAT_PROT_* */
    uint32_t max_prot;   /* 0 if unknown */
    uint32_t tag;        /* platform user tag, 0 if none */
    uint32_t flags;      /* PLAT_VM_* */
} plat_vm_region;

#define PLAT_VM_FILE         0x1u
#define PLAT_VM_MAX_UNKNOWN  0x2u
int plat_vm_query(uint64_t addr, plat_vm_region *out); /* [signal] only if platform can; see §6 */

typedef struct plat_mem_footprint {
    uint64_t resident_bytes;   /* 0 = unknown */
    uint64_t footprint_bytes;  /* jetsam / phys_footprint, 0 = unknown */
    uint64_t available_bytes;  /* per-process available, 0 = unknown */
    uint32_t flags;
    uint32_t _pad;
} plat_mem_footprint;

#define PLAT_MEM_HAVE_RSS         0x1u
#define PLAT_MEM_HAVE_FOOTPRINT   0x2u
#define PLAT_MEM_HAVE_AVAILABLE   0x4u
#define PLAT_MEM_AVAILABLE_SYSTEM 0x8u
int plat_mem_footprint_get(plat_mem_footprint *out);

/* ---- thread / TSD ---- */

struct plat_regs;
typedef uintptr_t plat_thread_t;

typedef enum plat_qos {
    PLAT_QOS_UNSPECIFIED = 0,
    PLAT_QOS_UI,
    PLAT_QOS_USER_INITIATED,
    PLAT_QOS_UTILITY,
    PLAT_QOS_BACKGROUND,
    PLAT_QOS_DEFAULT
} plat_qos;

int      plat_tsd_init(void);                          /* [startup] */
uint64_t plat_tsd_base(void);                           /* [thread], current base */
int      plat_tsd_offset(uint32_t key, uint64_t *out);  /* [thread], *out != 0 */

int plat_thread_self(plat_thread_t *out);               /* [thread] */
int plat_thread_suspend(plat_thread_t t);               /* [thread], not self; ENOTSUP allowed */
int plat_thread_resume(plat_thread_t t);                /* [thread] */
int plat_thread_get_regs(plat_thread_t t, struct plat_regs *out);
int plat_thread_cpu_ns(plat_thread_t t, uint64_t *out);
int plat_thread_stack_bounds(uintptr_t *low, uintptr_t *high);
int plat_thread_set_name(const char *name);
int plat_thread_set_qos(plat_qos q);                    /* ENOTSUP allowed */
int plat_cpu_perf_cores(void);                          /* 0 = unknown */
int plat_cpu_idle_ns(int core, uint64_t *out);

/* ---- time ---- */

uint64_t plat_now_ns(void);   /* [signal], monotonic, never fails */

/* ---- fault ---- */

typedef struct plat_regs {
    uint64_t x[29];       /* x0..x28 */
    uint64_t fp;          /* x29 */
    uint64_t lr;          /* x30 */
    uint64_t sp;
    uint64_t pc;
    uint64_t pstate;
    uint8_t  v[32][16];   /* q0..q31 */
    uint32_t fpcr;
    uint32_t fpsr;
    uint32_t _pad;        /* keep sizeof == 800 on LP64 */
} plat_regs;

#if defined(__cplusplus)
static_assert(sizeof(plat_regs) == 800, "plat_regs layout");
#else
_Static_assert(sizeof(plat_regs) == 800, "plat_regs layout");
#endif

#define PLAT_FAULT_ONSTACK 0x1u
#define PLAT_FAULT_RESTART 0x2u

int  plat_fault_install(int sig, void (*fn)(int, siginfo_t *, void *), unsigned flags);
int  plat_fault_altstack_init(void);   /* [thread], idempotent, 256 KiB + guard */
void plat_fault_altstack_free(void);  /* [thread] */
int  plat_fault_get_regs(void *uctx, plat_regs *out);        /* [signal] */
int  plat_fault_set_regs(void *uctx, const plat_regs *in);   /* [signal] */
int  plat_fault_write(void *uctx);     /* [signal], 1 = write, 0 = read, -1 = unknown */

/* ---- module image / code map ---- */

typedef struct plat_module_image {
    const void *text;  size_t text_size;
    const void *rw;    size_t rw_size;
    const void *patch; size_t patch_size;
} plat_module_image;

int plat_module_image_get(const char *name, plat_module_image *out); /* [startup] */
int plat_code_reserve(void **base, size_t size);                     /* [startup] */
int plat_code_map(void *dst, const void *src, size_t size, int writable);
int plat_code_seal(void *addr, size_t size);                         /* RX; Apple also max-prot */
int plat_code_contains(uint64_t addr);                               /* [thread], 1/0 */

#ifdef __cplusplus
}
#endif
#endif /* S2A_PLAT_H */
```

## D. 第一批 10 个的约束

| 函数 | 返回 / 失败 | 线程 | 关键约束 |
|---|---|---|---|
| `plat_page_size` | 页大小；0 = 平台取不到，调用方应拒绝起局 | 任意 | 进程常量；模块格式的 16 KB 键页另算，不随宿主页变化 |
| `plat_now_ns` | 单调纳秒；不失败 | `[signal]` | 零点任意；Apple mach absolute + timebase，Linux `CLOCK_MONOTONIC` |
| `plat_tsd_init` | 0 / errno | `[startup]` | 在 `pthread_key_create` 之后、写模块键页之前调；Apple 可空实现；Android 调 `s2a_android_tsd_probe`，失败拒绝起局，不能回退 |
| `plat_tsd_base` | 当前线程基址；0 不可用 | `[thread]` | Apple = `tpidrro_el0 & ~7`；Android = `bionic_tls` |
| `plat_tsd_offset` | 0 / errno；`*out != 0` | `[thread]` | key 保留 bit 31；Apple = key×8；Android = table_off + index×16 + 8。现有 probe 已间接覆盖一个 peer，多 key / 多线程矩阵待补 |
| `plat_fault_install` | 0 / errno | `[thread]` | 总是 `SA_SIGINFO`；`ONSTACK` / `RESTART` 由 flags 选；不返回旧 handler |
| `plat_fault_altstack_init` | 0 / errno | `[thread]` | 每 guest 线程 256 KiB + guard，幂等；ART 线程不装 |
| `plat_fault_altstack_free` | void | `[thread]` | 线程退出前调；幂等 |
| `plat_thread_stack_bounds` | 0 / errno | `[thread]` | 当前线程；`low` = 栈底，`high` = 栈顶 |
| `plat_thread_self` | 0 / errno | `[thread]` | Apple 存 Mach port，Linux 存 `pthread_t` / tid；句柄借用，线程退出后失效。CPU 时间、暂停、取寄存器都要先有这个句柄 |

其余 20 个候选：`plat_vm_alias`、`plat_vm_protect`、`plat_vm_query`、`plat_mem_footprint_get`、`plat_thread_cpu_ns`、`plat_thread_suspend`、`plat_thread_resume`、`plat_thread_get_regs`、`plat_thread_set_name`、`plat_thread_set_qos`、`plat_cpu_perf_cores`、`plat_cpu_idle_ns`、`plat_fault_get_regs`、`plat_fault_set_regs`、`plat_fault_write`、`plat_module_image_get`、`plat_code_reserve`、`plat_code_map`、`plat_code_seal`、`plat_code_contains`。这些等 §6 的问题有答案后再逐个定，不在第一批冻结。

## E. 验证计划

### Apple（第一版分支每个提交）

- `make host`：Mac 宿主编译通过。
- `make test`：现有 `runtime/tests` 全过，重点 `t_thread`、`t_det`、`t_vawin`、`t_tdump`、`t_energy`、`t_svc_mem`。
- iOS：`make ios IOS_MODS=<产物>` 编译通过；同一份改写产物跑一局 Mac / iOS 冒烟，确认窗口、模块基址、`host.log` 标记、帧数一致。
- **改写器不改**：`tests/rewrite_target_test.sh` 不受影响；Apple 改写产物逐字节不变。
- 对照读数：`s2a_vm_top` / `s2a_low_tags` / `s2a_low_holes` / `s2a_energy_capture` 数值在噪声范围内一致；`s2a_thread_dump` 的线程名 / QoS / PC 可读。

### Android（等 Android 覆盖层接上）

- `bash android/test.sh`：现有 CTest 全过。
- `android/tools/device_selftest.sh`：6 种改写块 × 2 条客体线程；现有 probe 已间接覆盖一个 peer 的 table offset，补第二把 key / 多线程断言。
- 真机：4 KB（Redmi K50 Ultra，Android 15）和 16 KB 页设备各跑一次；看 `MapSharedMemory`、`SetThreadActivity`、`GetInfo IdleTick`、`ThreadTickCount` 和崩溃现场。
- 失败路径：故意让 `plat_tsd_init` 失败、`plat_thread_suspend` 回 `ENOTSUP`、`plat_fault_write` 回 `-1`，确认调用方走退路而不是假成功。

### 静态检查

- `platform/plat.h` 能被 C / C++、Apple / Android / Linux 三种编译目标 `-fsyntax-only`；C 检查用 `-std=gnu11` 或 `-D_POSIX_C_SOURCE=200809L`（`siginfo_t` 是 POSIX 类型）。
- `_Static_assert(sizeof(plat_regs) == 800)` 在三端通过。
- 头文件不包含 `<mach/*>`、`<os/*>`、`<TargetConditionals.h>`、`<android/*>`；平台头只出现在实现文件。
