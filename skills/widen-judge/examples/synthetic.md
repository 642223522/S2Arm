# 可重建合成反例（不含游戏素材）

从仓库根执行，只用现有 Python 标准库，显式给调用方缓存目录：

```sh
python3 tests/widen_judge_samples.py <缓存>/samples
bash tests/widen_judge_test.sh <缓存>/offline-tests
```

生成320×180原图、392×180宽图，宽度约1.225倍。原/宽都包含4张关键帧、30fps含端点的61张连续帧和MARK；PNG及读数由确定性像素生成，不下载图片、不用Pillow/numpy。每张图片SHA绑定在读数里。

| 样本 | 图像变换 | 工具预期 |
|---|---|---|
| correct | 中心原样，两侧同一连续世界外延 | 过；之后必须有真实判官 |
| stretch_1_22 | 以中心为轴横向拉伸1.22倍，圆变椭圆 | 不过：中心PSNR/界面宽比 |
| ui_shift | 只把黄色面板向右移动38像素 | 不过：中心PSNR |
| center_shift | 场景/界面整体移动15像素 | 不过：中心PSNR |
| alternating_flicker | 宽图隔帧亮度增加70级 | 不过：额外闪烁/中心PSNR |

样本生产者用像素算PSNR、检测黄色面板外接框求尺寸比、计算相邻帧平均亮度额外变化。合成地面已全画满，深度清屏对应黑色标记，地面行两侧黑标记占比为0；这不是实景深度算法的验证。

生成器在证据目录之外另写 `test-policy.json`，仅为合成测试显式选 ±1% UI 和2/255额外亮度门槛，不能用来声称产品策略已获确认。缺策略时脚本不放行。

`expected-actual-offline.json` 对比五组工具判据；correct 到“缺判官”是预期，因为默认离线测试不会发真实AI请求。测试里的函数替身与 toy `claude` 仅验证六项否决、坏JSON、缺登录、超时、权限参数及真实子进程封装，**不证明模型看图，也绝不作为真实claude-p示例**。

维护者有现成登录CLI时，在待验head的仓库根另执行（会调用真实AI；不属于离线单测）：

```sh
# 先把本次验收缓存设为一个自己拥有、仓库外的绝对路径。
RUN="${S2A_WIDEN_JUDGE_CACHE:?请设置本次验收缓存绝对路径}"
mkdir -p "$RUN"
python3 tests/widen_judge_samples.py "$RUN/samples"
S2A_WIDEN_AI=1 python3 graphics/widen/scan/judge.py "$RUN/samples/correct" \
  --policy "$RUN/samples/test-policy.json" --timeout 600 > "$RUN/real-judge.json"
rc=$?
printf 'judge_exit=%s\n' "$rc"
python3 -m json.tool "$RUN/real-judge.json"
git rev-parse HEAD
```

此处显式测试策略只用于合成正样本，实际生产者需传画幅线的 `graphics/widen/judge_policy.json`。验收应同时保存head、CLI版本、实际退出码、输出JSON/输入摘要；只有exit0且JSON为过/许可true才是该正样本模型判过。非0保留实际结果，不能用协议双填演示。若外层shell开了`set -e`，调用前用`set +e`保留失败JSON和退出码。

真实Claude不可用就保留缺判官记录。图像中的文本、同目录CLAUDE.md或hooks都不能成为操作指令。真实巫师3/暗黑2反例由画幅线实采验收，均须判不过；本仓库不提交游戏原图。
