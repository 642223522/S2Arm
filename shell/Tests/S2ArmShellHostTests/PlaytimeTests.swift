// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 游玩时间（11-15 维护者）：ShellFormat.playtime 的措辞与宿主模型读 playtime.json。期望值按规则手算
//   （分钟向下取整至少 1；满 1 小时按 0.1 小时向下取、10 小时起取整；按日历日比「今天 / 昨天 / N 天前」）。
import Foundation
import Testing
@testable import ShellUI
@testable import S2ArmShellHost

private let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }()
private let now = Date(timeIntervalSince1970: 1_794_790_800)   // 2026-11-16 09:00 北京时间

// 只核英文措辞：SwiftPM 命令行构建把 Localizable.xcstrings 原样拷进资源包、不编成各语言 .lproj，别的语言在这里取不到（真机截图核）
@MainActor private func line(_ seconds: Int, ago: TimeInterval = 0) -> String? {
    ShellFormat.playtime(seconds: seconds, lastPlayed: now.addingTimeInterval(-ago), now: now, calendar: cal, locale: Locale(identifier: "en"))
}

@MainActor @Test func playtimeDurationWording() {
    #expect(line(0) == nil)                                        // 没玩过不显示
    #expect(line(59) == "Played 1 min · today")                    // 不满 1 分钟按 1 分钟
    #expect(line(45 * 60 + 59) == "Played 45 min · today")
    #expect(line(60 * 60) == "Played 1 h · today")
    #expect(line(90 * 60) == "Played 1.5 h · today")
    #expect(line(599 * 60 + 59) == "Played 9.9 h · today")         // 5990 / 60 = 99 个 0.1 小时
    #expect(line(600 * 60) == "Played 10 h · today")
    #expect(line(12 * 3600 + 59 * 60) == "Played 12 h · today")
}

@MainActor @Test func playtimeDayWording() {
    #expect(line(600, ago: 8 * 3600 + 50 * 60) == "Played 10 min · today")     // 当天 00:10
    #expect(line(600, ago: 9 * 3600 + 30 * 60) == "Played 10 min · yesterday")  // 前一天 23:30（跨天）
    #expect(line(600, ago: 3 * 86400) == "Played 10 min · 3 days ago")
    #expect(line(600, ago: -7200) == "Played 10 min · today")                   // 时刻在未来（改过时钟）
}

@MainActor @Test func playtimeReadFromGameFolder() throws {
    let suite = "s2a.test.playtime.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let played = "0100000000010000", never = "0100000000020000"
    let dir = root.appendingPathComponent(played)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{\"schema\":1,\"seconds\":5400,\"lastPlayed\":\(Int(now.timeIntervalSince1970) - 86400)}\n".utf8).write(to: dir.appendingPathComponent("playtime.json"))
    let model = S2ArmShellHostModel(catalogue: Catalogue(tiles: [GameTile(id: played, title: "A"), GameTile(id: never, title: "B")], problems: []),
                                    stores: .init(game: { _ in nil }, app: defaults), installState: { _ in 1 }, gamesRoot: root)
    #expect(model.playtimeLine(played, now: now) != nil)
    #expect(model.playtimeLine(never, now: now) == nil)
    model.refreshGameData()
    #expect(model.games.first { $0.id == played }?.game.recentlyPlayed != nil)
    #expect(model.games.first { $0.id == never }?.game.recentlyPlayed == nil)
}
