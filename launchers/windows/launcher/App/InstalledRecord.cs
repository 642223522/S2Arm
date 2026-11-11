// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Microsoft.Win32;

namespace S2Arm.Launcher;

/// <summary>安装版（launchers/windows/installer，v0.3.0 起）：启动时把「设置 → 应用 → 已安装的应用」里 S2Arm 那一项的版本号写成当前版本。
/// 更新器只换壳（pack/jobs/updater.py 把安装目录整个换新）不经安装程序，那里原先会一直显示安装时的版本。
/// 只在这份启动器就是安装程序登记的那份时写（卸载项的 InstallLocation 等于本程序目录）；压缩包版（便携版）、别处的副本都不碰注册表。</summary>
public partial class EnvironmentWindow
{
    /// <summary>安装程序的 AppId（launchers/windows/installer/S2Arm.iss），定下就不改</summary>
    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\{E44C11E8-9CDE-42B0-BBF0-619FA69156F2}_is1";

    private static void SyncInstalledVersion()
    {
        if (!OperatingSystem.IsWindows() || AppVersion == "-") return;
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(UninstallKey, writable: true);
            if (key?.GetValue("InstallLocation") is not string location ||
                !string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(location)), InstallDir, StringComparison.OrdinalIgnoreCase)) return;
            var version = AppVersion.TrimStart('v');
            if (key.GetValue("DisplayVersion") as string == version) return;
            key.SetValue("DisplayVersion", version);
            key.SetValue("DisplayName", "S2Arm");
        }
        catch (Exception error) when (error is UnauthorizedAccessException or IOException or System.Security.SecurityException) { }   // 写不进只影响「已安装的应用」里显示的版本，不挡启动
    }
}
