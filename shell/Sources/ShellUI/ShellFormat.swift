import Foundation

/// The wording of the version and last-played line, shared by every view and by the host and the demo that fill it:
/// "Version 1.0.0", "Played today", "Played yesterday", "Played 3 days ago", joined as "Version 1.0.0 · Played today".
public enum ShellFormat {
    /// "Version 1.0.0", empty for an empty version.
    public static func version(_ version: String) -> String {
        version.isEmpty ? "" : ShellStrings.text("Version \(version)")
    }

    /// "Played today", "Played yesterday" or "Played <relative date>", by calendar days, not by 24 hour spans.
    public static func played(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return ShellStrings.text("Played today")
        case 1: return ShellStrings.text("Played yesterday")
        default:
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.unitsStyle = .full
            formatter.dateTimeStyle = .numeric
            let relative = formatter.localizedString(for: calendar.startOfDay(for: date), relativeTo: calendar.startOfDay(for: now))
            return ShellStrings.text("Played \(relative)")
        }
    }

    /// 游玩时间（11-15 维护者）：「玩了 12 小时 · 昨天」，没玩过（0 秒）为 nil。规则同 Mac（launchers/macos/adapter Playtime.swift summary）：
    ///   时长不满 1 小时按分钟（向下取整，至少 1）；满 1 小时按 0.1 小时向下取、10 小时起取整；哪天按本机日历日比
    ///   （同天「今天」、差 1 天「昨天」、再早「N 天前」，时刻在未来按「今天」）。数据是运行时写的 Documents/games/<游戏号>/playtime.json
    public static func playtime(seconds: Int, lastPlayed: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard seconds > 0 else { return nil }
        let minutes = seconds / 60
        let duration: String
        if minutes < 60 {
            duration = ShellStrings.text("Played \(String(max(1, minutes))) min")
        } else {
            let tenths = minutes * 10 / 60
            let f = NumberFormatter(); f.locale = locale; f.minimumFractionDigits = 0
            f.maximumFractionDigits = tenths < 100 ? 1 : 0; f.roundingMode = .down
            let n = f.string(from: NSNumber(value: tenths < 100 ? Double(tenths) / 10 : Double(minutes / 60))) ?? String(minutes / 60)
            duration = ShellStrings.text("Played \(n) h")
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastPlayed), to: calendar.startOfDay(for: now)).day ?? 0
        let when = days <= 0 ? ShellStrings.text("today") : days == 1 ? ShellStrings.text("yesterday") : ShellStrings.text("\(days) days ago")
        return metaLine(duration, when)
    }

    /// The parts that are not empty, joined by a middle dot.
    public static func metaLine(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "Version 1.0.0 · Played today": the version line with the last-played date when there is one.
    public static func versionLine(version v: String, lastPlayed: Date?, now: Date = Date(), calendar: Calendar = .current,
                                   locale: Locale = .current) -> String {
        metaLine(version(v), lastPlayed.map { played($0, now: now, calendar: calendar, locale: locale) })
    }
}
