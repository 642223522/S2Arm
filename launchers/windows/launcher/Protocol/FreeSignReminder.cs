// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
namespace S2Arm.Launcher.Protocol;

/// <summary>「免费签名到期提醒」开关（缺省开）：启动器数据目录里有 free-sign-reminder.off 即关（同 home-widget.off 的存法，同 Mac S2AFreeSignReminderOff）。
/// 游戏库卡片状态行旁的「×」= 关掉，不再显示「还有几天 / 已到期」；设置里重新打开恢复。重启启动器照旧</summary>
public static class FreeSignReminder
{
    public const string OffFile = "free-sign-reminder.off";

    public static bool On(string privateRoot) => !File.Exists(Path.Combine(privateRoot, OffFile));

    /// <summary>写不进去照实抛（IOException / UnauthorizedAccessException），界面显示原因</summary>
    public static void Set(string privateRoot, bool on)
    {
        PrivateJobRequest.EnsurePrivateRoot(privateRoot);
        var path = Path.Combine(privateRoot, OffFile);
        if (on) File.Delete(path); else File.WriteAllBytes(path, []);
    }
}
