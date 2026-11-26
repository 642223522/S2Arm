using System.Collections;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace S2Arm.Launcher.Protocol;

/// <summary>
/// 启动器往作业层 / 控制口写的 JSON 都是「字典 + 列表 + 基本类型 + JsonElement」拼出来的。
/// JsonSerializer.Serialize(object) 靠反射按运行时类型走，NativeAOT 下不可用（IL2026 / IL3050）；
/// 这里按同样的输出规则手写，不碰反射：认不出的类型直接抛，不静默写错。
/// </summary>
public static class JsonOut
{
    static readonly JsonWriterOptions Strict = new();
    static readonly JsonWriterOptions Relaxed = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static string Serialize(object? value) => System.Text.Encoding.UTF8.GetString(Bytes(value, Strict));

    /// <summary>中文等不转义（控制口回给 s2armctl 的文字，原样给人看）。</summary>
    public static byte[] SerializeRelaxed(object? value) => Bytes(value, Relaxed);

    static byte[] Bytes(object? value, JsonWriterOptions options)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, options)) Write(writer, value);
        return stream.ToArray();
    }

    public static void Write(Utf8JsonWriter w, object? value)
    {
        switch (value)
        {
            case null: w.WriteNullValue(); return;
            case string s: w.WriteStringValue(s); return;
            case bool b: w.WriteBooleanValue(b); return;
            case int i: w.WriteNumberValue(i); return;
            case long l: w.WriteNumberValue(l); return;
            case uint u: w.WriteNumberValue(u); return;
            case ulong ul: w.WriteNumberValue(ul); return;
            case short sh: w.WriteNumberValue(sh); return;
            case ushort us: w.WriteNumberValue(us); return;
            case byte by: w.WriteNumberValue(by); return;
            case sbyte sb: w.WriteNumberValue(sb); return;
            case double d: w.WriteNumberValue(d); return;
            case float f: w.WriteNumberValue(f); return;
            case decimal m: w.WriteNumberValue(m); return;
            case JsonElement e: e.WriteTo(w); return;
            case JsonNode n: n.WriteTo(w); return;
            case IDictionary<string, object?> dict:
                w.WriteStartObject();
                foreach (var (k, v) in dict) { w.WritePropertyName(k); Write(w, v); }
                w.WriteEndObject();
                return;
            case IDictionary dict:
                w.WriteStartObject();
                foreach (DictionaryEntry kv in dict)
                {
                    if (kv.Key is not string key) throw new NotSupportedException($"JsonOut：字典键必须是字符串，遇到 {kv.Key?.GetType().FullName ?? "null"}");
                    w.WritePropertyName(key); Write(w, kv.Value);
                }
                w.WriteEndObject();
                return;
            case IEnumerable list:
                w.WriteStartArray();
                foreach (var item in list) Write(w, item);
                w.WriteEndArray();
                return;
        }
        throw new NotSupportedException($"JsonOut：不认识的类型 {value.GetType().FullName}（只收字典 / 列表 / 基本类型 / JsonElement / JsonNode）");
    }

    /// <summary>读字符串数组（["a","b"]）；不是数组或有非字符串项就抛 JsonException，调用方按读坏处理。</summary>
    public static HashSet<string> ReadStringSet(string json)
    {
        using var doc = JsonDocument.Parse(json);
        if (doc.RootElement.ValueKind != JsonValueKind.Array) throw new JsonException("不是数组");
        var set = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in doc.RootElement.EnumerateArray())
            set.Add(item.ValueKind == JsonValueKind.String ? item.GetString()! : throw new JsonException("数组里有非字符串项"));
        return set;
    }
}
