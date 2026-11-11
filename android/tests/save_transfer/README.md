# P10 存档迁移 JNI 前置桥

不加管理 UI，不创建新存档格式。`NativeBridge.saveTransfer(byte[])` 收发标准 UTF-8 JSON，
静态 game 组合直接调用同一服务库的 `S2A_SaveTransfer` / `S2A_SaveTransferFree`。
未链服务、动态诊断及静态诊断包明确抛 `UnsupportedOperationException`，不另加载 AOT 实例。
调用方必须先完成 `NativeBridge.load()` 的库身份验证。启动互斥、运行中拒绝以及
JSON/事务校验仍由共用服务负责，不用 Java UI 线程串行性冒充 `HostGate`。
本片未接管理入口；未来 UI 必须仅在启动前调用并检查 JSON 中 `ok/error`。

手动合成测试（Linux、JDK 17+、C++17；不改现有门禁）：

```sh
JAVA_HOME=/path/to/jdk bash android/tests/save_transfer/run.sh
```

实际 JVM `-Xcheck:jni` 调生产 transport header，15 项断言：中文/补充平面字符及字节
保真、null 请求/内嵌 NUL/超过 8 MiB 拒绝、恰好上限、缺任一服务函数、返回空/过大、释放配对。
空 byte[] 原样透传，由共用服务 JSON 校验；合成回显测试不证明空 JSON 校验。
撤掉 NUL 守卫后必须失败。服务调用为合成回显，不读写文件，不代表事务安全或设备验收。

额外共用导出边界夹具（.NET 10，无 NuGet 源）：

```sh
dotnet run --project android/tests/save_transfer/shared-export/Probe.csproj
```

直接编译实际 `SaveTransferExports.cs`，Host/SaveTransfer 引擎明确为替身；7 项验证覆盖
调用时持有 `HostGate`、HostStarted/Device 拒绝、空/过长/非法 UTF-8 与正常响应。
不把这项称为实际 `Host.Boot` 并发测试或真实恢复验证。

限制：未做 Android NativeAOT 完整链接、APK 安装、真实 Host.Boot 并发或真实存档恢复；
Java 内存分配失败下的释放由 RAII 保证，未做 JVM OOM 故障注入。
