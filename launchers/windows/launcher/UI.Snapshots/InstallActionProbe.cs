// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 装机前清单按钮落点（11-19 落点契约，同 Mac）：清单项的 action 是按钮的唯一来源，控制口 POST /install-action 走同一个 RunInstallAction，
// 做成后 GET /state 的 presented 是这个 action。全新窗口、游戏库一款 A，直接放一份清单，经真实入口 HandleControl 发请求。期望手写：
//   ① package 没好（openExport）→ 200、进出包页（build）、presented = openExport；② 证书项（devCertSettings）→ 200、进设置页、presented = devCertSettings；
//   ③ 已好的项 → 409；④ 清单不是这一款的 → 409；⑤ /dismiss 后 presented 清空；
//   ⑥ 装机页渲染：有 install.action.openExport 按钮；impactor_login（openImpactor）的按钮文案是「打开 Impactor」，不再是「去设置」（install.go_settings 不在）；
//   ⑦ GET /state 带 presented，清单项带 action。
// 负对照（修前）：没有 /install-action（404）、openImpactor 按钮是「去设置」、package 没按钮 —— ① ② ⑥ 不通。调用方核退出码 0 和末行「✓」。
using System.Reflection;
using System.Text;
using Avalonia.Controls;
using Avalonia.Threading;
using Avalonia.VisualTree;
using S2Arm.Launcher;
using S2Arm.Launcher.Protocol;

static class InstallActionProbe
{
    const string GameA = "0100AAAA00000000";

    public static int Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        var a = new LibraryGame(GameA, "Alpha Probe Game", "v1.0.0", "", false, [], true, null, true, [new("base", GameA, 917504, "v1.0.0", 1_000_000_000L, "")]);
        var items = new List<InstallItem>
        {
            new("package", false, false, "t", "d", "app", null, "openExport"),
            new("impactor_login", false, false, "t", "d", "human", null, "openImpactor"),
            new("devcert:install", false, false, "t", "d", "human", null, "devCertSettings"),
            new("connected", true, false, "t", "", "human", null, null),
        };
        int fails = 0, n = 0;
        void Case(string name, Action<EnvironmentWindow> body)
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

        Case("① 点 package → 进出包页、presented = openExport", w =>
        {
            Want(Post(w, "/install-action", $"{{\"gameId\":\"{GameA}\",\"id\":\"package\"}}"), 200);
            Eq((string)GetW(w, "page")!, "build", "page"); Eq((string?)GetW(w, "presented"), "openExport", "presented");
        });
        Case("② 点证书项 → 进设置页、presented = devCertSettings", w =>
        {
            Want(Post(w, "/install-action", $"{{\"gameId\":\"{GameA}\",\"id\":\"devcert:install\"}}"), 200);
            Eq((string)GetW(w, "page")!, "settings", "page"); Eq((string?)GetW(w, "presented"), "devCertSettings", "presented");
        });
        Case("③ 已好的项 → 409", w => Want(Post(w, "/install-action", $"{{\"gameId\":\"{GameA}\",\"id\":\"connected\"}}"), 409));
        Case("④ 清单不是这一款的 → 409", w =>
        {
            SetW(w, "readinessFor", "0100BBBB00000000");
            Want(Post(w, "/install-action", $"{{\"gameId\":\"{GameA}\",\"id\":\"package\"}}"), 409);
        });
        Case("⑤ /dismiss 后 presented 清空", w =>
        {
            Want(Post(w, "/install-action", $"{{\"gameId\":\"{GameA}\",\"id\":\"package\"}}"), 200);
            Want(Post(w, "/dismiss", "{}"), 200);
            Eq((string?)GetW(w, "presented"), null, "presented");
        });
        Case("⑥ 清单按钮：package 有「出包」、openImpactor 是「打开 Impactor」、没有旧的「去设置」", w =>
        {
            var buttons = w.GetVisualDescendants().OfType<Button>().ToList();
            string? Id(Button b) => Avalonia.Automation.AutomationProperties.GetAutomationId(b);
            string? Label(Button b) => b.Content is TextBlock tb ? tb.Text : b.Content?.ToString();
            var export = buttons.FirstOrDefault(b => Id(b) == "install.action.openExport") ?? throw new InvalidOperationException("package 没好却没有 install.action.openExport 按钮");
            Eq(Label(export), (string)CallW(w, "T", "nav.build")!, "出包按钮文案");
            var imp = buttons.FirstOrDefault(b => Id(b) == "install.action.openImpactor") ?? throw new InvalidOperationException("impactor_login 没有 install.action.openImpactor 按钮");
            Eq(Label(imp), (string)CallW(w, "T", "action.open_impactor")!, "Impactor 按钮文案");
            if (buttons.Any(b => Id(b) == "install.go_settings")) throw new InvalidOperationException("还有旧的「去设置」按钮（install.go_settings）");
        });
        Case("⑦ GET /state 带 presented、清单项带 action", w =>
        {
            Want(Post(w, "/install-action", $"{{\"gameId\":\"{GameA}\",\"id\":\"package\"}}"), 200);
            var state = (Dictionary<string, object?>)CallW(w, "ControlState")!;
            Eq((string?)state["presented"], "openExport", "state.presented");
            var install = (Dictionary<string, object?>)state["installReadiness"]!;
            var first = ((List<Dictionary<string, object?>>)install["items"]!)[0];
            Eq((string?)first["action"], "openExport", "items[0].action");
        });
        Console.WriteLine($"{(fails == 0 ? "✓" : "✗")} 装机前清单按钮落点：{n} 例，不通 {fails}");
        return fails == 0 ? 0 : 1;
    }

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
