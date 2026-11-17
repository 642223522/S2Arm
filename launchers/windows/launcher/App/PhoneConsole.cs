// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

/// <summary>
/// 0.6.0 iPhone 总控台（通用壳开关后面；同 Mac LauncherView+PhoneConsole / S2ArmLauncherModel+PhoneConsole，《0.6.0 极简流程》界面一节）：
/// 游戏库列表第一行固定「S2Arm」（不算进游戏数），选中它时上方大图区换成这台手机的总控台。开关关着 phoneOverview 为 null，什么都不出。
/// 本段接 ① 手机与 App、② 游戏同步、⑥ 帮助；③④⑤ 等对应作业进 main 后接。不加门、不加锁：要手机的按钮只在没连时灰并就近写原因。
/// </summary>
public sealed partial class EnvironmentWindow
{
    private const string ConsoleId = "s2arm.console";
    private PhoneOverview? phoneOverview;
    private string? consoleDevice;
    private readonly HashSet<string> consoleSelection = new(StringComparer.OrdinalIgnoreCase);
    private HashSet<string> consoleSeeded = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<string> consoleBatch = new();
    private bool ConsoleSelected => phoneOverview is not null && selectedGame == ConsoleId;
    private PhoneOverview.Phone? ConsolePhone => phoneOverview?.Pick(consoleDevice);

    private async Task RefreshPhoneOverviewAsync(bool probe = false)
    {
        try
        {
            var extra = probe ? new Dictionary<string, object?> { ["probe"] = true } : null;
            var job = await PackJobClient.RunAsync(PackRequest("phoneOverview", "", extra), null, CancellationToken.None);
            phoneOverview = job.Report.Succeeded ? PhoneOverview.Parse(job.Report.Result) : null;
            if (phoneOverview is not null && phoneOverview.Phones.All(p => p.Device != consoleDevice)) consoleDevice = null;
            SeedConsoleSelection();
        }
        // 读不到不弹框（首位卡是附带的入口），但不吞：记日志，保持上次的值
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception) { Console.Error.WriteLine("S2Arm phoneOverview: " + error.Message); }
        Render();
    }

    /// <summary>建议更新的默认勾上；玩家取消的不重勾，直到它的状态变了（同 Mac seedConsoleSelection）</summary>
    private void SeedConsoleSelection()
    {
        var suggested = (ConsolePhone?.Games ?? []).Where(g => g.State == PhoneOverview.GameState.Suggested).Select(g => g.GameId).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var id in suggested.Except(consoleSeeded)) consoleSelection.Add(id);
        consoleSeeded = suggested;
    }

    private string Tf(string key, params object[] args) =>
        args.Select((a, i) => (a, i)).Aggregate(T(key), (s, x) => s.Replace("{" + x.i + "}", x.a is DateTimeOffset d ? d.LocalDateTime.ToString("g") : x.a.ToString()));

    private int ConsoleBatchDone =>
        consoleBatch.Count(id => !phoneQueue.Any(q => string.Equals(q.GameId, id, StringComparison.OrdinalIgnoreCase))
                                 && !(installBusy && string.Equals(installGameId, id, StringComparison.OrdinalIgnoreCase)));

    private string ConsoleStatusText()
    {
        var (key, args) = PhoneOverview.Status(ConsolePhone, DateTimeOffset.Now, ConsoleBatchDone, consoleBatch.Count);
        return Tf(key, args);
    }

    /// <summary>「更新所选」：按游戏库顺序一款款推总控台这台（装机作业本身一次一款，后面的自动排进手机队列）</summary>
    private void UpdateSelected()
    {
        if (consoleBatch.Count > 0 || ConsolePhone is not { } phone) return;
        var order = (catalog?.Games ?? []).Where(g => !g.Hidden && consoleSelection.Contains(g.Id)).ToList();
        if (order.Count == 0) return;
        consoleBatch.AddRange(order.Select(g => g.Id.ToUpperInvariant()));
        foreach (var g in order) _ = InstallAsync(g, toDevice: phone.Device);
        Render();
    }

    /// <summary>「停下」：停在当前这款（推完照样算数；没推完的下次接着推），排着的不再推</summary>
    private void StopUpdateSelected()
    {
        var batch = consoleBatch.ToHashSet(StringComparer.OrdinalIgnoreCase);
        phoneQueue.RemoveAll(q => q.GameId is { } id && batch.Contains(id));
        consoleBatch.RemoveAll(id => !(installBusy && string.Equals(installGameId, id, StringComparison.OrdinalIgnoreCase)));
        Render();
    }

    /// <summary>手机槽空出且队里没有了（JobSlots.EndJob）：这一轮推完就收尾、重读总览</summary>
    private void ConsoleBatchStep()
    {
        if (consoleBatch.Count == 0 || ConsoleBatchDone < consoleBatch.Count) return;
        consoleBatch.Clear();
        _ = RefreshPhoneOverviewAsync();
    }

    /// <summary>游戏库列表第一行「S2Arm」</summary>
    private Control ConsoleRow()
    {
        var line = new Grid { ColumnDefinitions = new ColumnDefinitions("72,*,Auto"), ColumnSpacing = 18 };
        line.Children.Add(new Border { Width = 72, Height = 72, CornerRadius = new CornerRadius(12), Background = Brush.Parse("#202024"),
            Child = new TextBlock { Text = "📱 S2Arm", FontWeight = FontWeight.Bold, FontSize = 13, Foreground = Ink, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } });
        var detail = new StackPanel { Spacing = 5, VerticalAlignment = VerticalAlignment.Center };
        detail.Children.Add(Label(ConsolePhone is { } p && p.Name.Length > 0 ? p.Name : "S2Arm", 18));
        detail.Children.Add(Muted(ConsoleStatusText(), 13));
        Grid.SetColumn(detail, 1); line.Children.Add(detail);
        var open = Action("library.select", () => { selectedGame = ConsoleId; _ = RefreshPhoneOverviewAsync(probe: true); Render(); });
        open.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(open, 2); line.Children.Add(open);
        Avalonia.Automation.AutomationProperties.SetAutomationId(line, "card." + ConsoleId);
        return Card(line, 14);
    }

    private Control ConsoleSection(string titleKey, Control content)
    {
        var box = new StackPanel { Spacing = 8 };
        box.Children.Add(Muted(T(titleKey), 12));
        box.Children.Add(content);
        return new Border { Background = Brush.Parse("#0DFFFFFF"), CornerRadius = new CornerRadius(12), Padding = new Thickness(16), Child = box };
    }

    /// <summary>选中首位时大图区的整页</summary>
    private Control ConsolePanel()
    {
        var phone = ConsolePhone;
        var page = new StackPanel { Spacing = 16 };
        if (phone is null)   // 只在 Mac / 电脑上玩的人：三句介绍 +「连上 iPhone 开始」，不出空表和灰按钮
        {
            page.Children.Add(Label(T("console.status.introduce"), 28));
            page.Children.Add(new TextBlock { Text = T("console.intro.body"), TextWrapping = TextWrapping.Wrap, MaxWidth = 620, Foreground = Ink });
            page.Children.Add(Primary(T("console.intro.start"), () => _ = UpdatePhoneAsync(false, [])));
            Avalonia.Automation.AutomationProperties.SetAutomationId(page, "console.intro");
            return Card(page, 24);
        }
        var offline = phone.KnownOffline;
        Control Offline() => new TextBlock { Text = Tf("console.offline", phone.Name.Length > 0 ? phone.Name : "iPhone"), Foreground = Brush.Parse("#FF9F0A"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center };

        // 页顶：手机切换（多台）+ 状态；全部最新
        var head = new StackPanel { Spacing = 4 };
        if (phoneOverview!.Phones.Count > 1)
        {
            var pick = new ComboBox { ItemsSource = phoneOverview.Phones.Select(p => p.Name.Length > 0 ? p.Name : p.Device).ToList(),
                SelectedIndex = phoneOverview.Phones.ToList().FindIndex(p => p.Device == phone.Device) };
            pick.SelectionChanged += (_, _) => { if (pick.SelectedIndex >= 0) { consoleDevice = phoneOverview.Phones[pick.SelectedIndex].Device; SeedConsoleSelection(); Render(); } };
            Avalonia.Automation.AutomationProperties.SetAutomationId(pick, "console.phonePicker");
            head.Children.Add(pick);
        }
        else head.Children.Add(Label(phone.Name.Length > 0 ? phone.Name : phone.Device, 24));
        head.Children.Add(Muted(ConsoleStatusText(), 13));
        if (phone.Installed && phone.ShellCurrent && phone.Games.Count > 0 && phone.Games.All(g => g.State == PhoneOverview.GameState.Latest))
            head.Children.Add(new TextBlock { Text = "✓ " + T("console.allLatest"), Foreground = Brush.Parse("#30D158"), FontWeight = FontWeight.Bold });
        page.Children.Add(head);

        // ① 手机与 App
        var app = new StackPanel { Spacing = 8 };
        app.Children.Add(Label(ConsoleStatusText() + (phone.SignMode is { } m ? " · " + T("console.sign." + m) : "")));
        var appRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var appKey = !phone.Installed ? "console.button.install" : !phone.ShellCurrent ? "console.button.update" : "console.button.renew";
        appRow.Children.Add(Action(appKey, () => _ = UpdatePhoneAsync(false, [], device: phone.Device), !offline));
        if (offline) appRow.Children.Add(Offline());
        app.Children.Add(appRow);
        page.Children.Add(ConsoleSection("console.section.phone", app));

        // ② 游戏同步
        var sync = new StackPanel { Spacing = 6 };
        foreach (var game in (catalog?.Games ?? []).Where(g => !g.Hidden))
        {
            var g = phone.Games.FirstOrDefault(x => string.Equals(x.GameId, game.Id, StringComparison.OrdinalIgnoreCase))
                    ?? new PhoneOverview.Game(game.Id.ToUpperInvariant(), PhoneOverview.GameState.NotPushed, [], null);
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            var box = new CheckBox { IsChecked = consoleSelection.Contains(game.Id), IsEnabled = consoleBatch.Count == 0 };
            box.IsCheckedChanged += (_, _) => { if (box.IsChecked == true) consoleSelection.Add(game.Id); else consoleSelection.Remove(game.Id); Render(); };
            row.Children.Add(box);
            var pushing = installBusy && consoleBatch.Contains(game.Id.ToUpperInvariant()) && string.Equals(installGameId, game.Id, StringComparison.OrdinalIgnoreCase);
            row.Children.Add(new TextBlock { Text = (pushing ? "⟳ " : "") + game.Name, MinWidth = 180, Foreground = Ink, VerticalAlignment = VerticalAlignment.Center });
            var (text, color) = g.State switch
            {
                PhoneOverview.GameState.Latest => (T("console.game.latest"), "#30D158"),
                PhoneOverview.GameState.Suggested => (T("update.hint.badge") + " · " + string.Join(" ", g.Reasons.Select(UpdateReasonKey).OfType<string>().Select(T)), "#FF9F0A"),
                PhoneOverview.GameState.NeedsData => (T(g.DataOnComputer == false ? "console.game.needsDataOriginal" : "console.game.needsData"), "#FFD60A"),
                _ => (T(g.DataOnComputer == false ? "console.game.notPushedNoData" : "console.game.notPushed"), "#A0A0A8"),
            };
            row.Children.Add(new TextBlock { Text = text, Foreground = Brush.Parse(color), FontSize = 12.5, TextWrapping = TextWrapping.Wrap, MaxWidth = 520, VerticalAlignment = VerticalAlignment.Center });
            Avalonia.Automation.AutomationProperties.SetAutomationId(row, "console.game." + game.Id.ToUpperInvariant());
            sync.Children.Add(row);
        }
        var run = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Margin = new Thickness(0, 6, 0, 0) };
        if (consoleBatch.Count == 0)
        {
            run.Children.Add(Primary(Tf("console.updateSelected", consoleSelection.Count), UpdateSelected, consoleSelection.Count > 0 && !offline));
            if (offline) run.Children.Add(Offline());
        }
        else
        {
            var done = ConsoleBatchDone; var total = consoleBatch.Count;
            run.Children.Add(new ProgressBar { Minimum = 0, Maximum = Math.Max(total, 1), Value = done, Width = 240, VerticalAlignment = VerticalAlignment.Center });
            run.Children.Add(new TextBlock { Text = Tf("console.progress", Math.Min(done + 1, total), total) + (installGameName is { Length: > 0 } n ? " · " + n : ""), Foreground = Ink, VerticalAlignment = VerticalAlignment.Center });
            run.Children.Add(Action("console.stop", StopUpdateSelected));
        }
        sync.Children.Add(run);
        page.Children.Add(ConsoleSection("console.section.sync", sync));

        // ⑥ 帮助：重看第一次的引导、故障报修（同顶栏那颗）
        var help = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        help.Children.Add(Action("console.help.guide", () => { welcomeHome = true; Render(); }));
        help.Children.Add(Action("console.help.report", () => _ = UploadDiagnosticsAsync(null, null, () => "")));
        page.Children.Add(ConsoleSection("console.section.help", help));
        Avalonia.Automation.AutomationProperties.SetAutomationId(page, "console.panel");
        return Card(page, 24);
    }

    // ---- 顶栏动态窗口（同 Mac S2ArmLauncherModel+PhoneConsole「顶栏动态窗口」）：有和 App 相关的作业时「游戏库」那颗显示进度，做完闪 ✓，失败 / 停下留「!」直到点开 ----
    private bool dynamicDone, dynamicAlert;

    private void DynamicFinished(string state)
    {
        if (phoneOverview is null) return;
        if (state is "succeeded" or "needsPlayer")
        {
            if (phoneQueue.Count > 0) return;   // 一轮里还有排着的不闪，等最后一单
            dynamicDone = true;
            _ = Task.Delay(2000).ContinueWith(_ => Avalonia.Threading.Dispatcher.UIThread.Post(() => { dynamicDone = false; Render(); }));
        }
        else if (state is "failed" or "interrupted" or "cancelled" or "invalid") dynamicAlert = true;
    }

    /// <summary>顶栏「游戏库」那颗此刻显示什么；null = 照旧</summary>
    private string? DynamicLibraryText()
    {
        if (phoneOverview is null) return null;
        if (installBusy || phoneUpdating)
        {
            var pct = installDone is { } d && installTotal is { } t && t > 0 ? " " + (100 * d / t) + "%" : "";
            if (consoleBatch.Count > 0)
                return "⟳ " + Tf("dynamic.batch", Math.Min(ConsoleBatchDone + 1, consoleBatch.Count), consoleBatch.Count) + pct;
            return "⟳ " + (installGameName is { Length: > 0 } n && installBusy ? n : T("console.button.update")) + pct;
        }
        if (dynamicAlert) return "! " + T("nav.library");
        if (dynamicDone) return "✓ " + T("nav.library");
        return null;
    }

    /// <summary>点动态窗口：直接到总控台（选中首位「S2Arm」），看过就收起「!」</summary>
    private void OpenConsoleFromTopBar()
    {
        dynamicAlert = false;
        selectedGame = ConsoleId;
        Navigate("library");
    }
}
