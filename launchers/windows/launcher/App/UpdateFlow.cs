// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Diagnostics;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

// 覆盖更新：v0.3.10 起下载、Ed25519 验签、静默运行安装程序替换、重启都交给 NetSparkle（维护者拍板换业界标准组件，不再自写换版）。
// 这里只管状态和按钮；有没有新版、更新说明、公告仍由 pack/jobs/updater.py inbox 给。出包等作业进行中不提示、不替换。
public sealed partial class EnvironmentWindow
{
    private string updateProgress = "";
    private NetSparkleUpdater.AppCastItem? updateReady;   // 下载并验签好的那一版（NetSparkle 条目）
    private string updateReadyPath = "";                    // 它下载到的安装程序
    private NetSparkleUpdater.SparkleUpdater? sparkle;
    private string updateFailure = "";   // 错误码
    private string updateFailureMessage = "";   // 后端给的那句（updater.py 每个失败都带 message）：文案表没有这个码时显示它（剃刀 W11）
    private static readonly Uri DownloadPage = new("https://jhaizhou-ops.github.io/S2Arm/");   // 自动更新失败时「打开下载页」，系统浏览器打开
    private static string InstallDir => Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);
    // The release version lives in version.txt (written by bundle_win.py); the assembly version is always 1.0.0.0.
    private static string AppVersion => UpdateClient.CurrentVersion(InstallDir) is { Length: > 0 } version ? version : "-";
    private string UpdatesFolder => Path.Combine(privateRoot, "updates");
    private bool UpdateBlocked => AnyJob;
    private string InstallerLog => Path.Combine(privateRoot, "logs", "installer.log");   // 安装程序 /LOG 写在这里，诊断包按 logs/ 收进去
    private string PendingInstall => Path.Combine(UpdatesFolder, "pending-install.json");   // 点了更新、交给安装程序的那一版：下次启动对版本号判装没装上
    private string installFailedTarget = "";   // 上次要装的版本（没装上时顶栏写进那句话）
    /// <summary>退出让位给安装程序时，关窗走到哪一步（兜底记日志用）</summary>
    internal static volatile string ExitStep = "";
    /// <summary>NetSparkle 的脚本最多等旧进程 90 秒（每秒查一次，到点不装就退出）：关窗 15 秒还没退，结束本进程，让安装程序接着装</summary>
    private static readonly TimeSpan ExitGuard = TimeSpan.FromSeconds(15);

    private Dictionary<string, object?> UpdateStatus => updateProgress.Length > 0
        ? new() { ["state"] = "working", ["detail"] = updateProgress }
        : updateReady is { } ready ? new() { ["state"] = "ready", ["detail"] = ready.Version, ["via"] = "netsparkle" }
        : updateFailure.Length > 0 ? new() { ["state"] = "failed", ["detail"] = updateFailure, ["reason"] = updateFailureMessage }
        : new() { ["state"] = "idle" };

    /// <summary>上次点了更新、交给安装程序的那一版这次装上没有：静默安装失败时脚本照样拉起旧版，玩家什么也看不到（34 次里 14 次没装上）。
    /// 版本没到就在顶栏说「上次更新到 vX 没装上」，给「重试」和「打开下载页」；装上了只记一行。标记读完就删，只说一次</summary>
    private void FinishPendingUpdate()
    {
        string target = "";
        try
        {
            if (!File.Exists(PendingInstall)) return;
            using var doc = JsonDocument.Parse(File.ReadAllText(PendingInstall));
            target = doc.RootElement.TryGetProperty("version", out var v) ? v.GetString() ?? "" : "";
            File.Delete(PendingInstall);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { }
        if (target.Length == 0 || AppVersion == "-") return;
        var log = Path.Combine(privateRoot, "logs", "update.log");
        if (VersionAtLeast(AppVersion, target)) { UpdateLog.Write(log, $"上次更新到 {target}：装上了"); return; }
        var why = InstallerFailure();
        UpdateLog.Write(log, $"上次更新到 {target} 没装上，现在还是 {AppVersion}：{why}");
        installFailedTarget = target; updateFailure = "update_install_failed"; updateFailureMessage = why;
    }

    internal static bool VersionAtLeast(string have, string want) =>
        Version.TryParse(have, out var h) && Version.TryParse(want, out var w) && h >= w;

    /// <summary>安装程序日志里说明失败的那一行（Inno：Fatal exception / Exception message / Setup is exiting / Aborting）；没有日志或没找到给一句说明（进诊断、不上界面）</summary>
    private string InstallerFailure()
    {
        try
        {
            if (!File.Exists(InstallerLog)) return "没有安装程序日志（安装程序没跑起来，或旧进程没退出、脚本等满 90 秒放弃）";
            var hit = File.ReadLines(InstallerLog).LastOrDefault(l => l.Contains("Fatal exception", StringComparison.OrdinalIgnoreCase) || l.Contains("Exception message", StringComparison.OrdinalIgnoreCase)
                || l.Contains("Setup is exiting", StringComparison.OrdinalIgnoreCase) || l.Contains("Aborting", StringComparison.OrdinalIgnoreCase) || l.Contains("Installation process failed", StringComparison.OrdinalIgnoreCase));
            return hit?.Trim() ?? "安装程序日志里没有失败行";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return "安装程序日志读不了：" + error.Message; }
    }

    /// <summary>NetSparkle 已写好「等本进程退出 → 装 → 拉起」的脚本，要本进程让位：关窗，每一步记进 update.log；
    /// 15 秒还没退（关窗被卡住，比如显卡驱动里销毁窗口不返回）先记下停在哪一步，再 TerminateProcess 结束自己——
    /// 不用 Environment.Exit：它要跑终结器、等别的线程，卡住时照样可能退不出去</summary>
    private void ExitForInstaller()
    {
        ExitStep = "等界面线程关窗";
        CloseLog("让位给安装程序：开始关窗（15 秒没退出就结束本进程）");
        _ = Task.Run(async () =>
        {
            await Task.Delay(ExitGuard);
            CloseLog($"让位给安装程序：关窗 {ExitGuard.TotalSeconds:0} 秒进程还在，停在「{ExitStep}」；结束本进程，让安装程序接着装");
            Process.GetCurrentProcess().Kill();
        });
        Dispatcher.UIThread.Post(() => { ExitStep = "关窗（Close）"; CloseLog("让位给安装程序：界面线程开始关窗"); Close(); });
    }

    // ── 打开时给玩家看什么（11-13 维护者定稿草图，判定在 pack/jobs/updater.py inbox，两端共用「永远只给最新一期」）：
    //    最多一个弹窗（这版更新了什么 / 有新版）、横幅（最新一条没看过的重要公告）、「消息」列表与未读数（只算最新那条公告）
    private JsonElement? updatePopup;   // {kind: update | afterUpdate, version, notes?}；kind = feature 是新功能大窗（FeatureSpotlight.cs）
    private JsonElement? availableUpdate;   // 有新版那一版 {version, notes?}：顶栏「有新版 vX」点开回到弹窗
    private bool installWhenReady;   // 玩家点了「现在更新」时还没下：下完接着装（同 Mac S2ArmLauncherModel.installWhenReady）
    private JsonElement[] messages = [];
    private int unreadMessages;
    private bool messagesOpen;
    private string updateGate = "";   // 点「现在更新并重启」时有任务在跑：先拦下说明（草图④前置检查）

    private async Task LoadInboxAsync()
    {
        var current = UpdateClient.CurrentVersion(InstallDir);
        if (current.Length == 0 || EnvironmentProbe.BundleIncomplete(paths)) return;
        var result = await UpdateClient.RunAsync(paths, ["inbox", "--private-root", privateRoot, "--platform", "windows", "--current", current], null, TimeSpan.FromSeconds(30));
        if (result is not { ValueKind: JsonValueKind.Object } value || !value.TryGetProperty("messages", out var list) || list.ValueKind != JsonValueKind.Array) return;
        notice = value.TryGetProperty("banner", out var banner) && banner.ValueKind == JsonValueKind.Object ? banner : null;
        messages = list.EnumerateArray().ToArray();
        unreadMessages = value.TryGetProperty("unread", out var unread) && unread.ValueKind == JsonValueKind.Number ? unread.GetInt32() : 0;
        if (value.TryGetProperty("update", out var update) && update.ValueKind == JsonValueKind.Object && update.TryGetProperty("available", out var available) && available.ValueKind == JsonValueKind.True)
            availableUpdate = update;
        updatePopup = value.TryGetProperty("popup", out var popup) && popup.ValueKind == JsonValueKind.Object ? popup : null;
        Render();
        // 有新版只提示，不自动下载（11-16 维护者：启动器与手机端都改成手动更新；同 Mac restartToUpdate #1283）：玩家点「现在更新」才下、下完接着装
    }

    private void Seen(params string[] args) => _ = UpdateClient.RunAsync(paths, new[] { "inbox-seen", "--private-root", privateRoot }.Concat(args), null, TimeSpan.FromSeconds(20));

    /// <summary>关掉弹窗（以后再说 / 知道了 / Esc）：这一版不再弹</summary>
    private void CloseUpdatePopup()
    {
        if (FeatureOpen) { CloseFeature(); return; }
        updateGate = "";
        if (updatePopup is not { } popup) return;
        updatePopup = null;
        var version = popup.TryGetProperty("version", out var v) ? v.GetString() ?? "" : "";
        var after = popup.TryGetProperty("kind", out var k) && k.GetString() == "afterUpdate";
        if (version.Length > 0) Seen(after ? "--after" : "--update", version);
        Render();
    }

    private void ShowUpdatePopup()
    {
        if (availableUpdate is not { } update) return;
        var version = update.GetProperty("version").GetString() ?? "";
        var notes = update.TryGetProperty("notes", out var n) ? n.GetRawText() : "null";
        using var doc = JsonDocument.Parse($"{{\"kind\":\"update\",\"version\":{JsonOut.Serialize(version)},\"notes\":{notes}}}");
        updatePopup = doc.RootElement.Clone(); Render();
    }

    private void OpenMessages()
    {
        messagesOpen = true; unreadMessages = 0;
        var latest = messages.FirstOrDefault(m => m.TryGetProperty("kind", out var k) && k.GetString() == "notice");
        if (latest.ValueKind == JsonValueKind.Object && latest.GetProperty("id").GetString() is { Length: > 0 } id) Seen("--notice", id);
        Render();
    }

    private string NoteText(JsonElement item) =>
        (language == "en" && item.TryGetProperty("en", out var en) ? en.GetString() : null) ?? (item.TryGetProperty("zh-Hans", out var zh) ? zh.GetString() ?? "" : "");

    private static IEnumerable<JsonElement> Items(JsonElement owner, string key) =>
        owner.ValueKind == JsonValueKind.Object && owner.TryGetProperty(key, out var list) && list.ValueKind == JsonValueKind.Array ? list.EnumerateArray() : [];

    private static Uri ReleasePage(string version) => new("https://github.com/jhaizhou-ops/S2Arm/releases/tag/v" + version);

    private void AddBullets(StackPanel panel, IEnumerable<JsonElement> items, double size = 14)
    {
        foreach (var item in items)
            panel.Children.Add(new SelectableTextBlock { Text = "• " + NoteText(item), FontSize = size, Foreground = Ink, TextWrapping = TextWrapping.Wrap });
    }

    /// <summary>更新弹窗（整页，同添加游戏弹窗的做法）：① 有新版 + 这版说明；② 更新后第一次打开「已更新到 vX」+ 亮点</summary>
    private void RenderUpdatePopup(StackPanel body)
    {
        var popup = updatePopup!.Value;
        var version = popup.TryGetProperty("version", out var v) ? v.GetString() ?? "" : "";
        var notes = popup.TryGetProperty("notes", out var n) ? n : default;
        var after = popup.TryGetProperty("kind", out var k) && k.GetString() == "afterUpdate";
        var panel = new StackPanel { Spacing = 14, MaxWidth = 680, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center };
        if (after)
        {
            panel.Children.Add(Label("✓ " + T("update.after.title").Replace("{0}", version), 26));
            panel.Children.Add(Muted(T("update.after.lead"), 14));
            AddBullets(panel, Items(notes, "highlights"));
        }
        else
        {
            panel.Children.Add(Muted(T("update.popup.kicker"), 13));
            panel.Children.Add(Label("S2Arm v" + version, 28));
            panel.Children.Add(Muted(T("update.popup.meta"), 13));
            var sections = Items(notes, "sections").ToArray();
            if (sections.Length == 0) panel.Children.Add(Muted(T("update.popup.noNotes"), 14));
            foreach (var section in sections)
            {
                var title = Label(section.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "", 14); title.Foreground = Accent;
                panel.Children.Add(title);
                AddBullets(panel, Items(section, "items"));
            }
            if (updateProgress.Length > 0) panel.Children.Add(Muted(T("update.popup.downloading"), 12.5));
            if (updateGate.Length > 0)
            {
                // 点了「现在更新并重启」但有任务在跑：说清会打断什么，玩家选「仍然重启」照样换（11-18 维护者：认得出的风险让玩家确认后继续），默认焦点在「取消」
                var gate = new StackPanel { Spacing = 8 };
                gate.Children.Add(Label(T("update.gate.confirm.title"), 14));
                gate.Children.Add(Muted(RestartImpactText(), 13));
                var choose = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 10, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right };
                var cancel = Action("update.gate.confirm.cancel", () => { updateGate = ""; Render(); });
                AutomationId(cancel, "update.gate.cancel"); cancel.IsDefault = true;
                var restart = Action("update.gate.confirm.restart", () => RestartToUpdate(confirmed: true));
                AutomationId(restart, "update.gate.restart");
                choose.Children.Add(cancel); choose.Children.Add(restart);
                gate.Children.Add(choose);
                cancel.AttachedToVisualTree += (_, _) => cancel.Focus();
                var box = new Border { Child = gate, Padding = new Thickness(14), CornerRadius = new CornerRadius(12), Background = new SolidColorBrush(Color.Parse("#FFC857"), 0.14) };
                AutomationId(box, "update.gate");
                panel.Children.Add(box);
            }
        }
        var buttons = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 12, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right };
        buttons.Children.Add(Action("update.popup.fullLog", () => _ = OpenOfficialAsync(ReleasePage(version))));
        if (after) buttons.Children.Add(Action("update.after.ok", CloseUpdatePopup));
        else
        {
            buttons.Children.Add(Action("update.popup.later", CloseUpdatePopup));
            // 装过 iPhone、自动更新开着：写「更新启动器和 iPhone App」，新版启动后自动把 iPhone App 也更新（PhoneAutoUpdate.cs）；自动化 id 照旧
            var now = Action("update.popup.now", () => RestartToUpdate(), updateReady is not null || availableUpdate is not null);   // 没下也能点：点了才下、下完接着装；手动更新（11-16）：启动器升级不再顺带装手机，按钮不再写「和 iPhone App」
            Avalonia.Automation.AutomationProperties.SetAutomationId(now, "update.popup.now");
            buttons.Children.Add(now);
        }
        panel.Children.Add(buttons);
        body.Children.Add(Card(panel, 32));
    }

    /// <summary>「消息」页：公告（最新在前）+ 更新说明；旧的只在这里、不弹不算未读</summary>
    private void RenderMessages(StackPanel body)
    {
        var panel = new StackPanel { Spacing = 10, MaxWidth = 560, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Center };
        panel.Children.Add(Label(T("messages.title"), 22));
        if (messages.Length == 0) panel.Children.Add(Muted(T("messages.empty"), 13));
        foreach (var m in messages)
        {
            var row = new StackPanel { Spacing = 6 };
            if (m.TryGetProperty("kind", out var kind) && kind.GetString() == "update")
            {
                var version = m.GetProperty("version").GetString() ?? "";
                var installed = m.TryGetProperty("installed", out var i) && i.ValueKind == JsonValueKind.True;
                row.Children.Add(Muted(T("messages.kind.update").Replace("{0}", version) + " · " + T(installed ? "messages.installed" : "messages.available"), 12));
                var notes = m.TryGetProperty("notes", out var n) ? n : default;
                var items = Items(notes, "highlights").ToArray();
                if (items.Length == 0) items = Items(notes, "sections").SelectMany(s => Items(s, "items")).ToArray();
                AddBullets(row, items.Take(3), 13.5);
                row.Children.Add(Action("update.popup.fullLog", () => _ = OpenOfficialAsync(ReleasePage(version))));
            }
            else
            {
                var important = m.TryGetProperty("level", out var level) && level.GetString() == "important";
                var unread = m.TryGetProperty("unread", out var u) && u.ValueKind == JsonValueKind.True;
                row.Children.Add(Muted((unread ? "● " : "") + T(important ? "messages.kind.important" : "messages.kind.notice"), 12));
                var texts = m.TryGetProperty("text", out var tx) ? tx : default;
                if (texts.ValueKind == JsonValueKind.Object && texts.TryGetProperty(language == "en" ? "en" : "zh-Hans", out var said))
                    row.Children.Add(new SelectableTextBlock { Text = said.GetString() ?? "", FontSize = 13.5, Foreground = Ink, TextWrapping = TextWrapping.Wrap });
                if (m.TryGetProperty("url", out var url) && Uri.TryCreate(url.GetString(), UriKind.Absolute, out var link))
                    row.Children.Add(Action("notice.details", () => _ = OpenOfficialAsync(link)));
            }
            panel.Children.Add(Card(row, 14));
        }
        panel.Children.Add(Action("update.after.ok", () => { messagesOpen = false; Render(); }));
        body.Children.Add(panel);
    }

    /// <summary>顶栏「消息」：未读只算最新那条公告</summary>
    private Button MessagesButton()
    {
        var button = new Button { Content = T("messages.button") + (unreadMessages > 0 ? $"  ● {unreadMessages}" : ""), Padding = new Thickness(14, 8),
            CornerRadius = new CornerRadius(8), Background = Brush.Parse("#29292D"), Foreground = Ink };
        AutomationId(button, "top.messages");
        button.Click += (_, _) => OpenMessages();
        return button;
    }

    /// <summary>NetSparkle：appcast（缺省 dl.s2arm.com/appcast/windows.xml；验收 / 联调用 S2A_UPDATE_FEED 指本机假 appcast）+ Ed25519 严格验签
    /// （appcast 本身与安装程序都要签名，公钥同 Mac 的 SUPublicEDKey，私钥只在发版机）。版本按 version.txt 比</summary>
    private NetSparkleUpdater.SparkleUpdater Sparkle()
    {
        if (sparkle is not null) return sparkle;
        var feed = Environment.GetEnvironmentVariable("S2A_UPDATE_FEED") is { Length: > 0 } f ? f : UpdateFeed;
        var updater = new NetSparkleUpdater.SparkleUpdater(feed, new NetSparkleUpdater.SignatureVerifiers.Ed25519Checker(NetSparkleUpdater.Enums.SecurityMode.Strict, UpdatePublicKey))
        {
            UIFactory = null,
            UserInteractionMode = NetSparkleUpdater.Enums.UserInteractionMode.DownloadNoInstall,
            Configuration = new NetSparkleUpdater.Configurations.JSONConfiguration(new VersionAccessor(AppVersion), Path.Combine(UpdatesFolder, "netsparkle.json")),
            RelaunchAfterUpdate = true,
            // 静默装进现在这个目录（便携版也原地更新，不另装一份）；数据不在程序目录里（私有目录、游戏库），装新版不碰
            // /LOG：安装程序日志写进私有 logs/（诊断包收），静默安装失败时脚本照样拉起旧版、看不到原因，只能靠它
            CustomInstallerArguments = $"/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR=\"{InstallDir}\" /LOG=\"{InstallerLog}\"",
            RelaunchAfterUpdateCommandSuffix = string.Join(" ", Environment.GetCommandLineArgs().Skip(1).Select(a => "\"" + a.Replace("\"", "") + "\"")),
            // 装完拉起不靠当前目录（11-16 第 2 份候选手动更新：装好了却没拉起）：NetSparkle 写的脚本是 cd "<目录>" 再跑 "<可执行文件名>"，
            //   cd 不带 /d 换不了盘——脚本在系统盘的临时目录里跑，程序装在别的盘（便携版放 D:、测试装在 R:）时 cd 落空，相对的 S2Arm.exe 找不到，静默不拉起。
            //   可执行文件给绝对路径，前缀再 cd /d 到安装目录（工作目录同安装程序「现在打开」的 WorkingDir {app}）
            RestartExecutableName = Path.Combine(InstallDir, Path.GetFileName(Environment.ProcessPath ?? "S2Arm.exe")),
            RelaunchAfterUpdateCommandPrefix = $"cd /d \"{InstallDir}\" && ",
            LogWriter = new UpdateLog(Path.Combine(privateRoot, "logs", "update.log")),
        };
        updater.CloseApplicationAsync += () => { ExitForInstaller(); return Task.CompletedTask; };
        updater.DownloadMadeProgress += (_, item, e) => Dispatcher.UIThread.Post(() =>
        { updateProgress = T("update.downloading").Replace("{0}", e.ProgressPercentage.ToString()); RefreshLive(); });
        updater.DownloadFinished += (item, path) => Dispatcher.UIThread.Post(() =>
        { updateProgress = ""; updateReady = item; updateReadyPath = path; Render(); if (installWhenReady) RestartToUpdate(); });
        updater.DownloadHadError += (item, path, error) => Dispatcher.UIThread.Post(() => Fail("update_failed", error.Message));
        updater.InstallUpdateFailed += (reason, path) => { Dispatcher.UIThread.Post(() => Fail("update_failed", reason.ToString())); return true; };
        return sparkle = updater;
    }

    private const string UpdateFeed = "https://dl.s2arm.com/appcast/windows.xml";
    private const string UpdatePublicKey = "WoZkGLOTuLU2zl0gsPX+4sTKRsIN9ahBEfj0ulkqOqc=";

    private void Fail(string code, string why)
    {
        updateProgress = ""; updateReady = null; updateFailure = code; updateFailureMessage = why;
        UpdateLog.Write(Path.Combine(privateRoot, "logs", "update.log"), $"更新失败（{code}）：{why}");
        Render();
    }

    private async Task DownloadUpdateAsync()
    {
        if (updateProgress.Length > 0) return;
        updateFailure = ""; updateFailureMessage = ""; updateProgress = T("update.downloading").Replace("{0}", "0"); Render();
        SaveUpdateNotes();
        try
        {
            var info = await Sparkle().CheckForUpdatesQuietly(true);
            if (info.Status != NetSparkleUpdater.Enums.UpdateStatus.UpdateAvailable || info.Updates is not { Count: > 0 } updates)
            {
                updateProgress = "";
                if (info.Status == NetSparkleUpdater.Enums.UpdateStatus.UpdateNotAvailable) { Render(); return; }
                Fail("update_failed", $"查新版没成（{info.Status}）"); return;
            }
            await Sparkle().InitAndBeginDownload(updates[0]);   // 下载、验签完成走 DownloadFinished，失败走 DownloadHadError
        }
        catch (Exception error) { Fail("update_failed", error.Message); }
    }

    /// <summary>换上新版后第一次打开要弹「这版更新了什么」（updater.py inbox 读 updates/notes/&lt;版本&gt;.json）：说明随查到的新版记在本机</summary>
    private void SaveUpdateNotes()
    {
        if (availableUpdate is not { } update || !update.TryGetProperty("version", out var v) || !update.TryGetProperty("notes", out var notes)
            || notes.ValueKind != JsonValueKind.Object) return;
        try
        {
            var folder = Path.Combine(UpdatesFolder, "notes"); Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, v.GetString() + ".json"), notes.GetRawText());
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>重启以更新会中断哪些任务、重启后能不能接着做（出包被打断可以接着做：已做完的阶段与缓存保留；同 Mac updateRestartImpactText）</summary>
    private string RestartImpactText() =>
        string.Join("\n", jobs.Select(j => (j.Kind, j.GameId)).Distinct().Select(j =>
        {
            var name = T("update.gate.task." + j.Kind.ToString().ToLowerInvariant());
            var game = j.GameId is { } id ? catalog?.Games.FirstOrDefault(g => g.Id == id)?.Name : null;
            if (!string.IsNullOrEmpty(game)) name += " · " + game;
            return T(j.Kind == JobKind.Pack ? "update.gate.confirm.taskResume" : "update.gate.confirm.taskRestart").Replace("{0}", name);
        }));

    private void RestartToUpdate(bool confirmed = false)
    {
        // 有任务在跑：先说清会打断什么，玩家点「仍然重启」照样换（不再只能等）；确认后先取消在跑的任务再换版
        if (UpdateBlocked && !confirmed) { updateGate = "update.gate.confirm"; if (updatePopup is null) ShowUpdatePopup(); Render(); return; }
        updateGate = "";
        if (UpdateBlocked) foreach (var job in jobs.ToList()) job.Cancellation.Cancel();
        if (updateReady is null && availableUpdate is not null) { installWhenReady = true; _ = DownloadUpdateAsync(); return; }   // 玩家点了才下：下完在 DownloadFinished 里接着装
        if (updateReady is not { } ready || sparkle is null) return;
        installWhenReady = false;
        UpdateLog.Write(Path.Combine(privateRoot, "logs", "update.log"), $"玩家点了更新并重启：交给 NetSparkle 运行安装程序 {ready.Version}");
        try { Directory.CreateDirectory(UpdatesFolder); File.WriteAllText(PendingInstall, $"{{\"version\":{JsonOut.Serialize(ready.Version ?? "")},\"from\":{JsonOut.Serialize(AppVersion)}}}"); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }   // 记不下只是下次判不了装没装上，不挡更新
        _ = sparkle.InstallUpdate(ready, updateReadyPath);   // 写好等本程序退出再跑安装程序、装完拉起的脚本，再经 CloseApplicationAsync 关掉本程序
    }

    // ── 顶部公告条（v0.2.3，同 Mac LauncherView.noticeBar）：只放最新一条没看过的重要公告（inbox banner）；内容是数据（notice.json），代码里不写公告内容。
    //    × 关掉 = 看过它和更旧的，不再出现；取不到、起不来都不显示、不报错
    private JsonElement? notice;

    private void DismissNotice()
    {
        if (notice is not { } value) return;
        var id = value.GetProperty("id").GetString() ?? "";
        notice = null;   // 当场收起，再记下
        if (messages.FirstOrDefault().ValueKind == JsonValueKind.Object && messages[0].TryGetProperty("id", out var first) && first.GetString() == id) unreadMessages = 0;
        Render();
        Seen("--notice", id);
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

    /// <summary>顶栏的自更新状态（下载中百分比 / 重启更新 / 失败原因）；没有可显示的返回 null。是顶栏的活格子，下载进度事件只刷新它。</summary>
    private Control? UpdateControls()
    {
        var bar = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 10, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
        if (updateProgress.Length > 0)
            bar.Children.Add(new TextBlock { Text = updateProgress, FontSize = 12, Foreground = Brush.Parse("#A8A6A1"), VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center });
        else if (updateFailure == "update_install_failed")   // 上次没装上：排在「有新版」前面（启动时查到新版会把它盖掉）；重试 = 重新下载、下完接着装
        {
            bar.Children.Add(Action("update.retry", () => { installWhenReady = true; _ = DownloadUpdateAsync(); }));
            var why = new TextBlock { Text = T("update.error.update_install_failed").Replace("{0}", installFailedTarget) + " · " + T("update.code").Replace("{0}", updateFailure), FontSize = 12,
                Foreground = Brush.Parse("#A8A6A1"), MaxWidth = 360, TextWrapping = Avalonia.Media.TextWrapping.Wrap, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
            Avalonia.Automation.AutomationProperties.SetAutomationId(why, "update.failure");
            bar.Children.Add(why);
            bar.Children.Add(Action("update.download_page", () => _ = OpenOfficialAsync(DownloadPage)));
        }
        else if (availableUpdate is { } update)   // 草图：「以后再说」后顶栏留「有新版 vX」，点开回到弹窗；重启只在弹窗里点
        {
            var available = new Button { Content = T("update.top.available").Replace("{0}", update.GetProperty("version").GetString() ?? ""), Padding = new Thickness(14, 8),
                CornerRadius = new CornerRadius(8), Background = Accent, Foreground = Canvas };
            AutomationId(available, "top.update");
            available.Click += (_, _) => ShowUpdatePopup();
            bar.Children.Add(available);
        }
        else if (updateFailure.Length > 0)
        {
            // 失败原因直接写在按钮旁（人话 + 错误码），并给「打开下载页」：自动更新连不上 GitHub 时玩家能自己下（不再只藏在悬停提示里）
            bar.Children.Add(Action("update.retry", () => _ = DownloadUpdateAsync()));
            // 文案表有这个码就用表里的（中英都有）；没有（如 update_none）就用后端那句，不显示「[update.error.…]」原样键名（剃刀 W11）
            var reason = text.Has("update.error." + updateFailure) || updateFailureMessage.Length == 0 ? T("update.error." + updateFailure) : B(updateFailureMessage);
            var why = new TextBlock { Text = reason + " · " + T("update.code").Replace("{0}", updateFailure), FontSize = 12,
                Foreground = Brush.Parse("#A8A6A1"), MaxWidth = 360, TextWrapping = Avalonia.Media.TextWrapping.Wrap, VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center };
            Avalonia.Automation.AutomationProperties.SetAutomationId(why, "update.failure");
            bar.Children.Add(why);
            bar.Children.Add(Action("update.download_page", () => _ = OpenOfficialAsync(DownloadPage)));
        }
        return bar.Children.Count > 0 ? bar : null;
    }
}
