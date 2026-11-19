// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// 维护者 11-11 装机原则：认得出的风险让玩家确认、确认了就装。作业层可确认继续的停装码（会挤掉别处装的游戏 / 存档没能备份 / 都要按新版重出）
//   在结局页里问「仍然继续 / 先不」；确认后同一请求带上对应参数重发，参数累积（先确认挤掉、再撞上备份失败，第三次重发两个都带）。期望手写
@MainActor final class PhoneConfirmTests: XCTestCase {
    func testInstallConfirmsAccumulate() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-confirm-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let runner = ConfirmRunner(codes: ["container_would_drop", "save_backup_failed"])
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        let game = GameSummary(id: "0100A", name: "示例游戏")
        model.install(game, device: "D1")
        for _ in 0..<300 where model.busy || model.dropConfirm == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let first = try XCTUnwrap(model.dropConfirm)
        XCTAssertEqual(first.code, "container_would_drop"); XCTAssertEqual(first.accept, ["acceptDropped"])
        model.confirmDrop(first)
        for _ in 0..<300 where model.busy || model.dropConfirm == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let second = try XCTUnwrap(model.dropConfirm)
        XCTAssertEqual(second.code, "save_backup_failed"); XCTAssertEqual(second.accept, ["acceptDropped", "acceptNoBackup"])
        model.confirmDrop(second)
        for _ in 0..<300 where model.busy || runner.installs.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.installs.count, 3)
        XCTAssertNil(runner.installs[0]["acceptDropped"])
        XCTAssertEqual(runner.installs[1]["acceptDropped"] as? Bool, true); XCTAssertNil(runner.installs[1]["acceptNoBackup"])
        XCTAssertEqual(runner.installs[2]["acceptDropped"] as? Bool, true); XCTAssertEqual(runner.installs[2]["acceptNoBackup"] as? Bool, true)
        XCTAssertEqual(runner.installs[2]["device"] as? String, "D1", "还是同一台")
        for _ in 0..<300 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.lastPhoneSession?.phase, .finished(.completed), "两次确认后装成")
    }

    // 删除前也要备份存档（作业层 installRemove 同样报 save_backup_failed）：原先删除只认 container_would_drop，
    //   「仍然继续」只带 acceptDropped，删前备份失败就在确认里来回转。期望：先确认挤掉、再确认没备份，第三次两个参数都带、删成
    func testRemoveConfirmsAccumulate() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-confirm-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let runner = ConfirmRunner(codes: ["container_would_drop", "save_backup_failed"])
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        let game = GameSummary(id: "0100A", name: "示例游戏")
        model.removeFromPhone(game, device: "D1")
        for _ in 0..<300 where model.busy || model.dropConfirm == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let first = try XCTUnwrap(model.dropConfirm)
        XCTAssertEqual(first.kind, .installRemove); XCTAssertEqual(first.accept, ["acceptDropped"])
        model.confirmDrop(first)
        for _ in 0..<300 where model.busy || model.dropConfirm == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let second = try XCTUnwrap(model.dropConfirm)
        XCTAssertEqual(second.code, "save_backup_failed"); XCTAssertEqual(second.accept, ["acceptDropped", "acceptNoBackup"])
        model.confirmDrop(second)
        for _ in 0..<300 where model.busy || runner.installs.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.installs.count, 3)
        XCTAssertEqual(runner.installs[2]["operation"] as? String, "installRemove")
        XCTAssertEqual(runner.installs[2]["acceptDropped"] as? Bool, true); XCTAssertEqual(runner.installs[2]["acceptNoBackup"] as? Bool, true)
        XCTAssertEqual(runner.installs[2]["device"] as? String, "D1", "还是同一台")
    }

    // 0.5.4 玩家卡住（11-17）：「更新 iPhone 上的 S2Arm」中途先记了一条警告（补着色器时盘满），再报可确认的 save_backup_failed。
    //   诊断列表里警告在前、停装码在后，界面原先取第一条当失败码，结局页认不出、只有「重试 / 改为导出自签包」。
    //   期望（手写）：确认框照出、结局页那单的失败码就是 save_backup_failed（PhoneJobPanel 按它出「仍然继续」）；点了带 acceptNoBackup 重跑同一台、更新成
    func testUpdateConfirmsAfterEarlierWarning() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-confirm-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let runner = ConfirmRunner(codes: ["save_backup_failed"], warning: "disk_full")
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        model.updatePhone(acceptStale: false, repack: [], language: "zh-Hans", device: "D1")
        for _ in 0..<300 where model.busy || model.dropConfirm == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let ask = try XCTUnwrap(model.dropConfirm, "更新失败时也要问「仍然继续」")
        XCTAssertEqual(ask.kind, .installUpdate); XCTAssertEqual(ask.code, "save_backup_failed"); XCTAssertEqual(ask.accept, ["acceptNoBackup"])
        for _ in 0..<300 where model.lastPhoneSession == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.lastPhoneSession?.kind, .installUpdate)
        XCTAssertEqual(model.lastPhoneSession?.failureCode, "save_backup_failed", "结局页按这单的失败码出确认，不能是前面那条警告的码")
        model.confirmDrop(ask)
        for _ in 0..<300 where model.busy || runner.installs.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.installs.count, 2)
        XCTAssertEqual(runner.installs[1]["operation"] as? String, "installUpdate")
        XCTAssertEqual(runner.installs[1]["acceptNoBackup"] as? Bool, true)
        XCTAssertEqual(runner.installs[1]["device"] as? String, "D1", "还是同一台")
        for _ in 0..<300 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.lastPhoneSession?.phase, .finished(.completed), "确认后更新成")
    }
}

/// 假作业进程：装机 / 删除请求按 codes 依次失败（每个码只在还没带对应参数时失败一次），之后成功
private final class ConfirmRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    var installs: [[String: Any]] = []
    let codes: [String]
    let warning: String?   // 失败前先记的一条警告诊断的码（模拟作业中途的警告排在停装码前面）
    init(codes: [String], warning: String? = nil) { self.codes = codes; self.warning = warning }
    static let param = ["container_would_drop": "acceptDropped", "save_backup_failed": "acceptNoBackup"]
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        objc_sync_enter(self); defer { objc_sync_exit(self) }   // 作业客户端在并发线程池里同时调 start：替身状态串行改（无锁并发追加数组会 SIGSEGV 带崩整个测试进程）
        var taskId = ""; var request: [String: Any] = [:]
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { request = r; taskId = r["taskId"] as? String ?? "" }
        var event: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": "succeeded", "result": [:], "message": ""]
        if ["install", "installRemove", "installUpdate"].contains(request["operation"] as? String ?? "") {
            installs.append(request)
            if let code = codes.first(where: { request[Self.param[$0]!] == nil }) {
                event = ["schema": 1, "taskId": taskId, "type": "result", "state": "failed", "result": [:], "message": "需要确认：\(code)",
                         "diagnostics": (warning.map { [["code": $0, "severity": "warning", "summary": $0]] } ?? []) + [["code": code, "severity": "error", "summary": code]]]
            }
        }
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(event["state"] as? String == "succeeded" ? 0 : 1) }
        return Handle()
    }
}
