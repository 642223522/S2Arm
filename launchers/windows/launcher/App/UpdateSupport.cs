// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Text;

namespace S2Arm.Launcher;

/// <summary>给 NetSparkle 的版本号：发版版本在 version.txt（bundle_win.py 写），程序集版本永远是 1.0.0.0</summary>
internal sealed class VersionAccessor(string version) : NetSparkleUpdater.Interfaces.IAssemblyAccessor
{
    public string AssemblyCompany => "S2Arm";
    public string AssemblyCopyright => "";
    public string AssemblyDescription => "";
    public string AssemblyTitle => "S2Arm";
    public string AssemblyProduct => "S2Arm";
    public string AssemblyVersion => version;
}

/// <summary>给 NetSparkle 的频道过滤（11-19）：正式版只收正式版；测试版（X.Y.Z-test.N）收同频道的预发布与正式版</summary>
internal static class ReleaseChannel
{
    /// <summary>版本号的预发布频道名（0.6.0-test.1 → test；正式版 → 空串）</summary>
    public static string Of(string version)
    {
        var dash = version.IndexOf('-');
        if (dash < 0) return "";
        var pre = version[(dash + 1)..];
        var dot = pre.IndexOf('.');
        return dot < 0 ? pre : pre[..dot];
    }

    public static NetSparkleUpdater.AppCastHandlers.ChannelAppCastFilter Filter(string version, NetSparkleUpdater.Interfaces.ILogger? log) =>
        new(log) { ChannelSearchNames = Of(version) is { Length: > 0 } c ? [c] : [], KeepItemsWithNoChannelInfo = true };
}

/// <summary>NetSparkle 的日志与换版每一步都记进 <私有目录>/logs/update.log（诊断包会收）</summary>
internal sealed class UpdateLog(string file) : NetSparkleUpdater.LogWriter
{
    public override void PrintMessage(string message, params object[]? arguments) =>
        Write(file, "[NetSparkle] " + (arguments is { Length: > 0 } ? string.Format(message, arguments) : message));

    public static void Write(string file, string line)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.AppendAllText(file, $"{DateTimeOffset.UtcNow:O} {line}{Environment.NewLine}", Encoding.UTF8);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}
