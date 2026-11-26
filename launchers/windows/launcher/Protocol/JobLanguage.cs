// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
namespace S2Arm.Launcher.Protocol;

/// 启动器当前界面语言（zh-Hans / en）：LibraryJobClient / PackJobClient 拼的每个作业请求都带 uiLanguage，作业层（pack/jobs）据此出玩家看得到的
///   文件名与说明（自签导出的文件夹「S2Arm 自签导出」/「S2Arm Self-Sign Export」与安装说明等）。主窗口切语言时写（EnvironmentWindow.language）
public static class JobLanguage
{
    public static string Current { get; set; } = "zh-Hans";
    internal static void Stamp(IDictionary<string, object?> payload)
    {
        // 界面语言照原样带、由作业层认（中文界面中文定名，其余英文）。原先只带 zh-Hans / en，法 / 日 / 西 / 繁中界面不带、作业层回落成中文（#502，11-16 维护者）
        if (!string.IsNullOrEmpty(Current) && !payload.ContainsKey("uiLanguage")) payload["uiLanguage"] = Current;
    }
}
