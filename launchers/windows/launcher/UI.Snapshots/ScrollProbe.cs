// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 跳动验收：每个会被定时器 / 后台事件重画的页面，先滚到中间，再连续刷新 30 次（= 出包页 30 秒的每秒刷新），
// 每次刷新读两次控件屏幕坐标：
//   画面帧 —— 刷新后只跑到「渲染」优先级的任务、做一遍布局：下一帧屏幕上画出来的就是这个状态
//   稳定后 —— 所有排队任务（含事后恢复滚动位置的 Loaded 任务）跑完
// 两次都必须和刷新前一样（误差 0.5 像素内）才算不跳。每页把画面帧存成 PNG，ffmpeg 拼成录屏。
using System.Reflection;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Threading;
using Avalonia.VisualTree;
using S2Arm.Launcher;
using S2Arm.Launcher.Protocol;

static class ScrollProbe
{
    const int Refreshes = 30;

    public static int Run(string outDir)
    {
        var only = Environment.GetEnvironmentVariable("S2A_PROBE_ONLY");   // 只跑这几页（逗号分隔）
        Directory.CreateDirectory(outDir);
        Console.WriteLine($"渲染优先级 {DispatcherPriority.Render}，Loaded 优先级 {DispatcherPriority.Loaded}（Loaded {(DispatcherPriority.Loaded < DispatcherPriority.Render ? "低于" : "不低于")} 渲染）");
        var scenarios = new (string Name, string Label, Action<EnvironmentWindow> Setup)[]
        {
            ("progress", "出包进度页（每秒刷新）", w => { Library(w, 3); Progress(w, running: true); Go(w, "progress"); }),
            ("batch", "批量出包清单（出包中每秒刷新）", w => { Library(w, 14); Batch(w); Progress(w, running: true); SetW(w, "batchRunning", true); Go(w, "batch"); }),
            ("library", "游戏库（后台装机 / 出包事件重画）", w => { Library(w, 14); Progress(w, running: false); SetW(w, "packGame", null); Go(w, "library"); }),
            ("install", "装到 iPhone 页（每 5 秒查一次清单后重画）", w => { Library(w, 3); Progress(w, running: false); Go(w, "install"); }),
            ("storage", "存放位置页（作业事件重画）", w => { Library(w, 3); Go(w, "storage"); SetW(w, "overviewLoading", false); SetW(w, "overview", Storage()); CallW(w, "Render"); }),
            ("settings", "环境检查（检查结果回来重画）", w => { Library(w, 3); SetW(w, "report", Report()); Go(w, "settings"); }),
        };
        var failed = 0;
        var table = new List<string>();
        foreach (var (name, label, setup) in scenarios)
        {
            if (!string.IsNullOrEmpty(only) && !only.Split(',').Contains(name)) continue;
            Console.WriteLine($"── {label} …");
            var row = Probe(outDir, name, label, setup);
            table.Add(row.Line);
            Console.WriteLine(row.Line);
            if (!row.Pass) failed++;
        }
        Console.WriteLine();
        Console.WriteLine("页面 | 可滚动 | 标记控件 | 刷新次数 | 画面帧最大偏移 | 稳定后最大偏移 | 结论");
        foreach (var line in table) Console.WriteLine(line);
        return failed == 0 ? 0 : 1;
    }

    record Row(bool Pass, string Line);

    static Row Probe(string outDir, string name, string label, Action<EnvironmentWindow> setup)
    {
        foreach (var height in new[] { 700, 520, 400 })
        {
            var w = new EnvironmentWindow { Width = 1280, Height = height };
            w.Show();
            Dispatcher.UIThread.RunJobs();
            try
            {
                setup(w);
                Settle(w);
                var scroller = PageScroller(w);
                if (scroller is null) continue;   // 这个高度下页面不够长：换更矮的窗口
                scroller.Offset = new Vector(0, Math.Floor((scroller.Extent.Height - scroller.Viewport.Height) / 2));
                Settle(w);
                var markers = Markers(w);
                if (markers.Count == 0) return new(false, $"{label} | 是 | 0 | - | - | - | 红：找不到可当标记的文字");
                var frames = Path.Combine(outDir, name);
                Directory.CreateDirectory(frames);
                foreach (var f in Directory.GetFiles(frames, "*.png")) File.Delete(f);
                double frameMax = 0, settledMax = 0; var lost = 0;
                SaveFrame(w, frames, 0);
                for (var i = 1; i <= Refreshes; i++)
                {
                    CallW(w, "Render");
                    // 下一帧：渲染优先级及以上的任务 + 一遍布局（事后 Post 到 Loaded 的滚动恢复此时还没跑）
                    Dispatcher.UIThread.RunJobs(DispatcherPriority.Render);
                    w.UpdateLayout();
                    frameMax = Math.Max(frameMax, Deviation(w, markers, ref lost));
                    SaveFrame(w, frames, i * 2 - 1);
                    Settle(w);
                    settledMax = Math.Max(settledMax, Deviation(w, markers, ref lost));
                    SaveFrame(w, frames, i * 2);
                    // 计时器 / 进度事件那条路：只刷新活格子（修后才有 RefreshLive；修前计时器走的就是上面的整页 Render）
                    if (w.GetType().GetMethod("RefreshLive", BindingFlags.NonPublic | BindingFlags.Instance) is { } live)
                    {
                        live.Invoke(w, null);
                        Dispatcher.UIThread.RunJobs(DispatcherPriority.Render); w.UpdateLayout();
                        frameMax = Math.Max(frameMax, Deviation(w, markers, ref lost));
                        Settle(w);
                        settledMax = Math.Max(settledMax, Deviation(w, markers, ref lost));
                    }
                }
                var pass = frameMax <= 0.5 && settledMax <= 0.5 && lost == 0;
                var verdict = pass ? "绿：全程不动" : lost > 0 ? $"红：{lost} 次标记控件不在原处（滚走或重建后找不到）" : "红：跳动";
                return new(pass, $"{label} | 是（窗口高 {height}） | {markers.Count} | {Refreshes} | {frameMax:0.#} px | {settledMax:0.#} px | {verdict}");
            }
            finally { SetW(w, "packRunning", false); SetW(w, "batchRunning", false); w.Close(); Dispatcher.UIThread.RunJobs(); }   // 出包在跑时关窗会被拦下问取消
        }
        return new(false, $"{label} | 否 | - | - | - | - | 红：窗口压到 400 高仍不可滚，夹具不够长");
    }

    static void Settle(Window w) { Dispatcher.UIThread.RunJobs(); w.UpdateLayout(); Dispatcher.UIThread.RunJobs(); }

    /// 页面主滚动区：可滚、视口最高的那个（排除诊断文本框里的小滚动条）
    static ScrollViewer? PageScroller(Window w) => w.GetVisualDescendants().OfType<ScrollViewer>()
        .Where(s => s.Extent.Height > s.Viewport.Height + 40 && s.Viewport.Height > 200)
        .OrderByDescending(s => s.Viewport.Height).FirstOrDefault();

    /// 标记：当前视口里、全窗口只出现一次的文字（重画后按文字重新找，控件对象每次都是新的）
    static Dictionary<string, double> Markers(Window w)
    {
        var all = Texts(w).ToList();
        var unique = all.GroupBy(t => t.Text).Where(g => g.Count() == 1).Select(g => g.First());
        return unique.Where(t => t.Y > 60 && t.Y < w.Bounds.Height - 60).Take(5).ToDictionary(t => t.Text, t => t.Y);
    }

    static IEnumerable<(string Text, double Y)> Texts(Window w)
    {
        foreach (var tb in w.GetVisualDescendants().OfType<TextBlock>())
        {
            if (string.IsNullOrWhiteSpace(tb.Text) || !tb.IsEffectivelyVisible || tb.Text.Any(char.IsDigit)) continue;   // 带数字的多半是计时 / 进度，会变
            if (tb.TranslatePoint(new Point(0, 0), w) is not { } p) continue;
            yield return (tb.Text, p.Y);
        }
    }

    static double Deviation(Window w, Dictionary<string, double> markers, ref int lost)
    {
        var now = Texts(w).GroupBy(t => t.Text).ToDictionary(g => g.Key, g => g.First().Y);
        double max = 0;
        foreach (var (text, y) in markers)
        {
            if (!now.TryGetValue(text, out var y2)) { lost++; continue; }
            max = Math.Max(max, Math.Abs(y2 - y));
        }
        return max;
    }

    static void SaveFrame(Window w, string dir, int index)
    {
        AvaloniaHeadlessPlatform.ForceRenderTimerTick();
        var bmp = w.GetLastRenderedFrame();
        if (bmp is null) return;
        using var s = File.Create(Path.Combine(dir, $"f{index:000}.png"));
        bmp.Save(s);
    }

    // ── 夹具 ──────────────────────────────────────────────────────────────
    static LibraryGame Game(int i) => new(
        $"0100{i:X4}00000000", $"测试游戏 {(char)('A' + i)}", "v1.0.0", "", false, [], true,
        DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 86400.0, true,
        [new("base", $"0100{i:X4}00000000", 0, "v1.0.0", 4_000_000_000L, "extract")]);

    static void Library(EnvironmentWindow w, int count)
    {
        var games = Enumerable.Range(0, count).Select(Game).ToList();
        SetW(w, "catalog", new LibraryCatalog(games, true, "密钥已就绪"));
        SetW(w, "selectedGame", games[0].Id);
        SetW(w, "connectedFolder", "/tmp/s2arm-library");
        SetW(w, "libraryId", "mock-lib-id");
        SetW(w, "librarySummary", "library.completed");
        SetW(w, "report", Report());
    }

    static EnvironmentReport Report() => EnvironmentReport.Parse(
        "{\"schema\":1,\"ready\":true,\"checks\":[" + string.Join(",", Enumerable.Range(0, 12).Select(i =>
            $"{{\"id\":\"c{i}\",\"name\":\"检查项 {(char)('A' + i)}\",\"status\":\"ok\",\"ok\":true,\"message\":\"就绪\",\"code\":null,\"action\":null}}")) + "]}", 0);

    static StorageOverview Storage() => new(
        Enumerable.Range(0, 10).Select(i => new StorageOverview.Location($"l{i}", $"D:\\S2Arm 游戏库 {(char)('A' + i)}", $"磁盘 {(char)('A' + i)}",
            true, i == 0, 2_000_000_000_000L, 800_000_000_000L, 400_000_000_000L)).ToList(), [], []);

    static void Progress(EnvironmentWindow w, bool running)
    {
        var game = (LibraryGame)((LibraryCatalog)GetW(w, "catalog")!).Games[0];
        SetW(w, "packGame", game);
        SetW(w, "packState", running ? "running" : "succeeded");
        SetW(w, "packRunning", running);
        SetW(w, "packStarted", DateTime.UtcNow.AddSeconds(-30));
        var track = new MilestoneTrack();
        var plan = JsonDocument.Parse("""
{"type":"plan","milestone":null,"milestones":[
 {"id":"unpack","label":"解包","purpose":"读出游戏程序和资源，合并更新与 DLC。","expected":120,"source":"history","samples":3,"reuse":false},
 {"id":"prepare","label":"准备资源","purpose":"整理 DLC 和宽屏界面布局，同时在后台把游戏代码改写成苹果设备能直接运行的形式。","expected":80,"source":"history","samples":3,"reuse":false},
 {"id":"ipa","label":"编 App 与签名","purpose":"编出 iPhone / iPad 版程序、签名，并打好要推进手机的资源包。","expected":40,"source":"history","samples":3,"reuse":false}]}
""");
        track.Ingest(plan.RootElement, 0);
        var clock = DateTime.UtcNow.Subtract(DateTime.UnixEpoch).TotalSeconds;
        track.Ingest(JsonDocument.Parse("""{"type":"stage","milestone":"prepare","message":""}""").RootElement, clock - 30);
        SetW(w, "packTrack", track);
        var space = JsonDocument.Parse("""{"volumes":[{"role":"library","needBytes":79890000000,"freeBytes":153420000000,"basis":"rule","enough":true}]}""");
        SetW(w, "packSpace", PackSpace.TryParse(space.RootElement));
    }

    static void Batch(EnvironmentWindow w)
    {
        var games = ((LibraryCatalog)GetW(w, "catalog")!).Games;
        var items = string.Join(",", games.Select((g, i) =>
            $"{{\"gameId\":\"{g.Id}\",\"name\":\"{g.Name}\",\"platforms\":[\"iphone\"],\"results\":{{\"iphone\":{{\"state\":\"{(i == 0 ? "running" : "pending")}\"}}}}}}"));
        SetW(w, "batchState", BatchClient.Read(JsonDocument.Parse(
            $"{{\"batch\":{{\"schema\":1,\"location\":null,\"paused\":null,\"items\":[{items}]}},\"next\":null," +
            $"\"summary\":{{\"total\":{games.Count},\"completed\":0,\"failed\":0,\"cancelled\":0,\"pending\":{games.Count},\"done\":false}}}}").RootElement.Clone()).State);
    }

    static void Go(EnvironmentWindow w, string page)
        => w.GetType().GetMethod("Navigate", BindingFlags.NonPublic | BindingFlags.Instance)!.Invoke(w, [page]);

    static void SetW(object obj, string field, object? value)
    {
        var fi = obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance);
        if (fi is not null) { fi.SetValue(obj, value); return; }
        var pi = obj.GetType().GetProperty(field, BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Public)
            ?? throw new MissingMemberException(field);
        pi.SetValue(obj, value);
    }

    static object? GetW(object obj, string field)
        => obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance)?.GetValue(obj);

    static void CallW(object target, string method)
        => (target.GetType().GetMethod(method, BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new MissingMethodException(method)).Invoke(target, null);
}
