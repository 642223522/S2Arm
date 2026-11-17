// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace S2Arm.Launcher.Protocol;

/// <summary>作业层（pack/jobs）文字的英文显示（同 Mac 适配层 BackendText.swift，同一份对照表）：作业记录、事件、报错一律是中文原句，
/// 英文界面显示时才翻。对照表 = Mac 的 Localizable.json（source → en）+ 共享体验规格里的状态 / 结局 / 画面模式标签 / 阶段名。
/// 翻法同 Mac：整句对照 → 带 {0} 占位的句式（占位里的值再翻）→ 按「\n」「；」拆开逐句翻再拼；认不出的原样显示。纯函数、不缓存（同 Mac）：
/// 实测（剃刀 W16，11-11）一句没见过的约 6 µs、建表约 28 ms；原先的缓存不设上限，带计数的进度句每句都新记一条，长时间出包只涨不落。</summary>
public sealed class BackendText
{
    private readonly Dictionary<string, string> english;
    private readonly List<(Regex Regex, int[] Indices, string Replacement)> patterns = [];
    private readonly List<(string Source, string En)> entries = [];
    private readonly Dictionary<string, (Dictionary<string, string> Whole, List<(Regex Regex, int[] Indices, string Replacement)> Patterns)> localized = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Dictionary<string, string>> overlayText = new(StringComparer.Ordinal);
    private static readonly Regex Slots = new(@"\{(\d+)\}", RegexOptions.Compiled);
    private static readonly Regex Han = new(@"\p{IsCJKUnifiedIdeographs}", RegexOptions.Compiled);

    public BackendText(string localizableJson, string experienceJson)
    {
        var entries = new List<(string Source, string En)>();
        foreach (var e in JsonDocument.Parse(localizableJson).RootElement.EnumerateArray())
            entries.Add((e.GetProperty("source").GetString() ?? "", e.GetProperty("en").GetString() ?? ""));
        entries.AddRange(SharedEntries(experienceJson));
        this.entries = entries;
        english = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (s, en) in entries) english.TryAdd(s, en);
        patterns = Build(entries.Select(e => (e.Source, e.En)));
    }

    private static List<(Regex, int[], string)> Build(IEnumerable<(string Source, string Target)> pairs)
    {
        var list = new List<(Regex, int[], string)>();
        foreach (var (s, target) in pairs.OrderByDescending(e => Slots.Replace(e.Source, "").Length))
        {
            var matches = Slots.Matches(s);
            if (matches.Count == 0) continue;
            var pattern = new StringBuilder(@"\A"); var cursor = 0; var indices = new List<int>();
            foreach (Match m in matches)
            {
                pattern.Append(Regex.Escape(s[cursor..m.Index])).Append("(.*?)");
                indices.Add(int.Parse(m.Groups[1].Value)); cursor = m.Index + m.Length;
            }
            pattern.Append(Regex.Escape(s[cursor..])).Append(@"\z");
            list.Add((new Regex(pattern.ToString(), RegexOptions.Singleline), indices.ToArray(), target));
        }
        return list;
    }

    /// <summary>一门语言的叠加译文（共享 l10n/<语言>.json 的 text 块，按简中原句）：11-14 加新语言，同 Mac BackendText.overlay。</summary>
    public void AddOverlay(string language, string json)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        using var doc = JsonDocument.Parse(json);
        if (doc.RootElement.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.Object)
            foreach (var p in text.EnumerateObject())
                if (p.Value.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(p.Value.GetString())) map[p.Name] = p.Value.GetString()!;
        overlayText[language] = map;
        localized.Remove(language);
    }

    /// <summary>一句作业层文字在界面语言下的显示：en 英文；zh-Hans（及其余 zh 值）原句；其余查叠加译文，没翻的回落（繁中回落原句、其余回落英文）。</summary>
    public string Translate(string text, string language)
    {
        if (language == "en") return English(text);
        if (language.StartsWith("zh") && language != "zh-Hant") return text;
        if (!localized.TryGetValue(language, out var table))
        {
            var o = overlayText.GetValueOrDefault(language) ?? new(StringComparer.Ordinal);
            var chinese = SharedText.Fallback(language) == "zh-Hans";
            string Target((string Source, string En) e) => o.TryGetValue(e.Source, out var t) ? t : chinese ? e.Source : e.En;
            var whole = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var e in entries) whole.TryAdd(e.Source, Target(e));
            table = (whole, Build(entries.Select(e => (e.Source, Target(e)))));
            localized[language] = table;
        }
        return Localize(text, language, table, 0);
    }

    private string Localize(string text, string language, (Dictionary<string, string> Whole, List<(Regex Regex, int[] Indices, string Replacement)> Patterns) table, int depth)
    {
        if (text.Length == 0 || depth >= 4) return text;
        if (table.Whole.TryGetValue(text, out var hit)) return hit;
        if (!Han.IsMatch(text)) return text;
        foreach (var (regex, indices, replacement) in table.Patterns)
        {
            var m = regex.Match(text);
            if (!m.Success) continue;
            var args = new Dictionary<int, string>();
            for (var g = 0; g < indices.Length; g++) args[indices[g]] = Localize(m.Groups[g + 1].Value, language, table, depth + 1);
            return Slots.Replace(replacement, s => args.TryGetValue(int.Parse(s.Groups[1].Value), out var v) ? v : "");
        }
        foreach (var separator in new[] { "\n", "；" })
        {
            if (!text.Contains(separator)) continue;
            var pieces = text.Split(separator);
            var translated = pieces.Select(p => Localize(p, language, table, depth + 1)).ToArray();
            var cjk = language.StartsWith("zh") || language == "ja";
            if (!translated.SequenceEqual(pieces)) return string.Join(separator == "；" && !cjk ? "; " : separator, translated);
        }
        return text;
    }

    /// <summary>共享规格里进翻译表的中英文（同 Mac BackendText.sharedEntries）：running / failed 状态名、作业结局、出包画面模式标签、阶段名。</summary>
    private static IEnumerable<(string, string)> SharedEntries(string json)
    {
        var spec = JsonDocument.Parse(json).RootElement;
        (string, string)? Text(JsonElement t) =>
            t.ValueKind == JsonValueKind.Object && t.TryGetProperty("zh-Hans", out var zh) && t.TryGetProperty("en", out var en) ? (zh.GetString() ?? "", en.GetString() ?? "") : null;
        if (spec.TryGetProperty("states", out var states))
            foreach (var s in states.EnumerateArray())
                if (s.GetProperty("id").GetString() is "running" or "failed" && Text(s.GetProperty("title")) is { } t) yield return t;
        if (spec.TryGetProperty("event_map", out var map) && map.TryGetProperty("terminal_results", out var results))
            foreach (var id in new[] { "job.succeeded", "job.cancelled" })
                if (results.TryGetProperty(id, out var r) && r.TryGetProperty("title", out var title) && Text(title) is { } t) yield return t;
        if (spec.TryGetProperty("pack_graphics_mode", out var modes) && modes.TryGetProperty("labels", out var labels))
            foreach (var p in labels.EnumerateObject()) if (Text(p.Value) is { } t) yield return t;
        if (spec.TryGetProperty("stage_labels", out var stages))
            foreach (var p in stages.EnumerateObject()) if (Text(p.Value) is { } t) yield return t;
    }

    /// <summary>一句作业层文字的英文；没有汉字或认不出就原样。</summary>
    public string English(string text) => Translate(text, 0);

    private string Translate(string text, int depth)
    {
        if (text.Length == 0 || depth >= 4) return text;
        if (english.TryGetValue(text, out var hit)) return hit;
        if (!Han.IsMatch(text)) return text;
        foreach (var (regex, indices, replacement) in patterns)
        {
            var m = regex.Match(text);
            if (!m.Success) continue;
            var args = new Dictionary<int, string>();
            for (var g = 0; g < indices.Length; g++) args[indices[g]] = Translate(m.Groups[g + 1].Value, depth + 1);
            // 按模板拼，不在原句上替换：玩家给的值里可能有花括号、$、换行
            return Slots.Replace(replacement, s => args.TryGetValue(int.Parse(s.Groups[1].Value), out var v) ? v : "");
        }
        foreach (var separator in new[] { "\n", "；" })
        {
            if (!text.Contains(separator)) continue;
            var pieces = text.Split(separator);
            var translated = pieces.Select(p => Translate(p, depth + 1)).ToArray();
            if (!translated.SequenceEqual(pieces)) return string.Join(separator == "；" ? "; " : separator, translated);
        }
        return text;
    }
}
