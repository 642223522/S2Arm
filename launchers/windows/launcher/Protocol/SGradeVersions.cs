// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
namespace S2Arm.Launcher.Protocol;

/// <summary>S 级「补丁是别的版本的」写哪个版本（维护者 11-15 定，同 Mac SGradeStateText.pick）：离玩家最近、且比它新的；全是旧的取最新的旧版本。版本号按段比（1.10 &gt; 1.9）</summary>
public static class SGradeVersions
{
    public static int Compare(string a, string b)
    {
        static int[] P(string s) => s.Split('.').Select(x => int.TryParse(x, out var n) ? n : 0).ToArray();
        var x = P(a); var y = P(b);
        for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
        {
            int p = i < x.Length ? x[i] : 0, q = i < y.Length ? y[i] : 0;
            if (p != q) return p < q ? -1 : 1;
        }
        return 0;
    }

    /// <summary>→ (版本, 是否比玩家新)；没有可选的 = null</summary>
    public static (string Version, bool Newer)? Pick(IEnumerable<string> available, string mine)
    {
        var all = available.Where(v => v.Length > 0).ToList();
        var newer = all.Where(v => Compare(v, mine) > 0).OrderBy(v => v, Comparer<string>.Create(Compare)).ToList();
        if (newer.Count > 0) return (newer[0], true);
        return all.Count == 0 ? null : (all.OrderBy(v => v, Comparer<string>.Create(Compare)).Last(), false);
    }
}
