using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

/// <summary>S 级优化单款升级（11-18 维护者：「改成不自动运行，玩家手动点击 S 级优化再升级；升级过程给小图标和开始游戏按钮上加进度动画，
/// 不阻断玩家干别的，同时此时不能新开此游戏」；同 Mac S2ArmLauncherModel+SGradeUpgrade.swift）。
/// 作业 sgradeUpgradeGame（{gameId}，Windows 上补 iPhone 程序件）在后台跑、不占出包 / 手机槽：别的游戏照常操作；
/// 这款封面画进度、主按钮（Windows 没有「开始游戏」，是装到 iPhone / 出包）写「正在升级 xx%」不可点。一次一款，点了多款排队；
/// 做完重读游戏库。进度按阶段事件 stageIndex / stageCount；_bf 段（sgrade.bf）没有段内百分比，画不定进度</summary>
public sealed partial class EnvironmentWindow
{
    private readonly Dictionary<string, double?> sgradeUpgrades = new(StringComparer.OrdinalIgnoreCase);
    private readonly Queue<string> sgradeQueue = new();
    private string? sgradeRunning;
    private readonly Dictionary<string, string> sgradeErrors = new(StringComparer.OrdinalIgnoreCase);
    /// <summary>这一批第几款 / 共几款（升级页显示）；队列空了清掉</summary>
    private (int Done, int Total)? sgradeBatch;
    private CancellationTokenSource? sgradeCancel;
    /// <summary>升级页上勾选的款</summary>
    private readonly HashSet<string> sgradeSelected = new(StringComparer.OrdinalIgnoreCase);
    /// <summary>这次打开启动器里升级做完的款（升级页那一行写「已完成」）</summary>
    private readonly HashSet<string> sgradeDone = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>这款正在升级 / 排队（含游戏库 sgradeUpgrading：别的启动器进程起的还在跑）</summary>
    private bool SGradeUpgrading(LibraryGame game) => sgradeUpgrades.ContainsKey(game.Id) || game.SGradeUpgrading;
    private double? SGradeProgress(LibraryGame game) => sgradeUpgrades.TryGetValue(game.Id, out var p) ? p : null;

    /// <summary>排在队里还没轮到（一次只升一款）</summary>
    private bool SGradeQueued(string id) => sgradeQueue.Contains(id);

    /// <summary>主按钮上的字：排着的「排队中」；在升的「正在升级 xx%」，没有百分比（_bf 段）写「正在升级…」</summary>
    private string SGradeUpgradingTitle(LibraryGame game) => SGradeQueued(game.Id) ? T("sgrade.upgrade.queued")
        : SGradeProgress(game) is { } p ? T("sgrade.upgrading").Replace("{0}", ((int)Math.Floor(p * 100)).ToString())
        : T("sgrade.upgrading.wait");

    /// <summary>升级页行按钮上的字：正在做的「正在升级 37%」、排着的「排队中」、做完的「已完成」、其余「升级」</summary>
    private string SGradeRowTitle(string id)
    {
        if (id == sgradeRunning) return sgradeUpgrades.TryGetValue(id, out var p) && p is { } v
            ? T("sgrade.upgrade.rowProgress").Replace("{0}", ((int)Math.Floor(v * 100)).ToString()) : T("sgrade.upgrade.rowBusy");
        if (SGradeQueued(id)) return T("sgrade.upgrade.queued");
        if (SGradeBusy(id)) return T("sgrade.upgrade.rowBusy");
        if (sgradeDone.Contains(id)) return T("sgrade.upgrade.done");
        return T("sgrade.upgrade.row");
    }

    /// <summary>玩家点了升级（单款或「批量升级所选」）：排进队列（已在队里 / 在升的不重复），批量总数跟着加</summary>
    private void UpgradeSGrade(IEnumerable<string> ids)
    {
        var added = 0;
        foreach (var id in ids)
            if (!sgradeUpgrades.ContainsKey(id)) { sgradeUpgrades[id] = null; sgradeQueue.Enqueue(id); sgradeErrors.Remove(id); sgradeSelected.Remove(id); sgradeDone.Remove(id); added++; }
        if (added > 0) sgradeBatch = (sgradeBatch?.Done ?? 0, (sgradeBatch?.Total ?? 0) + added);
        Render();
        PumpSGrade();
    }

    /// <summary>中途停止：排着的不做了，在升的那款请作业停（作业层按记号保留已做完的段，这款显示「升级未完成」）；已做完的款不动</summary>
    private void StopSGrade()
    {
        foreach (var id in sgradeQueue) sgradeUpgrades.Remove(id);
        sgradeQueue.Clear();
        sgradeCancel?.Cancel();
        Render();
    }

    /// <summary>阶段事件 → 进度：第 i 段开始 = (i−1)/n；_bf 段 → 不定进度（null）；不是阶段事件 → 不改（返回 false）</summary>
    internal static bool SGradeStageProgress(JsonElement e, out double? progress)
    {
        progress = null;
        if (!e.TryGetProperty("stageIndex", out var i) || i.ValueKind != JsonValueKind.Number
            || !e.TryGetProperty("stageCount", out var n) || n.ValueKind != JsonValueKind.Number || n.GetDouble() <= 0) return false;
        if (e.TryGetProperty("stageKey", out var k) && k.ValueKind == JsonValueKind.String && k.GetString() == "sgrade.bf") return true;
        progress = Math.Clamp((i.GetDouble() - 1) / n.GetDouble(), 0, 1);
        return true;
    }

    private void PumpSGrade()
    {
        if (sgradeRunning is not null || sgradeQueue.Count == 0) return;
        var id = sgradeQueue.Dequeue();
        sgradeRunning = id;
        _ = RunSGradeAsync(id);
    }

    private async Task RunSGradeAsync(string id)
    {
        sgradeCancel = new CancellationTokenSource();
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("sgradeUpgradeGame", id),
                e => Dispatcher.UIThread.Post(() =>
                {
                    if (sgradeUpgrades.ContainsKey(id) && SGradeStageProgress(e, out var p)) { sgradeUpgrades[id] = p; Render(); }
                }), sgradeCancel.Token);
            if (job.Report.Succeeded) sgradeDone.Add(id);
            else if (!sgradeCancel.IsCancellationRequested) sgradeErrors[id] = job.Report.Message;   // 没成：这款上就近写原因，不弹框；玩家点停止不算失败
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception) { sgradeErrors[id] = error.Message; }
        finally
        {
            sgradeUpgrades.Remove(id);
            sgradeRunning = null;
            sgradeCancel = null;
            if (sgradeBatch is { } b) sgradeBatch = sgradeQueue.Count == 0 ? null : (b.Done + 1, b.Total);
            await RefreshLibraryAsync();
            Render();
            PumpSGrade();
        }
    }

    /// <summary>升级中的封面（小图标）：压暗一层、中间百分比（没有百分比写「…」）、底部进度条（不定进度时满条半透明）</summary>
    private Control WithSGradeProgress(LibraryGame game, Control cover, int size)
    {
        if (!SGradeUpgrading(game)) return cover;
        var p = SGradeProgress(game);
        var grid = new Avalonia.Controls.Grid();
        grid.Children.Add(cover);
        grid.Children.Add(new Avalonia.Controls.Border { Background = new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.FromArgb(115, 0, 0, 0)), CornerRadius = new Avalonia.CornerRadius(8) });
        var queued = SGradeQueued(game.Id);   // 排着的只写「排队中」、不画在走的进度（不冒充在升）
        grid.Children.Add(new Avalonia.Controls.TextBlock { Text = queued ? T("sgrade.upgrade.queued") : p is { } v ? ((int)Math.Floor(v * 100)) + "%" : "…", FontSize = Math.Max(11, size / 5.0), FontWeight = Avalonia.Media.FontWeight.Bold,
            Foreground = Avalonia.Media.Brushes.White, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center });
        if (!queued) grid.Children.Add(new Avalonia.Controls.ProgressBar { Minimum = 0, Maximum = 1, Value = p ?? 0, IsIndeterminate = p is null, Height = 4, MinHeight = 4,
            Foreground = Avalonia.Media.Brush.Parse("#E8C46A"), VerticalAlignment = Avalonia.Layout.VerticalAlignment.Bottom, Margin = new Avalonia.Thickness(6, 0, 6, 6) });
        Avalonia.Automation.AutomationProperties.SetAutomationId(grid, "card.sgradeUpgrading");
        return grid;
    }

    /// <summary>选中区一行：升级没成的原因（红）/ 上次中途退出没做完「升级未完成，点 S 级优化继续」（金，点了打开升级页）</summary>
    private Control? SGradeLine(LibraryGame game)
    {
        if (SGradeUpgrading(game)) return null;
        if (sgradeErrors.TryGetValue(game.Id, out var why))
            return new Avalonia.Controls.TextBlock { Text = why, Foreground = Avalonia.Media.Brush.Parse("#FF6B6B"), FontSize = 13, TextWrapping = Avalonia.Media.TextWrapping.Wrap, MaxWidth = 720 };
        if (!game.SGradeIncomplete) return null;
        var b = new Avalonia.Controls.Button { Content = T("sgrade.upgrade.incomplete"), Background = Avalonia.Media.Brushes.Transparent, Padding = new Avalonia.Thickness(0),
            Foreground = Avalonia.Media.Brush.Parse("#E8C46A"), FontSize = 13 };
        b.Click += (_, _) => OpenSGradeUpgrade();
        Avalonia.Automation.AutomationProperties.SetAutomationId(b, "sgrade.incomplete." + game.Id);
        return b;
    }

    /// <summary>这款正在升级 / 排队（按号，升级页行里用）</summary>
    private bool SGradeBusy(string id) => sgradeUpgrades.ContainsKey(id) || (catalog?.Games.Any(g => g.Id == id && g.SGradeUpgrading) ?? false);
}
