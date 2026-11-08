# 输入与输出 v1（接口已对齐，实采待验）

画幅线在 [PR180评审](https://github.com/jhaizhou-ops/S2Arm/pull/180#issuecomment-6380574089) 确认按本v1导出。生产者由画幅线实现，输入位置为 `<出表目录>/<档位>/full/`，内含 `orig/`、`wide/`、`metrics.json`；档位为 handheld / docked。同一份MARK后有镜头动作的GAL录像由galplay回放两遍（不放宽 / 整套 `--widen <屏幕比>`）；`capture.replay_sha256` 为录像文件SHA256，`fps` 按游戏上屏率30或60，七个数值字段名不变。

第二层由closed_loop自己判定，本工具只接收下述第三层证据，不提供TSV旁路。生产者导出尚待画幅线落地和真实录像端到端验证，接口认可不能代替实采验收。

输入根只读，所有图片必须直接位于 `orig/` 或 `wide/`，PNG（8位灰度/灰度alpha/RGB/RGBA，非隔行，≤16 MiB/张、≤16M像素/张，总计≤256 MiB；校验CRC和解压像素流），不允许路径穿越或符号链接。原图约16:9，宽图同高且更宽，同侧尺寸全程一致。`metrics.json` 顶层精确字段：

- `version`: `s2a-widen-judge/1`
- `capture`: `{replay_sha256: <原始录像SHA256>, fps: <整数1..120>}`。原/宽来自同一录像，脚本信任生产者的来源与数值，不读取录像或重算实景深度。
- `key_frames`: 四个按帧号严格递增的成对记录。
- `continuous_frames`: 连续两秒（含起止），恰好 `2*fps+1` 个成对记录，帧号每次加1。例如30fps为61对；不能用四张图冒充连续帧。
- `mark`: 一组成对的 MARK 截图记录。
- `metrics`: [判据表](criteria.md) 七个有限数值字段，不接受未知/重复键或布尔值。比值无单位，比例为0..1，PSNR单位dB。

每条成对记录形如（hash 用实际图片字节计算，不是文件名）：

```json
{"frame": 123, "orig": {"file": "orig/key_123.png", "sha256": "<64位小写SHA256>"}, "wide": {"file": "wide/key_123.png", "sha256": "<64位小写SHA256>"}}
```

AI 的 `structured_output` 精确包含以下字段（六项 checks 都必须有）：

```json
{
  "version": "s2a-widen-judge/1",
  "input_sha256": "<调用方提供的本次输入摘要>",
  "checks": {
    "stretch": {"pass": false, "reason": "人物横向变宽，圆形变椭圆"},
    "alignment": {"pass": true, "reason": "中间区锚点位置一致"},
    "ui_bounds": {"pass": true, "reason": "面板完整可见且居中"},
    "bright_bands": {"pass": true, "reason": "两侧接缝亮度连续"},
    "flicker": {"pass": true, "reason": "已逐一查看连续帧，未见新增交替变化"},
    "side_content": {"pass": false, "reason": "外延只是原图横向拉长"}
  },
  "evidence_complete": true,
  "uncertain": false,
  "inspected_files": ["metrics.json", "<清单中每张PNG，不可省略>"]
}
```

这是格式示例，**不是一次真实 Claude 输出**。`judge.py` 用 `--json-schema` 请求结构化结果，并再次校验精确字段、bool、理由、完整文件清单和输入摘要。JSON围栏、字符串bool、缺项、重复键、错误摘要、CLI `is_error`、输入变化均不放行。

| 退出码 | status | 含义 |
|---|---|---|
| 0 | 过 | 工具全过、六项AI全过、证据完整且确定 |
| 1 | 不过 | 工具失败，或 AI 任一失败/不确定/证据不完整 |
| 2 | 输入错误 | 证据/数值协议损坏、缺失或不支持 |
| 3 | 缺判官 | S2A_WIDEN_AI=0、无claude、未登录/CLI失败/超时；reason进一步区分 |
| 4 | 判官错误 | AI结果格式错、读数期间输入变化 |
| 5 | 待确认判据 | unverified_policy：输入有效，但UI/闪烁门槛未获确认；不误报输入损坏 |

输出只写 stdout；除0外 `allow_widen_full` 恒为 false。`input_sha256` 对排序后的相对文件名→SHA256表（包括 metrics.json）再SHA256，绑定本次帧/数值；不能复用其他录像或旧JSON的许可。它不是文件锁；生产者必须冻结输入直到消费者用完。

策略由画幅线维护在仓库 `graphics/widen/judge_policy.json`（证据目录之外），auto_table 显式传 `--policy`。精确字段仍是 `version`、`ui_ratio_tolerance`、`flicker_excess_luma_max`、`basis`；工具无产品默认值，也不替画幅线创建策略文件。

画幅线确认UI容差0.04：依据其10-22怪猎截图obj_scale量具误差最大约3.5%（横幅1.000/0.995、底部图标0.995/0.990、远景最差0.965），这是对接方提供的测量依据，并非本Server新增实测。闪烁先取2/255，basis必须写明“临时”，仍待画幅线拿巫师3露台原/宽真值校准，不能标为真实反例验收已完成。

没给策略时输入仍可完成格式/已有数值检查；判官可用则exit5 `unverified_policy`，缺失/禁用判官仍exit3。auto_table的状态和缺判官后重试由画幅线实现；此消费者始终不写启用表。输出另带实际策略对象，调用方须与输入摘要一起核对。本轮合成测试0.01与2/255仅为显式测试策略，不当产品默认值。

调用采用 Claude 官方 CLI 的 `-p --restricted --safe-mode --tools Read --allowedTools Read --permission-mode dontAsk`，禁 MCP/skills/命令/hooks，并关闭会话持久保存和自动更新；系统提示以内联仓库skill传入。restricted 把 Read 限于当前输入目录，safe-mode 保留用户既有认证而不自动加载项目定制。要求现有 CLI 支持这些官方参数（restricted ≥2.1.248）；不支持则缺判官，不降级权限、不安装或登录。CLI自身的认证/配置状态由既有用户安装管理，脚本不复制或输出认证。

官方参考（2026-10-23查阅）：[CLI flags](https://code.claude.com/docs/en/cli-reference)、[programmatic structured output](https://code.claude.com/docs/en/headless)。当前开发Server无CLI，真实调用/登录和只读限制的实际CLI行为均待维护者补验。
