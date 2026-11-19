# 鸿蒙开发外壳

这是鸿蒙协作的第一部分：可独立构建的 ArkTS 游戏库、N-API 桥、窗口生命周期、触控与手柄输入。包内没有游戏、引擎、签名证书或实验探针。开发身份为 `io.s2arm.ohos.dev`，与既有私用测试包分开。

## 从源码构建

依赖：Python 3.12+、已安装的 DevEco Studio（SDK API 26、配套 Node、ohpm、Hvigor、JBR）。脚本使用指定安装中的工具，不安装另一套环境。ohpm 会解析项目依赖；SDK 应预先安装。

在仓库根目录执行，替换两个路径：

```sh
python ohos/tools/build_shell.py --studio "<DevEco Studio 安装目录>" --out "<新的空构建目录>"
```

脚本复制源码到输出目录构建，失败保留日志；不会签名、安装、连接设备或加载本地引擎。成功后 `result.json` 给出本轮未签名 HAP 路径及 SHA256，`dependencies.log`、`build.log` 保留完整命令输出。已在 Windows + API 26 验证；macOS/Linux 工具安装布局尚待验证。

### 不装 DevEco：公开 OpenHarmony SDK

用 `ohos/tools/emu/setup.sh` 准备的公开 SDK（26.0.0）与锁版本 hvigor（6.26.20），不需要 DevEco Studio、HMS 或 ohpm。另需 PATH 上的 Node.js 与指向 JDK 17+ 的 `JAVA_HOME`。

```sh
python ohos/tools/build_shell.py --public-sdk --out "<新的空构建目录>"
```

默认读取 `$OHOS_EMU_HOME/sdk/26.0.0` 与 `$OHOS_EMU_HOME/hvigor`（与模拟器工具相同，未设置时为 `~/.cache/s2arm-ohos-emu`）；也可用 `--sdk-root <含 26.0.0 的目录>`、`--hvigor-dir <含 node_modules/@ohos/hvigor 的目录>` 指定。脚本只在构建副本里做三处适配，源码不变：

1. `build-profile.json5`：`runtimeOS` 改为 `OpenHarmony`，加 `"compileSdkVersion": "26.0.0"`；
2. `entry/src/main/module.json5`：`deviceTypes` 改为 `["default"]`（公开 SDK 没有 phone 能力集）；
3. 不跑 ohpm，把 `entry/src/main/cpp/types/libs2aprobehost` 复制为 `entry/oh_modules/libs2aprobehost.so`，供 ArkTS 推导 `engine.*` 类型。

产出的未签名 HAP 用 `ohos/tools/emu/sign.sh` 签名后可装到模拟器。

## 当前边界

- 本部分能编译外壳；还不能单独运行游戏，也不证明 Vulkan 首帧。
- 运行库从 `libS2AEngine.so` 动态加载；缺失时报实际错误，不用桩假装启动成功。运行时源代码、合成图形冒烟及新层构建接线在后续独立提交中交付。
- 源码保留已有 C ABI 名称和 `libs2aprobehost.so` 名称，避免另造兼容层。历史名称不表示仍包含实验探针。
- 默认直连与原始比例；旧版本的逐款推荐表不进入公共外壳。比例能力应从上游准备契约接入，不能把旧设备的验收记录套到新层。
- 本次没有附带原工程的图片；应用图标为随源码提供的简单 SVG。封面只从用户本机导入资源读取。
- 游戏库、详情与设置仍需持续对齐上游 ShellUI；本部分不声称已经达到 iOS 完整功能。

## 模块与协作入口

| 目录 | 责任 |
| --- | --- |
| `entry/src/main/ets/ui` | 游戏库展示、详情与视觉样式 |
| `entry/src/main/resources/base/element/string.json` | 玩家可见文字；界面用 `$r('app.string.<名称>')`，逻辑里拼接或保存的文字用 `ui/Strings.ets` 的 `str()`（`%s`/`%d` 占位） |
| `entry/src/main/ets/controls` | 设置存储、导入、触控、诊断 |
| `entry/src/main/ets/entryability` | 应用生命周期与启动请求 |
| `entry/src/main/cpp/bridge_ohos.cpp` | XComponent / 窗口持有、引擎 ABI、会话状态 |
| `entry/src/main/cpp/controller_ohos.cpp` | 手柄输入与反馈 |

模拟器贡献可以先接签名、安装、启动 `EntryAbility` 和外壳可见检查；这与后续的图形首帧测试分开报告。公开 SDK 调试签名由测试工具按平台生成或配置，证书与 profile 不放本目录。

外部启动参数为 `s2armLaunchId`（8–64 位小写字母、数字或连字符）与 `s2armGameKey`（1–64 位，同字符集）；输出在应用 files 目录的 `launch-results/launch-result-<id>.json`。`runtime-started` 只表示运行时状态，不表示首帧或可玩。真实游戏输入不用于公共 CI；下一部分应提供独立合成测试。

## 验证记录

首轮独立构建暴露一个 ArkTS 回调返回类型错误；显式标注 `onStart` 为 `void` 后，全新输出目录中的 ArkTS、native 链接和未签名 HAP 打包通过。只验证构建；签名、模拟器、真机和游戏功能均未验。宿主运行时仍是待交付依赖，不要求其他贡献者自行重写。

完整贡献检查已尝试：`bash tools/contrib_check.sh --base origin/main` 在 Windows 的环境检查阶段退出，Git Bash 未识别可用 python3，且缺少其要求的 Xcode/固定改写器依赖；不能记为通过。本次独立外壳构建使用系统 Python 与指定的 DevEco 工具，不依赖这些苹果构建工具。
