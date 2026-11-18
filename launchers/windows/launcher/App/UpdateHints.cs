// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

/// <summary>
/// 0.6.0「建议更新」（通用壳开关后面，同 Mac S2ArmLauncherModel+UpdateHints）：每份游戏列表读一次作业 updateHints（只读 game.json），
/// 对不上的款封面右上出「建议更新」、选中写原因 + 末行 +「更新这款」（就是这一款的推到 iPhone，只做这一款）。不点照旧能用；开关关着什么都不出。
/// </summary>
public sealed partial class EnvironmentWindow
{
    private Dictionary<string, string[]> updateHints = new(StringComparer.OrdinalIgnoreCase);
    private LibraryCatalog? updateHintsFor;

    /// <summary>游戏库页渲染时：这份游戏列表还没比过就比一次（载入 / 导入 / 推完重读都会换新列表）</summary>
    private void EnsureUpdateHints()
    {
        if (catalog is null || ReferenceEquals(updateHintsFor, catalog)) return;
        updateHintsFor = catalog;
        _ = RefreshUpdateHintsAsync();
        _ = RefreshPhoneOverviewAsync();   // 总控台（PhoneConsole.cs）：只读设备记录，秒回；选中首位卡时再探 USB
    }

    private async Task RefreshUpdateHintsAsync()
    {
        var hints = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("updateHints", ""), null, CancellationToken.None);
            if (job.Report.Succeeded && job.Report.Result.TryGetProperty("enabled", out var on) && on.ValueKind == System.Text.Json.JsonValueKind.True
                && job.Report.Result.TryGetProperty("games", out var games) && games.ValueKind == System.Text.Json.JsonValueKind.Array)
                foreach (var g in games.EnumerateArray())
                {
                    if (!g.TryGetProperty("gameId", out var id) || id.GetString() is not { Length: > 0 } gid || !g.TryGetProperty("reasons", out var rs)
                        || rs.ValueKind != System.Text.Json.JsonValueKind.Array) continue;
                    var why = rs.EnumerateArray().Select(r => r.GetString() ?? "").Where(r => UpdateReasonKey(r) is not null).ToArray();
                    if (why.Length > 0) hints[gid] = why;
                }
        }
        // 读不到不弹框（附带的提示，不是玩家点的操作），但不吞：记日志，提示清空、界面照旧
        catch (Exception error) when (error is LibraryProtocolException or IOException or UnauthorizedAccessException or ArgumentException or
            InvalidOperationException or System.ComponentModel.Win32Exception) { Console.Error.WriteLine("S2Arm updateHints: " + error.Message); }
        updateHints = hints;
        Render();
    }

    internal static string? UpdateReasonKey(string reason) => reason switch
    {
        "rewriter" => "update.hint.reason.rewriter", "hostAbi" => "update.hint.reason.hostAbi", "shader" => "update.hint.reason.shader", _ => null,
    };

    private string[] UpdateReasons(LibraryGame game) => updateHints.TryGetValue(game.Id, out var why) ? why : [];

    /// <summary>封面右上角「建议更新」小角标（同 Mac：收藏心旁边）</summary>
    private Control WithUpdateHintBadge(LibraryGame game, Control cover, int size)
    {
        if (UpdateReasons(game).Length == 0 || size < 80) return cover;   // 太小的封面（列表缩略图）只靠选中区那几行，不挤角标
        var badge = new Border { Margin = new Thickness(6), Padding = new Thickness(7, 3), CornerRadius = new CornerRadius(10),
            Background = Brush.Parse("#AD000000"), BorderBrush = Brush.Parse("#99FF9F0A"), BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Child = new TextBlock { Text = T("update.hint.badge"), FontSize = 10.5, FontWeight = FontWeight.Bold, Foreground = Brush.Parse("#FF9F0A") } };
        Avalonia.Automation.AutomationProperties.SetAutomationId(badge, "card.updateHint");
        return new Panel { Width = size, Height = size, Children = { cover, badge } };
    }

    /// <summary>选中区：对不上几样写几行原因，末行说点了会怎样，旁边「更新这款」</summary>
    private Control? UpdateHintLines(LibraryGame game)
    {
        var reasons = UpdateReasons(game);
        if (reasons.Length == 0) return null;
        var box = new StackPanel { Spacing = 4, MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var r in reasons)
            box.Children.Add(new TextBlock { Text = "↻ " + T(UpdateReasonKey(r)!), Foreground = Brush.Parse("#FF9F0A"), FontSize = 13, TextWrapping = TextWrapping.Wrap });
        var tail = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        tail.Children.Add(new TextBlock { Text = T("update.hint.tail"), Foreground = Brush.Parse("#A0A0A8"), FontSize = 12, TextWrapping = TextWrapping.Wrap, MaxWidth = 560,
            VerticalAlignment = VerticalAlignment.Center });
        tail.Children.Add(Action("update.hint.button", () => _ = InstallAsync(game)));
        box.Children.Add(tail);
        Avalonia.Automation.AutomationProperties.SetAutomationId(box, "update.hint");
        return box;
    }
}
