import XCTest
@testable import S2ArmAppleAdapter

/// 游戏库「玩了 12 小时 · 昨天」（GamePlaytime.summary）：期望值按规则手算（分钟向下取整至少 1；满 1 小时按 0.1 小时向下取、10 小时起取整；
/// 按本机时区比日历日），文案用真共享表（BackendText.launcherText）。
final class PlaytimeTests: XCTestCase {
    private var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }()
    /// 2026-11-16 09:00 北京时间
    private let now = Date(timeIntervalSince1970: 1_794_790_800)

    private func line(_ seconds: Int, lastAgo: TimeInterval = 0, lang: String = "zh-Hans") -> String {
        GamePlaytime(seconds: seconds, lastPlayed: now.timeIntervalSince1970 - lastAgo)
            .summary(now: now, calendar: cal, locale: Locale(identifier: lang), text: { BackendText.launcherText($0, language: lang) })
    }

    func testDuration() {
        XCTAssertEqual(line(59), "玩了 1 分钟 · 今天")              // 不满 1 分钟按 1 分钟
        XCTAssertEqual(line(45 * 60 + 59), "玩了 45 分钟 · 今天")
        XCTAssertEqual(line(60 * 60), "玩了 1 小时 · 今天")          // 1.0 去掉 .0
        XCTAssertEqual(line(90 * 60), "玩了 1.5 小时 · 今天")
        XCTAssertEqual(line(599 * 60 + 59), "玩了 9.9 小时 · 今天")  // 9 小时 59 分：5990/60 = 99 个 0.1 小时
        XCTAssertEqual(line(600 * 60), "玩了 10 小时 · 今天")
        XCTAssertEqual(line(12 * 3600 + 59 * 60), "玩了 12 小时 · 今天")
    }

    func testDay() {
        XCTAssertEqual(line(600, lastAgo: 8 * 3600 + 50 * 60), "玩了 10 分钟 · 今天")   // 当天 00:10
        XCTAssertEqual(line(600, lastAgo: 9 * 3600 + 30 * 60), "玩了 10 分钟 · 昨天")   // 前一天 23:30（跨天）
        XCTAssertEqual(line(600, lastAgo: 3 * 86400), "玩了 10 分钟 · 3 天前")
        XCTAssertEqual(line(600, lastAgo: -7200), "玩了 10 分钟 · 今天")               // 改过时钟、时刻在未来
    }

    func testOtherLanguages() {
        XCTAssertEqual(line(90 * 60, lastAgo: 86400, lang: "en"), "Played 1.5 h · yesterday")
        XCTAssertEqual(line(90 * 60, lastAgo: 86400, lang: "fr"), "1,5 h de jeu · hier")   // 法语小数逗号
    }

    func testCatalog() {
        XCTAssertNil(GamePlaytime(catalog: nil))
        XCTAssertNil(GamePlaytime(catalog: ["seconds": 0, "lastPlayed": 1]))
        XCTAssertEqual(GamePlaytime(catalog: ["seconds": 125, "lastPlayed": 1_794_790_800]), GamePlaytime(seconds: 125, lastPlayed: 1_794_790_800))
    }
}
