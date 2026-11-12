// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace S2Arm.Launcher;

// 游戏库选到 exFAT / FAT32 盘（作业层 setup 报 library_bad_format）：Windows 出包要在游戏文件夹里建目录联接，只有 NTFS / ReFS 能建，
//   物理上做不下去、照拦；但不只报一句不能用（v0.3.1 维护者）——原因下面列出本机能放游戏库的盘和剩余空间，点一下就在那块盘上建游戏库
//   （这次本来要搬现有游戏库的，照样搬过去）。游戏库页的状态卡和添加游戏弹窗里都显示（同一个失败，两处入口）。
public sealed partial class EnvironmentWindow
{
    /// <summary>最近一次建库 / 换库没成的失败码，和那次要不要搬现有游戏库（WelcomePage.EnsureLibraryAsync 记）</summary>
    private string? libraryFailCode, libraryFailMoveFrom;
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
        if (libraryFailCode != "library_bad_format" || libraryBusy) return null;
        var panel = new StackPanel { Spacing = 8, Margin = new Thickness(0, 12, 0, 0) };
        AutomationId(panel, "library.drives");
        var drives = LibraryDrives();
        panel.Children.Add(new TextBlock { Text = T(drives.Count > 0 ? "library.drives.title" : "library.drives.none"), FontSize = 14, FontWeight = FontWeight.Bold,
            Foreground = Ink, TextWrapping = TextWrapping.Wrap });
        foreach (var (root, format, free) in drives)
        {
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 12 };
            var name = new TextBlock { Text = root + "  ·  " + format + "  ·  " + T("library.drives.free").Replace("{0}", FormatBytes(free)),
                FontSize = 13, Foreground = Ink, VerticalAlignment = VerticalAlignment.Center };
            row.Children.Add(name);
            var use = Action("library.drives.use", () =>
            {
                libraryMoveFrom = libraryFailMoveFrom; libraryFailCode = null;
                ConnectLibrary(LibraryFolderOn(root));
            }, !libraryBusy);
            AutomationId(use, "library.drives.use." + root.TrimEnd('\\', ':'));
            Grid.SetColumn(use, 1); row.Children.Add(use);
            panel.Children.Add(row);
        }
        return panel;
    }
}
