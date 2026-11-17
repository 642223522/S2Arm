// --inspect 输出的 JSON 形状（源码生成序列化）：读取器随 App 发布为 NativeAOT 单文件，反射序列化在 AOT 下被关掉（匿名类型 + JsonSerializer.Serialize
//   运行时抛 InvalidOperationException，导入任何游戏都失败；开反射开关也只会因裁剪静默输出 {}）。字段名、顺序、取值与原匿名类型逐字一致：
//   属性按声明顺序写，名字由 CamelCase 命名策略从属性名得出（builds 是字典，键不受命名策略影响）。
using System.Collections.Generic;
using System.Text.Json.Serialization;

sealed record InspectPackage(string TitleId, string BaseId, uint Version, string Type, string Name, string EnglishName, string Display,
    Dictionary<string, string> Builds, string GuestIsa, string Icon, int Controls, long ContentBytes, string[] ContentIds);

sealed record InspectResult(int Schema, List<InspectPackage> Packages);

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(InspectResult))]
sealed partial class InspectJsonContext : JsonSerializerContext { }
