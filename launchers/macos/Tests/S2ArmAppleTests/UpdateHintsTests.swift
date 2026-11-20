// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// 0.6.0「建议更新」（通用壳开关后面）：启动器读作业 updateHints，对不上的款封面出角标、选中写原因 +「更新这款」。期望手写：
//   开关开着 → 按游戏号（不分大小写）给出原因，原因为空的款不算；开关关着 → 什么都没有（界面同 0.5.x）；
//   原因只认 rewriter / hostAbi / shader 三种，各对应一句共享文案（六种语言）
@MainActor final class UpdateHintsTests: XCTestCase {
    private func model(_ result: [String: Any]) throws -> (S2ArmLauncherModel, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-hints-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let m = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: HintsRunner(result: result)))
        return (m, root)
    }

    func testReasonsPerGame() async throws {
        let (m, root) = try model(["games": [["gameId": "0100abc", "reasons": ["shader", "hostAbi"]], ["gameId": "0100DEF", "reasons": [String]()]]])
        defer { try? FileManager.default.removeItem(at: root) }
        m.refreshUpdateHints()
        for _ in 0..<300 where m.updateHints.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(m.updateReasons(GameSummary(id: "0100ABC", name: "A")), ["shader", "hostAbi"], "游戏号不分大小写")
        XCTAssertEqual(m.updateReasons(GameSummary(id: "0100DEF", name: "B")), [], "原因为空不算建议更新")
        XCTAssertEqual(m.updateReasons(GameSummary(id: "0100XYZ", name: "C")), [], "不在表里的款没有提示")
    }

    func testNothingWhenResultHasNoGames() async throws {
        let (m, root) = try model([:])
        defer { try? FileManager.default.removeItem(at: root) }
        m.updateHints = ["0100ABC": ["rewriter"]]   // 上一次的值：读到不带 games 的结果要清掉
        m.refreshUpdateHints()
        for _ in 0..<300 where !m.updateHints.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(m.updateHints, [:], "结果里没有 games 什么都不出")
    }

    func testReasonKeysHaveSharedText() {
        XCTAssertEqual(S2ArmLauncherModel.updateReasonKey("rewriter"), "update.hint.reason.rewriter")
        XCTAssertEqual(S2ArmLauncherModel.updateReasonKey("hostAbi"), "update.hint.reason.hostAbi")
        XCTAssertEqual(S2ArmLauncherModel.updateReasonKey("shader"), "update.hint.reason.shader")
        XCTAssertNil(S2ArmLauncherModel.updateReasonKey("other"), "不认识的原因不显示")
        for key in ["update.hint.badge", "update.hint.button", "update.hint.tail", "update.hint.reason.rewriter", "update.hint.reason.hostAbi", "update.hint.reason.shader"] {
            for lang in ["zh-Hans", "zh-Hant", "en", "ja", "es", "fr"] {
                XCTAssertFalse(BackendText.launcherText(key, language: lang).hasPrefix("["), "\(key) 缺 \(lang)")
            }
        }
        XCTAssertEqual(BackendText.launcherText("update.hint.badge", language: "zh-Hans"), "建议更新")
    }
}

/// 假作业进程：updateHints 回给定结果，其余作业照常成功
private final class HintsRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    let result: [String: Any]
    init(result: [String: Any]) { self.result = result }
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        objc_sync_enter(self); defer { objc_sync_exit(self) }   // 作业客户端在并发线程池里同时调 start：替身状态串行改（无锁并发追加数组会 SIGSEGV 带崩整个测试进程）
        var taskId = ""; var request: [String: Any] = [:]
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { request = r; taskId = r["taskId"] as? String ?? "" }
        let body: [String: Any] = request["operation"] as? String == "updateHints" ? result : [:]
        let event: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": "succeeded", "result": body, "message": ""]
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(0) }
        return Handle()
    }
}
