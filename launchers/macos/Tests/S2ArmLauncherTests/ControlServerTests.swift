import XCTest
import AppKit
@testable import S2ArmLauncher

// 审计 18:00 P2-35：控制口令牌与 control.json 失败不当成功
@MainActor final class ControlServerTests: XCTestCase {
    // 期望手算：随机源返回 errSecAllocate(-108) → 抛错，不出全 0 令牌；随机源填 1…16 → "0102…0f10"
    func testTokenFailureThrowsInsteadOfZeros() throws {
        XCTAssertThrowsError(try ControlServer.makeToken { _ in errSecAllocate })
        let token = try ControlServer.makeToken { b in for i in b.indices { b[i] = UInt8(i + 1) }; return errSecSuccess }
        XCTAssertEqual(token, "0102030405060708090a0b0c0d0e0f10")
    }
    // 期望：<私有目录>/control.json 预先是个文件夹 → 写不上 → 控制口不算开（shared 为空）、报错给玩家、开关退回关
    func testControlFileWriteFailureIsNotOpen() {
        _ = NSApplication.shared
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-ctl-"+UUID().uuidString)
        try? FileManager.default.createDirectory(at:root.appendingPathComponent("control.json"),withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root)
        store.preferences.aiControl=true
        ControlServer.start(store:store)
        let end=Date().addingTimeInterval(5)
        while Date()<end && store.error==nil && (ControlServer.shared?.port ?? 0)==0 { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
        RunLoop.main.run(until:Date().addingTimeInterval(0.2))
        XCTAssertNil(ControlServer.shared, "control.json 写不上就不算开")
        XCTAssertTrue(store.error?.contains("control.json") == true, store.error ?? "没报错")
        XCTAssertEqual(store.preferences.aiControl, false)
        ControlServer.stop(store:store)
    }
}
