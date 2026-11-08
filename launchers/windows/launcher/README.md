# Windows 启动器（C11 / #1629）

首片：Avalonia 12.1.5 / .NET 10 工程骨架与环境自检页。仅调用 `pack/jobs/winenv.py --json --request <临时请求>`，
显示检查项、后端状态/处理建议与诊断。选游戏、任务/事件/取消页面留后续独立 PR。
接口按 #1629 启动器线最终 B/D 更正，后续出包接 `pack/jobs/main.py`；不直接接 oneclick 原生事件。

按 #1629 最终前端结论继续 Avalonia：导航为游戏库 / 构建 / 设置，本片只实现设置中的环境自检。
视觉参考 NX2Apple 的公开截图及 Qt README 描述（深色底、奶油色强调）；不引入其实现、图标或游戏资源。
官方链接位于对应检查行，点击只打开网页，玩家安装后重新检查；维护方最终合同明确不提供“安装/全部安装”执行接口。
随包 `pack.*` 项缺失时仅显示后端“重新安装完整 S2Arm”的处理文字，不提供官网按钮。

字体使用 Google Fonts 官方 Manrope 上游的未修改静态 Regular / SemiBold，
来源 https://github.com/googlefonts/manrope/tree/master/fonts/ttf ，Git blob 分别为
`573e38b06ea4b35dd9478fb27c0da3bd982a4e60` / `b045e51fef4906ffc49b7d80b5aef927a5ce95d3`；
保留原作者声明与 OFL 1.1 原文 `App/Assets/Fonts/OFL.txt`。
字体嵌入 exe，许可发布到 `licenses/Manrope-OFL.txt`，随分发包一起保留；中文由系统字体回退显示。

共享 launcher 文案按维护方正式合同读取 `launcher.items[]` 的 `id / zh-Hans / en`；缺键显示 `[键名]`。
条目需有唯一非空id和双语非空文字；不再使用未发布的嵌套文本假设。
本片不改共享文件、不维护中文/英文副本。错误标题和说明也直接读取共享原件，切换语言不重跑检查。
环境检查项的 name/message/action 当前由后端以中文返回，英文界面保留原文；后端按语言返回双语属于后续项，不阻塞首片。

## 环境报告

唯一协议来源为 `pack/jobs/WINDOWS_ENV.md`、`pack/jobs/winenv.py`。
解析器只读取 JSON 和进程退出码，保留后端状态、错误码和恢复文字；不计算空间预算或重算 ready。
`EnvironmentProbe` 在独立子进程设置 Runtime 环境，再在所选 Engine 下执行同一个 jobs 入口；不探测或复制后端业务规则。
恢复文字是数据，不能当 URL 或命令执行。协议异常只用于诊断，玩家文案应从共享资源读取。
维护方 `17ccb9049` 已发布独立 `url` 字段：非 ok 项有此字段时显示官方下载按钮，
仅消费后端给出的 HTTPS 地址，不从恢复文字提取链接，不在客户端维护下载地址表。
按钮交给系统默认浏览器，不下载安装；没有 url 的项仅显示处理文字。

入口为 `EnvironmentReport.Parse(json, exitCode)`：

- 0：有效且就绪的报告；1：有效但未就绪；2：请求/合同错误响应。
- 六种状态原样保留；非 `ok` 状态不变成已通过。
- 重复字段/检查 id、不支持的 schema/状态、状态与 `ok` 或退出码矛盾均明确拒绝。
- 允许协议新增未消费字段；列表只读，JSON 文档释放后仍可使用。

## 运行与发布

在仓库根目录执行（使用 .NET 10 SDK；`dotnet` 可替换为既有独立 SDK 的绝对路径）：

```powershell
dotnet restore launchers/windows/launcher/App/S2Arm.csproj
dotnet run --project launchers/windows/launcher/App/S2Arm.csproj
dotnet publish launchers/windows/launcher/App/S2Arm.csproj -c Release -r win-x64 --self-contained true -o <输出目录>
```

客户端可执行程序为 `S2Arm.exe`，共享体验 JSON 从仓库原件嵌入，资源不需要源码路径。
发布器同时可能产生调试符号，运行只需要该 exe；引擎和工具运行时仍按约定另行提供。
生产目录按维护方 `fb11a5591` 的 `launchers/windows/bundle_win.py`：`S2Arm.exe` 同级 `Engine/`、`Runtime/s2arm_env.cmd`、`Shell/`、`Fonts/`；预编件在 `Engine/Binaries/Prepare/`。
Engine、Runtime、Shell 可在路径设置里手工修改并应用，仅在本次客户端会话保持，不修改系统 PATH。
预编工具始终跟随所选 Engine 的 `Binaries/Prepare/`，手工选择其它 Runtime 不会移动此位置。
启动检查时设 `S2A_ENGINE` 供随包 Python 导入引擎模块、`S2A_FONTS` 指向 exe 同级 `Fonts/`；客户端只传发版路径，不判断组件是否就绪。
Shell 需指向 `Shell/`（含 manifest.json 与 root/），请求固定目标 ios，交给后端核验；客户端不核对壳身份。
临时请求仅含 schema、target 与 shell 路径，成功、异常或取消后删除；未选游戏时不传预算，由后端决定跳过磁盘项。

点击检查会运行只读后端，它可能只读枚举本机已连接的 Apple USB 设备；不登录、不配对、不签名装机。
检查进行时禁重复启动；最长两分钟，超时/关窗仅终止本窗口启动的检查进程树。
stdout 限 2 Mi 字符，stderr 限 128 Ki 字符；超量报错并结束自有检查，避免 UI 无界积累。
包内运行时尚未到位时会显示路径错误诊断，不声称环境就绪。

## 本机测试

使用 .NET 10 SDK，在仓库根目录执行：

```powershell
$env:S2A_TEST_PYTHON = (Get-Command python).Source
dotnet run --project launchers/windows/launcher/Protocol.Tests/Protocol.Tests.csproj
```

测试的期望来自协议文字与手写输入，包含 ok/missing/error 三项报告、另三类非就绪状态、两种请求错误、退出码矛盾及非法输入。
Windows 另运行合成后端进程测试：UTF-8、正确工作目录、含中文/空格/&/%/! 的路径、stderr、取消与超量输出退出。
非 Windows 会明确显示 Windows 进程用例未执行，不代替 Windows 验收。无游戏/设备操作。

离线门禁（先正常 restore 准备 NuGet 依赖；门禁只用本地包源、不联网）：

```sh
S2A_DOTNET=<dotnet路径> bash launchers/windows/launcher/gate.sh --negative-controls
```

门禁构建协议测试与实际 App 工程，运行手写断言；可选负控在临时副本把 HasAction 改成恒 true，同一套件必须红在 `ok has no action`。
另一个负控丢弃后端 url，同一套件必须红在 `backend official URL retained separately`。
Windows 再撤去请求中的 shell，必须红在 `configured shell reaches backend`。
Windows 将预编件路径撤回 exe 同级，必须红在 `selected Engine snapshot owns prepared tools`。
把正式 launcher.items 回退成嵌套字典读取，必须红在 `shared Chinese text`。
依赖缺失退出 75；默认不下载。门禁不启动窗口，实际 Windows UI/单文件发布仍单独验收。

## 游戏库页

游戏库为默认页，设置页保留原自检；构建页仍未启用。连接/创建库后，只通过 `pack/jobs/main.py run --request` 的 `setup/catalog/keys/import` 四操作读取和导入；不直接读写catalog.json。原件文件/目录、玩家自选prod.keys通过系统选择器进入请求；取消选择不提交任务。游戏库根就是工作产物位置，原件登记绝对路径、原地只读（由后端执行）。setup返回的库ID保持不透明，不额外限UUID；库路径采用后端返回的规范绝对路径。改动路径字段后，必须重新连接才能操作该库，不能把新路径当成旧连接。当前会话保存路径/库ID/选择状态，重启后需重新连接；不写另一份游戏数据库。

封面只加载后端在当前库games目录返回的本地cover.jpg（最多8MiB，缩小解码）；无封面显示共享文案占位。游戏名称/版本/缺件和密钥状态按后端显示；导入成功后重新catalog，不乐观插入条目；失败时保留错误码共享标题/说明与后端处理建议。中英切换保留当前库与选中项。关闭窗口先走jobs cancel（核PID起始时间），最多5秒控制口+3秒收尾后才结束本次自有进程树，未核实结束不当成功。

共享文案使用revision15原件的68键；26个library键由启动器线789474c79提供，pack/shared仍只读。完整构建/签名装机、删游戏与存档确认等后续各自独立PR。

`LibraryJobResult` 消费的是 `pack/jobs/main.py run --request` 的 jobs NDJSON，不是旧 oneclick 的 ev/t 流。按请求的 jobId / operation、递增 seq 与 schema=1 核对；缺终态、终态后仍来事件、退出码与 succeeded/failed/cancelled 不符均拒绝。`LibraryCatalog` 仅保留后端名称、版本、封面路径、隐藏标记、缺件文字与密钥状态，不推导出包就绪。

Windows 请求在受保护的当前用户目录内创建，写入之前已具备私有 DACL；现有目录若属主不符、为 reparse point、继承权限或给其他身份读取/写入（含仅对子文件继承）则拒绝。SYSTEM / Administrators 属后端允许的身份。请求结束删除临时文件；不改既有宽权限目录来强行通过。Windows 单测实际调用后端 `winproc.request_is_private` 核实，不以 chmod(0600) 代替。

`Protocol.Tests/Fixtures/library-catalog.ndjson` 录自 Windows 独立空库的真实 setup → catalog 后者输出（基点 fd5ee4862）。只把 jobId/taskId 换成固定值，并移除 result.jobs 内先前 setup 的进程记录；未改 games/keys/engineInfo 或终态。另有手写单游戏样本作为名称/版本/缺件与失败判据；没有游戏原件、密钥、存档或游戏封面资源。真实空库互操作不代表真实游戏/密钥导入已验收；界面与合成后端交互另列凭据。

## 出包页 / 出包进度 / 装到 iPhone

游戏库页选中游戏后「出包」页可用（`App/ExportPages.cs`，交互照 Mac 新前端 ExportView / ExportSessionView / InstallView）。只通过 `pack/jobs/main.py run --request`
的 `ipa / installCheck / install` 三个操作（`Protocol/PackJobClient.cs` 白名单），私有请求、固定命令行、取消路径与游戏库页相同；
事件逐行到达逐行校验（`JobEventReader`：schema、jobId / operation、seq 递增、唯一终态、终态与退出码一致）。

- 平台卡：Windows 只出 iPhone / iPad；macOS「仅 Mac 可出」、安卓 / 鸿蒙「即将上线」置灰。
- 没有游戏选项（维护者 11-07 拍板）：语言跟设备、移动端掌机、60 帧缺省开起不来自动降级、满屏缺省通用 + 补丁，出包页不给开关。
- 进度：只用作业层 plan / milestone / progress 事件；预计还需与 Mac 适配层 MilestoneEstimate 同一规则（本机历史 + 已完成步校准，缺记录不给）。
- 装机：installCheck 清单全齐才可 install；缺件的官方下载页只用后端 `items[].url`（install.readiness_windows），不从说明文字抠链接。
