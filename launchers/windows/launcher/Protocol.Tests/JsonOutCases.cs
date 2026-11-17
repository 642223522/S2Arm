// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using S2Arm.Launcher.Protocol;

// 去反射的 JSON 输出（Windows 去 .NET、NativeAOT）：期望串手写；再拿反射版 JsonSerializer 当第二个对照（测试进程里反射可用），两者逐字节相同才算替换无副作用。
public static class JsonOutCases
{
    public static void Run(Action<bool, string> check)
    {
        var element = JsonDocument.Parse("""{"a":[1,"x"]}""").RootElement.Clone();
        var payload = new Dictionary<string, object?>
        {
            ["s"] = "中<文>&'", ["b"] = true, ["n"] = null, ["i"] = 3, ["l"] = 1234567890123L, ["d"] = 0.5, ["neg"] = -2,
            ["list"] = new List<string> { "a", "b" }, ["arr"] = new[] { 1, 2 }, ["empty"] = Array.Empty<object>(),
            ["nested"] = new Dictionary<string, object?> { ["k"] = new List<Dictionary<string, object?>> { new() { ["x"] = false } } },
            ["el"] = element, ["set"] = new HashSet<string> { "only" },
        };
        const string expected = """{"s":"\u4E2D\u003C\u6587\u003E\u0026\u0027","b":true,"n":null,"i":3,"l":1234567890123,"d":0.5,"neg":-2,"list":["a","b"],"arr":[1,2],"empty":[],"nested":{"k":[{"x":false}]},"el":{"a":[1,"x"]},"set":["only"]}""";
        var strict = JsonOut.Serialize(payload);
        check(strict == expected, "jsonout: strict output matches hand-written string");
        check(strict == JsonSerializer.Serialize(payload), "jsonout: strict output identical to reflection serializer");
        var relaxed = Encoding.UTF8.GetString(JsonOut.SerializeRelaxed(new Dictionary<string, object?> { ["error"] = "中文 <b>" }));
        check(relaxed == """{"error":"中文 <b>"}""", "jsonout: relaxed keeps Chinese and markup unescaped");
        check(JsonOut.Serialize("v1.2+b") == "\"v1.2\\u002Bb\"", "jsonout: bare string uses default escaping");
        check(JsonOut.Serialize(new JsonObject { ["state"] = "interrupted" }) == """{"state":"interrupted"}""", "jsonout: JsonNode written as is");
        bool threw = false;
        try { JsonOut.Serialize(new Dictionary<string, object?> { ["bad"] = new Uri("https://example.com/") }); }
        catch (NotSupportedException e) { threw = e.Message.Contains("System.Uri"); }
        check(threw, "jsonout: unknown type throws naming the type (no silent wrong output)");
        check(JsonOut.ReadStringSet("""["a","b","a"]""") is { Count: 2 } s && s.Contains("a") && s.Contains("b"), "jsonout: string set read");
        foreach (var bad in new[] { "{}", "[1]", "null" })
        {
            bool rejected = false;
            try { JsonOut.ReadStringSet(bad); } catch (JsonException) { rejected = true; }
            check(rejected, "jsonout: string set rejects " + bad);
        }
    }
}
