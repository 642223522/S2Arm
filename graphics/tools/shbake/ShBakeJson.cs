// S2A.ShBake 写出的 JSON（源码生成序列化 + JSON 树）：S2A.ShBake 随 Mac 发版预编为 NativeAOT 单文件，反射序列化在 AOT 下被关掉
//   （匿名类型 / Dictionary<string, object> 交 JsonSerializer.Serialize 运行时抛 InvalidOperationException）。
// 具名 record 的参数名就是原匿名类型的成员名（小写开头、声明顺序同原文），不设命名策略：字段名、顺序、取值与改前逐字一致。
using Ryujinx.Graphics.GAL;
using System;
using System.Collections;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace S2A.ShBake
{
    // compute-smoke：metadata.json / stdout
    public sealed record ComputeStageBudgets(uint uniformBuffers, uint storageBuffers, uint textures, uint images);
    public sealed record ComputeSmokeMetadata(string contract, string stage, string entryPoint, int[] localSize, string bindingAbi,
        int uniformBufferSet, int storageBufferSet, int textureSet, int imageSet, ComputeStageBudgets perStageBudgets, int extraSetBase, int extraSetBudget,
        int reservedUniformBuffers, int reservedStorageBuffers, int reservedTextures, int reservedImages, int userResources, string deviceAdmission, bool runtimeProgram);
    // compute-smoke：gal-info.json（原写法 IncludeFields = true：管线状态 ProgramPipelineState 是公开字段的结构）
    public sealed record ComputeDescriptor(int binding, int count, string type, int stages);
    public sealed record ComputeUsage(int binding, int arrayLength, string type, int stages, bool write);
    public sealed record ComputeSet(int set, ComputeDescriptor[] descriptors, ComputeUsage[] usages);
    public sealed record ComputeGalInfo(string contract, int fragmentOutputMap, bool fromCache, ProgramPipelineState? pipelineState, ComputeSet[] sets,
        int sharedMemoryBytes, int localMemoryBytes);
    public sealed record ComputeErrorBody(string code, string message);
    public sealed record ComputeError(ComputeErrorBody error);

    [JsonSerializable(typeof(ComputeSmokeMetadata))]
    [JsonSerializable(typeof(ComputeError))]
    sealed partial class ShBakeJson : JsonSerializerContext { }

    [JsonSourceGenerationOptions(IncludeFields = true)]
    [JsonSerializable(typeof(ComputeGalInfo))]
    sealed partial class ShBakeFieldsJson : JsonSerializerContext { }

    /// <summary>bake.json 的报告是 Dictionary&lt;string, object&gt;，值是 int / long / double / string / bool / 枚举 / 字典 / 列表各种都有、且随功能增减：
    /// 按值的实际类型逐层转成 JsonNode 再写（JsonNode 写出不靠反射）。写法与原 JsonSerializer.Serialize(Dictionary&lt;string, object&gt;) 相同：
    /// 枚举写成数字、字典按插入顺序、序列按枚举顺序；认不得的类型当场抛异常（报告里多了新类型要在这里补，不许静默丢）。</summary>
    static class JsonTree
    {
        public static JsonNode Node(object v) => v switch
        {
            null => null,
            JsonNode n => n,
            string s => JsonValue.Create(s),
            bool b => JsonValue.Create(b),
            int i => JsonValue.Create(i),
            long l => JsonValue.Create(l),
            uint u => JsonValue.Create(u),
            ulong ul => JsonValue.Create(ul),
            short sh => JsonValue.Create(sh),
            ushort us => JsonValue.Create(us),
            byte by => JsonValue.Create(by),
            sbyte sb => JsonValue.Create(sb),
            double d => JsonValue.Create(d),
            float f => JsonValue.Create(f),
            decimal m => JsonValue.Create(m),
            char c => JsonValue.Create(c.ToString()),
            Enum e => Type.GetTypeCode(e.GetType()) is TypeCode.UInt64 ? JsonValue.Create(Convert.ToUInt64(e)) : JsonValue.Create(Convert.ToInt64(e)),
            IDictionary dict => Object(dict),
            IEnumerable seq => Array(seq),
            _ => throw new NotSupportedException($"bake.json 报告里有认不得的值类型 {v.GetType().FullName}：在 ShBakeJson.cs JsonTree.Node 补上"),
        };

        static JsonObject Object(IDictionary dict)
        {
            var o = new JsonObject();
            foreach (DictionaryEntry kv in dict) o[Convert.ToString(kv.Key, System.Globalization.CultureInfo.InvariantCulture)] = Node(kv.Value);
            return o;
        }

        static JsonArray Array(IEnumerable seq)
        {
            var a = new JsonArray();
            foreach (object x in seq) a.Add(Node(x));
            return a;
        }

        public static string Write(Dictionary<string, object> report, JsonSerializerOptions options) => Node(report).ToJsonString(options);
    }
}
