// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import Testing
@testable import S2ArmShellHost

/// 主屏小组件的共享数据（WidgetFeed）：放哪几款、认哪个共享组、点封面的链接、写盘只在内容变了时写
struct WidgetFeedTests {
    func g(_ id: String, _ seconds: Int, _ last: Double) -> WidgetFeed.Game {
        WidgetFeed.Game(id: id, name: id, seconds: seconds, lastPlayed: last, cover: nil)
    }

    // 11-16 维护者：左边 = 最近玩的那款；右边 = 其余玩过的按游玩时长从长到短取 3 款（不算左边那款）
    @Test func picksLatestThenLongestPlayed() {
        let games = [g("A", 12 * 3600, 500), g("B", 46 * 3600, 300), g("C", 9 * 3600, 200), g("D", 30 * 3600, 100), g("E", 6 * 3600, 50)]
        let p = WidgetFeed.pick(games)
        #expect(p.main?.id == "A")
        #expect(p.side.map(\.id) == ["B", "D", "C"])
    }

    // 玩过的不够三款：没玩过的按库里顺序补；一款都没玩过时左边放库里第一款
    @Test func fillsWithUnplayedInLibraryOrder() {
        #expect(WidgetFeed.pick([g("A", 0, 0), g("B", 60, 10), g("C", 0, 0), g("D", 0, 0)]).side.map(\.id) == ["A", "C", "D"])
        let none = WidgetFeed.pick([g("X", 0, 0), g("Y", 0, 0)])
        #expect(none.main?.id == "X")
        #expect(none.side.map(\.id) == ["Y"])
        #expect(WidgetFeed.pick([]).main == nil)
    }

    // 只认 group.s2arm.widget 与 group.s2arm.widget.<10 位团队号>；签名工具给每个包另建的、以包名开头的缺省组不认
    @Test func picksOnlyTheSharedGroup() {
        #expect(WidgetFeed.pickGroup(["group.io.s2arm.games.d9g8my5fb5.D9G8MY5FB5", "group.s2arm.widget.D9G8MY5FB5"]) == "group.s2arm.widget.D9G8MY5FB5")
        #expect(WidgetFeed.pickGroup(["group.s2arm.widget"]) == "group.s2arm.widget")
        #expect(WidgetFeed.pickGroup(["group.s2arm.widget.extra.D9G8MY5FB5", "group.s2arm.widgetX"]) == nil)
        #expect(WidgetFeed.pickGroup([]) == nil)
    }

    @Test func playLinkRoundTrips() {
        let url = WidgetFeed.playURL("0100ABCDEF012345")!
        #expect(url.absoluteString == "s2arm://play/0100ABCDEF012345")
        #expect(WidgetFeed.gameID(fromPlayURL: url) == "0100ABCDEF012345")
        #expect(WidgetFeed.gameID(fromPlayURL: URL(string: "s2arm://play/zz")!) == nil)
        #expect(WidgetFeed.gameID(fromPlayURL: URL(string: "https://play/0100ABCDEF012345")!) == nil)
    }

    // 内容一样不重写（返回 false：调用方不叫小组件刷新）；库里没了的款，封面一并删
    @Test func writesOnlyWhenChangedAndDropsOldCovers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("widgetfeed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("covers"), withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("covers/OLD-1.jpg"))
        let feed = WidgetFeed.Feed(games: [g("A", 60, 1)])
        #expect(WidgetFeed.write(feed, covers: [:], to: dir))
        #expect(!WidgetFeed.write(feed, covers: [:], to: dir))
        #expect(WidgetFeed.read(from: dir) == feed)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("covers/OLD-1.jpg").path))
    }
}
