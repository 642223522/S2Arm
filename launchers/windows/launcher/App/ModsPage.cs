// S2Arm（不是上游文件）：Windows「Mod」页（11-15 维护者「咱们也可以支持 mod 导入」）。同 Mac 启动设置里的「资源 Mod」：
//   看这款导入了哪些、导入 zip / 文件夹、删除。导入进这款游戏文件夹的 mods/（pack/jobs/mods.py，作业层找 romfs、标了别的程序号的不收），
//   下次「装到 iPhone」时推进手机上本款文档根 mods/（pack/jobs/install.py push_mods，只推变了的），进游戏时服务层 RomFsMods.cs 叠上
using System.Text.Json;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

public sealed partial class EnvironmentWindow
{
    private LibraryGame? modsFor;
    private JsonElement? modsList;
    private JsonElement? modsDone;
    private string modsError = "";
    private bool modsLoading;

    private void OpenMods(LibraryGame game)
    {
        modsFor = game; modsList = null; modsDone = null; modsError = ""; modsLoading = false;
        Render();
    }

    /// 读（extra 为空）或导入 / 删除后重读：结果里的 mods 是这款现在的列表，modsImported 是这次导入的说明
    private async Task RunModsAsync(Dictionary<string, object?>? extra)
    {
        if (modsFor is not { } game) return;
        modsLoading = true; modsError = ""; if (extra is not null) { modsList = null; Render(); }
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest(extra is null ? "community" : "communitySave", game.Id, extra), null, CancellationToken.None);
            if (job.Report.Succeeded && job.Report.Result.ValueKind == JsonValueKind.Object && job.Report.Result.TryGetProperty("mods", out var m))
            {
                modsList = m.Clone();
                modsDone = job.Report.Result.TryGetProperty("modsImported", out var d) ? d.Clone() : null;
            }
            else modsError = job.Report.Message.Length > 0 ? job.Report.Message : job.Report.State;
        }
        catch (Exception error)   // 任何失败都要落成错误文字：页面渲染时见「没结果、没在查、没错误」就再发，漏掉一类异常 = 无限重发卡死 UI（#1149）
        { modsError = error.Message; }
        finally { modsLoading = false; Dispatcher.UIThread.Post(Render); }
    }

    private async Task ImportModsAsync(bool folder)
    {
        List<string?> paths;
        if (folder)
        {
            var dirs = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { AllowMultiple = true, Title = T("mods.page.importFolder") });
            paths = dirs.Select(d => d.TryGetLocalPath()).ToList();
        }
        else
        {
            var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                AllowMultiple = true, Title = T("mods.page.importZip"),
                FileTypeFilter = [new FilePickerFileType("zip") { Patterns = ["*.zip"] }]
            });
            paths = files.Select(f => f.TryGetLocalPath()).ToList();
        }
        var list = paths.Where(p => !string.IsNullOrEmpty(p)).Cast<object?>().ToList();
        if (list.Count == 0) return;
        await RunModsAsync(new Dictionary<string, object?> { ["modsImport"] = list });
    }

    /// <summary>mod 导入旁的「？」（11-17 维护者：玩家不知道 mod 支持什么格式、去哪找）：鼠标移上去展开说明（共享文案 mods.help：支持的两类 mod、
    /// 认哪几种放法、什么时候生效、不收什么、去哪找），点一下也展开 / 收起（手柄、键盘够得着）。Mod 页导入按钮旁与出包页 S 级卡片「导入 Mod」旁两处；同 Mac ModHelpButton</summary>
    private Control ModHelp()
    {
        var tip = new TextBlock { Text = T("mods.help"), TextWrapping = TextWrapping.Wrap, MaxWidth = 460, FontSize = 13, LineHeight = 20 };
        var help = new Button
        {
            Content = "?", FontSize = 13, FontWeight = FontWeight.Bold, Width = 28, Height = 28, Padding = new Avalonia.Thickness(0),
            CornerRadius = new Avalonia.CornerRadius(14), HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center, VerticalAlignment = VerticalAlignment.Center
        };
        ToolTip.SetTip(help, tip); ToolTip.SetShowDelay(help, 150); ToolTip.SetPlacement(help, PlacementMode.Bottom);
        help.Click += (_, _) => ToolTip.SetIsOpen(help, !ToolTip.GetIsOpen(help));
        Avalonia.Automation.AutomationProperties.SetName(help, T("mods.help.label"));
        AutomationId(help, "mods.help");
        return help;
    }

    private void RenderMods(StackPanel body)
    {
        if (modsFor is not { } game) return;
        var head = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto,Auto,Auto"), ColumnSpacing = 10 };
        head.Children.Add(Label(T("mods.page.title").Replace("{0}", game.Name), 22));
        var help = ModHelp();
        Grid.SetColumn(help, 1); head.Children.Add(help);
        var zip = Action("mods.page.importZip", () => _ = ImportModsAsync(false), !modsLoading && !libraryBusy);
        Grid.SetColumn(zip, 2); head.Children.Add(zip);
        var dir = Action("mods.page.importFolder", () => _ = ImportModsAsync(true), !modsLoading && !libraryBusy);
        Grid.SetColumn(dir, 3); head.Children.Add(dir);
        var back = Action("cheats.page.back", () => { modsFor = null; Render(); });
        Grid.SetColumn(back, 4); head.Children.Add(back);
        body.Children.Add(head);
        var box = new StackPanel { Spacing = 10 };
        AutomationId(box, "mods.page");
        box.Children.Add(WrappedMuted(T("mods.page.note"), 13));
        if (modsError.Length > 0) box.Children.Add(WrappedMuted("⚠ " + B(modsError), 13));
        if (modsDone is { } done)
        {
            var got = done.TryGetProperty("imported", out var im) && im.ValueKind == JsonValueKind.Array ? im.EnumerateArray().Select(x => x.GetString() ?? "").ToList() : [];
            if (got.Count > 0) box.Children.Add(Label(T("display.mods.imported").Replace("{0}", string.Join(" · ", got)), 13));
            if (done.TryGetProperty("notes", out var ns) && ns.ValueKind == JsonValueKind.Array)
                foreach (var n in ns.EnumerateArray()) box.Children.Add(WrappedMuted("· " + B(n.GetString() ?? ""), 12));
        }
        if (modsList is not { } mods)
        {
            if (!modsLoading && modsError.Length == 0) _ = RunModsAsync(null);
            if (modsError.Length == 0) box.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 4 });
            body.Children.Add(Card(box)); return;
        }
        var items = mods.ValueKind == JsonValueKind.Array ? mods.EnumerateArray().ToList() : [];
        if (items.Count == 0) box.Children.Add(Label(T("mods.page.empty"), 14));
        foreach (var it in items)
        {
            var name = it.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "";
            long bytes = it.TryGetProperty("bytes", out var b) && b.TryGetInt64(out var bv) ? bv : 0;
            int files = it.TryGetProperty("files", out var f) && f.TryGetInt32(out var fv) ? fv : 0;
            bool on = !(it.TryGetProperty("enabled", out var en) && en.ValueKind == JsonValueKind.False);   // 关掉 = 作业层改名为 mods/.off-<名字>（不叠、不推）
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto"), ColumnSpacing = 10 };
            var text = new StackPanel { Spacing = 2 };
            text.Children.Add(new TextBlock { Text = name, FontSize = 13.5, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap });
            text.Children.Add(Muted(T("display.mods.files").Replace("{0}", files.ToString()).Replace("{1}", $"{bytes / 1048576.0:0.#} MB"), 12));
            row.Children.Add(text);
            var remove = Action("display.mods.remove", () => _ = RunModsAsync(new Dictionary<string, object?> { ["modsRemove"] = new List<object?> { name } }), !modsLoading && !libraryBusy);
            AutomationId(remove, "mods.remove." + name);
            remove.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(remove, 1); row.Children.Add(remove);
            var toggle = new CheckBox { IsChecked = on, IsEnabled = !modsLoading && !libraryBusy, VerticalAlignment = VerticalAlignment.Center };
            toggle.IsCheckedChanged += (_, _) => _ = RunModsAsync(new Dictionary<string, object?> { ["modsEnable"] = new Dictionary<string, object?> { [name] = toggle.IsChecked == true } });
            AutomationId(toggle, "mods.toggle." + name);
            Grid.SetColumn(toggle, 2); row.Children.Add(toggle);
            box.Children.Add(row);
        }
        body.Children.Add(Card(box));
    }
}
