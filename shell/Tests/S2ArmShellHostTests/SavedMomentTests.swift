// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 游戏库「从这一刻继续」（0.6.0）：宿主模型从快照目录读存下的时刻与那一刻的画面。期望值直接取自写进去的文件：
//   清单「保存时刻」写多少秒就是多少；旧快照没有这一项就用图的修改时间；没有快照目录就没有时刻；图没变不重解（同一份 Artwork）。
import Foundation
import Testing
@testable import ShellUI
@testable import S2ArmShellHost

// 1×1 像素的 PNG
private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

@MainActor private func model(_ dirs: [String: URL], ids: [String], delete: ((String) -> Bool)? = nil) throws -> (S2ArmShellHostModel, () -> Void) {
    let suite = "s2a.test.moment.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let m = S2ArmShellHostModel(catalogue: Catalogue(tiles: ids.map { GameTile(id: $0, title: $0) }, problems: []),
                                stores: .init(game: { _ in nil }, app: defaults), installState: { _ in 1 }, gamesRoot: root,
                                snapshotDir: { id in dirs[id].flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }, deleteSnapshot: delete)
    return (m, { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) })
}

@MainActor @Test func savedMomentReadsSaveTimeAndPicture() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let withTime = base.appendingPathComponent("a"), oldStyle = base.appendingPathComponent("b")
    for d in [withTime, oldStyle] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    try Data("版本\t1\n程序号\t0100000000010000\n保存时刻\t1795071127\n完整\t1\n".utf8).write(to: withTime.appendingPathComponent("manifest.tsv"))
    try png.write(to: withTime.appendingPathComponent("thumb.png"))
    // 旧快照：清单没有「保存时刻」，只有整帧图；图的修改时间设成一个已知时刻
    try Data("版本\t1\n完整\t1\n".utf8).write(to: oldStyle.appendingPathComponent("manifest.tsv"))
    let frame = oldStyle.appendingPathComponent("a_last.png"); try png.write(to: frame)
    let mtime = Date(timeIntervalSince1970: 1_795_000_000)
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: frame.path)

    let (m, done) = try model(["A": withTime, "B": oldStyle], ids: ["A", "B", "C"]); defer { done() }
    let a = try #require(m.savedMoment("A"))
    #expect(a.savedAt == Date(timeIntervalSince1970: 1_795_071_127))
    #expect(a.picture != nil)
    let b = try #require(m.savedMoment("B"))
    #expect(b.savedAt == mtime)
    #expect(b.picture != nil)
    #expect(m.savedMoment("C") == nil)                 // 没有快照
    #expect(m.savedMoment("A") == a)                   // 图没变：同一份（不重解、界面不重画）

    m.refreshGameData()
    #expect(m.games.first { $0.id == "A" }?.game.moment == a)
    #expect(m.games.first { $0.id == "C" }?.game.moment == nil)
}

// 长按「删除这一刻」：显示的大小就是目录实际占的空间；删完这一款没有快照了，游戏库数据里随即去掉
@MainActor @Test func deletingSavedMomentClearsIt() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("mem"), withIntermediateDirectories: true)
    try Data("保存时刻\t1795071127\n完整\t1\n".utf8).write(to: dir.appendingPathComponent("manifest.tsv"))
    try png.write(to: dir.appendingPathComponent("thumb.png"))
    try Data(count: 3 << 20).write(to: dir.appendingPathComponent("mem/0000.bin"))   // 3 MB 内存块
    var deleted: [String] = []
    let (m, done) = try model(["A": dir], ids: ["A"], delete: { id in deleted.append(id); try? FileManager.default.removeItem(at: dir); return true })
    defer { done() }
    m.refreshGameData()
    let before = try #require(m.games.first { $0.id == "A" }?.game.moment)
    #expect(before.bytes >= 3 << 20)                     // 至少那 3 MB
    m.deleteSnapshot("A")
    #expect(deleted == ["A"])
    #expect(m.games.first { $0.id == "A" }?.game.moment == nil)
}
