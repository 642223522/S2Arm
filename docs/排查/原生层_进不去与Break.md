# 原生层排查手册 ②：进不去 / 游戏 Break

适用：游戏起来了但没进可玩（没到 MARK），或者日志里有「收到 游戏 Break：优雅退出」。游戏 Break 就是游戏代码自己调 `svcBreak` 中止：SDK 断言失败、某个结果码不是成功。它不是我们这边的崩溃，但几乎总是我们哪里给错了。

配套：[① 崩溃](原生层_崩溃.md)、[③ 系统服务回答不对](原生层_服务回答不对.md)、skill [native-triage](../../skills/native-triage/SKILL.md)。

## 1. 先分三类

| 日志里有 | 归类 | 往下看 |
|---|---|---|
| `【红】Break 原因 …` | 游戏 Break | §2、§3 |
| `【红】CRASH 信号` | 崩溃 | 手册 ① |
| 两样都没有，只是没到 MARK | 多半不是原生层：看自动玩家那几行（认页、路线），以及画面有没有出帧 | 只有画面停在加载、且有 `【红】未实现` 行时，才回到本手册 §3.3 |

自动玩家那几行怎么读、没到 MARK 的常见根因，见 [自动玩家没到 MARK](自动玩家没到MARK.md)。

出包阶段就失败（`PFRW … gaps=N`、「异常类指令 …」），看手册 ① §3.3。

## 2. 游戏 Break 看哪几行

1. **`【红】Break 原因 R 载荷 A+L 位于 模块+偏移`**（runtime/src/svc_mem.c）：
   - 「位于」通常是 SDK 里 `svcBreak`（`svc #0x26`）那个小桩，不是出事的地方；
   - 要看的是后面的帧栈。
2. **`【红】Break 载荷结果码 r（2MMM-DDDD：模块 m、描述 d）`**：载荷是 4 字节时，SDK 把失败的 Result 放在这里。
   - **结果码非 0**：是某次调用回了失败（多半是系统调用或服务），按 §3.1 查；
   - **结果码 0**：不是结果码问题，是 SDK 自己的断言（`nn::diag::detail::AbortImpl()`），按 §3.2 查。
3. **`ServiceAm SetTerminateResult: … ResultErrApplicationAborted (2162-0001)`**：这是 Break 之后的结果，不是原因，别追。
4. **帧栈 `#0 … #N`**：前几帧是 `nn::diag` 的 Abort 链，往下第一个不属于 `nn::diag` 的帧才是出事的 SDK 函数。用 `python3 tools/nso_sym.py sym <exefs/sdk> <偏移…>` 换成函数名（帧里是返回地址，先减 4）；跳到 PLT 跳板的，用 `nso_sym.py plt` 看它实际调的是哪个函数。
5. **Break 之前最近的 `【红】`**：「未实现：系统调用/0x…」「未实现服务命令 …」「地址越界：svc …」常常就是直接原因。

## 3. 常见根因

### 3.1 结果码非 0：某个调用回了失败
- 结果码 → 名字：直接查 `compat/tree/src/Ryujinx.Horizon.Common/ResultNames.cs`（按原始值，例如 `0x10601` 就是 PortClosed）。模块号：1 = 内核（svc，定义在 `Ryujinx.Horizon.Common/KernelResult.cs`），2 = fs，其余看各服务目录下的 `ResultCode.cs`。
- 找 Break 前最后一次回这个码的调用。日志里有「未实现」红行时，就是它；没有的话，在可疑的 svc / 服务命令上加一行只读诊断（报红时带上参数），重跑一局。
- 修法：照上游 Ryujinx 同一命令的实现回同样的值（见手册 ③ §3）。

### 3.2 结果码 0：SDK 断言，要读 SDK 代码
- 把调用链换成函数名，读出断言条件。例子（Servonauts、Fit Boxing 3，10-29）：
  - 调用链：`ThreadManager::CreateThread → ThreadManagerImplByHorizon::MapAliasStack → StackGuardManager::MapAtRandomAddress` 返回 1 → `AbortImpl()`。
  - 读 `AddressSpaceAllocatorBase::AllocateSpace`：它在**栈区**里随机挑地址，前后各留保护区，512 次都撞上已占的就失败。
  - 读数：中止时栈区已映射 43–68 MB，而我们给的栈区只有 128 MB；Horizon / Ryujinx 39 位地址空间给的是 2 GB（`KPageTableBase` 里 `stackRegion.Size = 0x80000000`）。
  - 修法：栈区按真值给 2 GB（runtime/src/layout.c），只有「别名优先」的款仍压小，给别名区让窗口。
  - 单测：`runtime/tests/t_layout.c` 锁住两种款的栈区大小；把常量改回 128 MB 时，必须有断言不符。
- 教训：Horizon 给进程的各区是**地址承诺**，不是内存。为了省窗口把某个区缩得比真值小，SDK 里依赖随机放置、首次适配的分配器就会在游戏跑到一半时失败。缩任何一个区之前，先查 SDK 怎么用它。

### 3.3 地址区不够 / 分配失败
- 先看这几行：
  - 「地址按需」：窗口够不够标准布局；
  - 「布局提示：… 别名优先、堆区压小」：本款按「别名优先」排；
  - 「游戏地址峰值 […]：堆 … 栈区映射 X KB、最高到区内 +Y KB（栈区 Z MB）；共享内存 …（可随机区 W MB）」：每个区的峰值和区大小。
- 判据：任何一个区，峰值 × 2 应当 ≤ 区大小；随机放置的区（栈区、可随机区）余量要更大。
- 结果码落在内核模块、描述是「内存不足 / 状态不对」（例如 2001-0106，原始值 0xd401，Ryujinx 叫 `InvalidMemState`），而目标地址在窗口外：说明游戏映射到了窗口没占到的承诺段（`win_has` 拒掉）。查布局，不要改 svc 去「放行」。
- IML 地址档（iPhone 开了「提高内存上限」权限）：自检行「『提高内存上限』权限 已签 / 未签」。未签时窗口小得多，大地址款进不去是预期，不是 bug。

### 3.4 未实现的系统调用 / 服务
- `【红】未实现：系统调用/0x…（原因，第 n 次）x0=… 位于 模块+偏移`（runtime/src/gate.c）：补实现，照 Ryujinx `Syscall.cs` 同一号。
- 服务层未实现见手册 ③。铁律：**未实现一律报红，不返回成功兜底**。

## 4. 对齐 Ryujinx 与单测

同手册 ① §4、§5。Break 类问题的单测，大多可以落在「我们给游戏的那个值」这一层：
- 布局：`t_layout`；
- svc 参数校验：`t_svc_mem`；
- 服务回包：C# 测试。
都不需要游戏原件。
