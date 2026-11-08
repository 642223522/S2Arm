import XCTest
@testable import S2ArmLauncher

// 审计 P1-3 / 18:00 P1-2：等文件夹授权期间界面常驻写明在等什么（不走 6 秒自动消失的普通提示），期间再放进来的排队、不丢。期望手算：两份都读不了（不存在的路径）→
//   第一份起查时 notice 为空、常驻条写「正在等系统允许读取「missing-a」」；第二份进队列、常驻条加「1 批会在它之后接着导入」；
//   两份都查完后报错落在第二份「b」、常驻条消失
@MainActor final class AccessWaitTests: XCTestCase {
    func testSecondDropWhileWaitingIsQueuedNotDropped() {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-access-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root)
        let a=root.appendingPathComponent("missing-a"), b=root.appendingPathComponent("missing-b")
        store.readThenImport([a], prepare:false)
        XCTAssertNil(store.notice, "等待不走 6 秒普通提示")
        XCTAssertTrue(store.accessWaitNotice?.contains("正在等系统允许读取「missing-a」") == true, store.accessWaitNotice ?? "没有常驻条")
        store.readThenImport([b], prepare:false)
        XCTAssertNil(store.notice)
        XCTAssertTrue(store.accessWaitNotice?.contains("1 批会在它之后接着导入") == true, store.accessWaitNotice ?? "没有常驻条")
        let done=expectation(description:"两份都查完")
        func poll() { if store.waitingForAccess == nil && store.error?.contains("missing-b") == true { done.fulfill() } else { DispatchQueue.main.asyncAfter(deadline:.now() + 0.05, execute:poll) } }
        poll()
        wait(for:[done], timeout:10)
        XCTAssertNil(store.waitingForAccess)
        XCTAssertNil(store.accessWaitNotice, "授权查完才收")
    }
}
