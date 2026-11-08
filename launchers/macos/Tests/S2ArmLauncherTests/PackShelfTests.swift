import XCTest
@testable import S2ArmLauncher

/// 已出好的 iPhone 包（PackShelf.scan，11-01 维护者 转测试开发者反馈）：数据从产物读；同款多版本新在前；产物已删只留重出；游戏不在库里回退占位图标
final class PackShelfTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-shelf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("iPhone"), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    private func ipa(_ gid: String, _ name: String, bytes: Int = 100) throws -> URL {
        let d = root.appendingPathComponent("iPhone/\(gid)"); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let u = d.appendingPathComponent(name); try Data(count: bytes).write(to: u); return u
    }
    private func game(_ id: String) -> Game { Game(id: id, name: "游戏 " + id, display: "1.0", packages: [], hidden: false) }
    // 出包时间由假读取给（Info.plist S2APackTime）；名字里带的时刻 = 期望顺序，手写
    private let times = ["a1.ipa": "2026-11-01T10:00:00Z", "a2.ipa": "2026-11-01T12:00:00Z", "b1.ipa": "2026-11-01T13:00:00Z"]
    private func ev(_ u: URL) -> PackGraphicsEvidence {
        var e = PackGraphicsEvidence(); e.mode = .direct; e.packTime = times[u.lastPathComponent]; return e
    }

    func testVersionsNewestFirstAndEntriesSortedByLatest() throws {
        _ = try ipa("A", "a1.ipa"); _ = try ipa("A", "a2.ipa"); _ = try ipa("B", "b1.ipa")
        let shelf = PackShelf.scan(library: root, games: [game("A"), game("B")], tasks: [], evidence: ev)
        XCTAssertEqual(shelf.map(\.gameId), ["B", "A"], "按最近出包时间排，新的在前")
        XCTAssertEqual(shelf[1].versions.map { $0.ipa.lastPathComponent }, ["a2.ipa", "a1.ipa"], "同款多版本：最新的在前，旧版本可展开")
        XCTAssertEqual(shelf[1].latest?.mode, .direct)
    }

    func testPackBytesIncludeResourcePackIndex() throws {
        _ = try ipa("A", "a1.ipa", bytes: 100)
        let pack = root.appendingPathComponent("iPhone/A/游戏资源包"); try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try "romfs/x\t1000\th\nromfs/y\t24\th\n".write(to: pack.appendingPathComponent("index.tsv"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PackShelf.scan(library: root, games: [game("A")], tasks: [], evidence: ev).first?.latest?.bytes, 1124, "IPA 100 + 资源包 1000 + 24")
    }

    func testCleanedProductKeepsOnlyRepackCard() {
        var t = TaskRecord(id: "t1", operation: "ipa", state: "completed", gameId: "C", started: 1); t.ended = 1_700_000_000
        var gone = TaskRecord(id: "t2", operation: "ipa", state: "completed", gameId: "D", started: 1); gone.ended = 1_700_000_100
        let shelf = PackShelf.scan(library: root, games: [game("C")], tasks: [t, gone], evidence: ev)
        XCTAssertEqual(shelf.map(\.gameId), ["C"], "产物已删、游戏还在：留卡；游戏也不在库里：不留卡")
        XCTAssertTrue(shelf[0].versions.isEmpty); XCTAssertNil(shelf[0].latest, "没有版本 = 不给装机 / 查看产物这些死按钮")
        XCTAssertEqual(shelf[0].cleanedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testGameMissingFromLibraryFallsBackToPlaceholder() throws {
        _ = try ipa("Z", "a1.ipa")
        let e = try XCTUnwrap(PackShelf.scan(library: root, games: [], tasks: [], evidence: ev).first)
        XCTAssertNil(e.game, "游戏不在当前库：没有封面，用占位图标"); XCTAssertEqual(e.name, "Z")
    }

    func testMissingPackTimeFallsBackToFileDate() throws {
        let u = try ipa("A", "nodate.ipa")
        let d = Date(timeIntervalSince1970: 1_700_000_500); try FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: u.path)
        XCTAssertEqual(PackShelf.scan(library: root, games: [game("A")], tasks: [], evidence: ev).first?.latest?.date, d, "Info.plist 没有出包时间：用文件修改时间")
    }
}
