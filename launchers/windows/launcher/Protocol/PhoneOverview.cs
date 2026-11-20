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
    /// <summary>同一台手机上装着不止一个 S2Arm 时让玩家选的候选（作业 candidates，install.s2arm_candidates；同 Mac PhoneOverview.Candidate）</summary>
    /// <param name="ByThisLauncher">这台电脑的启动器装的</param>
    /// <param name="IdentityTeam">这个 S2Arm 导入的签名证书的团队；没导入 = null</param>
    public sealed record Candidate(string BundleId, string Team, bool ByThisLauncher, string? IdentityTeam)
    {
        /// <summary>导入的签名证书团队与 App 团队对得上（界面追加「已导入签名证书」）</summary>
        public bool CertImported => IdentityTeam is { Length: > 0 } t && t == Team;
    }
    /// <param name="Online">Probed：带 probe 才问过 USB；没问时 Online 无意义。问过时 null = 没连</param>
    /// <param name="InstalledBy">手机上的 S2Arm 谁装的（作业 installedBy）："launcher" | "external"（AltStore / SideStore…）；null = 没装或判不出（旧作业不带）</param>
    /// <param name="Actions">作业给的这台的按钮（别的工具装的才有：exportShellIpa / pushS2arm / exportS2arm / handOverIdentity）；没给 = 空</param>
    /// <param name="NeedsChoice">装着不止一个 S2Arm、玩家还没选（作业 needsChoice）：只出「选用哪个 S2Arm」</param>
    /// <param name="Candidates">装着不止一个时的全部候选（选没选过都带，选过的据此给「换一个」）；只有一个或没探测 = 空</param>
    public sealed record Phone(string Device, string Name, bool Installed, bool ShellCurrent, DateTimeOffset? ExpiresAtEstimate,
        bool Probed, string? Online, DateTimeOffset? LastSeen, string? SignMode, IReadOnlyList<Game> Games,
        string? InstalledBy = null, string BundleId = "", IReadOnlyList<string>? Actions = null,
        bool NeedsChoice = false, IReadOnlyList<Candidate>? Candidates = null)
    {
        public bool KnownOffline => Probed && Online is null;
        public bool External => InstalledBy == "external";
    }

    /// <summary>总控台一台手机上的按钮（同 Mac S2ArmLauncherModel.ConsoleAction；界面与控制口 GET /state 的 phoneConsole、POST /console-action 同一个来源）</summary>
    public static class Act
    {
        public const string InstallShell = "installShell", UpdateShell = "updateShell", RenewShell = "renewShell", ExportShellIpa = "exportShellIpa",
            HandOverIdentity = "handOverIdentity", UpdateSelected = "updateSelected", PushS2arm = "pushS2arm", ExportS2arm = "exportS2arm",
            ChooseApp = "chooseApp";   // 同一台手机上装着不止一个 S2Arm：选用哪一个（作业 phoneChooseApp）；选过了也能「换一个」
        public static readonly string[] All = [InstallShell, UpdateShell, RenewShell, ExportShellIpa, HandOverIdentity, UpdateSelected, PushS2arm, ExportS2arm, ChooseApp];
    }

    /// <summary>这台手机显示哪些按钮（同 Mac consoleActions）。别的工具装的：按作业给的 actions（认不得的丢掉；没给按四个缺省），绝不出安装 / 续签 / 更新 S2Arm、更新所选；
    /// 其余：① 安装 / 更新 / 续签 一颗 + 交签名身份，② 更新所选。装着不止一个、还没选（NeedsChoice）：只出「选用哪个 S2Arm」；选过了、候选不止一个：末尾加「换一个」</summary>
    public static IReadOnlyList<string> Actions(Phone p)
    {
        if (p.NeedsChoice) return [Act.ChooseApp];
        string[] change = (p.Candidates?.Count ?? 0) > 1 ? [Act.ChooseApp] : [];
        if (p.External)
        {
            string[] shell = [Act.InstallShell, Act.UpdateShell, Act.RenewShell, Act.UpdateSelected, Act.ChooseApp];
            var given = (p.Actions ?? []).Where(a => Act.All.Contains(a) && !shell.Contains(a)).ToArray();
            return [.. (given.Length > 0 ? given : [Act.ExportShellIpa, Act.PushS2arm, Act.ExportS2arm, Act.HandOverIdentity]), .. change];
        }
        return [!p.Installed ? Act.InstallShell : !p.ShellCurrent ? Act.UpdateShell : Act.RenewShell, Act.HandOverIdentity, Act.UpdateSelected, .. change];
    }

    /// <summary>候选的标签（文案键，按顺序拼；同 Mac candidateLabelKeys）：这台电脑的启动器装的 / 别的工具装的；导入的签名证书团队与 App 团队对得上时追加「已导入签名证书」。
    /// 只陈述事实、不推荐哪一个（候选按作业给的包名顺序列）</summary>
    public static IReadOnlyList<string> CandidateLabelKeys(Candidate c) =>
        [c.ByThisLauncher ? "console.choose.byLauncher" : "console.choose.byOther", .. c.CertImported ? new[] { "console.choose.certImported" } : []];

    /// <summary>GET /state 的 phoneConsole（同 Mac S2ArmControl.phoneConsole）：[{device, installed: {bundleId, by: s2arm | other | null}, actions, needsChoice,
    /// candidates: [{bundleId, team, byThisLauncher, identityTeam}]}]；needsChoice 时 installed.bundleId = null，选过的就是 installed.bundleId</summary>
    public List<Dictionary<string, object?>> ConsoleState() => Phones.Select(p => new Dictionary<string, object?>
    {
        ["device"] = p.Device,
        ["installed"] = new Dictionary<string, object?> { ["bundleId"] = p.BundleId.Length > 0 ? p.BundleId : null,
            ["by"] = p.InstalledBy switch { "launcher" => "s2arm", "external" => "other", _ => null } },
        ["actions"] = Actions(p).ToList(),
        ["needsChoice"] = p.NeedsChoice,
        ["candidates"] = (p.Candidates ?? []).Select(c => new Dictionary<string, object?>
            { ["bundleId"] = c.BundleId, ["team"] = c.Team, ["byThisLauncher"] = c.ByThisLauncher, ["identityTeam"] = c.IdentityTeam }).ToList(),
    }).ToList();

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
                var actions = p.TryGetProperty("actions", out var av) && av.ValueKind == JsonValueKind.Array
                    ? av.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToArray() : [];
                var candidates = new List<Candidate>();
                if (p.TryGetProperty("candidates", out var cs) && cs.ValueKind == JsonValueKind.Array)
                    foreach (var c in cs.EnumerateArray())
                        if (c.ValueKind == JsonValueKind.Object && S(c, "bundleId") is { Length: > 0 } bid)
                            candidates.Add(new Candidate(bid, S(c, "team") ?? "", B(c, "byThisLauncher"), S(c, "identityTeam") is { Length: > 0 } it ? it : null));
                phones.Add(new Phone(device, S(p, "name") ?? "", B(p, "installed"), B(p, "shellCurrent"), D(p, "expiresAtEstimate"),
                    p.TryGetProperty("online", out _), S(p, "online"), D(p, "lastSeen"), S(p, "signMode"), games,
                    S(p, "installedBy") is "launcher" or "external" ? S(p, "installedBy") : null, S(p, "bundleId") ?? "", actions,
                    B(p, "needsChoice"), candidates));
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
        if (p.NeedsChoice) return ("console.status.chooseApp", []);   // 装着不止一个 S2Arm、玩家还没选用哪一个
        if (p.External) return ("console.status.externalApp", []);   // 别的工具装的：没有我们的签名时刻与壳号，不判没装 / 有新版 / 到期
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
