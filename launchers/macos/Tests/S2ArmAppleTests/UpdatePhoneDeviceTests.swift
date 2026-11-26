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
        pinIosAfterPackInstall()
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

    /// 会挤掉别的电脑装的游戏（container_would_drop）：界面发起的弹确认、记着当时的设备；确认后带 acceptDropped 重发同一台。控制口发起的（ask: false）不弹
    func testUpdatePhoneAsksBeforeDroppingAndRetriesWithAcceptDropped() async throws {
        _ = NSApplication.shared
        pinIosAfterPackInstall()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-upd-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib"), withIntermediateDirectories: true)   // 游戏库文件夹在（更新后重读游戏库失败不能当成库没了，#1412）
        let runner = RequestRunner(); runner.dropFirst = 2
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        model.updatePhone(acceptStale: true, repack: [], language: "zh-Hans", device: "00008160-FIXTURE", ask: false)
        for _ in 0..<300 where model.busy || runner.updates.count < 1 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.dropConfirm, "控制口发起的不弹确认，原样失败")
        model.updatePhone(acceptStale: true, repack: [], language: "zh-Hans", device: "00008160-FIXTURE")
        for _ in 0..<300 where model.busy || model.dropConfirm == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let d = try XCTUnwrap(model.dropConfirm, "界面发起的弹确认")
        XCTAssertEqual(d.kind, .installUpdate); XCTAssertEqual(d.update?.device, "00008160-FIXTURE")
        XCTAssertNil(runner.updates[1]["acceptDropped"])
        model.confirmDrop(d)
        for _ in 0..<300 where model.busy || runner.updates.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(runner.updates.count, 3)
        XCTAssertEqual(runner.updates[2]["acceptDropped"] as? Bool, true, "确认后带 acceptDropped 重发")
        XCTAssertEqual(runner.updates[2]["acceptStale"] as? Bool, true)
        XCTAssertEqual(runner.updates[2]["device"] as? String, "00008160-FIXTURE", "还是同一台")
    }

    /// 覆盖装前存档备份做不成时，作业层看云存档里有没有这款的快照（pack/jobs/install.py cloud_save_copy）：玩家在环境页选了云存档文件夹 →
    ///   installUpdate 请求带 cloudSavesFolder；没选 → 不带（期望手写）
    func testUpdatePhonePassesCloudSavesFolder() async throws {
        _ = NSApplication.shared
        pinIosAfterPackInstall()
        for folder in ["cloud-fixture/S2Arm Saves", nil] as [String?] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-upd-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("apple-frontend"), withIntermediateDirectories: true)
            // 同真 App 写出的设置文件（SettingsProvider.write 总带 schema: 1；读的一方不认没有 schema 的文件，SettingsProvider.object）
            var settings: [String: Any] = ["schema": 1]
            if let folder { settings["cloudSavesFolder"] = folder }
            try JSONSerialization.data(withJSONObject: settings).write(to: root.appendingPathComponent("apple-frontend/launch-settings.json"))
            let runner = RequestRunner()
            let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
                privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
            model.updatePhone(acceptStale: false, repack: [], language: "zh-Hans", device: "00008160-FIXTURE")
            for _ in 0..<300 where model.busy || runner.updates.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(runner.updates.count, 1)
            XCTAssertEqual(runner.updates.first?["cloudSavesFolder"] as? String, folder, folder == nil ? "没选云存档文件夹就不带" : "选了就带上同一个路径")
        }
    }
}

private final class RequestRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    var updates: [[String: Any]] = []
    /// 前几次 installUpdate 以 container_would_drop 失败（不带 acceptDropped 时）
    var dropFirst = 0
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        objc_sync_enter(self); defer { objc_sync_exit(self) }   // 作业客户端在并发线程池里同时调 start：替身状态串行改（无锁并发追加数组会 SIGSEGV 带崩整个测试进程）
        var taskId = ""
        var isUpdate = false
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            taskId = request["taskId"] as? String ?? ""
            if request["operation"] as? String == "installUpdate" { updates.append(request); isUpdate = true }
        }
        let drop = isUpdate && updates.last?["acceptDropped"] == nil && dropFirst > 0
        if drop { dropFirst -= 1 }
        let event: [String: Any] = drop
            ? ["schema": 1, "taskId": taskId, "type": "result", "state": "failed", "result": [:], "message": "这次会让手机上的 1 款游戏暂时不能玩：外来款。",
               "diagnostics": [["code": "container_would_drop", "severity": "error", "summary": "这次会让手机上的 1 款游戏暂时不能玩：外来款。"]]]
            : ["schema": 1, "taskId": taskId, "type": "result", "state": "succeeded", "result": [:], "message": ""]
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(0) }
        return Handle()
    }
}
