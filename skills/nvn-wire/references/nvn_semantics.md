# NVN 逐对象 / 逐命令实现参照

用途：给新游戏写 NVN 接口层直连（S2Arm：NVN → Ryujinx IRenderer → graphics/metal）时，逐条对照「NVN 语义 → 小菠萝已跑通的做法 → S2Arm 现状」，让语义一次写对。

**来源与口径**
- 类型、枚举值只认社区头 `nvn.h`（MIT），不看任天堂官方 SDK 文档。
- 「缺省值」是小菠萝按 GL 缺省给的值，已在暗黑2 上跑通；nvn.h 只定义枚举，不定义缺省值。
- 文件简写：
  - 小菠萝 小菠萝树 `sw/gfx/nvn/`（内部资料，未公开）：H = `hle_nvn.c`（接口层）、M = `nvn_mtl.m`（Metal 回放）、O = `nvn_obj.h`、T = `nvn_tex.c`。
  - S2Arm 接线分支 wire/silksong-c 的 `graphics/wire/`：A = `WireApi.cs`、C = `WireCmd.cs`、R = `WireReplay.cs`、E = `NvnEnums.cs`、X = `NvnTex.cs`、S = `WireShaders.cs`。
- 行号取自 2026-10-23 的工作副本；代码改动后按函数名重新定位。
- 每条末尾标 S2Arm 现状：**已实现** / **未实现** / **有差异：差在哪**。⚠ 标出容易写错的点。

**通用约定（两边一致）**
- 对象就地存放在游戏分配的 NVN 对象内存里，大小不超过 nvn.h 的保留大小：小菠萝用 FITS 静态断言（O:8 起），S2Arm 启动时核（A:481）。
- NVNboolean 参数调用方不做扩展，只看低 8 位：小菠萝 `B(x)`（H:103），S2Arm `B()`（A:49）。⚠ 直接按 int 判真，会把高位垃圾当成真。
- 游戏会**按值拷贝**对象（memcpy NVNtexture），对象里不能存指向自身的东西：
  - 小菠萝：序号 + 不可变快照 `snap_tex` / `snap_prog`，命令载荷存快照地址（H:248–302）。
  - S2Arm：对象头 8 字节 = 魔数 + 宿主表号（A:19、42）。
- ⚠ 命令里录宿主表号或快照，**不录游戏对象地址**：游戏提交后可以改写或重建对象。

---

## 1. Device
- **DeviceInitialize / Finalize / BuilderSetDefaults / SetFlags**：只存 flags（H:108–116）。S2Arm **已实现**（A:54–57）。
- **DeviceGetInteger(what)**：返回 Tegra X1 真值表，游戏据此选渲染路径。
  - 小菠萝 H:122–144：表来自 nnheaders `nvn_DeviceConstantsNX.h`（SMO 上逐项实测），0x00–0x5F 共 96 项。0x5F（分离采样器绑定数）给 4096，未核；0x60 及以上报红给 0。
  - S2Arm **已实现**（A:59–67），同一张表按顺序展开。
  - ⚠ 表按下标逐项对齐，不凭记忆改值。0x00 / 0x01 是 API 版本 53 / 311，游戏只读不比较。
- **GetProcAddress**：按名字返回函数指针；名字不认识时，小菠萝返回报红跳板（H:117）。S2Arm **已实现**，在 `graphics/nvn/gfx/nvn/hle_nvn.c:181`，不在接线层里。
- **SetWindowOriginMode(0 左下 / 1 左上) / SetDepthMode(0 近=−w / 1 近=0)**
  - 小菠萝只记录（H:152–153）。D2R 实测左上、近=0，翻译查询按 D3D 作答，不翻转。
  - S2Arm **有差异**：两项都生效。深度模式 → GAL DepthMode（R:62）和支持缓冲标志位（R:507）；原点 → 对调正面绕序（R:406–407）。
  - ⚠ 两项要在首次提交前读到。S2Arm 的 DepthMode 只在渲染线程起来时读一次（R:62），游戏之后改不生效。
- **GetImageHandle / GetSeparateTextureHandle / GetSeparateSamplerHandle / GetTextureHandle**（编码见 §5）：小菠萝 H:145–148。S2Arm **已实现**（A:74–78），另有组合句柄 GetTextureHandle。
- **InstallDebugCallback**：小菠萝只存（H:149）。S2Arm **未实现**，调到走报红桩。
- **FinalizeCommandHandle**：小菠萝空实现（H:154）。S2Arm **未实现**。
- **GetCurrentTimestampInNanoseconds / GetTimestampInNanoseconds**：小菠萝无。S2Arm 在 A:68–69，按 19.2 MHz 节拍换算 `counter[1]*625/12`。

## 2. Queue / 提交 / 栅栏 / Sync
- **QueueBuilder***
  - 小菠萝：缺省命令区 64 KiB、计算区 256 KiB、控制区 16 KiB、冲刷阈值 4 KiB（H:471–474）。GetQueueMemorySize = 三块之和按 4 KiB 向上取整（H:482–485）；宿主不用这块内存，只是让游戏按此分配。
  - S2Arm **有差异**：各 Set 均为空，GetQueueMemorySize 固定 0x100000（A:81–89）。游戏照此分配即可，影响小。
- **QueueSubmitCommands(n, handles)**：按序提交；句柄数组属于游戏，入队时要拷一份。
  - 小菠萝（H:972–980）：进翻译队列，翻译线程按句柄顺序调 `mtl_exec`（H:850–870）。一次提交 = 一个 MTLCommandBuffer；栅栏值 = 已入队提交数（H:935、951）。
  - S2Arm **已实现**：每个句柄推一个作业（A:93），渲染线程按序回放（R:88、209）。
  - ⚠ 栅栏值必须与提交序号严格同步、单调。小菠萝提交时核对，对不上报红（H:861）。
- **QueueFenceSync(sync, cond, flags)**：此前提交到本队列的全部命令完成时触发；cond / flags 可忽略。
  - 小菠萝：`fenced=1, fence=x_fence()`，即当前已入队提交数（H:417）。
  - S2Arm **已实现**：先置 Pending，再推 JobFence；渲染线程回放到这里时用 `CreateSync` 分配 GAL 同步号（A:96–100、R:89）。
  - 命令流内的 **CommandBufferFenceSync**：小菠萝无；S2Arm 在 C:176，回放 R:274。
- **SyncWait(timeout ns)**：返回 0 ALREADY_SIGNALED / 1 CONDITION_SATISFIED / 2 TIMEOUT_EXPIRED。
  - 小菠萝（H:431–446）：没围栏过 → TIMEOUT_EXPIRED（同真机）；已完成 → ALREADY；否则等 GPU 完成值到 fence（M:854 `mtl_wait`，条件变量 + 截止时间）。
  - S2Arm **有差异**：`seq<=0` 一律返回 0（A:117），**没围栏过（−1）也返回已触发**，与真机的超时语义相反。
  - ⚠ 游戏若靠「没围栏 = 超时」判断首帧，会走错分支。
- **QueueWaitSync / CommandBufferWaitSync**（GPU 侧等待）
  - 小菠萝空实现（H:989–993）。前提：只有一条 Metal 队列；同步只来自 FenceSync / Acquire，两者都在同一队列上更早提交。
  - S2Arm **已实现**，同为空（A:101、C:175）。
  - ⚠ 以后加第二条队列（异步计算），这里必须改成真等。
- **QueueFinish**：等已入队的全部工作完成，含已入队的出图。
  - 小菠萝：`x_drain(); mtl_finish()`（H:496、M:871）。
  - S2Arm **已实现**：推临时栅栏后无限等（A:95）；出图在同一队列里，同样覆盖。
- **QueueFlush**：两边都是空实现。
- **QueueGetError**：小菠萝返回 NO_ERROR 并清零 info（H:492）。S2Arm **未实现**。
- **GPU 完成后才生效的 CPU 副作用**（事件写值、计数器）：小菠萝在命令缓冲完成回调里按序执行（M:798–850 `post` 表）。

## 3. MemoryPool
- **BuilderSetStorage(mem, size) / SetFlags / Initialize**：池就是游戏给的真内存。
  - flags：0x1 CPU_NO_ACCESS、0x2 / 0x4 CPU 非缓存 / 缓存、0x8 GPU_NO_ACCESS、0x10 / 0x20 GPU 非缓存 / 缓存、0x40 SHADER_CODE、0x80 COMPRESSIBLE、0x100 PHYSICAL、0x200 VIRTUAL。
  - 小菠萝 H:183–190：非虚拟池无存储时报红；建池时用 `newBufferWithBytesNoCopy` 建**零拷贝** MTLBuffer（M:422–434）。
  - S2Arm **已实现**（A:128–136）：GAL 缓冲在首用时 `CreateBuffer(mem,size)` 零拷贝建（R:112–117）。
- **GPU 地址 = CPU 地址**：GetBufferAddress 返回 mem 本身（H:193、A:142）。
  - 反查「地址 → 池 + 偏移」：小菠萝用线性区间表（M:446–466）；S2Arm 用有序区间表 + 二分（A:147–165）。
  - ⚠ 不在任何池里的地址必须报红，不能静默。小菠萝的缓冲拷贝遇到直接 die（M:677）。
- **页对齐**：Apple 页 16 KiB，NVN 池只保证 4 KiB。
  - 小菠萝：起点向下、终点向上取整到页，建覆盖整池的缓冲；偏移相对取整后的起点（M:424–430）。
  - S2Arm 交给 GAL CreateBuffer，S2Arm 侧未核。
  - ⚠ 偏移基准写错，所有 GPU 地址整体错位。
- **驻留**
  - 小菠萝：建池时**不进驻留集**；首次取址（`mtl_addr` / `mtl_gpu_addr`）时才放进去，并当场提交驻留集（M:405–417）。原因：iOS 把整池钉成 wired，512 MB 渲染目标池实测把 4 GB 机型挤死。
  - S2Arm **有差异**：由 graphics/metal 的 CreateBuffer 决定，接线层不控制。⚠ 大池在 iOS 上的内存要实测。
- **Finalize**：小菠萝退役缓冲，等用过它的提交完成后才释放（M:436–444）。S2Arm **已实现**（A:137 删区间 + JobFreePool；R:95）。
- **FlushMappedRange / InvalidateMappedRange**：统一内存，两边都是空。
- **CPU 改写了池里的贴图内容**
  - 小菠萝：脏页追踪（mprotect，`nvn_dirty_*`）；预排布贴图内容变了就重传（M:1302–1330）。
  - S2Arm **有差异**：只在首次被采样时上传一次（R:150），之后的 CPU 改写看不到；`S2A_WIRE_REUPLOAD=1` 只是诊断开关。
  - ⚠ 流式素材写进同一存储时，S2Arm 会显示旧图。

## 4. Buffer
- Buffer 只是池里的一段 `{pool, off, size}`，地址 = 池地址 + off。
- 小菠萝**未实现** Buffer 系列：D2R 不建 Buffer 对象，直接用池地址加偏移。
- S2Arm **已实现**：BufferBuilder / Initialize / GetAddress / Map 等（A:168–186），只存参数，不建宿主对象。
- **NVNbufferRange** = `{u64 address, u64 size}`。绑定时 size 可能为 0：S2Arm BufRange 把 0 当到池尾（R:124）。

## 5. Texture / TextureBuilder / TextureView / 池注册 / 句柄
- **TextureBuilderSetDefaults**：target 2D(1)；宽 = 高 = 深 = 级数 = 1；其余 0。
  - ⚠ 保留 device：小菠萝先取出 dev 再清零（H:209–212）。
  - S2Arm **已实现**（A:202、X:32），另给恒等 swizzle R=2、G=3、B=4、A=5。
- **SetSize1D**：小菠萝同时把 height、depth 置 1（H:219）。S2Arm **有差异**：只设 width（A:209），旧 height / depth 会残留。
- **SetPackagedTextureLayout(8 字节)**：预排布贴图。布局第 0 字节 = 块高 log2，以它为准（T:97 `pkg_block_h-1`）；真游戏 16 例里有 4 例与自动算法不同。S2Arm **已实现**（A:218、X:39）。
- **GetStorageSize / Alignment**：Tegra X1 块线性规则，算法移植自 deko3d（T:79–112）。
  - 一个 GOB = 64 B × 8 行；块高按「高×1.5」挑；各级按块对齐累加；分层贴图的层尺寸按块对齐。
  - LINEAR（flags 0x10）：行距 = stride，否则按 32 对齐（另一位 0x40 时按 128）。
  - BUFFER（target 10）：大小 = bpb × 宽。
  - S2Arm **已实现**（X:150–202，逐行移植）。
  - ⚠ 尺寸算错，游戏会把下一个资源压到这张贴图的尾部。
- **TextureInitialize**
  - 小菠萝：快照 builder、算布局、`mem = pool->mem + off`、换新序号（H:313–324）。
  - S2Arm **已实现**（A:223–232），每次新表号。
  - ⚠ 同一对象重新 Initialize 必须换新序号 / 表号，否则回放层会拿到旧的 MTLTexture。
- **宿主贴图的建法**（M:1302 `tex_mtl`）
  - 小菠萝：预排布贴图从池里解排布上传；BUFFER 贴图在池缓冲上零拷贝建贴图缓冲视图；其余建只被 GPU 写的 private 贴图。
  - S2Arm **有差异**：
    - 不区分预排布，凡没被 GPU 写过的贴图，首次被采样时都从池里解排布上传（R:143–151）。
    - 同一存储上的多个贴图对象共用一张 GAL 贴图，格式不同则建视图（R:126–142）。小菠萝没有别名处理，按序号各建各的。
- **TextureGetViewOffset(view)**：起始级偏移 + 起始层 × layer_size（H:346–352）。S2Arm **未实现**。
- **ReadTexels / ReadTexelsStrided**：CPU 读贴图。小菠萝先排空翻译队列；预排布贴图直接读池，其余从 GPU blit 回读（H:354–368、M:4784）。row / img 为 0 = 紧排。S2Arm **未实现**。
- **WriteTexels**：小菠萝无。S2Arm 在 A:251–263：拷一份交渲染线程 SetData，行按 4 字节对齐。
- **TextureCompare**：描述符相同且 mem 相同返回真（H:331）。S2Arm **未实现**。
- **TextureGetRawStorageClass**：头文件无原型；main 调用点拿返回值与 1 比，小菠萝给 1（H:336）。S2Arm **未实现**。
- **TextureView**：SetDefaults = 全不设；SetLevels(base, n) / SetLayers(min, n) / SetFormat / SetTarget 各带一个「已设」标志（H:338–342）。
  - ⚠ n = 0 = 到末尾。小菠萝回放：`nl = 0 → mipCount-l0`，层同理（M:2350–2352）。
  - ⚠ 3D 贴图的层 = depthPlane，不是 slice（M:1841）；cube 层数 = arrayLength × 6。
  - S2Arm **有差异**：
    - 视图打包成 0x28 字节，多了 swizzle 和 depth-stencil mode。
    - 用魔数识别「经我们的 Set* 初始化的视图」，游戏自写的视图报红并按无视图处理（A:192–272、R:171）。
    - 1D ↔ 2D 互建视图在 Metal 上会崩，报红后退回基础贴图（R:176）。
  - GetLayers：小菠萝 H:343；S2Arm **未实现**。
- **TexturePoolInitialize(pool, off, n) / RegisterTexture(id, tex, view) / SamplerPoolRegisterSampler(id, samp)**：描述符写进池，**登记时快照**贴图对象与视图。
  - 小菠萝：`mtl_reg_tex` 快照整个 tex_t + view（M:2296–2305），按需建 Metal 视图并缓存（M:2326–2361）。
  - 池容量 n 以外的号 = 空槽、读 0：游戏会用 `GetSeparateTextureHandle(0xFFFFF)` 绑不用的槽（M:2322）。池内未登记的号报红。
  - S2Arm **已实现**（A:275–298，存表号 + 视图值），另有 RegisterImage / RegisterSamplerBuilder。
  - ⚠ 0–255 号描述符驱动保留。绑 0 号句柄 = 此槽为空，按 D3D 读全零（见 §7 哑资源）。
- **句柄编码**（两边一致）
  - 分离贴图 = 贴图号；分离采样器 = 采样器号 << 20；组合 = 贴图号 | 采样器号 << 20。
  - 图像句柄 = 贴图池号：游戏不调 RegisterImage，图像与贴图共用登记（H:683）。
  - 回放：`tid = h & 0xfffff`，`sid = h >> 20`（M:2900–2906）。
  - ⚠ 合并采样的着色器从**贴图槽**取采样器（M:2900 `NVN_RB_SAMPT`、R:456 `sh = th`）。S2Arm BindTexture 把完整句柄同时写进贴图表和采样器表（C:117–118）。

## 6. Sampler
- **SamplerBuilderSetDefaults**（保留 device）：min NEAREST_MIPMAP_LINEAR(4)；mag LINEAR(1)；wrap s/t/r REPEAT(1)；compare mode NONE(0)、func LESS(2)；lod −1000..1000；bias 0；aniso 1；边框 0（H:373–379）。
  - S2Arm **有差异**：lodMin 缺省 0（A:305）。小菠萝回放也把负值钳到 0（M:2385），Metal 下效果相同，但 GetLodClamp 读回的值不同。
- **枚举**
  - min：0 NEAREST、1 LINEAR、2 N_MIP_N、3 L_MIP_N、4 N_MIP_L、5 L_MIP_L；mag：0 NEAREST、1 LINEAR。
  - wrap：0 CLAMP、1 REPEAT、2 MIRROR_CLAMP、3 MIRROR_CLAMP_TO_EDGE、4 MIRROR_CLAMP_TO_BORDER、5 CLAMP_TO_BORDER、6 MIRRORED_REPEAT、7 CLAMP_TO_EDGE。
  - compare func：1 NEVER … 8 ALWAYS。
  - ⚠ NVN 比较函数 = Metal MTLCompareFunction + 1：小菠萝写 `cmp_func-1`（M:2388），深度 / 模板同理（M:2733–2741）。
- **小菠萝映射**：寻址 0 / 7 → ClampToEdge、2 / 3 → MirrorClampToEdge、4 / 5 → ClampToBorder、6 → MirrorRepeat（M:2370）。边框色 Metal 只有 3 种预设，按 a、r 分量挑（M:2389）。
- **S2Arm** **已实现**（E:383–424、A:320–332 MakeSamp）：没登记的组合报红；GAL 边框色可任意。
- **SetLodSnap**：Metal 无对应，小菠萝忽略（H:388）。S2Arm **未实现**。
- **BuilderGetMinMagFilter / GetWrapMode**：小菠萝 H:389–394。S2Arm **未实现**（Get 系列只有 LodClamp / LodBias / Compare / BorderColor）。
- **SamplerInitialize**：快照 builder 参数（H:395）。S2Arm **已实现**。

## 7. Program（控制段、c1、绑定对照表）
- **ProgramSetShaders(n, NVNshaderData[])**：NVNshaderData = `{u64 data（代码 GPU 地址 = CPU 地址）, void* control（CPU 指针）}`，n ≤ 6。
  - 小菠萝：拷 sd 数组、换序号、旧快照退役（H:405–411）。回放时取键 `sha256(control 的 0x880 字节)` 前 16 个十六进制字符 → 映射表 → 离线 metallib（M:2261–2285）；查不到再查 main 内嵌计算核（M:2245）。
  - S2Arm **已实现**，而且更稳：控制段**在调用当场拷一份 0x880 字节**（A:362–368），实测首绘前游戏已覆盖控制段。
  - ⚠ 小菠萝回放时读的是游戏的 control 指针，换游戏前要核控制段的生命周期。
- **阶段判定**：小菠萝查表得出。S2Arm 看代码头：0x12345678 + SPH 第 0 字 bit10..13 = 阶段（0 / 1 顶点、2 TC、3 TE、4 几何、5 片元）；无 NVN 头 = 计算（A:382–387）。
- **BindProgram(prog, stages 位)**：stage 位 0x1 顶点、0x2 片元、0x4 几何、0x8 TC、0x10 TE、0x20 计算。语义是**按阶段替换**，prog 为空 = 解绑这些阶段。
  - 小菠萝：整个替换 `S.prog`，忽略 stages（M:3174）。
  - S2Arm **有差异**，更贴近语义：按位逐阶段绑，图形 / 计算分开存（R:239–250）。Unity 先绑 0x3，再 `BindProgram(NULL, 0x3c)`。
  - ⚠ 照小菠萝写，解绑计算会把图形程序一起清掉。
- **NVN 槽号 = D3D 寄存器号**（小菠萝 README:31–35，全库 10847 个变体实测）
  - uniform 槽 r = `c[3+r]`。
  - 分离贴图 t_r 的句柄在 `c[2][0x168+8r]`；分离采样器 s_r 在 `c[2][0x568+8r]`。
  - 存储缓冲 r 在 `c[0][基址+16r]`：地址 8 字节 + 大小 4 字节；基址 顶点 0x110、计算 0x310、片元 0x510。
  - 小菠萝：回放时**现填**驱动段（M:2949–2970）：c0 = 存储缓冲表；c2 = 贴图 / 采样器句柄表各 128 项；离线统计证明不读的段给 0。
  - S2Arm **有差异**：翻译器把 c0 / c2 取址反解成 NVN 槽号（S:557–610）；真读驱动段 c0 / c2 的着色器报红、未实现（R:443）。
  - ⚠ 其他阶段的 c0 基址未实测，小菠萝遇到报红（M:2956）。
- **c1**（着色器自带常量段）
  - 小菠萝：取自离线着色器包（M:2066 `c1_store`）；长度 0 而着色器仍声明时读全零缓冲（M:2941）。
  - S2Arm **有差异**：运行时零拷贝绑定代码块里 `[control+0x700, control+0x704)` 这一段（R:486–496）。
- **没绑的资源**（句柄 0 / 地址 0）：语义是按 D3D 读 0。
  - 小菠萝给全零哑资源（M:2757–2796、2910–2933）：哑贴图按「类型 × 像素类」缓存；图像写入进专用哑贴图；缓冲 64 KiB 全零。
  - S2Arm **有差异**：贴图给 null，缓冲直接跳过不绑（R:445、457）；GAL / Metal 下读到的值未核。
  - ⚠ 未绑资源读出非零会整屏偏色。
- **每阶段槽数**：小菠萝 贴图 / 采样器 128、图像 32、uniform 16；S2Arm 贴图 / 采样器 32（录制时也钳到 32，C:110）、图像 8、uniform 18。S2Arm **有差异**。

## 8. CommandBuffer（命令内存协议、补内存回调、宿主补段）
- **记录格式**（两边一致）：`{u32 op, u32 size（含头，8 字节对齐）}` + 载荷，写进游戏给的命令内存；段尾永远留够一条 JUMP / END（24 字节）（H:500、C:22）。
- **AddCommandMemory(pool, off, n)**：录制中换段时，在旧段尾写 `JUMP → 新段首`；新段首按 8 字节对齐（H:527–531、C:39）。
- **补内存回调**：空间不够时按 NVN 约定调 `cb(cmdbuf, OUT_OF_COMMAND_MEMORY(0), 需要字节, cb_data)`，最多重试 2 次（H:562–571、C:57–67）。⚠ 需要字节要包含 24 字节预留。
- **宿主补段**：我们的记录比真机大，游戏池会被用空，游戏会拿空池调 Add（`p=NULL` 或 `n<64`）。这不是错误，要兜住：给 1 MiB 宿主段，64 段轮用，8 帧后回收（H:532–558、C:42–56）。S2Arm **已实现**。⚠ 小菠萝原先在这里读 NULL+8 段错误。
- **按实际个数分配记录**：数组类绑定只分配 n 个元素（H:621–623 `RECN`）。定长按最大个数记，空尾占命令字节四到五成，会把游戏池撑爆。S2Arm **已实现**（C:88–110 按 n 计长）。
- **BeginRecording / EndRecording**：录 BEGIN / END；EndRecording 返回句柄 = BEGIN 记录地址；重入报红（H:572–583、C:68–69）。
- **CopyCommands / CallCommands**：录 CALL，回放递归执行（H:585、M:5200、R:222）。⚠ 小菠萝对 CopyCommands 是「调用」而非复制，前提是被调命令内存在执行时仍有效（游戏按栅栏回收）。
- **AddControlMemory**：两边都是空。**GetCommandMemoryFree**：小菠萝无；S2Arm 在 C:31。
- **状态跨命令缓冲继承**：小菠萝的回放状态 `S` 只在首次 exec 时 reset（M:5178），之后跨命令缓冲、跨提交沿用。S2Arm **已实现**，同样只 InitState 一次（R:61、199）。
  - ⚠ 不要在每次提交时重置状态：游戏常在前一个命令缓冲里绑定、下一个里绘制。
- **SetCopyRowStride / SetCopyImageStride**
  - 小菠萝：录成命令，回放时改状态（H:735–736、M:3207）。
  - S2Arm **有差异**：存在 CmdS 对象里，录拷贝时固化进记录（C:197、208–211），另有 Get。单个命令缓冲内两者等价；跨命令缓冲时，小菠萝沿用回放状态，S2Arm 沿用同一 CmdS 对象的值。
- **DebugGroup / Marker / SetShaderScratchMemory**：两边都是空（H:994–997、C:161–174）。

## 9. 状态对象（缺省值逐字段列，枚举值按 nvn.h）
游戏按值拷贝这些小结构：就地打包，绑定时按值录进命令。
- **BlendState**（H:741）：target 0；srcRGB ONE(2)；dstRGB ZERO(1)；srcA ONE(2)；dstA ZERO(1)；eqRGB ADD(1)；eqA ADD(1)。
  - 方程：1 ADD、2 SUB、3 REV_SUB、4 MIN、5 MAX（M:2503）。因子：1–11、0x10–0x13 双源、0x61–0x64 常量色 / 常量 α（M:2495）。
  - ⚠ 绑定时按 **target** 写进 `blend[target]`，不是覆盖全部目标（M:3180）。
  - S2Arm **已实现**（A:427、R:223）。
- **ColorState**（H:747）：blendEnable 位图 0；logicOp COPY(3)；alphaFunc ALWAYS(8)。
  - 小菠萝只用 blendEnable，logicOp 和 alphaFunc 都不处理（D2R 不用）。
  - S2Arm **有差异**，多做了透明测试：alphaFunc + SetAlphaRef 进支持缓冲，并按开关分着色器特化（R:365、508）。
- **ChannelMaskState**（H:752）：缺省 0xFFFFFFFF；每目标 4 位 r=1 g=2 b=4 a=8，置位 = 写。S2Arm **已实现**（R:225）。
- **MultisampleState**（H:758）：enable 1；samples 0；alphaToCoverage 0；其余 0；SampleLocations 为空。
  - 小菠萝：a2c 进管线（M:2527）。
  - S2Arm **有差异**：Op.Ms 回放时忽略（R:226），a2c 不生效。
- **PolygonState**（H:764）：cull NONE(0)；front CCW(1)；mode FILL(2)；offsetEnables NONE(0)。
  - 枚举：face 0 无 / 1 前 / 2 后 / 3 前后；front 0 CW / 1 CCW；mode 0 POINT / 1 LINE / 2 FILL；offset 位 1 POINT / 2 LINE / 4 FILL。
  - 小菠萝（M:4480–4485）：FRONT_AND_BACK 直接不画；LINE → Metal 线框；offset 位 4 才设 depthBias（units → bias、factor → slope、clamp）。
  - S2Arm **有差异**：polygon mode 不生效；DepthBias 回放为空（R:272）。⚠ 阴影贴图常靠 polygon offset。
- **DepthStencilState**（H:769）：depthTest 0；depthWrite **1**；depthFunc LESS(2)；stencilTest 0；stencilFunc 前 / 后 ALWAYS(8)；fail / zfail / zpass 前后都 KEEP(1)。
  - 枚举：深度 / 模板函数 1 NEVER … 8 ALWAYS；stencil op 1 KEEP、2 ZERO、3 REPLACE、4 INCR、5 DECR、6 INVERT、7 INCR_WRAP、8 DECR_WRAP。Metal 值 = NVN 值 −1（M:2733–2741）。
  - SetStencilFunc / SetStencilOp 的 face 按位作用于前 / 后。
  - S2Arm **已实现**（A:455–467、R:392–402）。
  - ⚠ 深度写缺省**开**。没挂深度附件时，深度测试和模板都要关（小菠萝 `dss_get(has_depth, has_stencil)`）。
- **VertexAttribState**（H:785）：format 0（= 未用）；offset 0；stream 0。打包 fmt 8 位、offset 19 位、stream 5 位；偏移超范围报红（H:787）。
  - S2Arm **已实现**（A:469–475），同样的位宽。
  - ⚠ format 0 的属性给常量 0 / 1：小菠萝走 bufferIndex 30 的常量零缓冲（M:2552–2554）。
  - ⚠ 按着色器反射的「NVN 属性号 → Metal loc」取属性，不是按顺序（M:2546）。
- **VertexStreamState**（H:791）：stride 0；divisor 0。
  - 小菠萝：stride 0 → Constant；divisor ≠ 0 → PerInstance，步进率 = divisor（M:2558–2561）。
  - S2Arm **已实现**，交给 GAL VertexBufferDescriptor（R:423）。
- **SetStencilValueMask / Mask / Ref(face, v)**：命令，face 按位；缺省 0xFF / 0xFF / 0（M:2474）。
  - 小菠萝：Metal 只有一个参考值，只用正面的（M:620）。
  - S2Arm **已实现**，前 / 后分开（R:265–267）。
- **SetBlendColor**：两边都已实现（M:3206、R:268）。

## 10. 绘制 / 派发 / 间接
- **图元**：0 POINTS … 6 TRIANGLE_FAN、7 QUADS、8 QUAD_STRIP、9 POLYGON、0xA–0xD 带邻接、0xE PATCHES。
  - ⚠ Metal 没有四边形。小菠萝给非索引 QUADS 用共享索引表 `0,1,2,0,2,3`（M:4563–4569）；带索引的四边形报红。
  - S2Arm 映射到 GAL Quads（E:341），交给 graphics/metal；实际表现未核。
- **DrawArrays(prim, first, count)**：count 0 不编码，Metal 校验层要求非零（M:4562）。S2Arm 有 DrawArrays / Instanced（C:180–181），count 0 的处理未核。
- **DrawElements*(prim, itype, count, ibufAddr, baseVertex, baseInstance, instances)**：itype 0 UBYTE、1 USHORT、2 UINT。
  - 小菠萝：8 位索引报红（M:4574）；instances 0 按 1（M:4580）。
  - S2Arm **已实现**：支持 UByte（E:360），`Max(1, inst)`（R:282）。
  - ⚠ 索引缓冲地址是 GPU 地址，要经池反查；长度 = count × 索引大小。
- **DrawArraysIndirect / DrawElementsIndirect**：小菠萝无。S2Arm 在 C:187–188、R:284–290。
- **MultiDraw*IndirectCount**：两边都没实现，小菠萝调到报红。
- **DispatchCompute(x, y, z)**：小菠萝线程组大小取反射，派发前结束渲染 / blit 编码器（M:4719–4760）。S2Arm **已实现**（R:291）。
- **DispatchComputeIndirect**：小菠萝空实现（H:988，D2R 调用 0 次）。S2Arm **未实现**，调到走报红桩。
- **Barrier(bits)**：位 1 ORDER_PRIMITIVES、2 ORDER_FRAGMENTS、4 TILED、8 INDIRECT、0x10 INV_TEXTURE、0x20 INV_SHADER、0x40 INV_TEX_DESCRIPTOR、0x80 INV_ZCULL。
  - 小菠萝：空实现，依赖 Metal 资源跟踪 / 编码器屏障（M:5261）。
  - S2Arm：`pl.Barrier()`（R:273）。
- **SetPrimitiveRestart / PointSize / LineWidth / DepthClamp / RasterizerDiscard**：小菠萝无。S2Arm 只有 PrimitiveRestart 生效（R:271），其余录了、回放为空（R:270）。

## 11. 拷贝（B2T / T2B / T2T / 行距 / 区域 / 标志）
- **NVNcopyRegion** = `{x, y, z offset, width, height, depth}`；depth 0 按 1。
- **行距**：来自命令流里的 SetCopyRowStride / ImageStride，0 = 紧排。
  - 紧排行 = ⌈w / 块宽⌉ × bpb；紧排像 = 行 × ⌈h / 块高⌉。
  - 小菠萝拒绝「行距 < 紧排」和溢出（`nvn_copy_pitch.h`）。
- **CopyBufferToTexture(src, tex, view, region, flags)**
  - 小菠萝（M:4815–4850）：级 = view 起始级；层 = view 起始层 + z；3D 整块一次 blit，其余逐层 blit；设备无 BC 时先在 CPU 解压。
  - S2Arm **有差异**：在渲染线程**由 CPU 读池**后 SetData（R:329–348），不在 GPU 时序上按序 blit，读到的是回放那一刻 CPU 内存的值；3D 多层未实现；行按 4 字节对齐。
  - ⚠ 源数据若由同一提交里更早的 GPU 命令写入，S2Arm 会读到旧值。
- **CopyTextureToBuffer**：小菠萝对称 blit（M:4762–4788）。S2Arm **未实现**（R:294 报红）。
- **CopyTextureToTexture(src, sv, sr, dst, dv, dr, flags)**：flags 1 LINEAR_FILTER、2 ENGINE_2D、4 / 8 / 0x10 MIRROR_X / Y / Z。
  - 小菠萝：只做「等尺寸、同格式、不镜像」的 blit；缩放、镜像、换格式报红（M:4892–4931）。
  - S2Arm **有差异**，覆盖更广：GAL `CopyTo(src 区域, dst 区域, linear)`，可缩放（R:349–357）；镜像标志被忽略。
  - ⚠ 区域是 x、y、w、h，要换成 Extents2D(x0, y0, x0+w, y0+h)；z 走层。
- **CopyBufferToBuffer(src, dst, n, flags)**：小菠萝 blit，按 GPU 时序（M:674–680）。S2Arm **已实现**（R:295）。
- **UpdateUniformBuffer(buf, bufSize, off, n, data)**
  - ⚠ 数据**在录制时**拷进命令内存（录制后调用方可以改原数据），回放时按序写入：小菠萝走 blit（H:606–611、M:5219）。
  - S2Arm **有差异**：录制一致（C:214–218）；回放用 `r.SetBufferData`（R:297），它在 GPU 时序上是否排在前后绘制之间，未核。
- **ClearBuffer**：小菠萝无，S2Arm 在 R:296。**Downsample**：小菠萝无；S2Arm 录了、回放报红（R:299）。

## 12. 清屏
- **ClearColor(index, rgba, mask)、ClearColorui / i、ClearDepthStencil(depth, depthMask, stencil, stencilMask)**：作用于当前渲染目标的第 index 个附件，受剪裁和通道掩码约束。
  - 小菠萝（M:5233–5248）：
    - 挂起清除，成为下一个通道的 `loadAction = Clear`。
    - 只支持「通道开始前、掩码 0xF、剪裁覆盖选中 mip 级」；通道中途、部分掩码、部分剪裁报红（M:5237）。
    - 有挂起的清除但没有绘制时，开一个只挂被清附件的通道落地（M:1996 `rp_flush`）。
  - S2Arm **有差异**：
    - 直接调 GAL `ClearRenderTargetColor(idx, 0, 1, mask, col)`（R:252–260），掩码真传。
    - ui / i 整数清除按浮点位处理，报红（R:256）。
    - 剪裁在回放 SetScissor 时立即下发（R:263）；GAL 清除是否遵守剪裁，未核。
  - ⚠ depthMask 是 NVNboolean，只看低 8 位（H:636、C:136）；stencilMask 为 0 = 不清模板。
- **ClearTexture / ClearTextureui(tex, view, region, rgba, mask)**
  - 小菠萝：只支持整级整面、四通道全写、可作渲染目标；逐层开只清不画的通道；视图换格式则在该格式视图上清（M:4933–4976）。游戏依赖清出的初值（Metal 私有贴图初值未定义）。
  - S2Arm **未实现**：Op.ClearTex 只是枚举值，WireTable 里没有这个函数。

## 13. 渲染目标
- **SetRenderTargets(n, colors[], views[], depth, depthView)**：colors / views 可以为 NULL，单个元素也可以为 NULL。
  - 小菠萝：录颜色 / 深度快照与视图（H:625–631）；回放时结束旧通道，下次绘制按挂起的清除开新通道（M:5221–5231、1855）。
  - S2Arm **已实现**：GAL `SetRenderTargets(rt[], depth)`，颜色对象号解析不出时报红（R:313–327）。
  - ⚠ 附件尺寸取**选中 mip 级**：`base >> level`，最小 1。默认视口 / 剪裁取全部已挂附件选中级宽高的最小值（M:1987–1995、README:91）。
  - ⚠ 颜色视图换格式（如 RGBA8 底图经 RGBA8_SRGB 视图写）必须挂该格式的视图；只挂底图，sRGB 编码整个丢掉、画面偏暗（M:1835–1851）。S2Arm 经 `View(..., asTarget:true)`（R:319）已覆盖格式视图。
  - ⚠ 3D 贴图附件的层要设 depthPlane（M:1841）。
- **管线颜色格式**取实际挂上的附件格式；只写 1 个目标而着色器输出更多时，多出的不绑即丢弃（小菠萝 NVN_Metal映射.md:174）。
- **DiscardColor / DiscardDepthStencil**：小菠萝无；S2Arm 为空（C:164–165）。

## 14. 视口 / 剪裁 / 深度范围 / 方向
- **SetViewports(first, n, float[4n] = x, y, w, h)、SetDepthRange(near, far) / SetDepthRanges**：深度范围单独设，缺省 0..1（M:2474）。
  - 小菠萝：只用 vp[0]，按 Metal `{x, y, w, h, near, far}` 原样设、**不翻转**（M:4470）；没设过视口用整个目标。
  - S2Arm **有差异**（后端坐标系不同）：GAL 视口按 `(x, y+h, w, −h)` 设，左上原点时对调正面绕序（R:309–311、406）。这是 10-23 接线局在丝之歌上的实测口径。
  - ⚠ 换游戏先读 SetWindowOriginMode，按真值核对翻转，不照搬。
- **SetScissor(x, y, w, h)**
  - 小菠萝：x、y 为负钳到 0；右 / 下钳到目标尺寸；钳完为空则跳过本次绘制（M:4472–4478）。
  - S2Arm：初值 65535 大框（R:201），`SetScissors` 立即下发；Rectangle 越界钳制交给 GAL，未核。
- **SetViewportSwizzles**：小菠萝无；S2Arm 为空，仅见恒等值（C:143）。
- **SetDepthBounds**：小菠萝空实现（H:988）；S2Arm 开启时报红（C:157）。

## 15. Window / Acquire / Present / 节拍
- **WindowBuilderSetDefaults**：interval 1，保留 device（H:1023）；SetTextures 最多 4 张（H:1026）。
- **WindowInitialize**：小菠萝快照交换链贴图并标为窗口贴图（H:1031–1039）。S2Arm **已实现**（A:397–406），crop 初值 = 首张贴图尺寸。
- **SetCrop(x, y, w, h)**
  - ⚠ 必须随出图**按值入队**：掌机有效区域小于交换链尺寸时，整张采样会把右 / 下没画的部分也搬上屏（README:67–72）。
  - 小菠萝：全零 / NULL = 整张（H:1041、1351）。S2Arm **已实现**：Present 时取当时的值给 ImageCrop（R:105）。
- **AcquireTexture(window, sync, &idx)**：返回下一张可画的交换链序号；垂直同步的阻塞**在这里**，不在出图（游戏常持锁调出图）。
  - 小菠萝（H:1058–1086）：轮转 `idx = next++ % n`；睡到 `avail[idx]`（这一张的显示时刻 + 一个出图周期）；该张上次的出图还没被出图线程处理完就等它归还；sync 置为 `fence = 当前已入队提交数`。
  - S2Arm **有差异**：节拍 = 上次出图 + interval / 60 秒（A:419–420），不按每张的可用时刻；sync Seq = 0 = **立即已触发**（A:421），不跟前面的提交挂钩。
  - ⚠ 游戏若在 SyncWait(acquire sync) 之后马上改写交换链贴图，S2Arm 可能与上一帧出图竞争。
- **QueuePresentTexture(queue, window, idx)**：只入队，立即返回。
  - 小菠萝：进翻译队列，按出图周期排显示时刻（H:1341–1352、1443–1449、`nvn_pace.h`）。
  - S2Arm **已实现**：JobPresent → 渲染线程 `r.Window.Present`（A:102–106、R:99–109）。
- **Set / GetPresentInterval**：小菠萝 Set（H:1040）；S2Arm **已实现**（A:410–411）。
- **WindowFinalize**：两边都是空（H:1000、A:407）。

## 16. 计数器与事件
- **ReportCounter(type, dstAddr)**：写 16 字节 `{u64 value, u64 timestamp}`，时间戳为 19.2 MHz 节拍（`ns × 12 / 625`）。
  - type：0 TIMESTAMP、1 SAMPLES_PASSED … 0xF ZCULL_STATS、0x10 TIMESTAMP_TOP。
  - 小菠萝（M:5205–5209、814–830）：TIMESTAMP / TOP 的 value = 时间戳；SAMPLES_PASSED 用 Metal 可见性结果，统计自上次 Reset 以来各槽之和；其余类型 value = 0。一律在**命令缓冲完成回调**里写。
  - S2Arm **有差异**：回放时 CPU 当场写 `{0, CPU 时刻}`（R:298）。所有类型 value 都是 0，SAMPLES_PASSED 恒 0，且写入早于 GPU 完成。
  - ⚠ 遮挡查询或 GPU 计时驱动动态分辨率的游戏会受影响。小菠萝也是完成后由 CPU 写，同一提交里的整理内核读到的是旧值（README:105）。
- **ResetCounter(type)**：小菠萝对 SAMPLES_PASSED 清零并开始计数（M:5210–5216）。S2Arm **未实现**（C:220 空函数）。
- **Event**（NVNevent = 池里的一个 u32）
  - EventBuilderSetStorage(pool, off)；Initialize 时取 `pool->mem + off`（H:450–457）。
  - EventGetValue 直接读这个 u32；EventSignal(mode, v) 由 CPU 写，WRITE(0) 赋值、ADD(1) 累加（H:464–467）。
  - **CommandBufferSignalEvent(event, mode, location, flags, v)**：命令缓冲完成后按序写入（H:588–593、M:5203、686、819），location / flags 可忽略。
  - **WaitEvent**：小菠萝空实现（H:998）。前提：单队列按序执行，所等的信号总在它之前。
  - S2Arm **整组未实现**：没有 Event 对象，也没有 SignalEvent / WaitEvent。⚠ 游戏用事件做 CPU ↔ GPU 进度握手时，读到的永远是初值，可能卡死或跳帧。

---

## 17. 小菠萝实现了、S2Arm 还没有的函数
对照方法：小菠萝 H 里的 `NVN(...)` / `NVN_NOPROTO(...)` 定义，加上 `g_nops` 空实现表，共 213 个；减去直连前端 `graphics/nvn/gfx/nvn/hle_nvn.c` 的实现，其中 GetProcAddress 在 `hle_nvn.c:181` 已实现，实际缺 **27** 个：
- 命令：`nvnCommandBufferClearTexture`、`nvnCommandBufferClearTextureui`、`nvnCommandBufferSignalEvent`、`nvnCommandBufferWaitEvent`（小菠萝为空）、`nvnCommandBufferDispatchComputeIndirect`（小菠萝为空）
- 事件：`nvnEventBuilderSetDefaults`、`nvnEventBuilderSetStorage`、`nvnEventInitialize`、`nvnEventFinalize`、`nvnEventGetValue`、`nvnEventSignal`
- 设备 / 队列：`nvnDeviceFinalizeCommandHandle`、`nvnDeviceInstallDebugCallback`、`nvnQueueGetError`
- 贴图：`nvnTextureReadTexels`、`nvnTextureReadTexelsStrided`、`nvnTextureInvalidateTexels`、`nvnTextureGetViewOffset`、`nvnTextureCompare`、`nvnTextureGetRawStorageClass`（无原型，返回 1）、`nvnTextureBuilderGetFlags`、`nvnTextureViewGetLayers`
- 采样器：`nvnSamplerBuilderGetMinMagFilter`、`nvnSamplerBuilderGetWrapMode`、`nvnSamplerBuilderSetLodSnap`
- 多重采样：`nvnMultisampleStateSetSampleLocations`、`nvnMultisampleStateSetSampleLocationsEnable`

S2Arm 表里有函数、但回放没做或报红的（不在上面的清单里，写新游戏时同样要补）：`CopyTextureToBuffer`（R:294）、`Downsample`（R:299）、`ResetCounter`（C:220 空函数）、MultisampleState 回放（R:226）、polygon offset / DepthBias 回放（R:272）、整数清色（R:256）、驱动段 c0 / c2（R:443）。

反向，S2Arm 有、小菠萝没有，新游戏可直接复用：Buffer 对象系列、WriteTexels、间接绘制、CommandBuffer / Queue 的 FenceSync、ClearBuffer、组合句柄 BindTexture(s)、RegisterImage / RegisterSamplerBuilder、视图 swizzle / depth-stencil mode、透明测试、PrimitiveRestart、GetCopyRowStride。
