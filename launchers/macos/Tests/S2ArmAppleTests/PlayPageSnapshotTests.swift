// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
import AppKit
import SwiftUI
import XCTest
@testable import NX2AppleUI
@testable import S2ArmAppleAdapter

// 启动游戏页（11-11 维护者「太丑、太不 S2Arm」重做）：一局在跑、一局运行中崩了，整窗渲染。
//   会话走真实那条路（model.start → 作业体发阶段事件 / 抛 JobFailure → finish），失败码与下一步要落到会话上；
//   设 S2A_SNAPSHOT_OUT=<目录> 存 play_running.png / play_failed.png 供肉眼核对（修前修后同一夹具对比）。
@MainActor final class PlayPageSnapshotTests: XCTestCase {
    private var root: URL!
    private var model: S2ArmLauncherModel!
    static let rawLog = "游戏运行中失败（退出码 139）：8c54d64a50eaf29f7500b59695e8af; not skippable; storage writes 0; waited for the queued compile 255.0 ms"

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-play-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Jobs"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Jobs/main.py"))
        model = S2ArmLauncherModel(client: JobClient(environment: JobEnvironment(
            privateRoot: root, resources: root, library: root.appendingPathComponent("lib").path, libraryId: "fixture"),
            runner: CatalogRunner()))
        model.refresh()
        for _ in 0..<300 where model.games.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.games.map(\.id), ["0100A"])
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func stage(_ sink: EventSink, _ name: String) {
        sink.emit(EngineEvent(ev: "stage", t: 0, code: nil, severity: .info, fields: ["stage": name, "message": name]))
    }

    func testRunningAndCrashedPages() async throws {
        let session = JobSession(kind: .play, gameID: "0100A", name: "测试游戏")
        model.start(session) { sink in
            self.stage(sink, "验证运行文件"); self.stage(sink, "游戏运行中")
            try await Task.sleep(for: .seconds(30)); return nil
        }
        for _ in 0..<100 where model.session?.stage != "游戏运行中" { try? await Task.sleep(for: .milliseconds(10)) }
        try snapshot("play_running")
        model.stop()
        for _ in 0..<300 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }

        let recovery = "再启动一次试试；还是这样，就在「环境检查」导出诊断包，到 GitHub 发帖附上，我们按崩溃现场修。"
        model.start(session) { sink in
            self.stage(sink, "验证运行文件"); self.stage(sink, "游戏运行中")
            throw JobFailure(JobOutcome(taskId: "t", state: .failed, exitCode: 1, message: Self.rawLog, result: [:],
                                        diagnostics: [["code": "game_crashed", "suggestion": recovery, "summary": Self.rawLog]], stderr: ""))
        }
        for _ in 0..<300 where model.busy { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.session?.failureCode, "game_crashed", "失败码落到会话上，启动页按码说人话")
        XCTAssertEqual(model.session?.suggestion, recovery, "下一步落到会话上")
        try snapshot("play_failed")
    }

    private func snapshot(_ name: String) throws {
        let view = NSHostingView(rootView: S2ArmAppleRootView(model: model, brand: "S2Arm × NX2Apple")
            .frame(width: 1280, height: 720).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view; view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8)); view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        if let o = ProcessInfo.processInfo.environment["S2A_SNAPSHOT_OUT"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: o).appendingPathComponent(name + ".png"))
        }
    }
}

/// 假作业进程：只回游戏库（一款）；别的作业回空结果
private final class CatalogRunner: JobProcessRunner {
    final class Handle: JobProcessHandle { func terminate() {} }
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        var result: [String: Any] = [:]; var taskId = ""
        if let last = arguments.last, last.hasSuffix(".json"), let data = try? Data(contentsOf: URL(fileURLWithPath: last)),
           let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            taskId = request["taskId"] as? String ?? ""
            if request["operation"] as? String == "catalog" {
                result = ["games": [["id": "0100A", "name": "测试游戏", "ready": true, "missing": [], "display": "1.0.0"]], "keys": [:]]
            }
        }
        let event: [String: Any] = ["schema": 1, "taskId": taskId, "type": "result", "state": "succeeded", "result": result, "message": ""]
        DispatchQueue.main.async { onLine(try! JSONSerialization.data(withJSONObject: event)); onExit(0) }
        return Handle()
    }
}
