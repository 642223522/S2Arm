// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 装机前清单按钮落点（11-19 落点契约，同 Mac）：清单项的 action 是按钮的唯一来源，控制口 POST /install-action 走同一个 RunInstallAction，
// 做成后 GET /state 的 presented 是这个 action。清单不手造：读 landing_items.json——后端 readiness_windows 真实产生的几组清单
// （pack/jobs/tests/test_landing_contract.py 核它逐项等于后端当前输出；11-19 原先手造了后端产生不了的 id「devcert:install」，测试绿、真实清单没按钮）。
// 全新窗口、游戏库一款 A，经真实入口 HandleControl 发请求。期望手写：
//   ① W1 点 package（openExport）→ 200、出包页、presented = openExport；② W3 点 devcert（devCertSettings）→ 200、设置页、presented = devCertSettings；
//   ③ 已好的项 → 409；④ 清单不是这一款的 → 409；⑤ /dismiss 后 presented 清空；
//   ⑥ 每组清单每个没好的项：带 action → 有 install.action.<动作> 按钮、文案是体验表 install_landing.actions 给的键；带 url → 有「打开官方下载页」按钮；
//      两样都不带 → 必须是体验表登记为只能人做（null）的项，否则红（真实清单上没按钮的情形）；
//   ⑦ W2 impactor_login 的按钮是「打开 Impactor」，全页没有旧的「去设置」（install.go_settings）；⑧ GET /state 带 presented、清单项带 action；
//   ⑨ InstallItem.Actions（解析白名单）= 体验表 install_landing.items.windows 用到的动作。
// 负对照（修前）：后端证书项不带 action → ② 404 / 409、⑥ devcert 没按钮。调用方核退出码 0 和末行「✓」。
using System.Reflection;
using System.Text;
using System.Text.Json;
using Avalonia.Controls;
using Avalonia.Threading;
using Avalonia.VisualTree;
using S2Arm.Launcher;
using S2Arm.Launcher.Protocol;

static class InstallActionProbe
{
    const string GameA = "0100AAAA00000000";

    static DirectoryInfo RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "launchers", "shared", "experience.v1.json"))) dir = dir.Parent;
        return dir ?? throw new InvalidOperationException("找不到仓库里的 launchers/shared/experience.v1.json");
    }

    static Dictionary<string, List<InstallItem>> Scenes(DirectoryInfo root)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(root.FullName, "launchers", "windows", "launcher", "UI.Snapshots", "landing_items.json")));
        var scenes = new Dictionary<string, List<InstallItem>>(StringComparer.Ordinal);
        foreach (var s in doc.RootElement.EnumerateObject())
            scenes[s.Name] = s.Value.EnumerateArray().Select(i => new InstallItem(i.GetProperty("id").GetString()!, i.GetProperty("ok").GetBoolean(),
                i.GetProperty("waiting").GetBoolean(), "t", "d", i.GetProperty("who").GetString() ?? "",
                i.GetProperty("url").ValueKind == JsonValueKind.String ? new Uri(i.GetProperty("url").GetString()!) : null,
                i.GetProperty("action").ValueKind == JsonValueKind.String ? i.GetProperty("action").GetString() : null)).ToList();
        return scenes;
    }

    /// <summary>体验表 install_landing.items.windows 里登记为 null 的项（只能人做：插线 / 解锁，不该有按钮）</summary>
    static HashSet<string> HumanOnly(DirectoryInfo root)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(root.FullName, "launchers", "shared", "experience.v1.json")));
        return doc.RootElement.GetProperty("install_landing").GetProperty("items").GetProperty("windows").EnumerateObject()
            .Where(p => p.Value.ValueKind == JsonValueKind.Null).Select(p => p.Name).ToHashSet(StringComparer.Ordinal);
    }

    static List<InstallItem> Scene(Dictionary<string, List<InstallItem>> scenes, string prefix) =>
        scenes.First(kv => kv.Key.StartsWith(prefix, StringComparison.Ordinal)).Value;

    public static int Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        var root = RepoRoot();
        var scenes = Scenes(root);
        var a = new LibraryGame(GameA, "Alpha Probe Game", "v1.0.0", "", false, [], true, null, true, [new("base", GameA, 917504, "v1.0.0", 1_000_000_000L, "")]);
        int fails = 0, n = 0;
        void Case(string name, List<InstallItem> items, Action<EnvironmentWindow> body)
        {
            n++;
            Exception? error = null;
            DispatcherUnhandledExceptionEventHandler trap = (_, e) => { error ??= e.Exception; e.Handled = true; };
            Dispatcher.UIThread.UnhandledException += trap;
            var w = new EnvironmentWindow { Width = 1280, Height = 900 };
            try
            {
                w.Show(); Dispatcher.UIThread.RunJobs();
                SetW(w, "catalog", new LibraryCatalog([a], true, "密钥已就绪"));
                SetW(w, "connectedFolder", Path.Combine(outDir, "library")); SetW(w, "libraryId", "probe-library");
                SetW(w, "selectedGame", GameA); SetW(w, "readinessFor", GameA); SetW(w, "readiness", new InstallReadiness(items.AsReadOnly(), false, "", ""));
                SetW(w, "page", "install"); CallW(w, "Render"); Dispatcher.UIThread.RunJobs();
                body(w);
            }
            catch (Exception e) { error ??= e is TargetInvocationException { InnerException: { } inner } ? inner : e; }
            finally { Dispatcher.UIThread.UnhandledException -= trap; try { w.Close(); Dispatcher.UIThread.RunJobs(); } catch (Exception) { } }
            if (error is null) Console.WriteLine($"通 {name}");
            else { fails++; Console.WriteLine($"不通 {name}：{error.GetType().Name}: {error.Message}"); }
        }
        var w1 = Scene(scenes, "W1"); var w2 = Scene(scenes, "W2"); var w3 = Scene(scenes, "W3");

        Case("① W1 点 package → 出包页、presented = openExport", w1, w =>
        {
            Want(Post(w, "/install-action", $"{{\"gameId\":\"{GameA}\",\"id\":\"package\"}}"), 200);
            Eq((string)GetW(w, "page")!, "build", "page"); Eq((string?)GetW(w, "presented"), "openExport", "presented");
        });
        Case("② W3 点 devcert → 设置页、presented = devCertSettings", w3, w =>
        {
            Want(Post(w, "/install-action", $"{{\"gameId\":\"{GameA}\",\"id\":\"devcert\"}}"), 200);
            Eq((string)GetW(w, "page")!, "settings", "page"); Eq((string?)GetW(w, "presented"), "devCertSettings", "presented");
        });
        Case("③ 已好的项 → 409", w3, w => Want(Post(w, "/install-action", $"{{\"gameId\":\"{GameA}\",\"id\":\"package\"}}"), 409));
        Case("④ 清单不是这一款的 → 409", w1, w =>
        {
            SetW(w, "readinessFor", "0100BBBB00000000");
            Want(Post(w, "/install-action", $"{{\"gameId\":\"{GameA}\",\"id\":\"package\"}}"), 409);
        });
        Case("⑤ /dismiss 后 presented 清空", w1, w =>
        {
            Want(Post(w, "/install-action", $"{{\"gameId\":\"{GameA}\",\"id\":\"package\"}}"), 200);
            Want(Post(w, "/dismiss", "{}"), 200);
            Eq((string?)GetW(w, "presented"), null, "presented");
        });
        foreach (var (scene, items) in scenes)
            Case($"⑥ {scene}：每个没好的项都有按钮", items, w =>
            {
                var buttons = w.GetVisualDescendants().OfType<Button>().ToList();
                var text = (SharedText)GetW(w, "text")!;
                foreach (var it in items.Where(i => !i.Ok && !i.Waiting))
                {
                    if (it.Action is { } act)
                    {
                        var b = buttons.FirstOrDefault(x => Id(x) == "install.action." + act) ?? throw new InvalidOperationException($"{it.Id}（{act}）没有按钮");
                        var key = text.InstallActionLabel(act) ?? throw new InvalidOperationException($"{act} 在体验表 install_landing.actions 里没有文案键");
                        Eq(Label(b), (string)CallW(w, "T", key)!, $"{it.Id} 按钮文案");
                    }
                    else if (it.OfficialUrl is not null)
                    {
                        var official = (string)CallW(w, "T", "action.open_official")!;
                        if (!buttons.Any(x => Label(x) == official)) throw new InvalidOperationException($"{it.Id} 带官方网页却没有「{official}」按钮");
                    }
                    else if (!HumanOnly(root).Contains(it.Id))   // 既没动作也没网页：只有体验表登记为「只能人做」（null）的项可以没按钮
                        throw new InvalidOperationException($"{it.Id} 没好却没有按钮（既不带 action 也不带 url，体验表也没登记为只能人做）");
                }
            });
        Case("⑦ W2 impactor_login 是「打开 Impactor」、没有旧的「去设置」", w2, w =>
        {
            var buttons = w.GetVisualDescendants().OfType<Button>().ToList();
            var imp = buttons.FirstOrDefault(b => Id(b) == "install.action.openImpactor") ?? throw new InvalidOperationException("impactor_login 没有 install.action.openImpactor 按钮");
            Eq(Label(imp), (string)CallW(w, "T", "action.open_impactor")!, "Impactor 按钮文案");
            if (buttons.Any(b => Id(b) == "install.go_settings")) throw new InvalidOperationException("还有旧的「去设置」按钮（install.go_settings）");
        });
        Case("⑧ GET /state 带 presented、清单项带 action", w1, w =>
        {
            Want(Post(w, "/install-action", $"{{\"gameId\":\"{GameA}\",\"id\":\"package\"}}"), 200);
            var state = (Dictionary<string, object?>)CallW(w, "ControlState")!;
            Eq((string?)state["presented"], "openExport", "state.presented");
            var install = (Dictionary<string, object?>)state["installReadiness"]!;
            Eq((string?)((List<Dictionary<string, object?>>)install["items"]!)[0]["action"], "openExport", "items[0].action");
        });
        Case("⑨ 解析白名单 = 体验表 Windows 落点用到的动作", w1, _ =>
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(root.FullName, "launchers", "shared", "experience.v1.json")));
            var used = doc.RootElement.GetProperty("install_landing").GetProperty("items").GetProperty("windows").EnumerateObject()
                .Where(p => p.Value.ValueKind == JsonValueKind.String).SelectMany(p => p.Value.GetString()!.Split('|')).Where(x => x != "@url").ToHashSet();
            if (!used.SetEquals(InstallItem.Actions))
                throw new InvalidOperationException($"体验表 {string.Join("/", used.Order())} ≠ 白名单 {string.Join("/", InstallItem.Actions.Order())}");
        });
        Console.WriteLine($"{(fails == 0 ? "✓" : "✗")} 装机前清单按钮落点：{n} 例，不通 {fails}");
        return fails == 0 ? 0 : 1;
    }

    static string? Id(Button b) => Avalonia.Automation.AutomationProperties.GetAutomationId(b);
    static string? Label(Button b) => b.Content is TextBlock tb ? tb.Text : b.Content?.ToString();

    static ControlReply Post(EnvironmentWindow w, string path, string body)
    {
        var bytes = Encoding.UTF8.GetBytes(body);
        var request = ControlRequest.Parse(Encoding.UTF8.GetBytes($"POST {path} HTTP/1.1\r\nContent-Length: {bytes.Length}\r\n\r\n").Concat(bytes).ToArray())
            ?? throw new InvalidOperationException("请求解析不出");
        var task = (Task<ControlReply>)CallW(w, "HandleControl", request)!;
        while (!task.IsCompleted) Dispatcher.UIThread.RunJobs();
        Dispatcher.UIThread.RunJobs();
        return task.Result;
    }

    static void Want(ControlReply reply, int code)
    {
        if (reply.Code != code) throw new InvalidOperationException($"回 {reply.Code}，应为 {code}（{Encoding.UTF8.GetString(reply.Body)}）");
    }

    static void Eq(string? got, string? want, string what)
    {
        if (got != want) throw new InvalidOperationException($"{what} = {got ?? "null"}，应为 {want ?? "null"}");
    }

    static void SetW(object obj, string field, object? value) =>
        (obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance) ?? throw new MissingMemberException(field)).SetValue(obj, value);

    static object? GetW(object obj, string field) =>
        (obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance) ?? throw new MissingMemberException(field)).GetValue(obj);

    static object? CallW(object obj, string method, params object?[] args) =>
        (obj.GetType().GetMethod(method, BindingFlags.NonPublic | BindingFlags.Instance) ?? throw new MissingMethodException(method)).Invoke(obj, args);
}
