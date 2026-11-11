// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Collections.ObjectModel;
using System.Text.Json;

namespace S2Arm.Launcher.Protocol;

public sealed class EnvironmentProtocolException(string message, Exception? inner = null)
    : Exception(message, inner);

public sealed record EnvironmentCheck(
    string Id, string Name, string Status, string Message, string? Code, string? Action, Uri? OfficialUrl, bool Blocking = false)
{
    // Recovery text is displayed verbatim; it is never interpreted as a command or URL.
    public bool HasAction => !string.IsNullOrWhiteSpace(Action);
}

public sealed record EnvironmentError(string Code, string Message);

public sealed record EnvironmentReport(
    bool Ready, ReadOnlyCollection<EnvironmentCheck> Checks, EnvironmentError? Error)
{
    public static EnvironmentReport Parse(string json, int exitCode)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            ValidateUniqueFields(root);
            if (root.ValueKind != JsonValueKind.Object ||
                !root.GetProperty("schema").TryGetInt32(out var schema) || schema != 1)
                throw new EnvironmentProtocolException("Unsupported environment report schema.");

            var ready = root.GetProperty("ready").GetBoolean();
            var checksElement = root.GetProperty("checks");
            if (checksElement.ValueKind != JsonValueKind.Array)
                throw new EnvironmentProtocolException("Environment checks must be an array.");

            // 剃刀 W6：前端只解析、只查链接安全，不再替后端核对报告（状态白名单、ok 与状态一致、恢复字段与状态一致、
            //   id 不重复、退出码与 ready 一致）——后端加一个新状态，前端就整页显示「格式无法核实」，再叠 W5 变成「已准备好」。
            //   后端 winenv.py 自己有 RecoveryContractError 守着这些约定。
            var checks = new List<EnvironmentCheck>();
            foreach (var item in checksElement.EnumerateArray())
            {
                var status = RequiredText(item, "status");
                checks.Add(new EnvironmentCheck(RequiredText(item, "id"), RequiredText(item, "name"), status,
                    RequiredText(item, "message"), NullableText(item, "code"), NullableText(item, "action"), OfficialUrl(item),
                    item.TryGetProperty("blocking", out var blocking) ? blocking.GetBoolean() : status != "ok"));
            }

            EnvironmentError? error = null;
            if (root.TryGetProperty("error", out var errorElement))
                error = new(RequiredText(errorElement, "code"), RequiredText(errorElement, "message"));

            return new(ready, checks.AsReadOnly(), error);
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException or
                                         KeyNotFoundException or FormatException)
        {
            // Do not copy untrusted output or local paths into the protocol error text.
            throw new EnvironmentProtocolException("Malformed environment report.", exception);
        }
    }

    private static string RequiredText(JsonElement item, string name)
    {
        var value = item.GetProperty(name).GetString();
        return !string.IsNullOrWhiteSpace(value) ? value :
            throw new EnvironmentProtocolException("Missing environment text field.");
    }

    private static string? NullableText(JsonElement item, string name)
    {
        var element = item.GetProperty(name);
        return element.ValueKind == JsonValueKind.Null ? null : element.GetString();
    }

    private static Uri? OfficialUrl(JsonElement item)
    {
        // The backend owns the official destination. Never infer links from recovery text.
        // An unsafe link (not https, no host, credentials in it) is dropped for that check only (razor W6 / W7).
        if (!item.TryGetProperty("url", out var element) || element.ValueKind != JsonValueKind.String ||
            !Uri.TryCreate(element.GetString(), UriKind.Absolute, out var url) ||
            url.Scheme != Uri.UriSchemeHttps || url.Host.Length == 0 || url.UserInfo.Length != 0)
            return null;
        return url;
    }

    private static void ValidateUniqueFields(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in element.EnumerateObject())
            {
                if (!names.Add(property.Name))
                    throw new EnvironmentProtocolException("Duplicate JSON field in environment report.");
                ValidateUniqueFields(property.Value);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in element.EnumerateArray()) ValidateUniqueFields(item);
        }
    }
}
