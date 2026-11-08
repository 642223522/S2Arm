# Linux 作业文本客户端原型（#705）

只消费已有 `pack/jobs/main.py` 的 `get/events/cancel`。不创建 worker、调度器或持久库，不接游戏导入、出包、安装、自动恢复或 Android 设备接口；不替代 Mac 启动器。需要 Python 3.12+；源码树运行，不安装额外依赖。

```sh
python3 launchers/linux/main.py show --private-root /用户自己的私有作业目录 --task 任务ID
python3 launchers/linux/main.py watch --private-root /用户自己的私有作业目录 --task 任务ID
python3 launchers/linux/main.py cancel --private-root /用户自己的私有作业目录 --task 任务ID
python3 launchers/linux/main.py devices
bash tests/launcher_client_test.sh
```

`devices` 明确报告未支持并退出 2，不将空列表伪装成已探测设备。`cancel` 只显示请求已发送，再读真实快照，不能立即显示已取消。关闭 `watch` 不取消任务。原型只支持本机当前用户作业，禁止用于他人的记录。

## 接口与真实状态

`launchers/shared/launcher_client/client.py` 提供：

- `Lines`：按完整 NDJSON 行解码，覆盖 UTF-8 分块；EOF 半行报错。
- `Projection`：仅用于当前 worker 的短期显示。与 Mac `Store.swift` 同义：`jobId` 别名、`succeeded → completed`、阶段切换清进度、取消 ACK 不改变终态。调用方须先排空 stdout，再调用 `eof`；退出 0 或进度 100% 不能证明成功。它不保存作业，不决定续跑或阶段跳过。
- `Client`：仅调用原 Jobs CLI，`get` 是重连后的当前状态依据。终端壳不把历史事件投影成当前 attempt 状态。
- `device_view`：沿用 `connected/models/osChoices`，quick 保留先前连接表；未支持使用外层能力结果，不修改 Jobs 合同。

### 物理游标

`Cursor` 仅在当前 `watch` 进程内保存字节位置、物理行数和文件身份；不使用 `get.events`、返回对象数或 `seq` 作游标，`seq` 在新 attempt 会重置。

先冻结已完整换行的事件前缀，再按原 `read_events` 的 `splitlines`/JSON 规则计算该前缀的有效事件数，调用原 CLI `events --since <物理行> --limit <有效数>`。响应必须与冻结前缀一致，再核文件身份与前缀字节，才推进游标。空行、坏 JSON 同原 Jobs 跳过；半行留到下轮。允许追加，不把本轮追加内容超读进游标；替换、截短或读取期间修改当前前缀则报错且不推进。

假设由现有 Jobs 以追加方式写日志，不支持第三方原地重写已经消费的历史前缀；同 inode 同大小的历史改写不是本原型提供的篡改检测服务。增量缓冲超过 4 MiB 明确拒绝，CLI 每次调用 30 秒超时；不是后台服务或无人值守队列。

## 验证边界

测试仅用原创合成状态与临时私有目录。`t_runtime.py` 调用真实 `main.run_request`/`Context`，仅通过测试入口注入无游戏操作，不向产品加入假成功命令。覆盖真实失败、取消、中断、新 attempt 和终端拒绝能力；客户端纯单测另覆盖事件分块、阶段重置、游标和源变更。

通过不等于 Mac/Windows UI、真实原件导入、出包、安装、设备或游戏通过。测试脚本由 `tools/gate.sh` 的 `tests/*_test.sh` 自动收集，两个 Python 测试文件显式接线；更改消费者按脚本头部覆盖范围选择。
