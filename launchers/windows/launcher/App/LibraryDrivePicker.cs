// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using S2Arm.Launcher.Protocol;

namespace S2Arm.Launcher;

// 游戏库选到 exFAT / FAT32 盘（作业层 setup 报 library_bad_format，v0.3.1）：认得出的风险——这种盘建不了目录链接，出包多占空间、断电时产物可能要重出。
//   给「仍然用这里」（带 acceptFormat 重来），下面列出本机 NTFS / ReFS 盘和剩余空间作推荐，点一下就在那块盘上建游戏库（这次本来要搬现有游戏库的，照样搬过去）。
//   游戏库页的状态卡和添加游戏弹窗里都显示（同一个失败，两处入口）。
// 选盘模式（library_choose_drive）：玩家第一次建库、本机不止一块能放库的盘时，添加游戏弹窗先列出各盘和剩余空间、标出系统盘，
//   玩家点哪块就建在哪块（系统盘仍是 %USERPROFILE%\S2Arm）。原先不问就建在系统盘用户目录，出过几款游戏就是几十 GB，玩家清 C 盘才发现。
public sealed partial class EnvironmentWindow
{
    /// <summary>选盘模式的「失败码」：还没建库、等玩家选盘（不是失败，借同一套字段和列表）</summary>
    private const string LibraryChooseDrive = "library_choose_drive";
    /// <summary>玩家这次已经选过盘（选了系统盘时照旧走缺省库流程），不再问</summary>
    private bool libraryDriveChosen;
    /// <summary>界面快照用：系统盘根目录（null = 读本机）</summary>
    private string? systemDriveOverride = null;

    private string SystemDrive => systemDriveOverride ?? Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.Windows)) ?? "C:\\";

    /// <summary>该不该先问玩家放哪块盘：没选过位置（无设置文件、缺省位置也没建好库）、用的是标准私有目录（--data-root 和测试不问）、
    ///   这次还没选过、本机能放库的盘不止一块。只有一块盘时照旧直接建，不多问一步</summary>
    private bool NeedsLibraryDrive(string defaultLib) =>
        !libraryDriveChosen && !File.Exists(LibraryPreference)
        && SameFolder(privateRoot, LibraryPaths.StandardPrivateRoot)
        && !File.Exists(Path.Combine(defaultLib, ".s2arm-library.json"))
        && LibraryDrives().Count > 1;

    /// <summary>最近一次建库 / 换库没成的失败码，和那次要不要搬现有游戏库（WelcomePage.EnsureLibraryAsync 记）</summary>
    private string? libraryFailCode, libraryFailMoveFrom, libraryFailFolder;
    /// <summary>下一次建库带 acceptFormat（「仍然用这里」点了一次，EnsureLibraryAsync 用掉就清）</summary>
    private bool acceptFormatOnce;
    /// <summary>界面快照用：不读本机磁盘，按给的盘画（UI.Snapshots；null = 读本机）</summary>
    private IReadOnlyList<(string Root, string Format, long Free)>? drivesOverride = null;

    /// <summary>本机能放游戏库的盘（NTFS / ReFS、已就绪的本地 / 移动盘），剩余空间大的在前</summary>
    private IReadOnlyList<(string Root, string Format, long Free)> LibraryDrives()
    {
        if (drivesOverride is { } fixedList) return fixedList;
        var list = new List<(string Root, string Format, long Free)>();
        foreach (var d in DriveInfo.GetDrives())
        {
            try
            {
                if (!d.IsReady || d.DriveType is not (DriveType.Fixed or DriveType.Removable)) continue;
                if (d.DriveFormat is not ("NTFS" or "ReFS")) continue;
                list.Add((d.RootDirectory.FullName, d.DriveFormat, d.AvailableFreeSpace));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }   // 读不了的盘不列
        }
        return list.OrderByDescending(d => d.Free).ToList();
    }

    /// <summary>这块盘上放游戏库的文件夹：「S2Arm Library」，被别的文件占着就顺延「S2Arm Library 2」…（已是游戏库的直接用）</summary>
    private static string LibraryFolderOn(string root)
    {
        for (var i = 1; ; i++)
        {
            var folder = Path.Combine(root, "S2Arm Library" + (i > 1 ? " " + i : ""));
            try
            {
                if (!Directory.Exists(folder) || File.Exists(Path.Combine(folder, ".s2arm-library.json")) || !Directory.EnumerateFileSystemEntries(folder).Any())
                    return folder;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            if (i >= 20) return folder;
        }
    }

    /// <summary>游戏库盘格式不对时的「换一个存放位置」：列出可用的盘，点了就在那里建 / 搬游戏库；不是这个失败返回 null</summary>
    private Control? LibraryDrivePicker()
    {
        if (libraryFailCode is not ("library_bad_format" or LibraryChooseDrive) || libraryBusy) return null;
        var choose = libraryFailCode == LibraryChooseDrive;
        var panel = new StackPanel { Spacing = 8, Margin = new Thickness(0, choose ? 0 : 12, 0, 0) };
        AutomationId(panel, choose ? "library.choose" : "library.drives");
        // exFAT / FAT32 可以照用（v0.3.1：多占空间、断电时产物可能要重出，作业层实目录模式 + 联接退回拷贝）：先给「仍然用这里」，NTFS 盘列在下面作推荐
        if (!choose && libraryFailFolder is { Length: > 0 } here)
        {
            var keep = Primary(T("library.format.keep"), () =>
            {
                libraryMoveFrom = libraryFailMoveFrom; libraryFailCode = null; acceptFormatOnce = true;
                ConnectLibrary(here);
            }, !libraryBusy);
            AutomationId(keep, "library.format.keep");
            keep.HorizontalAlignment = HorizontalAlignment.Left;
            panel.Children.Add(keep);
        }
        var drives = LibraryDrives();
        panel.Children.Add(new TextBlock { Text = T(choose ? "library.choose.title" : drives.Count > 0 ? "library.drives.title" : "library.drives.none"), FontSize = 14, FontWeight = FontWeight.Bold,
            Foreground = Ink, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) });
        if (choose)
            panel.Children.Add(new TextBlock { Text = T("library.choose.body"), FontSize = 13, Foreground = Brush.Parse("#A8A6A1"), TextWrapping = TextWrapping.Wrap });
        foreach (var (root, format, free) in drives)
        {
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 12 };
            var system = SameFolder(root, SystemDrive);
            var name = new TextBlock { Text = root + "  ·  " + format + "  ·  " + T("library.drives.free").Replace("{0}", FormatBytes(free))
                    + (system ? "  ·  " + T("library.drives.system") : ""),
                FontSize = 13, Foreground = Ink, VerticalAlignment = VerticalAlignment.Center };
            row.Children.Add(name);
            var use = Action("library.drives.use", () =>
            {
                libraryMoveFrom = libraryFailMoveFrom; libraryFailCode = null;
                if (choose && system) { libraryDriveChosen = true; EnsureLibrary(() => { }); return; }   // 系统盘：照旧缺省库 %USERPROFILE%\S2Arm（被占时 setup 换到旁边）
                if (choose) libraryDriveChosen = true;
                ConnectLibrary(LibraryFolderOn(root));
            }, !libraryBusy);
            AutomationId(use, "library.drives.use." + root.TrimEnd('\\', ':'));
            Grid.SetColumn(use, 1); row.Children.Add(use);
            panel.Children.Add(row);
        }
        return panel;
    }
}
