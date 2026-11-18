// S2Arm（不是上游文件）：「S 级优化升级」页（v0.4.0，同 Mac launchers/macos/frontend/Sources/NX2Apple/SGradeUpgradeView.swift；
//   11-14 维护者：Windows 出包和 macOS 使用者一样多，功能和体验对齐 macOS）。已经装在 iPhone 上 / 导出过的游戏不用重出包就补上 S 级优化：
//   打开即跑 sgradeScan（pack/jobs/sgrade.py）：逐款找原始程序、按启动器内置补丁库看这个版本能补什么 → 分组：可升级 / 没有对应补丁 / 出包时选了不打入 /
//   没找到原始程序（要重新出包覆盖更新）。一款都升不了只给「确认」；有可升级的 iPhone 款给「插上手机，一键升级并安装」「自签导出 IPA」
//   （11-18 起：玩家点「在电脑上升级」后台逐款升级 iPhone 程序件，之后照常装 / 导出就带上）
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

public sealed partial class EnvironmentWindow
{
    private bool sgradeOpen;
    private bool sgradeScanning;
    private JsonElement? sgradeScan;
    private string sgradeScanError = "";

    private void OpenSGradeUpgrade()
    {
        if (libraryId is null || libraryBusy || PackBusy) return;
        sgradeOpen = true; sgradeScan = null; sgradeScanError = "";
        Render();   // 页面渲染时发起查找（RenderSGradeUpgrade：还没结果、也没在查 → ScanSGradeAsync）
    }

    private async Task ScanSGradeAsync()
    {
        sgradeScanning = true;   // 由渲染发起，页面此刻已画着「正在查找」，不再重入渲染
        try
        {
            var job = await PackJobClient.RunAsync(PackRequest("sgradeScan", "", null), null, CancellationToken.None);
            if (job.Report.Succeeded && job.Report.Result.ValueKind == JsonValueKind.Object) sgradeScan = job.Report.Result.Clone();
            else sgradeScanError = job.Report.Message.Length > 0 ? job.Report.Message : job.Report.State;
        }
        catch (Exception error)   // 任何失败都要落成错误文字：页面渲染时见「没结果、没在查、没错误」就再发，漏掉一类异常 = 无限重发卡死 UI（#1149）
        { sgradeScanError = error.Message; }
        finally { sgradeScanning = false; Dispatcher.UIThread.Post(Render); }
    }

    /// <summary>游戏库页标题行的入口（同 Mac LauncherView+Library 的「S 级优化升级」按钮：金色 S + 字）</summary>
    private Control SGradeUpgradeEntry()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new Image { Source = SGoldImage(), Width = 18, Height = 18, Stretch = Stretch.Uniform });
        row.Children.Add(new TextBlock { Text = T("sgrade.upgrade.button"), FontSize = 13.5, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        var b = new Button { Content = row, IsEnabled = !libraryBusy && !PackBusy, Padding = new Thickness(12, 6) };
        b.Click += (_, _) => OpenSGradeUpgrade();
        Avalonia.Automation.AutomationProperties.SetAutomationId(b, "library.sgradeUpgrade");
        return b;
    }

    private void RenderSGradeUpgrade(StackPanel body)
    {
        string X(string k) => T("sgrade.upgrade." + k);
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        head.Children.Add(new Image { Source = SGoldImage(), Width = 34, Height = 34, Stretch = Stretch.Uniform });
        head.Children.Add(new TextBlock { Text = X("title"), FontSize = 22, FontWeight = FontWeight.Bold, VerticalAlignment = VerticalAlignment.Center,
            Foreground = Diag((SGoldHi, 0), (SGold, 0.5), (SRose, 1)) });
        body.Children.Add(head);
        var box = new StackPanel { Spacing = 14 };
        AutomationId(box, "sgrade.upgrade");
        void Close() { sgradeOpen = false; Render(); }
        void OkRow() { var ok = Primary(X("ok"), Close); AutomationId(ok, "sgrade.upgrade.ok"); box.Children.Add(ok); }
        if (sgradeScanError.Length > 0) { box.Children.Add(WrappedMuted(B(sgradeScanError), 14)); OkRow(); body.Children.Add(Card(box)); return; }
        if (sgradeScan is not { } scan)   // 还在查（sgradeScanning）
        {
            if (!sgradeScanning) _ = ScanSGradeAsync();
            box.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 4 });
            box.Children.Add(Muted(X("scanning"), 13));
            body.Children.Add(Card(box)); return;
        }
        string S(JsonElement e, string k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
        int N(JsonElement e, string k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : 0;
        bool Bo(JsonElement e, string k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
        var all = scan.TryGetProperty("games", out var gs) && gs.ValueKind == JsonValueKind.Array ? gs.EnumerateArray().ToList() : [];
        var found = all.Where(g => S(g, "program") is { Length: > 0 } p && p != "none").ToList();
        var yes = found.Where(g => N(g, "total") > 0 && !Bo(g, "off")).ToList();
        // 没有对应补丁拆两组（定稿表，同 Mac）：补丁库里有别的版本的 → 写版本号；一类都没有 → 补丁库里没有（作业层 versions）
        Dictionary<string, List<string>> Avail(JsonElement g) =>
            g.TryGetProperty("versions", out var vs) && vs.ValueKind == JsonValueKind.Object && vs.TryGetProperty("available", out var av) && av.ValueKind == JsonValueKind.Object
                ? av.EnumerateObject().Where(p => p.Value.ValueKind == JsonValueKind.Array)
                    .ToDictionary(p => p.Name, p => p.Value.EnumerateArray().Select(x => x.GetString() ?? "").Where(x => x.Length > 0).ToList())
                    .Where(kv => kv.Value.Count > 0).ToDictionary(kv => kv.Key, kv => kv.Value)
                : new();
        string Mine(JsonElement g) => g.TryGetProperty("versions", out var vs) && vs.ValueKind == JsonValueKind.Object ? S(vs, "mine") : "";
        var noVer = found.Where(g => N(g, "total") == 0 && Avail(g).Count > 0).ToList();
        var no = found.Where(g => N(g, "total") == 0 && Avail(g).Count == 0).ToList();
        string Versions(JsonElement g)
        {
            var a = Avail(g); var mine = Mine(g);
            var parts = new[] { "widescreen", "fps", "gfx", "cheat" }.Where(a.ContainsKey)
                .Select(c => SGradeVersions.Pick(a[c], mine) is { } p ? X(c == "cheat" ? "cat.cheatPlain" : "cat." + c) + " " + p.Version : null)
                .Where(s => s is not null);
            return string.Join(language == "en" ? ", " : "、", parts) + (mine.Length > 0 ? X("version.mine").Replace("{0}", mine) : "");
        }
        var off = found.Where(g => N(g, "total") > 0 && Bo(g, "off")).ToList();
        var missing = all.Where(g => !found.Contains(g)).ToList();
        string Gains(JsonElement g)
        {
            var p = g.TryGetProperty("patches", out var pp) && pp.ValueKind == JsonValueKind.Object ? pp : default;
            int C(string k) => p.ValueKind == JsonValueKind.Object ? N(p, k) : 0;
            var parts = new List<string>();
            if (C("widescreen") > 0) parts.Add(X("cat.widescreen"));
            else if (Bo(g, "ownWiden")) parts.Add(X("cat.ownWiden"));   // S2Arm 通用满屏（作业层 total 已算它 +1，同 Mac）
            if (C("fps") > 0) parts.Add(X("cat.fps"));
            if (C("gfx") > 0) parts.Add(X("cat.gfx"));
            if (C("cheat") > 0) parts.Add(X("cat.cheat").Replace("{0}", C("cheat").ToString()));
            return string.Join(language == "en" ? ", " : "、", parts);
        }
        void Group(string title, IEnumerable<JsonElement> rows, bool gold = false, bool gains = false, Func<JsonElement, string>? detail = null, bool rowUpgrade = false)
        {
            // 分组标题与游戏行要一眼分得开（11-14 体验走查：同号同色粗体分不清哪行是标题）：标题小一号、金 / 灰色、带款数，游戏行缩进（同 Mac SGradeUpgradeView）
            var list = rows.ToList();
            if (title.Length > 0)
            {
                var t = Muted($"{title} · {list.Count}", 12); t.FontWeight = FontWeight.SemiBold; t.Margin = new Thickness(0, 6, 0, 0);
                if (gold) t.Foreground = new SolidColorBrush(SGold);
                box.Children.Add(t);
            }
            if (rowUpgrade)
            {
                // 「全选」（11-18 维护者：可批量、有全选）：勾上 = 选中这组里没在升级的全部
                var free = list.Select(g => S(g, "id")).Where(id => !SGradeBusy(id)).ToList();
                var all = new CheckBox { Content = X("selectAll"), FontSize = 12, IsEnabled = free.Count > 0, IsChecked = free.Count > 0 && free.All(sgradeSelected.Contains), Margin = new Thickness(12, 0, 0, 0) };
                all.Click += (_, _) => { if (all.IsChecked == true) sgradeSelected.UnionWith(free); else sgradeSelected.ExceptWith(free); Render(); };
                AutomationId(all, "sgrade.upgrade.selectAll");
                box.Children.Add(all);
            }
            foreach (var g in list)
            {
                var line = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto,Auto"), Margin = new Thickness(title.Length > 0 ? 12 : 0, 0, 0, 0) };
                var nameText = new TextBlock { Text = S(g, "name"), FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(nameText, 1); line.Children.Add(nameText);
                if (gains || detail is not null) { var gtx = Muted(detail is not null ? detail(g) : Gains(g), 12); gtx.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(gtx, 2); line.Children.Add(gtx); }
                if (rowUpgrade)
                {
                    // 每款勾选 +「升级」（11-18 维护者：点了才做；可批量）：点「升级」只升这一款，勾选后「批量升级所选」逐款排队；页面不关（SGradeUpgrade.cs）
                    var id = S(g, "id");
                    var busy = SGradeBusy(id);
                    var pick = new CheckBox { IsChecked = !busy && sgradeSelected.Contains(id), IsEnabled = !busy, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) };
                    pick.Click += (_, _) => { if (pick.IsChecked == true) sgradeSelected.Add(id); else sgradeSelected.Remove(id); Render(); };
                    AutomationId(pick, "sgrade.upgrade.pick." + id);
                    line.Children.Add(pick);
                    var b = new Button { Content = X(busy ? "rowBusy" : "row"), IsEnabled = !busy, Padding = new Thickness(12, 5), Margin = new Thickness(12, 2, 0, 2), FontSize = 12.5 };
                    b.Click += (_, _) => UpgradeSGrade([id]);
                    AutomationId(b, "sgrade.upgrade.row." + id);
                    Grid.SetColumn(b, 3); line.Children.Add(b);
                }
                box.Children.Add(line);
            }
        }
        if (found.Count == 0) { box.Children.Add(WrappedMuted(X("nothing"), 14)); OkRow(); }
        else if (yes.Count == 0)
        {
            if (no.Count > 0) { box.Children.Add(WrappedMuted(X("none"), 14)); Group("", no); }
            if (noVer.Count > 0) Group(X("no.version"), noVer, detail: Versions);
            if (off.Count > 0) Group(X("off"), off);
            OkRow();
        }
        else
        {
            box.Children.Add(Label(X("found").Replace("{0}", found.Count.ToString()), 14));
            Group(X("yes"), yes, gold: true, gains: true, rowUpgrade: true);
            if (noVer.Count > 0) Group(X("no.version"), noVer, detail: Versions);
            if (no.Count > 0) Group(X("no.none"), no);
            if (off.Count > 0) Group(X("off"), off);
            if (missing.Count > 0) Group(X("missing"), missing);
            box.Children.Add(WrappedMuted(X("macNote"), 12));
            var footer = new WrapPanel { Orientation = Orientation.Horizontal };
            if (sgradeBatch is { } batch)
            {
                // 批量进行中：总进度（第几款 / 共几款）+「停止」（已做完的保留）
                var progress = Label(X("batchProgress").Replace("{0}", Math.Min(batch.Total, batch.Done + 1).ToString()).Replace("{1}", batch.Total.ToString()), 13);
                progress.Foreground = new SolidColorBrush(SGold); progress.VerticalAlignment = VerticalAlignment.Center; progress.Margin = new Thickness(0, 0, 12, 0);
                AutomationId(progress, "sgrade.upgrade.batchProgress"); footer.Children.Add(progress);
                var stop = Action("sgrade.upgrade.stop", StopSGrade); stop.Margin = new Thickness(0, 0, 12, 0); footer.Children.Add(stop);
            }
            else
            {
                var chosen = yes.Select(g => S(g, "id")).Where(id => sgradeSelected.Contains(id) && !SGradeBusy(id)).ToList();
                var batchButton = Primary(X("batch").Replace("{0}", chosen.Count.ToString()), () => UpgradeSGrade(chosen), chosen.Count > 0);
                AutomationId(batchButton, "sgrade.upgrade.batch"); batchButton.Margin = new Thickness(0, 0, 12, 0); footer.Children.Add(batchButton);
            }
            footer.Children.Add(Action("sgrade.upgrade.close", Close));
            box.Children.Add(footer);

        }
        body.Children.Add(Card(box));
    }
}
