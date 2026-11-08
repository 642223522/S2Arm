import XCTest
@testable import S2ArmLauncher

/// 放进来的游戏先由 App 读一下：读不了的报出来，能读的放行（期望按文件系统事实手写）
@MainActor final class ImportReadableTests: XCTestCase {
    func testUnreadableReportsMissingAndPassesReadable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-readable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.nsp"); try Data([1, 2, 3]).write(to: file)
        let missing = dir.appendingPathComponent("不存在.xci")
        XCTAssertNil(Store.unreadable([file, dir]))
        XCTAssertEqual(Store.unreadable([file, missing]), missing)
        // 没有读权限的文件（chmod 000）也要报出来
        let locked = dir.appendingPathComponent("locked.nsp"); try Data([9]).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        XCTAssertEqual(Store.unreadable([locked]), locked)
    }
}
