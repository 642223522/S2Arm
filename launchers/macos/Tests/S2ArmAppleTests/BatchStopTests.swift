import XCTest
import AppKit
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

// 剃刀 M7：批次记录没写成（batch.py 起不来 / 报错）→ 整批停住、批量页有原因；原先「继续 / 重试」点了没反应、mark 失败照样往下走。
// 资源目录是空的临时目录：批次脚本起不来（不依赖真后端）。期望手写
@MainActor final class BatchStopTests: XCTestCase {
    func testBatchCommandFailureStopsAndExplains() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-batchstop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("jobs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let m = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "lib-1")))
        m.resumeBatch()
        for _ in 0..<200 where m.batchError == nil { try? await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertEqual(m.batchError, "批次脚本没有回应")
        XCTAssertFalse(m.batchRunning, "没写成就不往下出")
        XCTAssertTrue(m.batchShown, "批量页打开说原因")
    }
}
