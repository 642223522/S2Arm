// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 闪烁验收（11-11）：出包 / 装机在跑时页面每秒（或每个进度事件）刷新一次。按真实那条路刷新 30 拍
//   （出包页走每秒计时器调的方法：有 RefreshLive 用它，没有就是整页 Render；装机页走进度事件 IngestPhoneEvent），每拍量三样：
//   ① 进度条换没换：控件被换掉，进度条动画（首次出包没有历史用时是来回滚的不确定进度条）就从头重来——肉眼看是一抽一抽
//   ② 新建了多少控件：刷新前不在窗口里的控件数
//   ③ 画面：刷新后下一帧（渲染优先级的任务跑完、事后 Post 的恢复还没跑）和刷新前那帧比，变了多少像素
//   判据：进度条 0 次被换、画面帧变化像素 ≤ 0.5%（计时数字那几个字），才算不闪。
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Avalonia.VisualTree;
using S2Arm.Launcher;
using S2Arm.Launcher.Protocol;

static class FlickerProbe
{
    const int Ticks = 30;

    public static int Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        var scenarios = new (string Name, string Label, Action<EnvironmentWindow> Setup, Action<EnvironmentWindow> Tick)[]
        {
            ("progress-first", "出包进度页 · 首次出包（没有历史用时，不确定进度条）",
                w => { Library(w, 3); Progress(w, history: false); Go(w, "progress"); }, PackTick),
            ("progress-history", "出包进度页 · 有历史用时", w => { Library(w, 3); Progress(w, history: true); Go(w, "progress"); }, PackTick),
            ("install", "装到 iPhone 页 · 装机进行中（进度事件）", w => { Library(w, 3); Installing(w); Go(w, "install"); }, PhoneTick),
        };
        var failed = 0;
        var table = new List<string>();
        foreach (var (name, label, setup, tick) in scenarios)
        {
            Console.WriteLine($"── {label} …");
            var row = Probe(Path.Combine(outDir, name), label, setup, tick);
            table.Add(row.Line); Console.WriteLine(row.Line);
            if (!row.Pass) failed++;
        }
        Console.WriteLine();
        Console.WriteLine("页面 | 刷新次数 | 进度条被换掉 | 每拍新建控件（中位 / 最多） | 画面帧变化像素（最多） | 结论");
        foreach (var line in table) Console.WriteLine(line);
        return failed == 0 ? 0 : 1;
    }

    record Row(bool Pass, string Line);

    static Row Probe(string dir, string label, Action<EnvironmentWindow> setup, Action<EnvironmentWindow> tick)
    {
        Directory.CreateDirectory(dir);
        foreach (var f in Directory.GetFiles(dir, "*.png")) File.Delete(f);
        var w = new EnvironmentWindow { Width = 1280, Height = 800 };
        w.Show(); Dispatcher.UIThread.RunJobs();
        try
        {
            setup(w); Settle(w);
            tick(w); Settle(w);   // 预热一拍：有的页第一次进来要等一拍才画成该页（不算数），基准帧从这之后取
            var bars = Bars(w);
            if (bars.Count == 0) return new(false, $"{label} | - | - | - | - | 红：页面上找不到进度条，夹具不对");
            var before = Frame(w, dir, 0);
            int barSwaps = 0; var created = new List<int>(); double worst = 0;
            for (var i = 1; i <= Ticks; i++)
            {
                var known = new HashSet<Visual>(w.GetVisualDescendants());
                tick(w);
                Dispatcher.UIThread.RunJobs(DispatcherPriority.Render); w.UpdateLayout();
                var shown = Frame(w, dir, i);
                worst = Math.Max(worst, Changed(before, shown));
                Settle(w);
                created.Add(w.GetVisualDescendants().Count(v => !known.Contains(v)));
                var now = Bars(w);
                if (!now.SetEquals(bars)) barSwaps++;
                bars = now; before = Frame(w, dir, -1);
            }
            created.Sort();
            var pass = barSwaps == 0 && worst <= 0.005;
            return new(pass, $"{label} | {Ticks} | {barSwaps} 次 | {created[created.Count / 2]} / {created[^1]} | {worst:P2} | {(pass ? "绿：不闪" : "红：闪")}");
        }
        finally { SetW(w, "packRunning", false); SetW(w, "installBusy", false); w.Close(); Dispatcher.UIThread.RunJobs(); }
    }

    static void PackTick(EnvironmentWindow w)
        => CallW(w, w.GetType().GetMethod("RefreshLive", BindingFlags.NonPublic | BindingFlags.Instance) is not null ? "RefreshLive" : "Render");

    static int phoneDone;
    static void PhoneTick(EnvironmentWindow w)
    {
        var e = JsonDocument.Parse($$"""{"type":"progress","message":"正在把游戏资源推到 iPhone（第 {{++phoneDone}} 块）"}""").RootElement;
        (w.GetType().GetMethod("IngestPhoneEvent", BindingFlags.NonPublic | BindingFlags.Instance)
            ?? throw new MissingMethodException("IngestPhoneEvent")).Invoke(w, [e]);
    }

    static HashSet<ProgressBar> Bars(Window w) => w.GetVisualDescendants().OfType<ProgressBar>().Where(b => b.IsEffectivelyVisible).ToHashSet();

    static void Settle(Window w) { Dispatcher.UIThread.RunJobs(); w.UpdateLayout(); Dispatcher.UIThread.RunJobs(); }

    /// 取当前画面像素（BGRA）；index ≥ 0 时另存 PNG 方便人看
    static byte[] Frame(Window w, string dir, int index)
    {
        AvaloniaHeadlessPlatform.ForceRenderTimerTick();
        var bmp = w.GetLastRenderedFrame() ?? throw new InvalidOperationException("没有画面帧");
        if (index >= 0) { using var s = File.Create(Path.Combine(dir, $"f{index:000}.png")); bmp.Save(s); }
        var stride = bmp.PixelSize.Width * 4;
        var buf = new byte[stride * bmp.PixelSize.Height];
        var h = GCHandle.Alloc(buf, GCHandleType.Pinned);
        try { bmp.CopyPixels(new PixelRect(bmp.PixelSize), h.AddrOfPinnedObject(), buf.Length, stride); }
        finally { h.Free(); }
        return buf;
    }

    /// 变了的像素占比（任一通道差 > 24 才算变，抗锯齿的细微差不算）
    static double Changed(byte[] a, byte[] b)
    {
        if (a.Length != b.Length) return 1;
        long n = 0;
        for (var i = 0; i < a.Length; i += 4)
            if (Math.Abs(a[i] - b[i]) > 24 || Math.Abs(a[i + 1] - b[i + 1]) > 24 || Math.Abs(a[i + 2] - b[i + 2]) > 24) n++;
        return (double)n / (a.Length / 4);
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
    }

    static void Progress(EnvironmentWindow w, bool history)
    {
        var game = ((LibraryCatalog)GetW(w, "catalog")!).Games[0];
        SetW(w, "packGame", game); SetW(w, "packState", "running"); SetW(w, "packRunning", true);
        SetW(w, "packStarted", DateTime.UtcNow.AddSeconds(-30));
        string M(string id, string label, int expected) => history
            ? $$"""{"id":"{{id}}","label":"{{label}}","purpose":"","expected":{{expected}},"source":"history","samples":3,"reuse":false}"""
            : $$"""{"id":"{{id}}","label":"{{label}}","purpose":"","expected":null,"source":"none","samples":0,"reuse":false}""";
        var track = new MilestoneTrack();
        track.Ingest(JsonDocument.Parse($$"""{"type":"plan","milestone":null,"milestones":[{{M("unpack", "解包", 120)}},{{M("prepare", "准备资源", 80)}},{{M("ipa", "编 App 与签名", 40)}}]}""").RootElement, 0);
        var clock = DateTime.UtcNow.Subtract(DateTime.UnixEpoch).TotalSeconds;
        track.Ingest(JsonDocument.Parse("""{"type":"stage","milestone":"prepare","message":"正在改写游戏代码"}""").RootElement, clock - 30);
        SetW(w, "packTrack", track);
    }

    static void Installing(EnvironmentWindow w)
    {
        var game = ((LibraryCatalog)GetW(w, "catalog")!).Games[0];
        SetW(w, "installBusy", true); SetW(w, "installState", "running"); SetW(w, "installMessage", "正在连接 iPhone");
        SetW(w, "installGameId", game.Id); SetW(w, "installGameName", game.Name); SetW(w, "installSeen", false);
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
