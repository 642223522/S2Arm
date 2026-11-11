import XCTest
import AppKit
import Combine
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

// 游戏库刷新失败（P1-148）：启动先显示的上次列表要一直标成「上次的」，并带上失败原因给库页提示条；没有上次列表时不出这条提示。
// 资源目录是空的临时目录：catalog 作业起不来，必然走失败分支（不依赖真后端）。
@MainActor final class LibraryStaleTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-stale-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("jobs"), withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func model(snapshot: Bool) throws -> S2ArmLauncherModel {
        if snapshot {
            let saved = #"{"libraryId":"lib-1","result":{"games":[{"id":"0100A","name":"Alpha","ready":true,"missing":[]}],"keys":{}}}"#
            try Data(saved.utf8).write(to: root.appendingPathComponent("library-snapshot.json"))
        }
        return S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "lib-1")))
    }

    private func settle(_ m: S2ArmLauncherModel) async {
        for _ in 0..<200 where m.loading { try? await Task.sleep(nanoseconds: 25_000_000) }
    }

    func testFailedRefreshKeepsSnapshotMarkedAsLastTime() async throws {
        let m = try model(snapshot: true)
        m.refresh()
        XCTAssertEqual(m.games.map(\.id), ["0100A"], "先显示上次的列表")
        XCTAssertTrue(m.showingSnapshot)
        await settle(m)
        XCTAssertFalse(m.loading)
        XCTAssertNotNil(m.libraryError)
        XCTAssertEqual(m.games.map(\.id), ["0100A"], "失败不清空列表")
        XCTAssertTrue(m.showingSnapshot, "失败后仍标成上次的列表")
        XCTAssertEqual(m.staleLibraryError, m.libraryError)
    }

    // 剃刀 M8：正在列时又要刷新，不再丢掉——这一轮列完再补列一次；期间挂的回调归补的那一轮。期望手写：加载开始 2 次，回调各 1 次、按先后
    func testRefreshDuringLoadIsQueuedNotDropped() async throws {
        // 假作业：睡 0.3 秒、不出结果就退出（列表作业真的「在列」一段时间再失败，不依赖真后端）
        let jobs = root.appendingPathComponent("Jobs"); try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try Data("import time\ntime.sleep(0.3)\n".utf8).write(to: jobs.appendingPathComponent("main.py"))
        let m = try model(snapshot: false)
        var starts = 0, order: [String] = []
        let watch = m.$loading.sink { if $0 { starts += 1 } }
        m.refresh { order.append("first:\(starts)") }
        XCTAssertTrue(m.loading)
        m.refresh { order.append("second:\(starts)") }   // 列的过程中又要刷新
        for _ in 0..<400 where order.count < 2 || m.loading { try? await Task.sleep(nanoseconds: 25_000_000) }
        watch.cancel()
        XCTAssertEqual(starts, 2, "补列了一次")
        XCTAssertEqual(order, ["first:1", "second:2"], "第二个回调等补的那一轮列完才调")
    }

    func testFailureWithoutSnapshotShowsNoStaleBanner() async throws {
        let m = try model(snapshot: false)
        m.refresh()
        await settle(m)
        XCTAssertNotNil(m.libraryError)
        XCTAssertFalse(m.showingSnapshot)
        XCTAssertNil(m.staleLibraryError, "没有上次的列表：走欢迎页的报错，不出「上次的列表」")
    }
}
