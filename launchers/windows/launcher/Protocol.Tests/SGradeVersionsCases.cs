// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using S2Arm.Launcher.Protocol;

// S 级升级页「补丁是别的版本的」写哪个版本（维护者 11-15）：期望按规则手写。
public static class SGradeVersionsCases
{
    public static void Run(Action<bool, string> check)
    {
        check(SGradeVersions.Pick(["1.0.0", "1.1.0", "1.0.4"], "1.0.2") == ("1.0.4", true), "sgrade versions: nearest newer one");
        check(SGradeVersions.Pick(["1.0.0", "1.2.0"], "1.3.0") == ("1.2.0", false), "sgrade versions: only older ones -> the newest older one, no downgrade advice");
        check(SGradeVersions.Pick(["1.10"], "1.9") == ("1.10", true), "sgrade versions: compared by segment (1.10 > 1.9)");
        check(SGradeVersions.Pick([], "1.0") is null, "sgrade versions: nothing to say");
    }
}
