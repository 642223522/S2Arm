// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
namespace S2Arm.Launcher.Protocol;

/// <summary>启动器界面语言（11-13）：第一次跟随系统；设置里选过就记住（私有目录 ui-language），以后不再跟系统；选「跟随系统」删掉记录、回到跟随。
/// 规则同 Mac（NXCore Lang.initial）与 iOS：按系统界面语言挑包里有文案的那门（繁中系统 → zh-Hant，日文系统 → ja …），都没有 → en（11-14 加新语言）。</summary>
public static class LauncherLanguage
{
    public const string FileName = "ui-language";
    /// <summary>可选的界面语言：zh-Hans / en 必有，其余是打进包的叠加文案（共享 l10n/<语言>.json，启动时 SetAvailable 登记）</summary>
    public static string[] Choices { get; private set; } = ["zh-Hans", "en"];

    public static void SetAvailable(IEnumerable<string> overlays) =>
        Choices = ["zh-Hans", "en", .. overlays.Where(o => o is not ("zh-Hans" or "en")).Distinct().Order(StringComparer.Ordinal)];

    /// <summary>系统界面语言名（CultureInfo.CurrentUICulture.Name，如 zh-CN / zh-TW / zh-Hant-HK / en-US / ja-JP）→ 启动器语言</summary>
    public static string FromCulture(string culture)
    {
        var c = culture.ToLowerInvariant();
        if (c.StartsWith("zh"))
        {
            var hant = c.StartsWith("zh-hant") || c is "zh-tw" or "zh-hk" or "zh-mo" or "zh-cht";
            return hant && Choices.Contains("zh-Hant") ? "zh-Hant" : "zh-Hans";
        }
        var primary = c.Split('-')[0];
        return Choices.FirstOrDefault(x => x.Equals(primary, StringComparison.OrdinalIgnoreCase)) ?? "en";
    }

    /// <summary>设置里选过的语言；没选过 / 选了「跟随系统」/ 读不出 → null</summary>
    public static string? Saved(string privateRoot)
    {
        try { var v = File.ReadAllText(Path.Combine(privateRoot, FileName)).Trim(); return Array.IndexOf(Choices, v) >= 0 ? v : null; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    /// <summary>记住选择；null = 跟随系统（删掉记录）</summary>
    public static void Save(string privateRoot, string? code)
    {
        var file = Path.Combine(privateRoot, FileName);
        if (code is null) { File.Delete(file); return; }
        if (Array.IndexOf(Choices, code) < 0) throw new ArgumentException("Unknown launcher language.", nameof(code));
        Directory.CreateDirectory(privateRoot);
        File.WriteAllText(file, code);
    }

    /// <summary>启动时用哪种：选过的优先，否则跟系统</summary>
    public static string Resolve(string privateRoot, string culture) => Saved(privateRoot) ?? FromCulture(culture);
}
