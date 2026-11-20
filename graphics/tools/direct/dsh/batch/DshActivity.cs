// 进度文件里的活动行（#dsh_activity\t<JSON>，Ticker.PublishActivity）：dsh_batch 随 Mac 发版预编为 NativeAOT 单文件，反射序列化在 AOT 下被关掉，
//   改具名 record + 源码生成；参数名即原匿名类型的成员名、顺序同原文，不设命名策略，写出的 JSON 逐字不变。
using System.Text.Json.Serialization;

sealed record DshActivity(int schema, int pid, string stage, int target, int pool, string state);

[JsonSerializable(typeof(DshActivity))]
sealed partial class DshActivityJson : JsonSerializerContext { }
