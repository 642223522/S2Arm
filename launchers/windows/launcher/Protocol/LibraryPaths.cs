// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text.Json;

namespace S2Arm.Launcher.Protocol;

/// <summary>
/// 游戏库结构 P3：玩家指定的库是入口，私有目录（%LOCALAPPDATA%\S2Arm\WindowsLauncher）只留设置、密钥和控制口文件。
/// 启动器算「库放哪」「日志 / 任务记录在哪」都只调这里（作业层同一规则：pack/jobs/core.py logs_root、layout.py relocate_default）。
/// </summary>
public static class LibraryPaths
{
    /// <summary>设置：玩家选的库路径（一行文字）。</summary>
    public static string PreferenceFile(string privateRoot) => Path.Combine(privateRoot, "library-location.txt");

    public static string StandardPrivateRoot =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "S2Arm", "WindowsLauncher");

    /// <summary>新装的缺省库：%USERPROFILE%\S2Arm（资源管理器里看得见）；自定义数据目录（--data-root=、测试）时仍是数据目录下的 DefaultLibrary。</summary>
    public static string DefaultLibrary(string privateRoot) =>
        SamePath(privateRoot, StandardPrivateRoot)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "S2Arm")
            : Path.Combine(privateRoot, "DefaultLibrary");

    /// <summary>设置里记的库路径按作业层的搬库标记（library-relocate.json，旧默认库同盘改名到新缺省位置时写）换成现在的位置：
    /// 记的是旧路径、新位置有库标识、旧位置没有，就用新位置；其余原样。</summary>
    public static string Library(string privateRoot, string saved)
    {
        if (string.IsNullOrEmpty(saved)) return saved;
        try
        {
            using var note = JsonDocument.Parse(File.ReadAllText(Path.Combine(privateRoot, "library-relocate.json")));
            var root = note.RootElement;
            if (root.ValueKind == JsonValueKind.Object &&
                root.TryGetProperty("from", out var from) && from.ValueKind == JsonValueKind.String &&
                root.TryGetProperty("to", out var to) && to.ValueKind == JsonValueKind.String &&
                SamePath(from.GetString()!, saved) && Built(to.GetString()!) && !Built(saved))
                return to.GetString()!;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or ArgumentException or NotSupportedException) { }
        return saved;
    }

    /// <summary>设置文件里的库路径（已按搬库标记换过）；没有设置就是缺省库。</summary>
    public static string SavedLibrary(string privateRoot)
    {
        try
        {
            var saved = File.ReadAllText(PreferenceFile(privateRoot)).Trim();
            if (saved.Length > 0) return Library(privateRoot, saved);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return DefaultLibrary(privateRoot);
    }

    /// <summary>任务日志 + 任务记录（logs\jobs\）：库建好了（有 .s2arm-library.json）是 库\logs，否则退回 私有目录\logs。library 不给就读设置。</summary>
    public static string LogsRoot(string privateRoot, string? library = null)
    {
        var lib = library is null ? SavedLibrary(privateRoot) : Library(privateRoot, library);
        return Path.Combine(!string.IsNullOrEmpty(lib) && Built(lib) ? lib : privateRoot, "logs");
    }

    public static string JobsDir(string privateRoot, string? library = null) => Path.Combine(LogsRoot(privateRoot, library), "jobs");

    private static bool Built(string library) => File.Exists(Path.Combine(library, ".s2arm-library.json"));

    private static bool SamePath(string a, string b)
    {
        try
        {
            return string.Equals(Path.GetFullPath(a).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                                 Path.GetFullPath(b).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                                 OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException) { return false; }
    }
}
