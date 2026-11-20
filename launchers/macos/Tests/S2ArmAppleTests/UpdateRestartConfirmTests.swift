// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// 「重启以更新」时有局 / 任务在跑：不再只能等，先说清会打断什么、玩家点「仍然重启」照样换版（11-18 维护者：认得出的风险让玩家确认后继续）。
//   期望手写：点重启 → 出确认（不换版）→ 选「仍然重启」→ 停掉在跑的局、真的交给换版；选「取消」什么都不发生。
@MainActor final class UpdateRestartConfirmTests: XCTestCase {
    private final class FakeInstaller: LauncherUpdateDriver {
        var readyToInstall = true
        var downloadBytes: (received: UInt64, expected: UInt64) { (0, 0) }
        private(set) var installs = 0
        func check(current: String, fresh: Bool) async -> [String: Any]? { nil }
        func startDownload() {}
        func installNow() { installs += 1 }
    }
    private final class IdleRunner: JobProcessRunner {
        final class Handle: JobProcessHandle { func terminate() {} }
        func start(executable: URL, arguments: [String], environment: [String: String],
                   onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
            DispatchQueue.main.async { onLine(Data("{}".utf8)); onExit(0) }
            return Handle()
        }
    }

    private func model() throws -> (S2ArmLauncherModel, FakeInstaller, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-update-confirm-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let m = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: IdleRunner()))
        let fake = FakeInstaller()
        m.updateDriver = fake
        return (m, fake, root)
    }

    func testPlayingThenConfirmRestartReallyInstalls() throws {
        let (m, fake, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        m.playSession = JobSession(kind: .play, gameID: "0100ABC", name: "Original Game")   // 一局在游戏槽
        XCTAssertTrue(m.busy)

        m.restartToUpdate()
        XCTAssertEqual(m.updateGate, "update.gate.confirm", "有局在跑：先出确认")
        XCTAssertEqual(fake.installs, 0, "确认前不换版")
        let zh = m.updateRestartImpactText { BackendText.launcherText($0, language: "zh-Hans") }
        XCTAssertEqual(zh, "正在玩的「Original Game」会被关掉，没存的进度会丢；可以先在游戏里存一下再重启。", "说清关掉的是哪款、会丢什么")

        m.restartToUpdate(confirmed: true)
        XCTAssertNil(m.updateGate, "选了「仍然重启」确认框收起")
        XCTAssertEqual(m.playSession?.phase, .stopping, "先停掉在跑的那局")
        XCTAssertEqual(fake.installs, 1, "真的交给换版")
    }

    func testCancelLeavesEverythingRunning() throws {
        let (m, fake, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        m.session = JobSession(kind: .export, gameID: "0100ABC", name: "Export Original Game")
        m.restartToUpdate()
        XCTAssertEqual(m.updateGate, "update.gate.confirm")
        let en = m.updateRestartImpactText { BackendText.launcherText($0, language: "en") }
        XCTAssertEqual(en, "\"Export Original Game\" will be interrupted; you can pick it up after the restart, and finished parts are kept.",
                       "出包被打断：写明重启后可以接着做")
        m.updateGate = nil   // 「取消」按钮做的就是这一步
        XCTAssertEqual(m.session?.phase, .running, "取消：任务照常跑")
        XCTAssertEqual(fake.installs, 0, "取消：不换版")
    }

    func testNothingRunningRestartsWithoutAsking() throws {
        let (m, fake, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        m.restartToUpdate()
        XCTAssertNil(m.updateGate, "没在跑东西：不问，直接换")
        XCTAssertEqual(fake.installs, 1)
    }
}
