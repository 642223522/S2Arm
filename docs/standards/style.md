# 代码风格与自愿检查

本文为项目自有代码提供风格建议和自查工具。工具由开发者自愿使用，本阶段不作为新增合入要求，不接入门禁、列车、出包或 CI。项目当前多线并行，格式、功能和搬迁应分开提交，避免无关差异和冲突。现有工程边界及 `MUST`、`SHOULD` 的含义见[仓库规范](repository.md)。

## 工具与配置

| 语言 | 格式化 | 静态检查 |
|---|---|---|
| C、C++、Objective-C、Objective-C++ | `clang-format`，以 Google 风格为基础，项目根 `.clang-format` 为准 | 现有编译与门禁；本阶段不新增全面 `clang-tidy` 门禁 |
| C# | `.editorconfig` 与 `dotnet format whitespace` | 现有构建与测试；本阶段只统一空白格式，不混入分析器自动重构 |
| Python | Ruff formatter | Ruff lint，启用规则以 `ruff.toml` 为准 |
| Shell | `shfmt` | ShellCheck；解释器以脚本 shebang／显式 shell 约定为准 |

选择使用这些工具时，版本由 [`tools/style-requirements.txt`](../../tools/style-requirements.txt) 与 [`tools/style-tools.json`](../../tools/style-tools.json)固定，以便复现自查结果。缺工具或版本不符会明确失败，不会自动安装或跳过检查。requirements 同时锁定包版本和安装哈希；`shfmt-py`、`shellcheck-py` 固定的是包装包版本，不能把包版本当成内含二进制版本。所需 .NET SDK 按版本清单准备。

格式器配置是这些工具的排版依据；文档不重复缩进宽度、换行长度等机器可读设置。工具升级应单独说明受影响语言、增量基线变化与验证。以后是否接入门禁，待主线修复告一段落后另开 PR，由测试出包线与相关维护者决定。

## 统一入口

需要自查时，在仓库根手动准备工具环境，再选择相应操作：

```sh
make style-setup
make format
make format-check
make lint
```

`make style-setup` 在 `build/style-venv/` 建立工具环境，按含哈希的锁定 requirements 安装；只有开发者显式运行此目标时才安装，可以联网。门禁、列车和出包不能调用此目标或其他安装步骤。格式和检查本身不自动联网安装。三个入口统一经 `tools/style.py` 选取文件：`format` 修改选中的自有文件，`format-check` 调用 CLI 的 `check` 只检查格式，`lint` 检查静态问题及日志设计资料。提交前应检查 diff；格式化会处理所选整份文件，不承诺只改动本次新增的行。`bash tools/style_verify.sh` 可手动验证工具链与 Git 快照处理；它位于自动测试发现范围之外。

需要明确选择范围时直接调用：

```sh
build/style-venv/bin/python tools/style.py check --base origin/main
build/style-venv/bin/python tools/style.py lint --staged
build/style-venv/bin/python tools/style.py format --files tools/example.py runtime/src/example.c
build/style-venv/bin/python tools/style.py lint --files tools/example.py --all
```

默认以 `origin/main` 的 merge-base 为基准，覆盖分支提交、已暂存、未暂存及未跟踪文件。`--base <ref>` 更换基准引用；`--staged` 只读取 index 快照并与 `HEAD` 比较，二者不能同时使用。`--files <路径…>` 限定文件，可与 `--base` 或 `--staged` 配合；`--all` 对所选文件完整检查，包含存量债务。`format --staged` 会拒绝执行，避免把工作区格式化结果误当作暂存区内容。详细参数见 `build/style-venv/bin/python tools/style.py --help`。如果以后另行接入 CI，应显式提供 PR 基准。示例路径只是参数形式，实际使用时替换为待检查文件。

文件选择、Git 路径解析和排除逻辑 MUST 由 `tools/style.py` 统一处理；CI、编辑器和其他脚本不另写一套 `find`／正则过滤。删除文件不参与格式化，文件名中的空格等字符不能被错误拆分。重命名按目标文件与可用的原文件基线处理。

## 存量债务与自查范围

自查工具对新文件检查整份内容。已有文件以基准版本识别存量问题：格式检查报告本次实际变更行内的问题；静态检查报告变更行上的问题及任意位置新出现的诊断，未变的历史问题不导致检查失败。这些结果供开发者自查，不自动阻断合入，也不要求无关功能 PR 清理全库格式。配置和工具发生变化时应重新评估基线。

格式器可能调整相邻上下文；检查入口将格式差异与 Git 变更范围关联，并按上述诊断基线识别静态问题。需要全文件重排时，应单独提交格式 PR。没有必要时不要顺手修改导入顺序、符号命名或控制流。

以下内容 MUST 排除在项目格式器和本阶段静态检查之外：

- `compat/tree/` 与 `graphics/third_party/` 的第三方源码；补丁流程仍按[仓库规范](repository.md)执行。
- 各层级 `bin/`、`obj/`、`build/` 及其他已声明的生成内容。
- 游戏资源、固件、密钥、存档、局日志与二进制产物。

排除目录中若有项目自有包装层需要检查，须先明确源码归属和显式范围，不能直接取消整个第三方目录的保护。新增排除项 MUST 有具体原因，不能为让门禁变绿而扩大排除范围。

## 人工审查与验证

命名 SHOULD 表达对象和职责；注释说明约束、原因和边界。错误在发生处暴露，不能捕获后继续运行、静默 fallback 或用日志代替失败返回。公共接口写清所有权、生命周期、线程要求和单位；`extern` 声明与互操作布局改动仍需两端核对。

格式检查不能证明行为正确。功能 PR MUST 按变化路径执行适当的构建、测试或真实复现场景；仅文案／配置改动采用直接检查、差异检查或必要格式验证。不得用 mock、伪造数据或绕过检查替代真实接口验证。格式、功能和搬迁分开审查，沿用 [Google 代码审查指南](https://google.github.io/eng-practices/review/reviewer/looking-for.html)关于复杂度、测试及避免混合大范围格式差异的公开建议；具体工具与增量策略由 S2Arm 决定。
