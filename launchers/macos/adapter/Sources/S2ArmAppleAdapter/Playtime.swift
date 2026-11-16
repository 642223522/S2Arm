import Foundation

/// 一款在这台 Mac 上的游玩时间（catalog 的 playtime：运行时 runtime/src/playtime.c 写进游戏文件夹的 playtime.json，作业层原样转）。
/// 没玩过 catalog 不给这一项，界面什么都不显示。
public struct GamePlaytime: Equatable {
    public let seconds: Int
    /// 最近一次玩（Unix 秒）
    public let lastPlayed: Double

    public init(seconds: Int, lastPlayed: Double) { self.seconds = seconds; self.lastPlayed = lastPlayed }

    public init?(catalog p: [String: Any]?) {
        guard let p, let s = (p["seconds"] as? NSNumber)?.intValue, s > 0 else { return nil }
        self.init(seconds: s, lastPlayed: (p["lastPlayed"] as? NSNumber)?.doubleValue ?? 0)
    }

    /// 游戏库一行：「玩了 12 小时 · 昨天」。规则（三端同一份，iOS 见 ios/library.m s2a_playtime_text）：
    ///   时长：不满 1 小时按分钟（向下取整，至少 1 分钟）；满 1 小时按小时，不满 10 小时带一位小数（去掉 .0），10 小时起取整（向下）
    ///   哪天：按本机时区比日历日：同一天「今天」、差 1 天「昨天」、再早「N 天前」；时刻在未来（改过时钟）按「今天」
    /// text：按文案键取当前界面语言的模板（{0} 占位）；locale 决定小数点写法
    public func summary(now: Date, calendar: Calendar, locale: Locale, text: (String) -> String) -> String {
        let p = parts(now: now, calendar: calendar, locale: locale, text: text)
        return text(p.template).replacingOccurrences(of: "{0}", with: p.number) + " · " + p.when
    }

    /// 同 summary 的规则，拆成三块给要单独排版数字的地方（Mac 首页游玩时间）：时长模板的文案键、填进 {0} 的数、哪天
    public func parts(now: Date, calendar: Calendar, locale: Locale, text: (String) -> String) -> (template: String, number: String, when: String) {
        let minutes = seconds / 60
        let template: String, number: String
        if minutes < 60 {
            template = "library.playtime.minutes"; number = "\(max(1, minutes))"
        } else {
            let tenths = minutes * 10 / 60   // 向下取到 0.1 小时
            let f = NumberFormatter(); f.locale = locale; f.minimumFractionDigits = 0
            f.maximumFractionDigits = tenths < 100 ? 1 : 0; f.roundingMode = .down
            template = "library.playtime.hours"
            number = f.string(from: NSNumber(value: tenths < 100 ? Double(tenths) / 10 : Double(minutes / 60))) ?? "\(minutes / 60)"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date(timeIntervalSince1970: lastPlayed)),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let when = days <= 0 ? text("library.playtime.today") : days == 1 ? text("library.playtime.yesterday")
            : text("library.playtime.daysAgo").replacingOccurrences(of: "{0}", with: "\(days)")
        return (template, number, when)
    }
}
