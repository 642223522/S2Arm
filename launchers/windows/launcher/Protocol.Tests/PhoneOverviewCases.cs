// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;
using S2Arm.Launcher.Protocol;

// 0.6.0 iPhone 总控台（同 Mac PhoneConsoleTests）。期望按《0.6.0 极简流程》界面一节手写：
//   首位卡状态行自上而下取第一条成立的；没选过时管连着的那台，再不然管最近同步过的那台；开关关着不出
internal static class PhoneOverviewCases
{
    public static void Run(Action<bool, string> check)
    {
        static JsonElement J(string s) => JsonDocument.Parse(s).RootElement.Clone();
        check(PhoneOverview.Parse(J("""{}""")) is null, "console: no phones key (old job layer) → no first card");
        var o = PhoneOverview.Parse(J("""{"phones":[ {"device":"D1","name":"我的手机","installed":true,"shellCurrent":false,"online":null,"lastSeen":1999990000,"signMode":"devCert", "games":[{"gameId":"0100a","state":"suggested","reasons":["hostAbi"]},{"gameId":"0100B","state":"needsData","dataOnComputer":false},{"gameId":"0100C","state":"weird"}]}, {"device":"D2","name":"旧手机","lastSeen":1999000000}]}"""))!;
        var p = o.Phones[0];
        check(o.Phones.Count == 2 && p.SignMode == "devCert" && !p.ShellCurrent, "console: phone fields parsed");
        check(p.Probed && p.KnownOffline && !o.Phones[1].Probed, "console: online key present and null = probed and offline; absent = not probed");
        check(string.Join(",", p.Games.Select(g => g.GameId)) == "0100A,0100B" && p.Games[1].DataOnComputer == false, "console: ids upper-cased, unknown states dropped");

        var now = DateTimeOffset.FromUnixTimeSeconds(2_000_000_000);
        PhoneOverview.Phone Ph(bool installed = true, bool current = true, double? expires = 6 * 86_400 - 60, bool probed = false, string? online = null,
            PhoneOverview.GameState[]? games = null, string device = "D1", DateTimeOffset? seen = null) =>
            new(device, "我的手机", installed, current, expires is { } e ? now.AddSeconds(e) : null, probed, online, seen, "appleId",
                (games ?? []).Select((s, i) => new PhoneOverview.Game("G" + i, s, s == PhoneOverview.GameState.Suggested ? ["shader"] : [], true)).ToArray());
        string K(PhoneOverview.Phone? x, int done = 0, int total = 0) { var (k, a) = PhoneOverview.Status(x, now, done, total); return k + (a.Length > 0 ? ":" + string.Join(",", a) : ""); }
        check(K(null) == "console.status.introduce", "status: nothing seen → intro card");
        check(K(Ph(installed: false, probed: true, seen: now)) == "console.status.notConnected:" + now, "status: offline before not-installed");
        check(K(Ph(installed: false, probed: true)) == "console.status.notConnectedNever", "status: offline, never synced");
        check(K(Ph(), 1, 3) == "console.status.updating:2,3", "status: updating shows the current one");
        check(K(Ph(installed: false)) == "console.status.notInstalled", "status: not installed");
        check(K(Ph(current: false, expires: -10)) == "console.status.appOutdated", "status: new app before expiry");
        check(K(Ph(expires: -10)) == "console.status.expired", "status: expired");
        check(K(Ph(expires: 86_400 + 5, games: [PhoneOverview.GameState.Suggested])) == "console.status.expiring:2", "status: a day and a bit = 2 days; expiring before suggested");
        check(K(Ph(games: [PhoneOverview.GameState.Suggested, PhoneOverview.GameState.Suggested, PhoneOverview.GameState.Latest])) == "console.status.suggested:2", "status: suggested count");
        check(K(Ph(games: [PhoneOverview.GameState.Latest])) == "console.status.ok:6", "status: ok with days");
        check(K(Ph(expires: null)) == "console.status.okNoDays", "status: no estimate (certificate) → no days");

        var two = new PhoneOverview([Ph(device: "OLD", seen: now.AddSeconds(-99)), Ph(device: "NEW", seen: now)]);
        check(two.Pick(null)?.Device == "NEW", "pick: most recently synced");
        var online = new PhoneOverview([Ph(device: "OLD", probed: true, online: "usb", seen: now.AddSeconds(-99)), Ph(device: "NEW", seen: now)]);
        check(online.Pick(null)?.Device == "OLD" && online.Pick("NEW")?.Device == "NEW", "pick: connected one first; a chosen one wins");

        // 11-19 自签走查结构 4、5：别的工具（AltStore / SideStore）装的 S2Arm（同 Mac PhoneConsoleTests；期望按作业契约 host_update.phone_overview 手写）
        const string alt = "io.s2arm.games.example01";
        var ext = PhoneOverview.Parse(J("""{"phones":[{"device":"ALT-1","name":"备用手机","installed":true,"installedBy":"external","bundleId":"io.s2arm.games.example01","shellCurrent":null,"signMode":"external","online":"usb","actions":["exportShellIpa","pushS2arm","exportS2arm","handOverIdentity"],"games":[]}, {"device":"P1","installed":true,"installedBy":"launcher","bundleId":"io.example.one","shellCurrent":true}, {"device":"OLD","installed":true,"shellCurrent":true}, {"device":"NEW","installedBy":"weird"}]}"""))!;
        var a1 = ext.Phones[0];
        check(a1.InstalledBy == "external" && a1.External && a1.BundleId == alt && !a1.ShellCurrent && a1.Actions!.SequenceEqual(["exportShellIpa", "pushS2arm", "exportS2arm", "handOverIdentity"]),
            "external: installedBy / bundleId / actions parsed, shellCurrent null → false");
        check(ext.Phones[1].InstalledBy == "launcher" && ext.Phones[2].InstalledBy is null && ext.Phones[3].InstalledBy is null && ext.Phones[2].Actions!.Count == 0,
            "external: old job without installedBy → null; unknown value → null; no actions → empty");
        check(K(a1) == "console.status.externalApp", "status: external app has its own state (not notInstalled / appOutdated / expired)");
        check(K(a1 with { Online = null }) == "console.status.notConnectedNever", "status: offline still comes first");
        string Acts(PhoneOverview.Phone x) => string.Join(",", PhoneOverview.Actions(x));
        check(Acts(a1) == "exportShellIpa,pushS2arm,exportS2arm,handOverIdentity", "actions: external → the four job buttons in order");
        check(Acts(a1 with { Actions = ["installShell", "renewShell", "handOverIdentity", "bogus"] }) == "handOverIdentity", "actions: external never shows install / renew, unknown dropped");
        check(Acts(a1 with { Actions = [] }) == "exportShellIpa,pushS2arm,exportS2arm,handOverIdentity", "actions: external without job actions → the four defaults");
        check(Acts(Ph()) == "renewShell,handOverIdentity,updateSelected" && Acts(Ph(installed: false)).StartsWith("installShell,") && Acts(Ph(current: false)).StartsWith("updateShell,"),
            "actions: launcher phones keep install / update / renew + identity + update selected");
        var st = ext.ConsoleState();
        Dictionary<string, object?> Inst(int i) => (Dictionary<string, object?>)st[i]["installed"]!;
        check((string?)Inst(0)["by"] == "other" && (string?)Inst(0)["bundleId"] == alt && st[0]["device"] as string == "ALT-1", "state: external → installed.by other with its bundle id");
        var acts0 = (List<string>)st[0]["actions"]!;
        check(!acts0.Contains("installShell") && acts0.Contains("handOverIdentity"), "state: acceptance — external phone has handOverIdentity and no installShell");
        check((string?)Inst(1)["by"] == "s2arm" && Inst(2)["by"] is null && Inst(3)["bundleId"] is null, "state: launcher → s2arm; unknown → null; no bundle → null");
    }
}
