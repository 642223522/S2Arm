// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using S2Arm.Launcher.Protocol;

/// <summary>游戏库目录输入规范（LibraryFolderInput）：只管把输入转成绝对路径；期望按规则手写；按当前系统的路径写法各测一遍。</summary>
internal static class LibraryFolderCases
{
    public static void Run(Action<bool, string> check)
    {
        var win = OperatingSystem.IsWindows();
        string P(string w, string u) => win ? w : u;
        void Expect(string? input, string? folder, string? error, string what)
        {
            var r = LibraryFolderInput.Normalize(input);
            check(r.Folder == folder && r.ErrorKey == error, $"{what}: {input} → ({r.Folder}, {r.ErrorKey})");
        }
        // 玩家截图原样（末尾带分隔符）：转成规范路径交给作业层；「在启动器目录里」由 setup 拒收（剃刀 W19，pack/jobs/tests/test_library_move.py）
        Expect(P(@"D:\WORK\NX2Apple-windows-x64\1\", "/work/NX2Apple-windows-x64/1/"), P(@"D:\WORK\NX2Apple-windows-x64\1", "/work/NX2Apple-windows-x64/1"), null, "末尾分隔符去掉");
        // 首尾空白与引号去掉
        Expect(P(@"  ""E:\Games\S2Arm\"" ", " \"/games/S2Arm/\" "), P(@"E:\Games\S2Arm", "/games/S2Arm"), null, "末尾分隔符与引号");
        Expect("", null, "library.folder_empty", "空");
        Expect("   ", null, "library.folder_empty", "只有空白");
        Expect(P(@"E:\", "/"), P(@"E:\", "/"), null, "盘根留着分隔符，交作业层拒收");
        Expect(P(@"E:\a<b", "/a|b\0c"), null, "library.folder_invalid", "非法字符");
    }
}
