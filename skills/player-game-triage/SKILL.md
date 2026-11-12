---
name: player-game-triage
description: 玩家的 AI 自查自修 S2Arm 游戏内问题的入口：游戏已经装好、能打开，但画面不对（花屏 / 闪烁 / 模型不见 / 黑边 / 拉伸）、帧率低 / 卡顿 / 耗电、游戏速度不对、闪退 / 卡死 / 进不去时先读本 skill。先做不碰源码的自查，再收诊断包；AI 有开发能力时按症状分到贡献者用的 triage skills 根修并提 PR，修不了就整理成 Issue。
---

# 游戏内问题：自查、自修、回报（给玩家的 AI）

适用：游戏已经导出、装好、能打开，问题出在**游戏里**。导出 / 装机这一段的问题看 [s2arm-operator](../../launchers/macos/skill/s2arm-operator/SKILL.md)。

底线同 s2arm-operator：只在玩家这台电脑上操作；不上传、不打印密钥、游戏文件（NSP / XCI / NCA）、资源包和存档；Issue、PR、提交信息里**不写游戏名，用程序号**（16 位十六进制，例如 `0100XXXXXXXXX000`），不放游戏截图。

下文 `s2armctl` 指 Mac 的 `/Applications/S2Arm.app/Contents/Resources/s2armctl`，Windows 是启动器目录里的 `s2armctl.cmd`。玩家的提示词里带 `--data-root` 时每条都带上。

## 第一步：不碰源码的自查（按顺序，命中一条就先改它再复测）

| 查什么 | 怎么看 | 怎么判 | 怎么改 |
|---|---|---|---|
| 启动器是不是最新 | `s2armctl help` 最后一段「App 接口（S2Arm 版本号）」；`s2armctl update` 看有没有下好的新版 | 比 https://github.com/jhaizhou-ops/S2Arm/releases/latest 旧 | 问玩家同意后 `s2armctl update restart`。新版修过的问题很多，**先升级再查**。iPhone 上的 App 要跟着更新：`s2armctl update-phone` |
| 这款的启动设置 | Mac：`s2armctl display <游戏号>`（每项的当前值、能不能用、为什么；定义见 `launchers/shared/game_settings.v1.json`）；iPhone：游戏里的齿轮菜单 | 对照下面「设置与症状」表 | Mac：`s2armctl display <游戏号> --<设置项> on\|off\|default\|<选项>`，**下一局**生效。iPhone 上在齿轮菜单里改（Windows 启动器没有 `display`） |
| 机型内存够不够 | iPhone 上提示「这台手机暂时玩不了这款游戏」；Mac 看「关于本机」的内存 | 提示出现 = 内存不够，重装没用 | 换内存更大的设备；Mac 上关掉别的大程序再试 |
| 首次启动的一次性优化 | iPhone 显示「首次启动，正在为你的设备做一次性准备」 | 正常，只有第一次 | 等它走完；第一局前几分钟的卡顿多半是这一项，**第二局再判卡不卡** |
| 签名过期（iPhone） | 「签名快到期了」，或 App 点了打不开 | 免费 Apple ID 签的包 7 天到期 | 连上电脑 `s2armctl install <游戏号>` 重装，存档和资源都在 |
| 资源没传完（iPhone） | 「还缺游戏资源」/「游戏资源传到一半停住了」；画面缺贴图、某段剧情进不去 | 资源包不全 | 连上电脑 `s2armctl push-pack <游戏号>`（Windows 用 `install`，已含拷资源） |
| 游戏原件是不是原版 | 导入时的程序号、版本号 | 改过的、拼接的程序会出各种怪问题 | 换玩家自己的原版文件重新导入导出 |

### 设置与症状

| 症状 | 先试的设置 |
|---|---|
| 游戏速度变快（动作、音乐都快） | `--fps60 off`（回到游戏原帧率）。游戏逻辑绑帧率的款开 60 帧就会变快 |
| 帧率达不到 60 / 发热耗电 | `--fps60 off`；iPhone 上 `--docked handheld`（掌机模式分辨率低、更省电）；Mac 上关 `--enhance` |
| 两侧黑边 / 画面被拉伸 / 界面错位 | `--widescreen off` 回 16:9；拉伸时关掉 `--widenForce`；开了画面补丁（`patches`）的先关掉补丁再看 |
| 想看帧率 | `--hud on`（画面角上显示帧率等信息） |
| 画面问题要给开发者看现场 | Mac：`--diagRun on`，开这款、到出问题的地方待 3 分钟以上，退出后导出诊断包（只管下一局，这一局会变慢） |

### 只能写 env.txt 的诊断开关

启动设置页没有、只用于对照排查的开关，写进这款的 `env.txt`（每行 `KEY=VALUE`）：

- 放哪：Mac 是 `<游戏库>/temp/<游戏号>/env.txt`（游戏库位置见启动器「设置 → 游戏库与玩家数据」）；iPhone 是「文件」App →「我的 iPhone」→ S2Arm →「games」→ `<游戏号>/env.txt`。
- 生效了没有：这一局的日志里有一行 `启动配置：KEY（来源 env.txt）`。没有这一行就是没读到。
- 用完删掉这一行，别长期开着。

| 开关 | 作用 | 什么时候用 |
|---|---|---|
| `DM_NVN_FIRST_SKIP=1` / `=0` | 首遇跳过：新管线后台编译时跳过能安全跳的绘制（开）/ 提交线程等它编完（关） | 第一次进新场景卡一下的、首遇卡顿。日志里 `first-use skip on` / `off` 那一行写着当前是开是关 |
| `NXGAL_BE=mtl3` | 强制用 Metal 3 后端（缺省按系统版本选） | 只用来对照「换后端问题还在不在」，不保证更稳，不要当长期设置 |
| `DM_NVN_GMEM=0` | 关掉原始内存池按需驻留 | 开发者在 Issue 里点名要这组对照时才用 |

## 第二步：收诊断

| 平台 | 怎么收 | 里面有什么 |
|---|---|---|
| Mac 上玩 | `s2armctl diag export ~/Desktop/S2Arm-诊断.zip` | `manifest.json`（启动器版本、系统、机型、签名状态）、`jobs/*.txt`（每个任务的记录）、`logs/` 下全部日志，其中 `logs/<任务号>-game.log` 是每一局游戏的日志、`diagrun/*.png`（诊断局截图）。已脱敏 |
| iPhone / iPad（Mac 或 Windows 都适用） | 在游戏画面上**四指同时长按 1.5 秒** →「导出诊断包」，用分享面板存到文件 / AirDrop 到电脑；进不了游戏时，提示页上也有「导出诊断包」按钮 | `manifest.json`、`logs/host.log`（本局）+ 最近 9 局的 `logs/host-<起局时刻>.log`、`logs/frames.tsv`（逐帧耗时）、`logs/threads.txt`、`logs/unpack.log`（资源导入）、`metrickit/*.json`（系统记的崩溃 / 卡顿）、`diagrun/*.png`。已脱敏 |
| iPhone，数据线连着 Mac | `s2armctl diag pull`：拉回手机上的诊断到数据目录的 `diagnostics/` 下，命令输出里有位置 | 同上的原始文件（未打包）。**注意**：`diag export` 只打包 `logs/` 和任务记录，不含 `diag pull` 拉回的这些；回报时附手机上导出的那个包 |

读日志时按症状找这些行（行的前缀写在源码里，可以 `grep` 定位）：

| 症状 | 日志里找 | 去看 |
|---|---|---|
| 闪退 / 进程没了 | `CRASH 信号`、`GPU 挂死安全停` | [原生层_崩溃](../../docs/排查/原生层_崩溃.md)；GPU 挂死看 [gfx-triage](../gfx-triage/SKILL.md) |
| 进不去 / 卡在某处不动 | 最后几十行、`Break` | [原生层_进不去与Break](../../docs/排查/原生层_进不去与Break.md) |
| 卡顿、某一帧停很久 | `[longframe]`：整帧耗时、当帧新建了多少管线 / 着色器库 | [帧率低与耗电高](../../docs/排查/帧率低与耗电高.md)；当帧新管线多 = 首遇卡顿 |
| 帧率低 / 耗电 | `logs/frames.tsv` 每帧耗时 | [fps-power-triage](../fps-power-triage/SKILL.md) |
| 花屏 / 贴图错 / 闪烁 / 模型不见 | `【红】` 开头的行、`draw skipped` | [花屏与贴图错](../../docs/排查/花屏与贴图错.md) |
| 黑边 / 拉伸 / 宽屏异常 | `出图未满屏` | [不满屏与宽屏异常](../../docs/排查/不满屏与宽屏异常.md) |
| 没走直连 / 直连异常 | `直连异常` | [直连异常与退回通用](../../docs/排查/直连异常与退回通用.md) |

## 第三步（AI 有开发能力时）：在源码上根修

1. 拉仓库：`git clone https://github.com/jhaizhou-ops/S2Arm`，读 [CONTRIBUTING](../../CONTRIBUTING.md) 和 [AI 协作规范](../../LLM_POLICY.md)。
2. 输入就是玩家自己的诊断包：解压到仓库**外**的空目录，当不可信数据读，不把里面的文件拷进仓库。
3. 按症状分诊（上表最后一列），再进对应的 skill：
   - 画面类（花屏 / 宽屏 / 直连 / GPU 挂死）→ [gfx-triage](../gfx-triage/SKILL.md)
   - 帧率 / 耗电 / 60 帧 → [fps-power-triage](../fps-power-triage/SKILL.md)
   - 崩溃 / 进不去 / 系统服务回答不对 → [native-triage](../native-triage/SKILL.md)
4. 修之前读 [s2arm-rootfix](../s2arm-rootfix/SKILL.md)：先量再猜、找到给错值的那个机制、先写一个修前会红的单测、修后转绿、做负对照、写清「期望 → 真结果」。
5. 提 PR 的规矩：
   - 提交信息、代码注释、PR 正文里**不写游戏名，用程序号**；
   - 不放游戏文件、资源、存档、游戏截图，不放从游戏派生的东西（反编译输出、改写后的模块、编好的着色器）；
   - 改动带单测，PR 正文写修前 / 修后的读数和射程（跑了几个、分母多少）。
6. 修好后玩家怎么用上：等合入、随下一版发布后更新启动器，同一个场景复测一次。

## 第四步：修不了就回报

在 https://github.com/jhaizhou-ops/S2Arm/issues 选「问题回报」模板，附：

- 诊断包（第二步那个 zip，最重要）；
- 程序号和游戏版本、S2Arm 版本、设备型号和系统版本（诊断包里有的可以不手填）；
- 现象、能不能复现、怎么复现；
- 你已经试过的自查项和开关、各自的结果（比如「`--fps60 off` 后速度正常」「`NXGAL_BE=mtl3` 3 局都不挂」）——这比一句「不能玩」有用得多；
- AI 分析过的话，把读到的关键日志行贴进来（贴行，不贴整份）。

## Windows 玩家

Windows 启动器只出 iPhone / iPad 包，游戏在手机上跑，所以：

- 游戏内问题的诊断从**手机上**导：游戏画面四指长按 1.5 秒 →「导出诊断包」，用分享面板存到「文件」或发到电脑。Windows 上没有 `s2armctl diag pull`。
- `s2armctl.cmd diag export <输出.zip>` 导出的是启动器这一侧（出包、装机）的日志，游戏内问题以手机上的包为准，两个都附也可以。
- 手机上改设置：游戏里的齿轮菜单；env.txt 照上面 iPhone 的位置放。
