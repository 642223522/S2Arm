// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iPhone 上 S2Arm 的更新：手动更新（11-16 维护者「那改成更稳妥的手动更新吧 启动器和移动端都是」；同 Mac S2ArmLauncherModel.keptModulesTick / +PhoneBanner.swift）。
//   每 2 分钟跑一次 phoneKeptPull 作业查手机要不要更新：Windows 自己不从手机收回代码模块（WinPhone.pull_kept 回 0，收回只在 Mac 上做），
//   kept 只会来自 Mac 收回过的同一个游戏库里还没补进的（一般为空），平时起作用的是壳旧了（shellUpdate）；
//   查到要更新只重读游戏库，顶栏亮「更新 iPhone」，不自动装。
//   新版启动器头一次读到要更新的手机 → 后台 installUpdatePrepare（不碰手机，点了以后装得快），准备期间不出横幅；准备完出横幅「有新版，点这里更新」，
//   点了 = 顶栏「更新 iPhone」；玩家点了更新后横幅显示进度，装完 phoneUpdates 空了横幅自己收起。
//   开关：privateRoot/auto-update-phone.off 存在 = 玩家关了（缺省开，存的是「关」，同 Mac S2AAutoUpdatePhoneOff）：不准备、不出横幅。
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

public sealed partial class EnvironmentWindow
{
    private DispatcherTimer? phoneAutoTimer;
    private bool phoneAutoTicking;
    private readonly HashSet<string> phoneAutoTried = new();

    private string AutoUpdatePhoneOffPath => Path.Combine(privateRoot, "auto-update-phone.off");
    // 自动更新的后台作业失败不再静默（0.5.0 候选验收：请求体被拒、循环 catch 吞掉，十几分钟一单都没发出也看不出来）：
    //   每次失败写一行 <私有目录>/logs/phone-auto-update.log（诊断包收 logs/），带「连续第几次」；成功一次计数归零。同 Mac S2ArmLauncherModel+PhoneBanner.swift
    private readonly Dictionary<string, int> phoneAutoFails = new();
    private void NotePhoneAuto(string operation, string? failure)
    {
        if (failure is null) { phoneAutoFails.Remove(operation); return; }
        var n = phoneAutoFails[operation] = phoneAutoFails.GetValueOrDefault(operation) + 1;
        try
        {
            var dir = Path.Combine(privateRoot, "logs"); Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "phone-auto-update.log"), $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz} {operation} 失败（连续第 {n} 次）：{failure}{Environment.NewLine}");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
    private bool AutoUpdatePhoneOn => !File.Exists(AutoUpdatePhoneOffPath);

    /// <summary>2 分钟循环这一轮跳过的原因（null = 照常收）：原因变了才记一行进 phone-auto-update.log。原先跳过不留痕，
    /// 11-16 实机验收「8 分钟一单 phoneKeptPull 都没发、日志里什么都没有」，查不出是哪一条拦的</summary>
    private string? lastPhoneTickSkip = "";
    private void NotePhoneTick(string? skip)
    {
        if (skip == lastPhoneTickSkip) return;
        lastPhoneTickSkip = skip;
        try
        {
            var dir = Path.Combine(privateRoot, "logs"); Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "phone-auto-update.log"),
                $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz} 2 分钟循环：{(skip is null ? "照常收" : "这一轮跳过（" + skip + "）")}{Environment.NewLine}");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>横幅状态："" 不显示 / preparing / ready / onConnect</summary>
    private string phoneBanner = "";
    private bool phonePrepareTried;

    /// <summary>更新弹窗主按钮写「更新启动器和 iPhone App」：装过 iPhone、且没关自动更新 iPhone App</summary>

    /// <summary>这次启动头一次读到要更新的手机：后台准备一次</summary>
    private async Task PreparePhoneUpdateAsync()
    {
        if (phonePrepareTried || IosAfterPackIsExport || catalog is not { PhoneUpdates.Count: > 0 } || !AutoUpdatePhoneOn || connectedFolder is null || libraryId is null) return;
        phonePrepareTried = true;
        var ok = false;
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("installUpdatePrepare", ""), null, CancellationToken.None);
            ok = job.Report.Succeeded;
            NotePhoneAuto("installUpdatePrepare", ok ? null : "作业没成功（作业记录里有原因）");
        }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or OperationCanceledException or System.ComponentModel.Win32Exception) { NotePhoneAuto("installUpdatePrepare", error.GetType().Name + "：" + error.Message); }
        if (phoneBanner.Length == 0) { phoneBanner = ok ? "ready" : "onConnect"; Render(); }   // 准备期间不出横幅（「正在更新 iPhone」只给玩家点了之后的装机）
    }

    /// <summary>横幅这一刻的文案键（Percent 非空 = 进行中、不给 ×）：在更新 iPhone → 正在更新；否则按准备结果；手机已是本版 → null</summary>
    private (string Key, long? Percent)? PhoneBannerLine()
    {
        if (phoneBanner.Length == 0) return null;
        if (phoneUpdating) return ("phone.update.banner.preparing", -1);   // 更新进度事件只刷新顶栏那一格（RefreshLive），横幅不写会停住的百分比；-1 = 进行中、不给 ×
        if (catalog is not { PhoneUpdates.Count: > 0 }) return null;
        return phoneBanner switch { "preparing" => ("phone.update.banner.preparing", null), "ready" => ("phone.update.banner.ready", null), _ => ("phone.update.banner.on_connect", null) };
    }

    private void AddPhoneUpdateBar(StackPanel body)
    {
        if (PhoneBannerLine() is not { } line) return;
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 10 };
        var text = new TextBlock { Text = T(line.Key), FontSize = 13, FontWeight = FontWeight.SemiBold,
            Foreground = Ink, TextWrapping = TextWrapping.Wrap, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
        Avalonia.Automation.AutomationProperties.SetAutomationId(text, "notice.phoneUpdate");
        if (line.Percent is null && phoneBanner != "preparing" && !phoneUpdating)
        {   // 手动更新（11-16）：横幅文字点了 = 顶栏「更新 iPhone」（RequestPhoneUpdateAsync），玩家点了才装
            var open = new Button { Content = text, Padding = new Thickness(0), Background = Brushes.Transparent, BorderThickness = new Thickness(0) };
            Avalonia.Automation.AutomationProperties.SetAutomationId(open, "notice.phoneUpdate.open");
            open.Click += (_, _) => _ = RequestPhoneUpdateAsync();
            row.Children.Add(open);
        }
        else row.Children.Add(text);
        if (line.Percent is null)
        {
            var close = new Button { Content = "✕", Padding = new Thickness(8, 4), Background = Brushes.Transparent, Foreground = Ink };
            ToolTip.SetTip(close, T("notice.close"));
            Avalonia.Automation.AutomationProperties.SetName(close, T("notice.close"));
            Avalonia.Automation.AutomationProperties.SetAutomationId(close, "notice.phoneUpdate.close");
            close.Click += (_, _) => { phoneBanner = ""; Render(); };
            Grid.SetColumn(close, 1); row.Children.Add(close);
        }
        body.Children.Add(new Border { Child = row, Padding = new Thickness(16, 10), CornerRadius = new CornerRadius(10), Background = new SolidColorBrush(Colors.White, 0.06) });
    }

    private void StartPhoneAutoUpdate()
    {
        if (phoneAutoTimer is not null) return;
        phoneAutoTimer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(2) };
        phoneAutoTimer.Tick += (_, _) => _ = PhoneAutoUpdateTickAsync();
        phoneAutoTimer.Start();
        lastPhoneTickSkip = "";   // 起循环记一行：之后每轮按原因变化记（定时器根本没跑起来时，日志里连这行都没有）
        NotePhoneTick("循环已启动，第一轮 2 分钟后");
    }

    /// <summary>一轮：→ 这次有没有发起「更新 iPhone」</summary>
    private async Task<bool> PhoneAutoUpdateTickAsync()
    {
        // 玩家在出包页选了「出完之后导出自签」：不走启动器装机，自动装到手机也不做（玩家选择优先）
        // 只按真冲突跳过（维护者「只按真冲突互斥」）：别的作业在跑照样收（升级首启迁移几分钟，原先「有任何作业就整轮跳过」拖到第 360 秒）；
        //   和同一台手机上装机 / 推包的冲突由作业层判（phoneKeptPull 拿不到手机锁就这一轮不收）
        var skip = IosAfterPackIsExport ? "出包页选了导出自签" : phoneAutoTicking ? "上一轮还没完" : connectedFolder is null || libraryId is null ? "游戏库没连上"
            : batchRunning ? "批量出包在跑" : null;
        NotePhoneTick(skip);
        if (skip is not null) return false;
        phoneAutoTicking = true;
        try
        {
            JsonElement r;
            try
            {
                var job = await PackJobClient.RunAsync(PackRequest("phoneKeptPull", ""), null, CancellationToken.None);
                if (!job.Report.Succeeded || job.Report.Result.ValueKind != JsonValueKind.Object) { NotePhoneAuto("phoneKeptPull", "作业没成功（作业记录里有原因）"); return false; }
                NotePhoneAuto("phoneKeptPull", null);
                r = job.Report.Result;
            }
            catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
                InvalidOperationException or OperationCanceledException or System.ComponentModel.Win32Exception) { NotePhoneAuto("phoneKeptPull", error.GetType().Name + "：" + error.Message); return false; }
            var device = r.TryGetProperty("device", out var d) && d.ValueKind == JsonValueKind.String ? d.GetString() ?? "" : "";
            var kept = r.TryGetProperty("kept", out var k) && k.ValueKind == JsonValueKind.Array
                ? k.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.String).Select(e => e.GetString()!).OrderBy(s => s, StringComparer.Ordinal).ToList()
                : new List<string>();
            var shellUpdate = r.TryGetProperty("shellUpdate", out var s) && s.ValueKind == JsonValueKind.True && AutoUpdatePhoneOn;
            if ((kept.Count == 0 && !shellUpdate) || device.Length == 0) return false;
            // 正在玩（或查不清）：装 App 会杀掉玩家这一局，等下一轮（这一批不记已试）
            if (!(r.TryGetProperty("running", out var run) && run.ValueKind == JsonValueKind.False)) return false;
            // 只发现、不装（11-16 维护者：「改成更稳妥的手动更新吧，启动器和移动端都是」）：重读游戏库，顶栏 / 更新页按 phoneUpdates 亮「更新 iPhone」，玩家点了才装
            var batch = device + ":" + string.Join(",", kept) + (shellUpdate ? ":shell" : "");
            if (phoneAutoTried.Contains(batch) || batchRunning) return false;
            phoneAutoTried.Add(batch);
            await RefreshLibraryAsync();
            return false;
        }
        finally { phoneAutoTicking = false; }
    }
}
