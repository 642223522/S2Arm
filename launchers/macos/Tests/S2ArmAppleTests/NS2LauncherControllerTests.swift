import XCTest
@testable import NX2AppleUI

// 手柄弹窗标题照连接程序报的型号写（#520）。期望按 ns2_kind 数值手写：1 Pro、2 Joy-Con 左、3 右、4 左右一对；
//   没连 / 旧连接程序没报 kind 时写通用的 Switch 手柄 / Switch Controller
final class NS2LauncherControllerTests: XCTestCase {
    func testTitleFollowsKind() {
        XCTAssertEqual(NS2LauncherController.title(kind: 2, simplifiedChinese: true), "Joy-Con 2 (L)")
        XCTAssertEqual(NS2LauncherController.title(kind: 3, simplifiedChinese: false), "Joy-Con 2 (R)")
        XCTAssertEqual(NS2LauncherController.title(kind: 4, simplifiedChinese: true), "Joy-Con 2 (L + R)")
        XCTAssertEqual(NS2LauncherController.title(kind: 1, simplifiedChinese: true), "Switch 2 Pro")
        XCTAssertEqual(NS2LauncherController.title(kind: 0, simplifiedChinese: true), "Switch 手柄")
        XCTAssertEqual(NS2LauncherController.title(kind: 0, simplifiedChinese: false), "Switch Controller")
    }

    func testKindFromStatusLine() throws {
        let line = #"{"status":4,"message":"","name":"Joy-Con 2 (R)","identifier":"x","kind":3}"#
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(NS2LauncherController.kind(from: object), 3)
        XCTAssertEqual(NS2LauncherController.kind(from: ["status": 4]), 0, "旧连接程序没报 kind")
    }

    // 剃刀 M16：停连接程序不再在主线程无上限 waitUntilExit。期望按信号语义手写：
    //   ① 收到 SIGTERM 就退的子进程：terminate 回来时已退出、没动用 SIGKILL，用时远小于宽限
    //   ② 忽略 SIGTERM 的子进程（trap '' TERM）：宽限 0.5 秒到点 SIGKILL，回来时已退出，用时在 [0.5, 0.5 + 2) 秒内（改前会一直等下去）
    func testTerminateIsBounded() throws {
        func spawn(_ script: String) throws -> Process {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", script]; try p.run(); usleep(200_000); return p
        }
        let polite = try spawn("sleep 30")
        var t0 = Date()
        XCTAssertFalse(NS2LauncherController.terminate(polite, grace: 0.5), "SIGTERM 就退，不该动用 SIGKILL")
        XCTAssertFalse(polite.isRunning); XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
        let stubborn = try spawn("trap '' TERM; while :; do sleep 0.05; done")
        t0 = Date()
        XCTAssertTrue(NS2LauncherController.terminate(stubborn, grace: 0.5), "忽略 SIGTERM 的要到点 SIGKILL")
        let took = Date().timeIntervalSince(t0)
        XCTAssertFalse(stubborn.isRunning); XCTAssertGreaterThanOrEqual(took, 0.5); XCTAssertLessThan(took, 2.5)
    }
}
