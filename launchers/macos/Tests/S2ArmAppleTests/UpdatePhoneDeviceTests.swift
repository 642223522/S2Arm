// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// 「更新 iPhone 上的 S2Arm」连着多台 iPhone 时要说清更新哪台（v0.3.0 验收测出：原先不传 device，作业层报「连着不止一台」）：
//   给了 device → installUpdate 请求里带上它；没给时用壳旧的那台 / 玩家选的那台，都没有就不带（作业层拒绝，11-11 设备号贯穿所有装机入口）
@MainActor final class UpdatePhoneDeviceTests: XCTestCase {
    func testUpdatePhonePassesTheChosenDevice() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-upd-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let runner = RequestRunner()
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        for device in ["00008160-FIXTURE", nil] as [String?] {
            model.updatePhone(acceptStale: false, repack: [], language: "zh-Hans", device: device)
            for _ in 0..<300 where model.busy || runner.updates.count < (device == nil ? 2 : 1) { try? await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(runner.updates.count, 2)
        XCTAssertEqual(runner.updates.first?["device"] as? String, "00008160-FIXTURE", "指定了哪台就带上哪台")
        XCTAssertNil(runner.updates.last?["device"], "既没壳旧的那台、也没选中 / 连着的设备时不带：作业层拒绝（device_required），不自己挑")
    }
}

private final class RequestRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    var updates: [[String: Any]] = []
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        var taskId = ""
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            taskId = request["taskId"] as? String ?? ""
            if request["operation"] as? String == "installUpdate" { updates.append(request) }
        }
        let event: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": "succeeded", "result": [:], "message": ""]
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(0) }
        return Handle()
    }
}
