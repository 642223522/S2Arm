import XCTest
import AppKit
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

// 启动器剃刀 M6：启动时碰游戏库的作业一个接一个起。顺序靠 refresh(done) 在「这次列完」之后才回调来保证：
// 回调时 loading 必须已经是 false；列表还在列时再要一次，记一笔、这一轮列完补列一次，第二个回调在补的那一轮列完后调（剃刀 M8）。
// 资源目录里放一个睡 0.3 秒、不出结果的假作业：列表作业真的「在列」一段时间再失败（不依赖真后端；空目录时作业当场起不来、同步失败，测不到「在列」）。
@MainActor final class StartupOrderTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-startup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("jobs"), withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testRefreshCallsBackOnlyAfterListingEndsAndCoalescesWaiters() async throws {
        let jobs = root.appendingPathComponent("Jobs"); try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        try Data("import time\ntime.sleep(0.3)\n".utf8).write(to: jobs.appendingPathComponent("main.py"))
        let m = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "lib-1")))
        var calls: [(String, Bool)] = []
        m.refresh { calls.append(("first", m.loading)) }
        XCTAssertTrue(m.loading, "列表作业已起")
        m.refresh { calls.append(("second", m.loading)) }
        XCTAssertTrue(calls.isEmpty, "还在列：两个回调都不该先调")
        for _ in 0..<200 where m.loading || calls.count < 2 { try? await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertEqual(calls.map(\.0), ["first", "second"], "按登记顺序各调一次（第二个在补列那一轮之后）")
        XCTAssertEqual(calls.map(\.1), [false, false], "回调时列表作业已经结束，下一个作业不会和它并发")
    }
}
