// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 出包页打开哪一款（玩家反馈：A 在出包时点 B 的出包，进的是 A 的进度页）：全新窗口、游戏库两款 A / B，
// 用真实入口 ResetPack 登记 A 的出包作业，再按游戏库「出包」的走法设 selectedGame、调 OpenBuild。期望手写：
//   ① A 在出、打开 B → 停在出包页（build），左边说明带 A 的名字、开始键是「加入出包队列」；
//   ② A 在出、打开 A → 进度页（progress）；③ 没在出、打开 B → 出包页，开始键不是「加入出包队列」。
// 负对照：把 OpenBuild 换回「有出包在跑就去进度页」，① 不通。调用方核退出码 0 和末行「✓」。
using System.Reflection;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Threading;
using Avalonia.VisualTree;
using S2Arm.Launcher;
using S2Arm.Launcher.Protocol;

static class BuildRouteProbe
{
    static LibraryGame Game(string id, string name) => new(id, name, "v1.0.0", "", false, [], true, null, true,
        [new("base", id, 917504, "v1.0.0", 1_000_000_000L, "")]);

    public static int Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        var a = Game("0100AAAA00000000", "Alpha Probe Game");
        var b = Game("0100BBBB00000000", "Beta Probe Game");
        int fails = 0;
        var cases = new (string Name, bool APacking, LibraryGame Open, string WantPage, bool WantQueueHint)[]
        {
            ("A 在出包、打开 B", true, b, "build", true),
            ("A 在出包、打开 A", true, a, "progress", false),
            ("没在出包、打开 B", false, b, "build", false),
        };
        foreach (var (name, aPacking, open, wantPage, wantHint) in cases)
        {
            Exception? error = null;
            DispatcherUnhandledExceptionEventHandler trap = (_, e) => { error ??= e.Exception; e.Handled = true; };
            Dispatcher.UIThread.UnhandledException += trap;
            var w = new EnvironmentWindow { Width = 1280, Height = 900 };
            try
            {
                w.Show(); Dispatcher.UIThread.RunJobs();
                SetW(w, "catalog", new LibraryCatalog([a, b], true, "密钥已就绪"));
                SetW(w, "connectedFolder", Path.Combine(outDir, "library")); SetW(w, "libraryId", "probe-library");
                SetW(w, "page", "library");
                if (aPacking) CallW(w, "ResetPack", a);
                SetW(w, "selectedGame", open.Id);
                CallW(w, "OpenBuild"); CallW(w, "Render"); Dispatcher.UIThread.RunJobs();
                var page = (string)GetW(w, "page")!;
                if (page != wantPage) throw new InvalidOperationException($"打开 {open.Name} 进了 {page}，应进 {wantPage}");
                if (wantPage == "build")
                {
                    var queueLabel = (string)CallW(w, "T", "export.action.queue")!;
                    var start = w.GetVisualDescendants().OfType<Button>().FirstOrDefault(x => Avalonia.Automation.AutomationProperties.GetAutomationId(x) == "export.start")
                        ?? throw new InvalidOperationException("出包页找不到开始键（export.start）");
                    var label = start.Content is TextBlock tb ? tb.Text : start.Content?.ToString();
                    var texts = w.GetVisualDescendants().OfType<TextBlock>().Select(t => t.Text ?? "").ToList();
                    var hint = texts.Any(t => t.Contains(a.Name));
                    if (wantHint && (label != queueLabel || !hint)) throw new InvalidOperationException($"开始键「{label}」、说明里{(hint ? "有" : "没有")} A 的名字；应为「{queueLabel}」且带 A 的名字");
                    if (!wantHint && label == queueLabel) throw new InvalidOperationException("没在出包却显示「加入出包队列」");
                }
                var bmp = w.CaptureRenderedFrame();
                if (bmp is not null) { using var s = File.OpenWrite(Path.Combine(outDir, "build_route_" + name + ".png")); bmp.Save(s); }
            }
            catch (Exception e) { error ??= e is TargetInvocationException { InnerException: { } inner } ? inner : e; }
            finally { Dispatcher.UIThread.UnhandledException -= trap; try { w.Close(); Dispatcher.UIThread.RunJobs(); } catch (Exception) { } }
            if (error is null) Console.WriteLine($"通 {name}：进 {wantPage}" + (wantHint ? "，说明带正在出的那款、开始键是加入出包队列" : ""));
            else { fails++; Console.WriteLine($"不通 {name}：{error.GetType().Name}: {error.Message}"); }
        }
        Console.WriteLine($"{(fails == 0 ? "✓" : "✗")} 出包页打开哪一款：{cases.Length} 例，不通 {fails}");
        return fails == 0 ? 0 : 1;
    }

    static void SetW(object obj, string field, object? value)
    {
        var fi = obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance);
        if (fi is not null) { fi.SetValue(obj, value); return; }
        var pi = obj.GetType().GetProperty(field, BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Public)
            ?? throw new MissingMemberException(field);
        pi.SetValue(obj, value);
    }

    static object? GetW(object obj, string field)
    {
        var fi = obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance);
        if (fi is not null) return fi.GetValue(obj);
        return (obj.GetType().GetProperty(field, BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Public)
            ?? throw new MissingMemberException(field)).GetValue(obj);
    }

    static object? CallW(object obj, string method, params object[] args)
        => (obj.GetType().GetMethod(method, BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Public, args.Select(x => x.GetType()).ToArray())
            ?? throw new MissingMethodException(method)).Invoke(obj, args);
}
