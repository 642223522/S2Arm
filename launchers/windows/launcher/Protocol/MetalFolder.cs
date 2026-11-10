// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
namespace S2Arm.Launcher.Protocol;

/// <summary>
/// 玩家手动指定的 Metal Developer Tools 文件夹（装了但自动没找到时的退路）：在选的文件夹里认 metal.exe、bin\metal.exe、ios\bin\metal.exe，
/// 找到就把 metal.exe 所在目录记进私有目录 metal-folder.txt，并设进本进程的环境变量 S2A_METAL_PICKED——之后起的环境检查 / 出包子进程都继承它，
/// 作业层 pack/orch/oneclick_win.metal_search 把它排在自动查找之前。
/// </summary>
public static class MetalFolder
{
    public const string Variable = "S2A_METAL_PICKED";

    public static string PreferenceFile(string privateRoot) => Path.Combine(privateRoot, "metal-folder.txt");

    /// <summary>选中的文件夹里依次找的位置（找不到时原样告诉玩家）。</summary>
    public static string[] Candidates(string folder) =>
        [Path.Combine(folder, "metal.exe"), Path.Combine(folder, "bin", "metal.exe"), Path.Combine(folder, "ios", "bin", "metal.exe")];

    /// <summary>找到 → metal.exe 所在目录；没有 → null。</summary>
    public static string? Resolve(string folder) =>
        Candidates(Path.GetFullPath(folder)).FirstOrDefault(File.Exists) is { } exe ? Path.GetDirectoryName(exe) : null;

    /// <summary>记下并立即生效（本进程环境变量）。</summary>
    public static void Save(string privateRoot, string binDir)
    {
        Directory.CreateDirectory(privateRoot);
        File.WriteAllText(PreferenceFile(privateRoot), binDir);
        Environment.SetEnvironmentVariable(Variable, binDir);
    }

    /// <summary>启动时读回上次指定的目录；文件不在 / 读不了就当没指定。</summary>
    public static void Load(string privateRoot)
    {
        try
        {
            var dir = File.ReadAllText(PreferenceFile(privateRoot)).Trim();
            if (dir.Length > 0) Environment.SetEnvironmentVariable(Variable, dir);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}
