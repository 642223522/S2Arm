// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
namespace S2Arm.Launcher.Protocol;

/// <summary>
/// 玩家在「游戏库 / 输出目录」里填的路径 → 规范后的绝对路径，或一个界面文案键说明为什么不行。
/// 玩家反馈（v0.2.0）：填 <c>D:\WORK\NX2Apple-windows-x64\1\</c>（末尾反斜杠、就在启动器解压目录里）点「连接或创建游戏库」闪退、位置也改不了。
/// 这里只把输入转成一个能发给作业层的绝对路径：去首尾空白和引号；转绝对路径（非法字符 / 太长 → invalid）；去掉末尾分隔符。
/// 「哪里能放游戏库」（盘根、启动器自己的目录里或包含它、已有别的文件）只在作业层 setup 判（pack/jobs/library.py，剃刀 W19），失败原话照显示。
/// </summary>
public static class LibraryFolderInput
{
    public sealed record Result(string? Folder, string? ErrorKey);

    public static Result Normalize(string? input)
    {
        var text = (input ?? "").Trim().Trim('"').Trim();
        if (text.Length == 0) return new(null, "library.folder_empty");
        string full;
        try { full = Path.GetFullPath(text); }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException or System.Security.SecurityException)
        { return new(null, "library.folder_invalid"); }
        var root = Path.GetPathRoot(full) ?? "";
        var trimmed = full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (trimmed.Length < root.Length) trimmed = root;   // 盘根留着分隔符（「E:」是当前目录），由作业层 setup 拒收
        if (Path.GetInvalidPathChars().Any(trimmed.Contains) || trimmed[Math.Min(root.Length, trimmed.Length)..].IndexOfAny(['<', '>', '|', '"', '*', '?']) >= 0)
            return new(null, "library.folder_invalid");
        return new(trimmed, null);
    }
}
