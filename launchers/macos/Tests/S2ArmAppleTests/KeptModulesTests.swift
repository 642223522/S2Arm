// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import Foundation
import AppKit
import XCTest
@testable import NX2AppleUI
import S2ArmAppleAdapter

// 手机上宿主留下的代码模块（#8be819）与壳旧了（启动器升级）：2 分钟循环（S2ArmLauncherModel.keptModulesTick）只发现、重读游戏库亮「更新 iPhone」，
//   不发起装机（11-16 维护者：「改成更稳妥的手动更新吧，启动器和移动端都是」）——手机在线、有更新、没在玩、循环跑多轮，一次都不装
@MainActor final class KeptModulesTests: XCTestCase {
    func testTickNeverInstallsOnlyRefreshes() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-kept-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let runner = KeptRunner()
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        runner.kept = []
        let none = await model.keptModulesTick()
        XCTAssertFalse(none, "没有要补的款：不发起")
        runner.kept = ["0100C9C00E25C000"]; runner.running = true
        let playing = await model.keptModulesTick()
        XCTAssertFalse(playing, "手机上 S2Arm 正在跑：不推（装 App 会杀掉这局）")
        XCTAssertEqual(runner.updates.count, 0)
        runner.running = false
        let keptAfter = UserDefaults.standard.object(forKey: "S2AIosAfterPack")
        defer { UserDefaults.standard.set(keptAfter, forKey: "S2AIosAfterPack") }
        model.iosAfterPack = "export"
        let selfSign = await model.keptModulesTick()
        XCTAssertFalse(selfSign, "出包页选了导出自签：不自动装到手机（玩家选择优先）")
        XCTAssertEqual(runner.updates.count, 0)
        model.iosAfterPack = "install"
        runner.shellUpdate = true
        for round in 0..<5 {   // 手机在线、有没补进的款也壳旧了、没在玩：跑多轮
            let started = await model.keptModulesTick()
            for _ in 0..<30 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(started, "第 \(round + 1) 轮：只发现、不发起装机")
        }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runner.updates.count, 0, "循环跑多轮也不发 installUpdate（玩家点了才装）")
        XCTAssertGreaterThan(runner.catalogs, 0, "发现有要更新的：重读游戏库，顶栏按 phoneUpdates 亮「更新 iPhone」")
    }

    // 启动器升级后手机壳旧了（shellUpdate）：开关开 / 关、在玩 / 没在玩，循环都不发起装机（手动更新，11-16）；没碰过开关缺省开（只管首启准备与提示）
    func testShellUpdateNeverAutoInstalls() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-shell-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        let runner = KeptRunner(); runner.kept = []; runner.shellUpdate = true
        let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
        let key = S2ArmLauncherModel.autoUpdatePhoneOffKey, before = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        S2ArmLauncherModel.setAutoUpdatePhone(false)
        let off = await model.keptModulesTick()
        XCTAssertFalse(off, "开关关：壳旧了也不自动更新")
        S2ArmLauncherModel.setAutoUpdatePhone(true); runner.running = true
        let playing = await model.keptModulesTick()
        XCTAssertFalse(playing, "正在玩：不更新")
        runner.running = false
        for _ in 0..<3 {
            let started = await model.keptModulesTick()
            XCTAssertFalse(started, "开关开、没在玩、壳旧了：也只提示、不装")
        }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(runner.updates.count, 0)
        XCTAssertTrue(S2ArmLauncherModel.autoUpdatePhoneOn(UserDefaults(suiteName: "s2arm-fresh-" + UUID().uuidString)!), "没碰过开关：缺省开")
    }

    // 新版启动器首次读到游戏库：有要更新的手机 → 后台 installUpdatePrepare 一次（不碰手机），准备完出横幅 准备好 / 没准备成（都是「点这里更新」，手动更新 11-16）；
    //   开关关 → 不准备、不显示
    func testPrepareBannerAfterLauncherUpdate() async throws {
        _ = NSApplication.shared
        let key = S2ArmLauncherModel.autoUpdatePhoneOffKey, before = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        func run(fails: Bool, on: Bool) async throws -> (S2ArmLauncherModel, KeptRunner) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-prep-" + UUID().uuidString)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
            let runner = KeptRunner(); runner.prepareFails = fails
            runner.catalog = ["games": [[String: Any]](), "phoneDevices": 1,
                              "phoneUpdates": [["device": "dev1", "games": [["gameId": "0100C9C00E25C000", "name": "A"]], "stale": [[String: Any]]()]]]
            S2ArmLauncherModel.setAutoUpdatePhone(on)
            let model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
                privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"), runner: runner))
            model.refresh()
            for _ in 0..<300 where !model.libraryLoaded || (on && model.phoneBanner == nil) { try? await Task.sleep(for: .milliseconds(10)) }
            return (model, runner)
        }
        let (ok, okRunner) = try await run(fails: false, on: true)
        XCTAssertEqual(okRunner.prepared, 1, "有要更新的手机：准备一次")
        XCTAssertEqual(ok.phoneBanner, .ready)
        XCTAssertEqual(ok.phoneBannerLine?.key, "phone.update.banner.ready")
        ok.phoneUpdates = []
        XCTAssertNil(ok.phoneBannerLine, "手机已是本版：横幅收起")
        let (bad, _) = try await run(fails: true, on: true)
        XCTAssertEqual(bad.phoneBannerLine?.key, "phone.update.banner.on_connect", "准备不了：连上时更新")
        let (off, offRunner) = try await run(fails: false, on: false)
        XCTAssertEqual(offRunner.prepared, 0, "开关关：不准备")
        XCTAssertNil(off.phoneBannerLine)
    }
}

private final class KeptRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    var updates: [[String: Any]] = []
    var kept: [String] = []
    var running = false
    var shellUpdate = false
    var prepareFails = false
    var prepared = 0
    var catalog: [String: Any] = [:]
    var catalogs = 0
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        var taskId = "", op = ""
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            taskId = request["taskId"] as? String ?? ""; op = request["operation"] as? String ?? ""
            if op == "installUpdate" { updates.append(request) }
            if op == "installUpdatePrepare" { prepared += 1 }
            if op == "catalog" { catalogs += 1 }
        }
        let result: [String: Any] = op == "phoneKeptPull" ? ["device": "00008160-FIXTURE", "new": kept.count, "kept": kept, "shellUpdate": shellUpdate, "stale": [String](), "running": running]
            : op == "catalog" ? catalog : [:]
        let failed = op == "installUpdatePrepare" && prepareFails
        let event: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": failed ? "failed" : "succeeded", "result": result, "message": failed ? "fixture" : ""]
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(0) }
        return Handle()
    }
}
