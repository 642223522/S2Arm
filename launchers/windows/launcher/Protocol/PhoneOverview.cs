// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;

namespace S2Arm.Launcher.Protocol;

/// <summary>
/// 0.6.0 iPhone 总控台用的「这台手机的全貌」（作业 phoneOverview；同 Mac S2ArmAppleAdapter.PhoneOverview）。开关关着作业回 enabled = false → Parse 给 null。
/// </summary>
public sealed record PhoneOverview(IReadOnlyList<PhoneOverview.Phone> Phones)
{
    public enum GameState { Latest, Suggested, NotPushed, NeedsData }
    public sealed record Game(string GameId, GameState State, IReadOnlyList<string> Reasons, bool? DataOnComputer);
    /// <param name="Online">Probed：带 probe 才问过 USB；没问时 Online 无意义。问过时 null = 没连</param>
    public sealed record Phone(string Device, string Name, bool Installed, bool ShellCurrent, DateTimeOffset? ExpiresAtEstimate,
        bool Probed, string? Online, DateTimeOffset? LastSeen, string? SignMode, IReadOnlyList<Game> Games)
    {
        public bool KnownOffline => Probed && Online is null;
    }

    public static PhoneOverview? Parse(JsonElement r)
    {
        if (r.ValueKind != JsonValueKind.Object || !r.TryGetProperty("phones", out var ps0) || ps0.ValueKind != JsonValueKind.Array) return null;
        static string? S(JsonElement o, string k) => o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        static bool B(JsonElement o, string k) => o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
        static DateTimeOffset? D(JsonElement o, string k) => o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? DateTimeOffset.FromUnixTimeMilliseconds((long)(v.GetDouble() * 1000)) : null;
        var phones = new List<Phone>();
        if (r.TryGetProperty("phones", out var ps) && ps.ValueKind == JsonValueKind.Array)
            foreach (var p in ps.EnumerateArray())
            {
                if (p.ValueKind != JsonValueKind.Object || S(p, "device") is not { Length: > 0 } device) continue;
                var games = new List<Game>();
                if (p.TryGetProperty("games", out var gs) && gs.ValueKind == JsonValueKind.Array)
                    foreach (var g in gs.EnumerateArray())
                    {
                        if (g.ValueKind != JsonValueKind.Object || S(g, "gameId") is not { Length: > 0 } id) continue;
                        GameState? state = S(g, "state") switch { "latest" => GameState.Latest, "suggested" => GameState.Suggested, "notPushed" => GameState.NotPushed, "needsData" => GameState.NeedsData, _ => null };
                        if (state is null) continue;
                        var reasons = g.TryGetProperty("reasons", out var rs) && rs.ValueKind == JsonValueKind.Array ? rs.EnumerateArray().Select(x => x.GetString() ?? "").Where(x => x.Length > 0).ToArray() : [];
                        bool? data = g.TryGetProperty("dataOnComputer", out var dv) && dv.ValueKind is JsonValueKind.True or JsonValueKind.False ? dv.GetBoolean() : null;
                        games.Add(new Game(id.ToUpperInvariant(), state.Value, reasons, data));
                    }
                phones.Add(new Phone(device, S(p, "name") ?? "", B(p, "installed"), B(p, "shellCurrent"), D(p, "expiresAtEstimate"),
                    p.TryGetProperty("online", out _), S(p, "online"), D(p, "lastSeen"), S(p, "signMode"), games));
            }
        return new PhoneOverview(phones);
    }

    /// <summary>总控台当前这台：选过的那台；没选过 → 连着的那台 → 最近同步过的那台</summary>
    public Phone? Pick(string? chosen) =>
        Phones.FirstOrDefault(p => p.Device == chosen)
        ?? Phones.FirstOrDefault(p => p.Probed && p.Online is not null)
        ?? Phones.OrderByDescending(p => p.LastSeen ?? DateTimeOffset.MinValue).FirstOrDefault();

    /// <summary>首位卡状态行（流程稿表格，自上而下取第一条成立的；同 Mac S2ArmLauncherModel.consoleStatus）。返回 (文案键, 参数)</summary>
    public static (string Key, object[] Args) Status(Phone? p, DateTimeOffset now, int batchDone = 0, int batchTotal = 0)
    {
        if (p is null) return ("console.status.introduce", []);
        if (batchTotal > 0) return ("console.status.updating", [Math.Min(batchDone + 1, batchTotal), batchTotal]);
        if (p.KnownOffline) return p.LastSeen is { } seen ? ("console.status.notConnected", [seen]) : ("console.status.notConnectedNever", []);
        if (!p.Installed) return ("console.status.notInstalled", []);
        if (!p.ShellCurrent) return ("console.status.appOutdated", []);
        int? days = p.ExpiresAtEstimate is { } end ? DaysLeft(end, now) : null;
        if (days is <= 0) return ("console.status.expired", []);
        if (days is <= 2) return ("console.status.expiring", [days.Value]);
        var n = p.Games.Count(g => g.State == GameState.Suggested);
        if (n > 0) return ("console.status.suggested", [n]);
        return days is { } d ? ("console.status.ok", [d]) : ("console.status.okNoDays", []);
    }

    /// <summary>还剩几天（不足一天按一天，过了 0）；到期本来就是估的，界面写「约」</summary>
    public static int DaysLeft(DateTimeOffset end, DateTimeOffset now)
    {
        var s = (end - now).TotalSeconds;
        return s <= 0 ? 0 : (int)Math.Ceiling(s / 86_400);
    }
}
