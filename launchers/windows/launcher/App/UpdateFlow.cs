// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

// 覆盖更新：下载、校验、替换、回滚都在共用的 pack/jobs/updater.py，这里只管状态和按钮。出包等作业进行中不提示、不替换。
public sealed partial class EnvironmentWindow
{
    private string updateProgress = "";
    private JsonElement? updateReady;
    private string updateFailure = "";   // 错误码
    private static readonly Uri DownloadPage = new("https://jhaizhou-ops.github.io/S2Arm/");   // 自动更新失败时「打开下载页」，系统浏览器打开
    private static string InstallDir => Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);
    // The release version lives in version.txt (written by bundle_win.py); the assembly version is always 1.0.0.0.
    private static string AppVersion => UpdateClient.CurrentVersion(InstallDir) is { Length: > 0 } version ? version : "-";
    private string UpdatesFolder => Path.Combine(privateRoot, "updates");
    private bool UpdateBlocked => PackBusy || libraryBusy || importBusy || busy;

    private Dictionary<string, object?> UpdateStatus => updateProgress.Length > 0
        ? new() { ["state"] = "working", ["detail"] = updateProgress }
        : updateReady is { } ready ? new() { ["state"] = "ready", ["detail"] = ready.GetProperty("version").GetString(), ["via"] = ready.GetProperty("via").GetString() }
        : updateFailure.Length > 0 ? new() { ["state"] = "failed", ["detail"] = updateFailure }
        : new() { ["state"] = "idle" };

    private void FinishPendingUpdate()
    {
        try
        {
            if (File.Exists(Path.Combine(UpdatesFolder, "pending.json"))) File.WriteAllText(Path.Combine(UpdatesFolder, "health.ok"), "ok");
            var failure = Path.Combine(UpdatesFolder, "last_failure.json");
            if (File.Exists(failure))
            {
                using var document = JsonDocument.Parse(File.ReadAllText(failure));
                updateFailure = document.RootElement.GetProperty("code").GetString() ?? "update_failed";
                File.Delete(failure);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or KeyNotFoundException) { }
    }

    private async Task CheckForUpdateAsync()
    {
        var current = UpdateClient.CurrentVersion(InstallDir);
        if (current.Length == 0 || EnvironmentProbe.BundleIncomplete(paths)) return;
        var result = await UpdateClient.RunAsync(paths, ["check", "--platform", "windows", "--current", current], null, TimeSpan.FromSeconds(20));
        if (result is { } value && value.TryGetProperty("available", out var available) && available.GetBoolean())
            await DownloadUpdateAsync();   // 后台下好，不打断玩家
    }

    private async Task DownloadUpdateAsync()
    {
        if (updateProgress.Length > 0) return;
        updateFailure = ""; updateProgress = T("update.downloading").Replace("{0}", "0"); Render();
        var command = new List<string> { "prepare", "--platform", "windows", "--current", UpdateClient.CurrentVersion(InstallDir), "--private-root", privateRoot, "--install", InstallDir };
        if (connectedFolder is not null) { command.Add("--protect"); command.Add(connectedFolder); }
        var result = await UpdateClient.RunAsync(paths, command, e => Dispatcher.UIThread.Post(() =>
        {
            switch (e.GetProperty("state").GetString())
            {
                case "downloading":
                    var total = e.GetProperty("total").GetInt64();
                    updateProgress = T("update.downloading").Replace("{0}", total > 0 ? (e.GetProperty("done").GetInt64() * 100 / total).ToString() : "0");
                    Render(); break;
                case "verifying": updateProgress = T("update.verifying"); Render(); break;
                case "unpacking": updateProgress = T("update.unpacking"); Render(); break;
            }
        }), TimeSpan.FromHours(2));
        updateProgress = "";
        if (result is { } ready && ready.GetProperty("state").GetString() == "ready")
            updateReady = ready;
        else updateFailure = (result is { } failed && failed.TryGetProperty("code", out var code) ? code.GetString() : null) ?? "update_failed";
        Render();
    }

    private void RestartToUpdate()
    {
        if (updateReady is not { } ready || UpdateBlocked) return;
        try
        {
            UpdateClient.Apply(ready, InstallDir, privateRoot, Environment.GetCommandLineArgs().Skip(1));
            Close();
        }
        catch (Exception error) when (error is IOException or InvalidOperationException or System.ComponentModel.Win32Exception or KeyNotFoundException)
        { updateFailure = "update_failed"; updateReady = null; Render(); }
    }

    // ── 顶部公告条（v0.2.3，同 Mac LauncherView.noticeBar）：内容是数据（官方下载页上的 notice.json，取不到用随包那份，pack/jobs/updater.py notice），
    //    代码里不写公告内容；× 关掉后同一条不再出现，换了新号的公告照常出现。取不到、起不来都不显示、不报错
    private JsonElement? notice;

    private async Task LoadNoticeAsync()
    {
        var result = await UpdateClient.RunAsync(paths, ["notice", "--private-root", privateRoot], null, TimeSpan.FromSeconds(20));
        if (result is { } value && value.ValueKind == JsonValueKind.Object && value.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String)
        { notice = value; Render(); }
    }

    private void DismissNotice()
    {
        if (notice is not { } value) return;
        var id = value.GetProperty("id").GetString() ?? "";
        notice = null; Render();   // 当场收起，再记下这条的号
        _ = UpdateClient.RunAsync(paths, ["notice-dismiss", "--private-root", privateRoot, "--id", id], null, TimeSpan.FromSeconds(20));
    }

    private void AddNoticeBar(StackPanel body)
    {
        if (notice is not { } value || !value.TryGetProperty("text", out var texts) || !texts.TryGetProperty(language == "en" ? "en" : "zh-Hans", out var textValue)) return;
        var amber = Color.Parse("#FFC73D");
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto,Auto"), ColumnSpacing = 10 };
        row.Children.Add(new TextBlock { Text = "⚠", FontSize = 15, Foreground = new SolidColorBrush(amber), VerticalAlignment = Avalonia.Layout.VerticalAlignment.Top });
        var message = new SelectableTextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 13, Foreground = Ink };
        message.Inlines!.Add(new Avalonia.Controls.Documents.Run(T("notice.label") + "  ") { FontWeight = FontWeight.Bold });
        message.Inlines.Add(new Avalonia.Controls.Documents.Run(textValue.GetString() ?? ""));
        Avalonia.Automation.AutomationProperties.SetAutomationId(message, "notice.text");
        Grid.SetColumn(message, 1); row.Children.Add(message);
        if (value.TryGetProperty("url", out var url) && Uri.TryCreate(url.GetString(), UriKind.Absolute, out var link))
        {
            var details = new Button { Content = T("notice.details"), Padding = new Thickness(10, 4), Background = Brushes.Transparent, Foreground = Ink,
                VerticalAlignment = Avalonia.Layout.VerticalAlignment.Top };
            Avalonia.Automation.AutomationProperties.SetAutomationId(details, "notice.details");
            details.Click += (_, _) => _ = OpenOfficialAsync(link);
            Grid.SetColumn(details, 2); row.Children.Add(details);
        }
        var close = new Button { Content = "✕", Padding = new Thickness(8, 4), Background = Brushes.Transparent, Foreground = Ink,
            VerticalAlignment = Avalonia.Layout.VerticalAlignment.Top };
        ToolTip.SetTip(close, T("notice.close"));
        Avalonia.Automation.AutomationProperties.SetName(close, T("notice.close"));
        Avalonia.Automation.AutomationProperties.SetAutomationId(close, "notice.close");
        close.Click += (_, _) => DismissNotice();
        Grid.SetColumn(close, 3); row.Children.Add(close);
        body.Children.Add(new Border { Child = row, Padding = new Thickness(16, 10), CornerRadius = new CornerRadius(10),
            Background = new SolidColorBrush(amber, 0.16), BorderBrush = new SolidColorBrush(amber, 0.45), BorderThickness = new Thickness(1) });
    }

    private void AddUpdateControls(StackPanel bar)
    {
        if (updateProgress.Length > 0)
            bar.Children.Add(new TextBlock { Text = updateProgress, FontSize = 12, Foreground = Brush.Parse("#A8A6A1"), VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center });
        else if (updateReady is not null)   // 只有玩家点了才重启；作业进行中置灰并说明
            bar.Children.Add(Action(UpdateBlocked ? "update.restart.busy" : "update.restart", RestartToUpdate, !UpdateBlocked));
        else if (updateFailure.Length > 0)
        {
            // 失败原因直接写在按钮旁（人话 + 错误码），并给「打开下载页」：自动更新连不上 GitHub 时玩家能自己下（不再只藏在悬停提示里）
            bar.Children.Add(Action("update.retry", () => _ = DownloadUpdateAsync()));
            var why = new TextBlock { Text = T("update.error." + updateFailure) + " · " + T("update.code").Replace("{0}", updateFailure), FontSize = 12,
                Foreground = Brush.Parse("#A8A6A1"), MaxWidth = 360, TextWrapping = Avalonia.Media.TextWrapping.Wrap, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
            Avalonia.Automation.AutomationProperties.SetAutomationId(why, "update.failure");
            bar.Children.Add(why);
            bar.Children.Add(Action("update.download_page", () => _ = OpenOfficialAsync(DownloadPage)));
        }
    }
}
